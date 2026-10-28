import Foundation
import PilotGate
import Synchronization

/// AI chat (SPEC story 166, Sven 2026-10-10: "a small chat window … kind of a notch from top bar"): a conversation, not
/// one question and answer, through the provider picked on the AI page. The Claude Code CLI resumes its own saved
/// session (`--resume`), codex its thread (`codex exec resume`); the APIs are sent the whole history; a CLI whose
/// session belongs to another provider gets the earlier turns written out before the new message.
public enum AIChat {
    /// Runs one turn, handing each piece of the answer on as it arrives: ClaudeCLI.chat, PlanCLI.chat, AnthropicAPI.chat
    /// or OpenAIChat.chat.
    public typealias Runner = @Sendable (Request, @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> Reply

    /// A provider set up from the AI page that answers both ways: Quick AI's one-shot and a chat turn.
    public protocol Route: Sendable {
        func run(_ job: QuickAI.Job, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> String
        func chat(_ request: Request, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> Reply
    }

    public static let prompt = "You chat with the user in a small panel on their Mac. Answer directly and keep it short unless "
        + "they ask for more; use Markdown for code. No preamble and no offers to help further."

    /// The chat's prompt with the moment the turn is sent.
    public static func prompt(at now: Now) -> String { prompt + " " + now.line }

    /// When a turn is sent, as the model is told it (Sven 2026-10-10: "whats the time in uk right now" got "I can't see
    /// the current time"): every prompt carries it, read fresh for each turn and each Quick AI job.
    public struct Now: Equatable, Sendable {
        public var date: Date
        public var timeZone: TimeZone
        public var locale: Locale

        public init(_ date: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current) {
            self.date = date; self.timeZone = timeZone; self.locale = locale
        }

        /// This Mac's clock, zone and locale as they are now.
        public static var current: Now { Now() }

        /// "It is now Saturday 10 October 2026, 14:32 local time (time zone Europe/Malta, UTC+02:00); the user's locale
        /// is en_MT."
        public var line: String {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = timeZone
            format.dateFormat = "EEEE d MMMM yyyy, HH:mm"
            let seconds = timeZone.secondsFromGMT(for: date), minutes = abs(seconds) / 60
            let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", minutes / 60, minutes % 60)
            return "It is now \(format.string(from: date)) local time (time zone \(timeZone.identifier), \(offset)); "
                + "the user's locale is \(locale.identifier)."
        }
    }

    /// When the chat starts over by itself: after this long with no turn, the next open is a new chat (Sven 2026-10-10).
    public enum Reset: String, CaseIterable, Sendable {
        case never, minutes15, minutes30, hour1, hours4

        public static let standard = Reset.minutes30

        public var title: String {
            switch self {
            case .never: "Never"
            case .minutes15: "15 min"
            case .minutes30: "30 min"
            case .hour1: "1 h"
            case .hours4: "4 h"
            }
        }

        public var interval: TimeInterval? {
            switch self {
            case .never: nil
            case .minutes15: 15 * 60
            case .minutes30: 30 * 60
            case .hour1: 60 * 60
            case .hours4: 4 * 60 * 60
            }
        }

        /// Whether a chat last used at `last` starts over at `now`.
        public func expired(last: Date, now: Date) -> Bool {
            interval.map { now.timeIntervalSince(last) >= $0 } ?? false
        }
    }

    public struct Turn: Equatable, Sendable {
        public enum Role: String, Sendable { case user, assistant }
        public let role: Role
        public var text: String
        /// A picture sent with the message: a capture asked about (story 191).
        public var image: Image?

        public init(_ role: Role, _ text: String, image: Image? = nil) { self.role = role; self.text = text; self.image = image }
    }

    /// A picture sent with a message (story 191, Ask AI about a capture): its bytes, already sized to send
    /// (CaptureAskAI.picture), and their type. Every route takes one: claude's stream-json input, codex's `--image`, the
    /// Messages API's image block, Chat Completions' data URL; Ollama and an endpoint only on a model that reads images.
    public struct Image: Equatable, Sendable {
        /// Which picture it is: two are the same picture when their ids are, never a compare of their bytes.
        public let id = UUID()
        public let data: Data
        public let mediaType: String
        /// Encoded once: an API route sends it again with every later turn.
        public let base64: String

        public init(_ data: Data, mediaType: String = "image/png") {
            self.data = data; self.mediaType = mediaType; base64 = data.base64EncodedString()
        }

        public static func == (a: Image, b: Image) -> Bool { a.id == b.id }

        /// `data:image/png;base64,…`, as Chat Completions' `image_url` takes it.
        public var dataURL: String { "data:\(mediaType);base64,\(base64)" }
        /// The Messages API's image block, which claude's stream-json input takes too.
        public var anthropicBlock: [String: Any] {
            ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64]]
        }
        /// The file name codex's `--image` reads it from.
        public var fileExtension: String { mediaType == "image/jpeg" ? "jpg" : "png" }
    }

    /// A starter over the chat's input while a capture waits to be asked about (story 191): its chip's title, and the
    /// message a click sends with the picture.
    public struct Starter: Equatable, Sendable {
        public let title: String
        public let prompt: String

        public init(_ title: String, _ prompt: String) { self.title = title; self.prompt = prompt }

        /// Explain this error, Translate (into the Mac's language, named in English) and Extract text.
        public static func capture(language: String) -> [Starter] {
            [Starter("Explain this error", "Explain the error in this capture: what went wrong, and how do I fix it?"),
             Starter("Translate", "Translate the text in this capture into \(language). Reply with the translation only."),
             Starter("Extract text", "Write out all the text in this capture exactly as it reads, keeping its line breaks. Reply with the text only.")]
        }

        /// The Mac's language in English ("Spanish"), English when it has none.
        public static func language(_ locale: Locale = .current) -> String {
            locale.language.languageCode.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0.identifier) } ?? "English"
        }
    }

    /// A CLI's own saved conversation, with the provider that keeps it.
    public struct Session: Equatable, Sendable {
        public let provider: AIProvider
        public let id: String

        public init(_ provider: AIProvider, _ id: String) { self.provider = provider; self.id = id }
    }

    /// One turn to send: the turns before it, the new message, the session the last answer came from, and when it is
    /// sent.
    public struct Request: Equatable, Sendable {
        public var history: [Turn]
        public var message: String
        /// A picture sent with the message.
        public var image: Image?
        public var session: Session?
        public var now: Now

        public init(history: [Turn] = [], message: String, image: Image? = nil, session: Session? = nil, now: Now = .current) {
            self.history = history; self.message = message; self.image = image; self.session = session; self.now = now
        }

        /// The system prompt for this turn.
        public var prompt: String { AIChat.prompt(at: now) }

        /// Every turn with the new message last: what an API is sent, each picture with its turn.
        public var turns: [Turn] { history + [Turn(.user, message, image: image)] }

        /// The session's id when `provider` keeps it.
        public func session(for provider: AIProvider) -> String? { session?.provider == provider ? session?.id : nil }

        /// What a CLI is sent: the message alone when there is nothing before it; on a session it resumes, the time
        /// first, since claude and codex keep the prompt of the session's first run (claude 2.1.296 ignores a resumed
        /// run's --system-prompt and --append-system-prompt, tried 2026-10-10); else the earlier turns written out first.
        public func text(for provider: AIProvider) -> String {
            if session(for: provider) != nil { return "(\(now.line))\n\n\(message)" }
            guard !history.isEmpty else { return message }
            let earlier = history.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n\n")
            return "Earlier in this conversation:\n\n\(earlier)\n\nThe user's new message:\n\n\(message)"
        }
    }

    public struct Reply: Equatable, Sendable {
        public var answer: String
        /// The session to resume next turn; nil for a route that keeps none.
        public var session: Session?

        public init(_ answer: String, session: Session? = nil) { self.answer = answer; self.session = session }
    }

    /// The conversation as it stands: the turns asked and answered, the session to resume, and the message on its way.
    public struct Conversation: Equatable, Sendable {
        public private(set) var turns: [Turn] = []
        public private(set) var session: Session?

        public init() {}

        /// The request for `message` and its picture, which show at once as the user's turn.
        public mutating func send(_ message: String, image: Image? = nil, now: Now = .current) -> Request {
            let request = Request(history: answeredTurns, message: message, image: image, session: session, now: now)
            turns.append(request.turns[request.turns.count - 1])
            return request
        }

        /// The answer to the last message, and the session it came from.
        public mutating func answered(_ reply: Reply) {
            turns.append(Turn(.assistant, reply.answer))
            if let next = reply.session { session = next }
        }

        /// A turn that came back with no answer (stopped, failed): the message stays, unanswered, and the history the
        /// next request carries leaves it out, so the API's roles still alternate.
        public var answeredTurns: [Turn] {
            var out: [Turn] = []
            for turn in turns {
                if turn.role == .user, out.last?.role == .user { out.removeLast() }
                out.append(turn)
            }
            if out.last?.role == .user { out.removeLast() }
            return out
        }

        public mutating func clear() { self = Conversation() }
    }
}

