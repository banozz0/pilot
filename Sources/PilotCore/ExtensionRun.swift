import Darwin
import Foundation
import Synchronization

/// Running an extension command (card agent-bo-95423242, ADR 0010): its program as a direct child through ChildProcess,
/// off the main thread, in its own folder; a Raycast-format command's program is its bundle, which pilot-ext-host runs
/// (ADR 0017). Pilot writes one JSON line on its stdin, `{"type":"run",...}`, and closes it;
/// the program prints JSON lines on stdout. The child gets a small fixed environment, never Pilot's own, so the link
/// token and any key Pilot was started with stay out of it.
public enum ExtensionRun {
    /// A no-view command may take this long, like a script's network call; then it is stopped.
    public static let noViewTimeout: Duration = .seconds(30)

    /// What a no-view run shows: its HUD line (nil when it said nothing) with its sound, its error message, the actions it
    /// printed in order (and how many past the limit were dropped), a timeout or a failed exit.
    public enum Outcome: Equatable, Sendable {
        case hud(String?, sound: String? = nil), error(String), actions([Extension.Item.Action], dropped: Int = 0), timedOut, failed(String)
    }

    /// The most actions one run may print; the rest are dropped and logged.
    public static let mostActions = 8

    /// One line the program prints; anything else it prints is a plain line.
    private struct Message: Decodable { let type: String, text: String?, sound: String?, action: Extension.Item.Action.Line? }

    /// The child's whole environment: HOME, USER and TMPDIR from Pilot's, PATH with the program's folder and Homebrew's
    /// (launchd's does not reach it) before the system's, LANG, and the extension's id.
    static func environment(for command: Extension.Command, from pilot: [String: String]) -> [String: String] {
        pilot.filter { ["HOME", "USER", "TMPDIR"].contains($0.key) }.merging([
            "PATH": ChildProcess.searchPath(for: command.program.path), "LANG": "en_US.UTF-8", "PILOT_EXTENSION_ID": command.id.extension,
        ]) { _, new in new }
    }

    /// What every run message of an extension carries (card agent-bo-95423246): its preference values by name and its
    /// data and cache folders, never in the program's arguments or environment; and Pilot's own defaults (Surfaces v2:
    /// `repos`, Defaults › Folders › Repos, and `terminal`, the terminal app's bundle id), never a token or a variable.
    public struct Inputs: Equatable, Sendable {
        public let preferences: [String: JSONValue], data: URL, cache: URL
        public var pilot: [String: String]
        public init(preferences: [String: JSONValue], data: URL, cache: URL, pilot: [String: String] = [:]) {
            self.preferences = preferences; self.data = data; self.cache = cache; self.pilot = pilot
        }
    }

    /// The line Pilot writes on the command's stdin; a list's carries the search, a surface's which surface asks (story 161),
    /// a run's the text typed or the answer asked for (`input`, Surfaces v2; a Raycast command's first argument, T11).
    /// `answers`: a Raycast host's one-shot run whose stdin Pilot keeps open to answer its asks (T11, `hosted`).
    static func message(_ command: Extension.Command, query: String? = nil, context: JSONValue? = nil,
                        surface: Extension.Surface.Kind? = nil, input: String? = nil, inputs: Inputs, answers: Bool = false) -> Data {
        // A Raycast command hears its own extension's name (environment.extensionName), not the id Pilot keys it by (T28).
        let name = command.runtime == .raycast ? RaycastManifest.name(command.id.extension) : command.id.extension
        var fields: [String: JSONValue] = ["type": .string("run"), "extension": .string(name), "command": .string(command.name),
                                           "preferences": .object(inputs.preferences),
                                           "paths": .object(["data": .string(inputs.data.path), "cache": .string(inputs.cache.path)])]
        fields["query"] = query.map(JSONValue.string)
        fields["context"] = context
        fields["surface"] = surface.map { .string($0.rawValue) }
        fields["input"] = input.map(JSONValue.string)
        fields["pilot"] = inputs.pilot.isEmpty ? nil : .object(inputs.pilot.mapValues(JSONValue.string))
        if answers { fields["answers"] = .bool(true) }
        return line(fields)
    }

