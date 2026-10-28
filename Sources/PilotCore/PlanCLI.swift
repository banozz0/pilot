import Foundation
import Synchronization

/// The ChatGPT subscription route (SPEC story 162, Sven 2026-10-10: "we should support all subscriptions"): OpenAI's
/// `codex` command line on the login it keeps in Pilot's own Codex home (AICommand.codexHome, Q203), run as a child whose
/// JSON lines Pilot reads. Connect runs
/// codex's own sign-in, which opens ChatGPT's page in the browser. Pilot never reads, copies or keeps its tokens: codex
/// is asked `codex login status`.
public struct PlanCLI: Sendable {
    /// Runs a child with arguments, environment and stdin, handing each stdout line on: ChildProcess in Pilot, a fake
    /// in tests.
    public typealias Spawn = @Sendable (_ path: String, _ arguments: [String], _ environment: [String: String], _ input: Data?,
                                        _ timeout: Duration, _ line: @escaping @Sendable (String) -> Void) async throws -> String

    public let provider: AIProvider
    public let path: String
    /// How long one answer may take before the child is killed.
    public var timeout: Duration
    /// The model picked on the AI page; nil runs the CLI's own default.
    public var model: String?
    /// The effort picked on the AI page; codex alone takes one.
    public var effort: AIEffort = .low
    var spawn: Spawn

    public init(_ provider: AIProvider, path: String, timeout: Duration = .seconds(120), model: String? = nil, spawn: @escaping Spawn = PlanCLI.child) {
        self.provider = provider; self.path = path; self.timeout = timeout; self.model = model; self.spawn = spawn
    }

    /// The real child, in the CLIs' own empty folder (AICommand.folder).
    public static let child: Spawn = { path, arguments, environment, input, timeout, line in
        try await ChildProcess.run(path, arguments, environment: environment, input: input, directory: AICommand.folder, timeout: timeout,
                                   lines: line)
    }