extension ClaudeCLI: AIChat.Route {}
extension PlanCLI: AIChat.Route {}
extension AnthropicAPI: AIChat.Route {}
extension OpenAIChat: AIChat.Route {}

// MARK: Agent (AI helper T14)

extension AIChat {
    /// What an agent turn hands on as it goes: its words, each command it runs and what came back, the session to resume
    /// and its end. Tool calls and results pair by id.
    public enum AgentEvent: Equatable, Sendable {
        case text(String)
        case toolCall(id: String, command: String)
        case toolResult(id: String, output: String, isError: Bool)
        /// claude's session (its `result` line), codex's thread (`thread.started`).
        case session(String)
        /// The turn ended: claude's whole answer, or nil for codex, whose words come whole in `text`; or the error.
        case done(String?, isError: Bool)
    }

    /// A chat turn that may act (spec pilot-ai-helper T14): Claude Code with one tool, the shell, limited to the `pilot`
    /// command, or Codex with one MCP tool that runs it (pilot-mcp, Q203); `pilot` drives Pilot over its socket (ADR 0013). Every call and result is handed on, so the
    /// chat can show what it ran. API-key providers act through Pilot's own loop instead (APIAgent, Q193).
    public struct Agent: Sendable {
        public let provider: AIProvider
        /// The CLI.
        public let path: String
        /// The system prompt, `Packaging/pilot-agent.md` in the bundle's Resources.
        public let prompt: URL
        /// Where `pilot` is: the bundle's Contents/Helpers, first on the child's PATH so it resolves without the link.
        public let helpers: URL
        public var model: String?
        public var effort: AIEffort
        /// How long one turn may take, its tool calls included, before the child tree is killed.
        public var timeout: Duration
        /// What claude may use besides `pilot`.
        public var reach: Reach
        var spawn: PlanCLI.Spawn

