import Foundation
import PilotGate
import Synchronization

// MARK: Tools on an API key (Sven Q193, 2026-10-16)

extension AIChat {
    /// An API provider that may act: Anthropic's Messages API or a Chat Completions API (OpenAI, Ollama, an endpoint) with
    /// one tool, `pilot`, whose input is one `pilot …` command line. Pilot runs the loop itself: each call is checked by
    /// the shell gate's own rule (Packaging/pilot-agent-shell, `Gate`), then run as the bundle's `pilot` with the agent's
    /// environment (PILOT_AGENT=1, AIChat.Agent.environment), so its changes wait on the same plan card and Allow as
    /// Claude Code's, and a refused command never runs. Every call and result is handed on as the CLI agent's are. A model
    /// that takes no tools chats instead, and the chat says so once.
    public struct APIAgent: Sendable {
        public let route: any ToolRoute
        /// Packaging/pilot-agent.md's text: the CLI agents' prompt.
        public let instructions: String
        /// Where `pilot` is: the bundle's Contents/Helpers.
        public let helpers: URL
        /// How long one turn may take, its calls included: the CLI route's.
        public var timeout: Duration = .seconds(300)
        /// How long one `pilot` may take: past the Allow gate's 60 s, so a question left unanswered comes back denied.
        public var callTimeout: Duration = .seconds(120)
        /// The most `pilot` calls one turn runs; later calls are answered refused.
        public var cap = 12
        var spawn: PlanCLI.Spawn

        public init(_ route: any ToolRoute, instructions: String, helpers: URL, spawn: @escaping PlanCLI.Spawn = PlanCLI.child) {
            self.route = route; self.instructions = instructions; self.helpers = helpers; self.spawn = spawn
        }

        /// The prompt the model gets: the CLI agents' own, with the moment the turn is sent.
        public func system(at now: Now) -> String { instructions + "\n\n" + now.line }

        /// The routes found to take no tools this run (provider and model): they chat, and the chat said so.
        static let chatOnly = Mutex<Set<String>>([])

        public static func notice(_ model: String) -> String {
            "_\(model) can't run pilot commands, so it can explain Pilot but not read or change your setup._\n\n"
        }

        /// One turn: rounds of the API's answer and the commands it asked for, until it answers without one.
        public func turn(_ request: Request, event: @escaping @Sendable (AgentEvent) -> Void) async throws(QuickAI.Failure) -> Reply {
            let timedOut = Atomic(false)
            let work = Task { () async throws -> Reply in try await rounds(request, event: event) }
            let clock = Task { [timeout] in
                try await Task.sleep(for: timeout)
                timedOut.store(true, ordering: .relaxed)
                work.cancel()
            }
            defer { clock.cancel() }
            do {
                return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            } catch {
                if timedOut.load(ordering: .relaxed) { throw .timedOut }
                if let failure = error as? QuickAI.Failure { throw failure }
                throw Task.isCancelled || error is CancellationError ? .cancelled : .failed(error.localizedDescription)
            }
        }

        func rounds(_ request: Request, event: @escaping @Sendable (AgentEvent) -> Void) async throws(QuickAI.Failure) -> Reply {
            let name = route.toolRouteName
            if Self.chatOnly.withLock({ $0.contains(name) }) { return try await chat(request, event: event, notice: false) }
            var conversation = route.toolMessages(request.turns)
            let system = system(at: request.now)
            var answer = "", used = 0
            // One round past the cap: the model hears each call past it refused and answers with what it has.
            for _ in 0...(cap + 1) {
                let round: ToolRound
                do {
                    round = try await route.round(system: system, messages: conversation) { piece in
                        event(.text(piece))
                    }
                } catch ToolRoundError.noTools {
                    Self.chatOnly.withLock { _ = $0.insert(name) }
                    guard answer.isEmpty else { throw .api(route.toolProvider, "the model stopped taking tools mid-turn") }
                    return try await chat(request, event: event, notice: true)
                } catch ToolRoundError.failure(let failure) {
                    throw failure
                } catch {
                    throw .failed(error.localizedDescription)
                }
                if !round.text.isEmpty { answer += (answer.isEmpty ? "" : "\n\n") + round.text }
                guard !round.calls.isEmpty else { return Reply(answer) }
                conversation.append(round.assistant)
                var results: [ToolResult] = []
                for call in round.calls {
                    event(.toolCall(id: call.id, command: call.command ?? ""))
                    let result: ToolResult
                    if let command = call.command, used < cap {
                        used += 1
                        result = await run(command, id: call.id)
                    } else if call.command == nil {
                        result = ToolResult(id: call.id, output: "Pilot has one tool, pilot, which takes {\"command\": \"pilot …\"}.", isError: true)
                    } else {
                        result = ToolResult(id: call.id, output: "Pilot runs at most \(cap) commands a turn; answer with what you have.", isError: true)
                    }
                    if Task.isCancelled { throw .cancelled }
                    event(.toolResult(id: result.id, output: result.output, isError: result.isError))
                    results.append(result)
                }
                conversation += route.toolResults(results)
            }
            throw .api(route.toolProvider, "it kept asking for commands past Pilot's limit of \(cap) a turn")
        }