    /// One message as a JSON line, its keys sorted.
    static func line(_ fields: [String: JSONValue]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(fields)) ?? Data()) + Data("\n".utf8)
    }

    /// What the command prints, run to its end; throws ChildProcess's TimedOut or Failure, or CancellationError when cancelled.
    public static func output(_ command: Extension.Command, query: String? = nil, context: JSONValue? = nil,
                              surface: Extension.Surface.Kind? = nil, input: String? = nil, inputs: Inputs,
                              environment pilot: [String: String] = ProcessInfo.processInfo.environment,
                              timeout: Duration = noViewTimeout) async throws -> String {
        let (path, arguments, directory) = try launch(command, environment: pilot)
        let env = environment(for: command, from: pilot)
        guard command.runtime == .raycast else {
            let line = message(command, query: query, context: context, surface: surface, input: input, inputs: inputs)
            return try await ChildProcess.run(path, arguments, environment: env, input: line, directory: directory, timeout: timeout)
        }
        // A surface's run (a bar tick, a page) never asks the AI or reads the selection (Q478, T12): only a run with no
        // surface keeps its stdin for answers.
        let answers = surface == nil
        let line = message(command, query: query, context: context, surface: surface, input: input, inputs: inputs, answers: answers)
        return try await hosted(path, arguments, environment: env, input: line, directory: directory, timeout: timeout,
                                extension: command.id.extension, answers: answers)
    }

    /// A Raycast-format view command run once with its first argument filled by `input` (T11), as `list(_:query:…)` runs
    /// one without.
    @concurrent public static func list(_ command: Extension.Command, query: String, input: String?, inputs: Inputs,
                                        environment pilot: [String: String] = ProcessInfo.processInfo.environment,
                                        timeout: Duration = listTimeout) async -> ListOutcome {
        do { return answer(try await output(command, query: query, input: input, inputs: inputs, environment: pilot, timeout: timeout)) }
        catch { return .error(reason(error, timeout: timeout)) }
    }

    // MARK: The host's memory stop (ADR 0017, T4)

    /// The most memory (phys_footprint, Activity Monitor's Memory) a host may use before Pilot kills it: 512 MB, so Brew
    /// Search's 477.6 MB peak runs (Sven, 2026-11-19, Q1, open question 3). MB is MiB, as lean-check counts it.
    public static let memoryStopMB = 512
    public static let memoryStopBytes = UInt64(memoryStopMB) << 20

    /// How long a one-shot host may still run once the last answer to its asks came after its timeout (T11): the host's
    /// own grace (main.swift's 0.5 s) and a little.
    static let answerGrace: Duration = .milliseconds(750)

    /// How often Pilot reads a running host's footprint.
    static let memoryPoll: Duration = .milliseconds(250)

    /// The host passed the memory stop and was killed with every process it started.
    public struct OverMemory: LocalizedError, Equatable {
        public let limitMB: Int
        public var errorDescription: String? { "used more than \(limitMB) MB and was stopped" }
    }

    /// The process's footprint in bytes, as `proc_pid_rusage` reads it; nil once it is gone.
    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let read = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return read == 0 ? info.ri_phys_footprint : nil
    }

    /// Reads `pid`'s footprint every `memoryPoll` until cancelled, and calls `over` once when it passes `limit`. A host
    /// stuck in a synchronous JavaScript loop cannot dodge it: the read and the kill are Pilot's.
    public static func watchMemory(of pid: pid_t, limit: UInt64 = memoryStopBytes, over: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let used = footprint(pid), used > limit { return over() }
                try? await Task.sleep(for: memoryPoll)
            }
        }
    }

    /// A one-shot run of the host, as ChildProcess.run runs a program (stdout to its end, TimedOut past `timeout`, a
    /// failed exit as Failure, cancellation as CancellationError), with its footprint watched: past the stop it is
    /// killed and throws OverMemory. Its stdin stays open for the answers to its asks (T11): each `ask` line is answered
    /// through ExtensionAI for the extension `id`, never kept as output, and while one waits `timeout` waits too (the
    /// AI route's own timeout still ends it); stdin closes once the host is gone. Without `answers` (a surface's run, T12)
    /// stdin closes right after the run message, so the host fails each ask at once, and an ask line is kept as output.
    static func hosted(_ path: String, _ arguments: [String], environment: [String: String], input: Data, directory: URL,
                       timeout: Duration, extension id: String = "", answers: Bool = true) async throws -> String {
        enum Stop { case late, memory, cancelled }
        struct State {
            var session: ChildProcess.Session?, watch: Task<Void, Never>?, stop: Stop?, lines: [String] = [], done = false
            /// Asks waiting for their answers (T11), and whether `timeout` passed while one waited.
            var asking = 0, late = false
            var continuation: CheckedContinuation<String, any Error>?
        }
        let state = Mutex(State()), tool = URL(filePath: path).lastPathComponent
        @Sendable func stop(_ why: Stop) {
            state.withLock { s in
                // Late counts only while it still runs: one that exited is answering, its stderr still draining.
                guard !s.done, s.stop == nil, why != .late || s.session.map({ kill($0.pid, 0) == 0 }) ?? true else { return }
                s.stop = why
                s.session?.stop()
            }
        }
        /// Late, unless an ask is still waiting for its answer: then late `answerGrace` after the last answer.
        @Sendable func late() {
            let waits = state.withLock { s in
                s.late = !s.done && s.asking > 0
                return s.late
            }
            if !waits { stop(.late) }
        }
        @Sendable func received(_ line: String) {
            guard answers, let (number, ask) = ExtensionAI.hostAsk(line) else { return state.withLock { $0.lines.append(line) } }
            state.withLock { $0.asking += 1 }
            Task.detached {
                let answer = await ExtensionAI.answer(number, ask, of: id)
                let lateNow = state.withLock { s in
                    s.asking -= 1
                    if !s.done { s.session?.send(answer) }
                    return s.asking == 0 && s.late
                }
                if lateNow { DispatchQueue.global().asyncAfter(deadline: .now() + answerGrace.inSeconds) { late() } }
            }
        }
        @Sendable func ended(_ status: Int32, _ stderr: String) {
            state.withLock { s in
                guard !s.done, let continuation = s.continuation else { return }
                s.done = true
                s.watch?.cancel()
                s.session?.closeInput()
                switch s.stop {
                case .memory: continuation.resume(throwing: OverMemory(limitMB: memoryStopMB))
                case .late: continuation.resume(throwing: ChildProcess.TimedOut(tool: tool))
                case .cancelled: continuation.resume(throwing: CancellationError())
                case nil:
                    let stdout = s.lines.joined(separator: "\n")
                    if status == 0 { continuation.resume(returning: stdout) }
                    else { continuation.resume(throwing: ChildProcess.Failure(tool: tool, status: status, message: stderr.isEmpty ? stdout : stderr)) }
                }
            }
        }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                let session: ChildProcess.Session
                do {
                    session = try ChildProcess.Session(path, arguments, environment: environment, directory: directory,
                                                       lines: received, ended: ended)
                } catch {
                    state.withLock { $0.done = true }
                    return continuation.resume(throwing: error)
                }
                let watch = watchMemory(of: session.pid) { stop(.memory) }
                let stopped = state.withLock { s in
                    (s.session, s.watch) = (session, watch)
                    if s.done { watch.cancel() }
                    return s.stop
                }
                if stopped != nil { session.stop() }
                session.send(input)
                if !answers { session.closeInput() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.inSeconds) { late() }
            }
        } onCancel: {
            stop(.cancelled)
        }
    }

    /// What starts `command` and where: its own program in its own folder, or for a Raycast-format command (ADR 0017) the
    /// extension host with the prelude and the command's bundle as its arguments, in the extension's folder, where its
    /// `package.json` and `assets/` are, even when the bundle is in `dist/`: `folder` when the caller knows it (an open
    /// view's session, T2), else the one the bundle's place gives.
    static func launch(_ command: Extension.Command, folder: URL? = nil, environment pilot: [String: String]) throws
        -> (path: String, arguments: [String], directory: URL) {
        guard command.runtime == .raycast else { return (command.program.path, [], command.program.deletingLastPathComponent()) }
        guard let (host, prelude) = host(environment: pilot) else { throw NoHost() }
        return (host.path, ["--prelude", prelude.path, command.program.path], folder ?? RaycastManifest.folder(of: command.program))
    }

    /// pilot-ext-host and pilot-ext-prelude.js: the app's Contents/Helpers and Contents/Resources; outside a bundle (the
    /// sandbox host, `swift run`) the folder `PILOT_EXT_HOST` names, holding both; nil when neither has them.
    static func host(environment pilot: [String: String], bundle: URL = Bundle.main.bundleURL) -> (host: URL, prelude: URL)? {
        let bundled = (bundle.appending(path: "Contents/Helpers/\(hostName)"), bundle.appending(path: "Contents/Resources/\(preludeName)"))
        let named = pilot["PILOT_EXT_HOST"].map { folder in
            (URL(filePath: folder).appending(path: hostName), URL(filePath: folder).appending(path: preludeName))
        }
        return [bundled, named].compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.0.path) && FileManager.default.fileExists(atPath: $0.1.path) }
    }

    static let hostName = "pilot-ext-host", preludeName = "pilot-ext-prelude.js"

    /// No extension host in this Pilot, so a Raycast-format command cannot run.
    struct NoHost: LocalizedError { var errorDescription: String? { "needs the extension host, which this Pilot does not have" } }

    /// Runs a no-view command and says what it showed.
    public static func noView(_ command: Extension.Command, context: JSONValue? = nil, input: String? = nil, inputs: Inputs,
                              environment pilot: [String: String] = ProcessInfo.processInfo.environment,
                              timeout: Duration = noViewTimeout) async -> Outcome {
        do { return outcome(of: try await output(command, context: context, input: input, inputs: inputs, environment: pilot, timeout: timeout)) }
        catch is ChildProcess.TimedOut { return .timedOut }
        catch {
            return .failed(String(((error as? ChildProcess.Failure)?.message ?? error.localizedDescription).prefix(200)))
        }
    }

    /// The first error message; else every action message in printed order, the first eight; else the last HUD message
    /// with its sound; else the last plain line, as a script's; else nothing. A message of a type Pilot does not know is
    /// skipped.
    public static func outcome(of output: String) -> Outcome {
        var hud: String?, sound: String?, actions: [Extension.Item.Action] = [], plain: [Substring] = []
        let decoder = JSONDecoder()
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.first == "{", let message = try? decoder.decode(Message.self, from: Data(line.utf8)) else {
                plain.append(line)
                continue
            }
            switch message.type {
            case "error": return .error(message.text ?? "")
            case "hud": (hud, sound) = (message.text, Extension.sound(message.sound))
            case "action":
                guard let known = message.action.flatMap(Extension.Item.Action.init) else { return .error("sent an action Pilot does not know") }
                actions.append(known)
            default: continue
            }
        }
        if !actions.isEmpty { return .actions(Array(actions.prefix(mostActions)), dropped: max(actions.count - mostActions, 0)) }
        if let hud { return .hud(hud, sound: sound) }
        return .hud(ScriptCommand.lastLine(plain.joined(separator: "\n")))
    }
}