        /// What an agent turn may touch: `pilot` alone (the chat), or also the file tools (/extension, T17), which
        /// `--restricted` confines to the child's working folder.
        public enum Reach: Sendable { case pilot, files }

        /// nil for a provider with no agent: only the two subscriptions run tools, and only claude the file tools.
        public init?(_ provider: AIProvider, path: String, prompt: URL, helpers: URL, model: String? = nil, effort: AIEffort = .low,
                     timeout: Duration = .seconds(300), reach: Reach = .pilot, spawn: @escaping PlanCLI.Spawn = PlanCLI.child) {
            guard provider == .claudeCode || provider == .codex && reach == .pilot else { return nil }
            self.provider = provider; self.path = path; self.prompt = prompt; self.helpers = helpers; self.model = model
            self.effort = effort; self.timeout = timeout; self.reach = reach; self.spawn = spawn
        }

        // MARK: Command lines

        /// `claude --help` (2.1.296, checked 2026-10-11): the shell alone, allowed only for `pilot …`, anything else
        /// refused unasked (dontAsk), save read-only commands chained after it, which Pilot's shell gate refuses
        /// (`environment`); no MCP servers. `--restricted` keeps the person's settings files out: run without
        /// it, the turn loaded Sven's CLAUDE.md, memory, output style and SessionStart hooks (probes E–I, 2026-10-11).
        /// `--safe-mode` is the second lock (Sven, 2026-10-11): its help names what it turns off (CLAUDE.md, skills,
        /// plugins, hooks, MCP, custom commands and agents, output styles), where `--restricted`'s names only settings
        /// files; the shell and the `pilot` allow-list still work under both (probe C2, 2026-10-11). Never `--bare`,
        /// which needs an API key, not the subscription. The message goes on stdin. With `.files` (T17) Read, Write and
        /// Edit join, allowed by name, since dontAsk refuses a tool no rule allows; `--restricted` confines them to the
        /// working folder, refusing an absolute path, `../` or a symlink out of it (probe B, 2026-10-12).
        public static func claudeArguments(prompt: String, session: String?, model: String?, effort: AIEffort, reach: Reach = .pilot) -> [String] {
            let files = reach == .files ? ["Read", "Write", "Edit"] : []
            return ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--tools", (["Bash"] + files).joined(separator: ","),
                    "--allowedTools", "Bash(pilot *)"] + files + ["--permission-mode", "dontAsk", "--strict-mcp-config", "--restricted",
                    "--safe-mode", "--append-system-prompt-file", prompt, "--effort", effort.rawValue]
                + (session.map { ["--resume", $0] } ?? []) + (model.map { ["--model", $0] } ?? [])
        }