        /// The turn as plain chat, the chat's own prompt; `notice` first says the model takes no tools.
        func chat(_ request: Request, event: @escaping @Sendable (AgentEvent) -> Void, notice: Bool) async throws(QuickAI.Failure) -> Reply {
            let said = notice ? Self.notice(route.toolModel) : ""
            if notice { event(.text(said)) }
            var reply = try await route.chat(request) { event(.text($0)) }
            reply.answer = said + reply.answer
            return reply
        }

        /// One command as the shell gate would run it: refused unrun unless it is one plain `pilot …` call, else the
        /// bundle's `pilot` with its words, no shell, in the agent's base environment. Its answer, or its error and whether it
        /// failed (exit 4 is denied).
        func run(_ command: String, id: String) async -> ToolResult {
            func result(_ output: String, failed: Bool = true) -> ToolResult { ToolResult(id: id, output: AgentTool.cut(output), isError: failed) }
            guard let words = Gate.words(command) else { return result(Gate.refusal) }
            let pilot = helpers.appending(path: "pilot").path
            do {
                return result(try await spawn(pilot, words, Agent.base(), nil, callTimeout) { _ in }, failed: false)
            } catch let failure as ChildProcess.Failure {
                return result(failure.message)
            } catch is ChildProcess.TimedOut {
                return result("pilot did not answer in time")
            } catch {
                return result(Task.isCancelled ? "stopped" : error.localizedDescription)
            }
        }
    }

    /// Packaging/pilot-agent-shell's rule for the commands Pilot runs itself: PilotGate's, which pilot-mcp shares.
    public typealias Gate = AgentGate

    /// A route's tool call: its id and the command line it asked for; nil command for a tool Pilot has none of, or input
    /// that is no `{"command": …}`.
    public struct ToolCall: Equatable, Sendable {
        public let id: String
        public let command: String?
    }

    public struct ToolResult: Equatable, Sendable {
        public let id: String
        public let output: String
        public let isError: Bool
    }

    /// One answer from the API: its words, the calls it asked for, and the message that goes back into the conversation.
    public struct ToolRound {
        public var text: String
        public var calls: [ToolCall]
        /// The assistant's message as the API takes it back.
        public var assistant: [String: Any]
    }

    enum ToolRoundError: Error {
        /// The model or server takes no tools: a 4xx naming tools or functions.
        case noTools
        case failure(QuickAI.Failure)
    }

    /// A chat route that also takes the `pilot` tool: the API's own tool format, its stream read for calls.
    public protocol ToolRoute: Route {
        var toolProvider: AIProvider { get }
        var toolModel: String { get }
        /// The chat's turns as the API's messages.
        func toolMessages(_ turns: [Turn]) -> [[String: Any]]
        /// One request with the tool, streamed: each piece of words to `text`.
        func round(system: String, messages: [[String: Any]], text: @escaping @Sendable (String) -> Void) async throws -> ToolRound
        /// The commands' answers as the messages that follow the assistant's.
        func toolResults(_ results: [ToolResult]) -> [[String: Any]]
    }
}

extension AIChat.ToolRoute {
    /// The provider and model, as the set of chat-only routes keeps them.
    var toolRouteName: String { toolProvider.rawValue + "|" + toolModel }
}

/// The tool, the same for every API: PilotGate's AgentTool.
enum PilotTool {
    static let name = AgentTool.name
    static let description = AgentTool.description
    static var schema: [String: Any] { AgentTool.schema }