    /// The CLI's command on the PATH, else in the folders Install looks in, as ClaudeCLI finds `claude`.
    public static func locate(_ provider: AIProvider, path: String?,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> PlanCLI? {
        guard provider.isPlan, let command = provider.command else { return nil }
        return AICommand.find(command, path: path, isExecutable: isExecutable).map { PlanCLI(provider, path: $0) }
    }

    // MARK: Command lines

    /// The instruction, which the CLI takes as an argument; the text goes on stdin, never in an argument (`ps` lists
    /// those). codex appends stdin after it as a `<stdin>` block.
    public static func prompt(for job: QuickAI.Job) -> String { prompt(job.prompt) }

    static func prompt(_ instruction: String) -> String { instruction + " The user's message is the <stdin> block below." }

    /// `codex exec --help` (0.162.1): JSON lines, no saved session, outside a git repository, the person's config and
    /// its MCP servers left out (the login still applies), a read-only sandbox, the AI page's reasoning effort (low by
    /// default).
    public static func arguments(_ provider: AIProvider, for job: QuickAI.Job, model: String? = nil, effort: AIEffort = .low) -> [String] {
        arguments(provider, instruction: job.prompt, keep: false, model: model, effort: effort)
    }

    /// The first run's command line: codex's thread kept (`keep`, no `--ephemeral`) for a chat to resume.
    /// `image` is a picture's file (`--image`, story 191), right after `--json`: the flag takes several files, so a flag
    /// must follow it, never the prompt.
    static func arguments(_ provider: AIProvider, instruction: String, keep: Bool, model: String?, effort: AIEffort, image: String? = nil) -> [String] {
        ["exec", "--json"] + imageFlag(image) + (keep ? [] : ["--ephemeral"]) + ["--skip-git-repo-check", "--ignore-user-config", "--sandbox", "read-only",
            "--color", "never", "-c", "model_reasoning_effort=\"\(effort.rawValue)\""] + (model.map { ["--model", $0] } ?? []) + [prompt(instruction)]
    }

    /// AI chat's command lines (story 166). codex's first turn is the one-shot's without `--ephemeral`, so its thread is
    /// kept; a later turn is `codex exec resume` on that thread (`codex exec resume --help`, 0.162.1: no `--sandbox` or
    /// `--color` there, so the sandbox goes as config), the message on stdin through `-`.
    /// The instruction carries the time; codex's resumed thread keeps its first, so its message does (AIChat.Request.text).
    public static func chatArguments(_ provider: AIProvider, session: String?, model: String? = nil, effort: AIEffort = .low,
                                     now: AIChat.Now = .current, image: String? = nil) -> [String] {
        guard let session else {
            return arguments(provider, instruction: AIChat.prompt(at: now), keep: true, model: model, effort: effort, image: image)
        }
        return ["exec", "resume", "--json"] + imageFlag(image) + ["--skip-git-repo-check", "--ignore-user-config", "-c", "model_reasoning_effort=\"\(effort.rawValue)\"",
                "-c", "sandbox_mode=\"read-only\""] + (model.map { ["--model", $0] } ?? []) + [session, "-"]
    }

    static func imageFlag(_ path: String?) -> [String] { path.map { ["--image", $0] } ?? [] }

    /// codex's thread id (`thread.started`), which the next chat turn resumes.
    public static func thread(_ line: String) -> String? {
        guard line.contains("thread.started"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "thread.started" else { return nil }
        return object["thread_id"] as? String
    }

    /// The child's environment: the tool PATH, codex's own folder first, and Pilot's own Codex home (Q203), so every
    /// codex run, the sign-in included, keeps to it and never reads ~/.codex.
    public static func environment(_ path: String) -> [String: String] {
        var environment = ChildProcess.toolEnvironment(path)
        environment["CODEX_HOME"] = AICommand.codexHome.path
        return environment
    }

    /// The sign-in: `codex login` serves its callback and opens ChatGPT's sign-in page; its login lands in Pilot's Codex home.
    public static let login = ["login"]

    // MARK: Models

    /// The models codex offers in its own picker (`codex debug models`, 0.162.1: `{"models":[{slug, visibility,
    /// priority}]}`), in its order; nil when the output is no catalog.
    public static func models(_ catalog: String) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        return models.filter { $0["visibility"] as? String == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { $0["slug"] as? String }
    }

    /// Refresh on codex: its catalog, which codex keeps fresh with its own login (Pilot reads only the list it prints).
    public func models() async throws(QuickAI.Failure) -> [String] {
        let out: String
        do {
            out = try await spawn(path, ["debug", "models"], Self.environment(path), nil, .seconds(20)) { _ in }
        } catch {
            throw await failure(error, said: nil)
        }
        guard let ids = Self.models(out) else { throw .api(provider, "codex's model list came back in a shape Pilot does not read.") }
        return ids
    }

    // MARK: Output

    /// One JSON line. codex (`exec --json`): the agent's message whole in an `item.completed`, then `turn.completed`, or
    /// `turn.failed` whose message may be the API's JSON error; its `error` lines are retries, never parsed.
    public static func event(_ provider: AIProvider, _ line: String) -> AIStreamEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        switch (provider, object["type"] as? String) {
        case (.codex, "item.completed"):
            guard let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message", let text = item["text"] as? String
            else { return nil }
            return .text(text)
        case (.codex, "turn.completed"):
            return .stop("done")
        case (.codex, "turn.failed"):
            let said = (object["error"] as? [String: Any])?["message"] as? String
            return .error(said.map { AIStream.message($0) ?? $0 } ?? "the turn failed")
        default:
            return nil
        }
    }

    // MARK: Runs

    /// Runs the job, handing each piece of the answer to `text` as it arrives; returns the whole answer. codex hands its
    /// message over whole, so it shows at once.
    public func run(_ job: QuickAI.Job, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> String {
        try await stream(Self.arguments(provider, for: job, model: model, effort: effort), input: job.text, text: text).answer
    }

    /// One chat turn (story 166): codex resumes its thread; with no thread of this conversation it is sent the earlier
    /// turns written out before the message.
    /// A picture goes as a file of its own in codex's folder, `--image`'s, removed once the turn ends.
    public func chat(_ request: AIChat.Request, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> AIChat.Reply {
        let session = request.session(for: provider)
        var picture: URL?
        if let image = request.image {
            let file = AICommand.folder.appending(path: "pilot-ask-\(UUID().uuidString).\(image.fileExtension)")
            do { try image.data.write(to: file, options: .atomic) } catch { throw .api(provider, "Pilot could not hand the picture over: \(error.localizedDescription)") }
            picture = file
        }
        defer { picture.map { try? FileManager.default.removeItem(at: $0) } }
        let got = try await stream(Self.chatArguments(provider, session: session, model: model, effort: effort, now: request.now, image: picture?.path),
                                   input: request.text(for: provider), text: text)
        return AIChat.Reply(got.answer, session: (got.thread ?? session).map { AIChat.Session(provider, $0) })
    }

    private func stream(_ arguments: [String], input: String,
                        text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> (answer: String, thread: String?) {
        let got = Mutex<(answer: String, stop: Bool, error: String?, thread: String?)>(("", false, nil, nil))
        do {
            _ = try await spawn(path, arguments, Self.environment(path), Data(input.utf8), timeout) { line in
                if let thread = Self.thread(line) { got.withLock { $0.thread = thread } }
                switch Self.event(provider, line) {
                case .text(let piece):
                    // codex's messages come whole; a second one starts a paragraph.
                    let piece = got.withLock { g in
                        let piece = g.answer.isEmpty ? piece : "\n\n" + piece
                        g.answer += piece
                        return piece
                    }
                    text(piece)
                case .stop: got.withLock { $0.stop = true }
                case .error(let why): got.withLock { $0.error = $0.error ?? why }
                case nil: break
                }
            }
        } catch {
            throw await failure(error, said: got.withLock { $0.error })
        }
        let (answer, stopped, said, thread) = got.withLock { $0 }
        if let said { throw .api(provider, said) }
        guard stopped else { throw .api(provider, "the answer broke off") }
        return (answer, thread)
    }

    /// A failed child as Quick AI's failure: stopped, out of time, signed out, or the CLI's own words.
    func failure(_ error: any Error, said: String?) async -> QuickAI.Failure {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        if error is ChildProcess.TimedOut { return .timedOut }
        let exit = error as? ChildProcess.Failure
        if await !signedIn() { return .notConnected(provider) }
        return .api(provider, said ?? exit.flatMap { ScriptCommand.lastLine($0.message) } ?? error.localizedDescription)
    }

    /// Whether the CLI has a login: `codex login status` exits 0 signed in and 1 not ("Not logged in"), true when it
    /// cannot tell so the run's own message shows.
    public func signedIn() async -> Bool {
        do {
            _ = try await spawn(path, ["login", "status"], Self.environment(path), nil, .seconds(10)) { _ in }
            return true
        } catch {
            return (error as? ChildProcess.Failure)?.status != 1
        }
    }

    /// Connect: the CLI's own sign-in in the browser, then whether it took, up to 10 minutes.
    public func connect() async throws(QuickAI.Failure) {
        let said = Mutex<String?>(nil)
        do {
            _ = try await spawn(path, Self.login, Self.environment(path), nil, .seconds(600)) { line in
                if case .error(let why) = Self.event(provider, line) { said.withLock { $0 = $0 ?? why } }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw .cancelled }
            if error is ChildProcess.TimedOut { throw .notConnected(provider) }
            if await signedIn() { return }
            let why = said.withLock { $0 } ?? (error as? ChildProcess.Failure).flatMap { ScriptCommand.lastLine($0.message) }
            throw .api(provider, "Sign-in did not finish" + (why.map { ": \($0)" } ?? "."))
        }
        guard await signedIn() else { throw .notConnected(provider) }
    }
}

/// Where Quick AI's command lines are found: Pilot runs with launchd's short PATH, and Install and Quick AI must agree
/// on whether a command is there.
public enum AICommand {
    /// The CLIs' working folder, made if missing: codex reads its working folder, and
    /// claude's chat keeps the sessions it resumes under it (story 166).
    public static var folder: URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-ai", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Pilot's own Codex home (Q203, CODEX_HOME for every codex run): its sign-in, threads and logs, apart from the
    /// person's ~/.codex, whose instructions, skills, hooks and login Pilot never reads. Private; made if missing. Pilot
    /// writes nothing in it: codex keeps it, and Pilot's guide goes on the command line (AIChat.Agent.codexLock).
    public static var codexHome: URL {
        let folder = PilotFolder.support.appending(path: "codex", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// `command` on `path` (the PATH), else in the folders Install looks in (CatalogueEntry.Check.commandFolders).
    public static func find(_ command: String, path: String?, isExecutable: (String) -> Bool) -> String? {
        let onPath = (path ?? "").split(separator: ":").map { "\($0)/\(command)" }
        return onPath.first(where: isExecutable) ?? CatalogueEntry.Check.copies(of: command, isExecutable: isExecutable).first
    }
}