        /// `codex exec --help` (0.163.0, checked 2026-10-16): JSON lines, its config and rules left out, a read-only sandbox,
        /// never asking; a later turn resumes the thread (`exec resume` takes no `-C` or `-s`, so the sandbox goes as config).
        /// The message on stdin through `-`. It runs in Pilot's own Codex home (AICommand.codexHome, codexEnvironment), so
        /// ~/.codex, its AGENTS.md, skills, hooks and login are never read (Q203). Its one tool is `pilot` (codexLock).
        public static func codexArguments(directory: String, session: String?, model: String?, effort: AIEffort, instructions: String,
                                          helpers: URL) -> [String] {
            let shared = ["--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "-c", #"approval_policy="never""#,
                          "-c", "model_reasoning_effort=\"\(effort.rawValue)\""] + codexLock(instructions: instructions, helpers: helpers)
                + (model.map { ["--model", $0] } ?? [])
            guard let session else { return ["exec"] + shared + ["-C", directory, "-s", "read-only", "-"] }
            return ["exec", "resume"] + shared + ["-c", #"sandbox_mode="read-only""#, session, "-"]
        }

        /// What holds codex to `pilot` (Q203, probes on codex-cli 0.163.0 against a fake model server, 2026-10-16): every
        /// tool off but MCP (the tools array it sent then held only the MCP resource readers, the Plan-mode question tool and
        /// `pilot`; a call to its shell came back "unsupported call" unrun), and one MCP server, the bundle's pilot-mcp,
        /// which codex starts itself outside its sandbox and whose one tool runs one gated `pilot` call (AgentGate); its
        /// calls pre-approved, since approval_policy never refuses an MCP call that asks, and Pilot's own plan card and
        /// Allow hold the changes. Pilot's guide goes as developer_instructions, which a resumed thread keeps once. Every
        /// turn passes the whole lock: a resumed thread given less gets its tools back.
        static func codexLock(instructions: String, helpers: URL) -> [String] {
            let off = ["shell_tool", "unified_exec", "view_image", "multi_agent", "goals", "apps", "plugins", "hooks", "computer_use",
                       "browser_use", "image_generation", "memories"]
            let server = "{command=\(toml(helpers.appending(path: "pilot-mcp").path)),args=[\(toml(helpers.appending(path: "pilot").path))],"
                + #"default_tools_approval_mode="approve"}"#
            return off.flatMap { ["--disable", $0] } + ["-c", #"web_search="disabled""#, "-c", "skills.include_instructions=false",
                                                        "-c", "developer_instructions=" + toml(instructions), "-c", "mcp_servers.pilot=" + server]
        }

        /// A TOML basic string: JSON's escapes are TOML's.
        static func toml(_ text: String) -> String {
            (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }

        // MARK: Output

        /// One line of claude's `stream-json`: the text deltas and the result with its session as Quick AI reads them
        /// (QuickAI.event), plus the tool calls in each assistant message and the tool results in the user message that
        /// follows. The init, message start and stop, thinking and rate-limit lines say nothing.
        public static func claudeEvents(_ line: String) -> [AgentEvent] {
            switch QuickAI.event(line) {
            case .text(let piece): return [.text(piece)]
            case .result(let answer, let isError): return (QuickAI.session(line).map { [.session($0)] } ?? []) + [.done(answer, isError: isError)]
            case nil: break
            }
            guard line.contains("tool_"), let object = json(line) else { return [] }
            switch object["type"] as? String {
            case "assistant":
                return blocks(object).compactMap { block in
                    guard block["type"] as? String == "tool_use", let id = block["id"] as? String else { return nil }
                    return .toolCall(id: id, command: call(block))
                }
            case "user":
                return blocks(object).compactMap { block in
                    guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                    return .toolResult(id: id, output: text(of: block["content"]), isError: block["is_error"] as? Bool ?? false)
                }
            default:
                return []
            }
        }

        /// One line of codex's `exec --json`: the thread, its messages whole and the turn's end as the chat reads them
        /// (PlanCLI.thread, PlanCLI.event), plus each `pilot` call (an `mcp_tool_call`) or command as it starts and ends
        /// (a non-zero exit, an error or a status other than completed is an error).
        public static func codexEvents(_ line: String) -> [AgentEvent] {
            if let thread = PlanCLI.thread(line) { return [.session(thread)] }
            switch PlanCLI.event(.codex, line) {
            case .text(let piece): return [.text(piece)]
            case .stop: return [.done(nil, isError: false)]
            case .error(let why): return [.done(why, isError: true)]
            case nil: break
            }
            if line.contains("mcp_tool_call"), let object = json(line), let item = object["item"] as? [String: Any],
               item["type"] as? String == "mcp_tool_call" { return mcpEvents(object["type"] as? String, item) }
            guard line.contains("command_execution"), let object = json(line), let item = object["item"] as? [String: Any] else { return [] }
            let id = item["id"] as? String ?? ""
            switch object["type"] as? String {
            case "item.started":
                return [.toolCall(id: id, command: command(item["command"] as? String ?? ""))]
            case "item.completed":
                let failed = (item["exit_code"] as? Int).map { $0 != 0 } ?? false || item["status"] as? String != "completed"
                return [.toolResult(id: id, output: item["aggregated_output"] as? String ?? "", isError: failed)]
            default:
                return []
            }
        }

        /// An MCP call's start (its command, else its server and tool) or end (its text, else its error).
        static func mcpEvents(_ type: String?, _ item: [String: Any]) -> [AgentEvent] {
            let id = item["id"] as? String ?? ""
            switch type {
            case "item.started":
                let command = (item["arguments"] as? [String: Any])?["command"] as? String
                return [.toolCall(id: id, command: command ?? "\(item["server"] as? String ?? "") \(item["tool"] as? String ?? "")")]
            case "item.completed":
                let content = (item["result"] as? [String: Any])?["content"]
                let output = content.map { text(of: $0) } ?? (item["error"] as? [String: Any])?["message"] as? String ?? ""
                return [.toolResult(id: id, output: output, isError: item["status"] as? String != "completed")]
            default:
                return []
            }
        }

        /// A tool call as its row names it: the shell's command, else the tool with the file it reads or writes, by its
        /// folder and name ("Write ports/main.py").
        static func call(_ block: [String: Any]) -> String {
            let input = block["input"] as? [String: Any], name = block["name"] as? String ?? "tool"
            if let command = input?["command"] as? String { return command }
            guard let path = input?["file_path"] as? String else { return name }
            return name + " " + (path as NSString).pathComponents.suffix(2).joined(separator: "/")
        }

        /// codex wraps each command in the login shell (`/bin/zsh -lc 'pilot ping'`); the command as the model wrote it.
        static func command(_ wrapped: String) -> String {
            guard let quote = wrapped.range(of: " -lc '"), wrapped.hasSuffix("'"), wrapped.distance(from: quote.upperBound, to: wrapped.endIndex) > 0
            else { return wrapped }
            return String(wrapped[quote.upperBound..<wrapped.index(before: wrapped.endIndex)]).replacingOccurrences(of: #"'\''"#, with: "'")
        }

        static func json(_ line: String) -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }

        static func blocks(_ object: [String: Any]) -> [[String: Any]] {
            (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        }

        /// A tool result's content: a string, or text blocks.
        static func text(of content: Any?) -> String {
            if let string = content as? String { return string }
            return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        // MARK: Runs

        /// One turn: claude resumes its session; codex its thread, the prompt as its developer instructions (codexLock).
        /// Hands each event on as it arrives, on the reading thread; codex's second message onwards starts a paragraph, so
        /// the text handed on is the answer returned.
        public func turn(_ request: Request, event: @escaping @Sendable (AgentEvent) -> Void) async throws(QuickAI.Failure) -> Reply {
            let session = request.session(for: provider)
            let input = request.text(for: provider)
            let arguments: [String], environment: [String: String]
            if provider == .claudeCode {
                arguments = Self.claudeArguments(prompt: prompt.path, session: session, model: model, effort: effort, reach: reach)
                environment = Self.environment(cli: path, helpers: helpers)
            } else {
                guard let instructions = try? String(contentsOf: prompt, encoding: .utf8) else { throw .failed("Pilot's agent prompt is missing") }
                arguments = Self.codexArguments(directory: AICommand.folder.path, session: session, model: model, effort: effort,
                                                instructions: instructions, helpers: helpers)
                environment = Self.codexEnvironment(cli: path)
            }
            // claude's answer is its result line; codex's, its messages as handed on.
            let got = Mutex<(text: String, done: (said: String?, isError: Bool)?, session: String?)>(("", nil, nil))
            let parse = provider == .claudeCode ? Self.claudeEvents : Self.codexEvents
            do {
                _ = try await spawn(path, arguments, environment, Data(input.utf8), timeout) { line in
                    for parsed in parse(line) {
                        let each = got.withLock { g -> AgentEvent in
                            switch parsed {
                            case .text(let piece) where provider == .codex:
                                let piece = g.text.isEmpty ? piece : "\n\n" + piece
                                g.text += piece
                                return .text(piece)
                            case .session(let id): g.session = id
                            case .done(let said, let isError): g.done = (said, isError)
                            default: break
                            }
                            return parsed
                        }
                        event(each)
                    }
                }
            } catch {
                let said = got.withLock { $0.done.flatMap { $0.isError ? $0.said : nil } }
                if provider == .codex { throw await PlanCLI(.codex, path: path, spawn: spawn).failure(error, said: said) }
                if Task.isCancelled || error is CancellationError { throw .cancelled }
                if error is ChildProcess.TimedOut { throw .timedOut }
                if await !claudeSignedIn() { throw .signedOut }
                throw .failed(said ?? (error as? ChildProcess.Failure).flatMap { ScriptCommand.lastLine($0.message) } ?? error.localizedDescription)
            }
            let end = got.withLock { $0 }
            guard let done = end.done else { throw failed("the answer broke off") }
            if done.isError {
                let said = done.said ?? "the turn failed"
                if provider == .claudeCode, await !claudeSignedIn() { throw .signedOut }
                throw failed(said)
            }
            return Reply(provider == .claudeCode ? done.said ?? "" : end.text, session: (end.session ?? session).map { Session(provider, $0) })
        }

        /// What the child and every command it runs see (Moody, T14 review): the home folder, the account (claude finds
        /// its Keychain login by USER; without it, "OAuth session expired"), the temporary folder and the language, with
        /// `pilot` first on PATH, then the CLI's own folder and the system's. Nothing else of Pilot's environment, so no
        /// token or key there reaches the AI (probe v2-env, 2026-10-11). claude's shell tool also loads the person's zsh
        /// startup files, which handed every command Sven's exported API keys (probe T14v2-live-lock-1): zsh with ZDOTDIR
        /// on the Helpers folder, which holds no dotfiles, reads the system's files alone. Every shell command goes through
        /// Pilot's gate, Packaging/pilot-agent-shell beside `pilot` (claude's shell prefix), which runs one plain `pilot …`
        /// call and refuses the rest: claude's allow-list alone let `pilot ping; ps aux` through (T17 probe E, 2026-10-12).
        /// A gate missing from the folder fails every command. PILOT_AGENT marks each `pilot` it runs as the agent's, so
        /// its changes wait on one plan and one Allow (ControlPlan); no command it may run can unset it.
        public static func environment(cli: String, helpers: URL,
                                       from parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
            var environment = base(from: parent)
            environment["PATH"] = helpers.path + ":" + ChildProcess.searchPath(for: cli)
            environment["SHELL"] = "/bin/zsh"
            environment["ZDOTDIR"] = helpers.path
            environment["CLAUDE_CODE_SHELL_PREFIX"] = helpers.appending(path: "pilot-agent-shell").path
            return environment
        }

        /// codex's: the agents' base (so no token or key of Pilot's reaches it), the CLI's folder and the system's on PATH,
        /// and Pilot's own Codex home, its sign-in included. codex runs no shell here; pilot-mcp gives each `pilot` the
        /// base environment again.
        public static func codexEnvironment(cli: String, from parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
            var environment = base(from: parent)
            environment["PATH"] = ChildProcess.searchPath(for: cli)
            environment["CODEX_HOME"] = AICommand.codexHome.path
            return environment
        }

        /// What every `pilot` an agent runs sees, with no shell between (the API route's, APIAgent): the home folder,
        /// the account, the temporary folder and the language, and PILOT_AGENT; the CLI agents add the shell's on top.
        public static func base(from parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
            AgentTool.environment(from: parent)
        }

        /// `claude auth status --json`'s loggedIn, through the spawn seam, as ClaudeCLI.signedIn reads it; true when it
        /// cannot tell, so the CLI's own message shows. It exits 1 signed out, its JSON on stdout.
        func claudeSignedIn() async -> Bool {
            let out: String
            do {
                out = try await spawn(path, ["auth", "status", "--json"], Self.environment(cli: path, helpers: helpers), nil, .seconds(10)) { _ in }
            } catch let exit as ChildProcess.Failure where exit.status == 1 {
                out = exit.message
            } catch {
                return true
            }
            return (Self.json(out)?["loggedIn"] as? Bool) ?? true
        }

        /// The CLI's own words as a failure, named for the provider as the chat-only routes name it.
        func failed(_ said: String) -> QuickAI.Failure { provider == .codex ? .api(.codex, said) : .failed(said) }
    }
}