    /// The command from a call's input, nil when it is not `{"command": "…"}`.
    static func command(name: String?, input: [String: Any]?) -> String? {
        guard name == Self.name else { return nil }
        return (input?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a refused request says the model or server takes no tools (Ollama: "… does not support tools", 400;
    /// OpenRouter: "No endpoints found that support tool use", 404). A refused key or a rate limit never is.
    static func refusesTools(status: Int, body: String) -> Bool {
        guard (400..<500).contains(status), ![401, 403, 429].contains(status) else { return false }
        let said = (AIStream.message(body) ?? body).lowercased()
        return said.contains("tool") || said.contains("function")
    }
}

extension AIStream {
    /// One tool round's stream read as the chat routes read theirs, `object` hearing each event's JSON; noTools when the
    /// server refuses the tool.
    static func round(_ request: URLRequest, provider: AIProvider, http: any AIHTTP, parse: @escaping @Sendable (String) -> AIStreamEvent?,
                      object: @escaping @Sendable ([String: Any]) -> Void, text: @escaping @Sendable (String) -> Void) async throws -> Read.Result {
        do {
            let (status, got) = try await stream(request, provider: provider, http: http, parse: parse, object: object, text: text)
            if status != 200, PilotTool.refusesTools(status: status, body: got.body) { throw AIChat.ToolRoundError.noTools }
            try check(status: status, got, provider: provider)
            return got
        } catch let failure as QuickAI.Failure {
            throw AIChat.ToolRoundError.failure(failure)
        }
    }
}

// MARK: Anthropic: tool_use blocks

extension AnthropicAPI: AIChat.ToolRoute {
    public var toolProvider: AIProvider { .anthropicAPI }
    public var toolModel: String { model.id ?? "" }

    public func toolMessages(_ turns: [AIChat.Turn]) -> [[String: Any]] { Self.messages(turns) }

    /// The chat body with the tool.
    public static func toolBody(system: String, messages: [[String: Any]], model: AIModelChoice, effort: AIEffort) -> [String: Any] {
        var body = body(system: system, messages: messages, model: model, effort: effort)
        body["tools"] = [["name": PilotTool.name, "description": PilotTool.description, "input_schema": PilotTool.schema]]
        return body
    }

    /// Each content block as it streams (text, thinking with its signature, tool_use with its input's JSON in pieces),
    /// kept whole by index: the API takes the assistant's blocks back unchanged, thinking included.
    public func round(system: String, messages: [[String: Any]], text: @escaping @Sendable (String) -> Void) async throws -> AIChat.ToolRound {
        let blocks = AnthropicBlocks()
        let got = try await AIStream.round(request(Self.toolBody(system: system, messages: messages, model: model, effort: effort)),
                                           provider: .anthropicAPI, http: http, parse: Self.event, object: blocks.add, text: text)
        let content = blocks.content
        let calls = content.compactMap { block -> AIChat.ToolCall? in
            guard block["type"] as? String == "tool_use", let id = block["id"] as? String else { return nil }
            return AIChat.ToolCall(id: id, command: PilotTool.command(name: block["name"] as? String, input: block["input"] as? [String: Any]))
        }
        return AIChat.ToolRound(text: got.answer, calls: calls, assistant: ["role": "assistant", "content": content])
    }

    public func toolResults(_ results: [AIChat.ToolResult]) -> [[String: Any]] {
        [["role": "user", "content": results.map { ["type": "tool_result", "tool_use_id": $0.id, "content": $0.output, "is_error": $0.isError] }]]
    }
}

/// The Messages API's content blocks, built from `content_block_start` and each `content_block_delta`. A lock, not a
/// Mutex: the blocks are JSON objects, which are not Sendable; nothing hands them out but `content`, a copy.
final class AnthropicBlocks: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [Int: [String: Any]] = [:]
    /// Each block's streamed text, thinking and signature so far, by index, added to in place.
    private var fields: [Int: [String: String]] = [:]
    /// A tool_use block's input JSON so far, by index.
    private var inputs: [Int: String] = [:]

    func add(_ object: [String: Any]) {
        guard let index = object["index"] as? Int else { return }
        lock.lock()
        defer { lock.unlock() }
        switch object["type"] as? String {
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any] { blocks[index] = block }
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any], let type = delta["type"] as? String else { return }
            if type == "input_json_delta" { inputs[index, default: ""] += delta["partial_json"] as? String ?? ""; return }
            // text_delta, thinking_delta and signature_delta each add to the block's field of that name.
            let field = String(type.dropLast("_delta".count))
            guard ["text", "thinking", "signature"].contains(field), let piece = delta[field] as? String else { return }
            fields[index, default: [:]][field, default: ""] += piece
        default:
            return
        }
    }

    /// The blocks in order, each tool_use's input parsed (`{}` when its JSON broke off); an empty text block, which the
    /// API refuses back, left out.
    var content: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return blocks.sorted { $0.key < $1.key }.compactMap { index, start in
            var block = start
            for (field, text) in fields[index] ?? [:] { block[field] = (start[field] as? String ?? "") + text }
            switch block["type"] as? String {
            case "text" where (block["text"] as? String)?.isEmpty != false:
                return nil
            case "tool_use":
                guard let json = inputs[index] else { return block }
                block["input"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [String: Any]()
                return block
            default:
                return block
            }
        }
    }
}

// MARK: Chat Completions: tool_calls

extension OpenAIChat: AIChat.ToolRoute {
    public var toolProvider: AIProvider { provider }
    public var toolModel: String { model }

    public func toolMessages(_ turns: [AIChat.Turn]) -> [[String: Any]] { Self.messages(turns) }

    /// The chat body with the tool: the system message first, then the conversation.
    public static func toolBody(system: String, messages: [[String: Any]], model: String, provider: AIProvider, effort: AIEffort) -> [String: Any] {
        var body = body(system: system, messages: messages, model: model, provider: provider, effort: effort)
        body["tools"] = [["type": "function", "function": ["name": PilotTool.name, "description": PilotTool.description, "parameters": PilotTool.schema]]]
        return body
    }

    /// The calls as they stream, each by its index: the id and name first, the arguments' JSON in pieces. Ollama sends a
    /// call whole, and may leave out the index or the id.
    public func round(system: String, messages: [[String: Any]], text: @escaping @Sendable (String) -> Void) async throws -> AIChat.ToolRound {
        let calls = OpenAICalls()
        let got = try await AIStream.round(request(Self.toolBody(system: system, messages: messages, model: model, provider: provider, effort: effort)),
                                           provider: provider, http: http, parse: Self.event, object: calls.add, text: text)
        let made = calls.calls
        var assistant: [String: Any] = ["role": "assistant", "content": got.answer.isEmpty ? NSNull() : got.answer]
        if !made.isEmpty {
            assistant["tool_calls"] = made.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
        }
        let parsed = made.map { call in
            let input = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]
            return AIChat.ToolCall(id: call.id, command: PilotTool.command(name: call.name, input: input))
        }
        return AIChat.ToolRound(text: got.answer, calls: parsed, assistant: assistant)
    }

    public func toolResults(_ results: [AIChat.ToolResult]) -> [[String: Any]] {
        results.map { ["role": "tool", "tool_call_id": $0.id, "content": $0.output] }
    }
}

/// Chat Completions' streamed `delta.tool_calls`, joined by index.
final class OpenAICalls: Sendable {
    struct Call { var id: String, name: String, arguments: String }
    private let state = Mutex<[Int: Call]>([:])

    func add(_ object: [String: Any]) {
        guard let choice = (object["choices"] as? [[String: Any]])?.first,
              let deltas = (choice["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]] else { return }
        state.withLock { calls in
            for (position, delta) in deltas.enumerated() {
                let index = delta["index"] as? Int ?? (calls.count + position)
                let function = delta["function"] as? [String: Any]
                if calls[index] == nil { calls[index] = Call(id: "", name: "", arguments: "") }
                if let id = delta["id"] as? String, !id.isEmpty { calls[index]!.id = id }
                if let name = function?["name"] as? String { calls[index]!.name += name }
                if let arguments = function?["arguments"] as? String { calls[index]!.arguments += arguments }
                // Ollama's arguments may come as an object, not a string.
                else if let object = function?["arguments"] as? [String: Any],
                        let data = try? JSONSerialization.data(withJSONObject: object) { calls[index]!.arguments = String(decoding: data, as: UTF8.self) }
            }
        }
    }

    /// The calls in order, one without an id given one.
    var calls: [Call] {
        state.withLock { $0 }.sorted { $0.key < $1.key }.map { index, call in
            var call = call
            if call.id.isEmpty { call.id = "call_\(index)" }
            return call
        }
    }
}
