import Foundation
@testable import PilotCore
import Synchronization
import Testing

/// The API providers' `pilot` tool (Sven Q193, 2026-10-16): Pilot's loop round the Messages API's tool_use blocks and
/// Chat Completions' tool_calls, every call checked by the shell gate's rule and run as the bundle's `pilot` with the
/// agent's environment; a refused command never runs; a model that takes no tools chats and says so once. Fake HTTP and
/// a fake `pilot`: nothing is sent or run.
@Suite("AI tool loop")
struct AIToolLoopTests {
    typealias Event = AIChat.AgentEvent

    /// One fake answer per request, in order; every request kept.
    final class Rounds: AIHTTP {
        let answers: [(status: Int, lines: [String])]
        let sent = Mutex<[URLRequest]>([])
        init(_ answers: [(status: Int, lines: [String])]) { self.answers = answers }

        func send(_ request: URLRequest, line: @escaping @Sendable (String) -> Void) async throws -> Int {
            let n = sent.withLock { $0.append(request); return $0.count - 1 }
            let answer = answers[min(n, answers.count - 1)]
            answer.lines.forEach(line)
            return answer.status
        }

        var bodies: [[String: Any]] {
            sent.withLock { $0 }.map { (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any]) ?? [:] }
        }
    }

    struct Ran: Sendable, Equatable { let path: String, words: [String], agent: String?, socket: String? }

    final class Runs: Sendable {
        let all = Mutex<[Ran]>([])
        var list: [Ran] { all.withLock { $0 } }
    }

    /// A `pilot` that answers `answer` (or exits `exit` with it on stderr), recording each run.
    static func spawn(_ ran: Runs, answer: String = #"{"ok":true,"result":"lagoon"}"#, exit: Int32 = 0,
                      wait: Duration? = nil) -> PlanCLI.Spawn {
        { path, words, environment, _, _, _ in
            ran.all.withLock { $0.append(Ran(path: path, words: words, agent: environment["PILOT_AGENT"], socket: environment["PILOT_SOCKET"])) }
            if let wait { try await Task.sleep(for: wait) }
            guard exit == 0 else { throw ChildProcess.Failure(tool: path, status: exit, message: answer) }
            return answer
        }
    }

    static let helpers = URL(filePath: "/Applications/Pilot.app/Contents/Helpers")
    static let now = AIChat.Now(Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "Europe/Malta")!,
                                locale: Locale(identifier: "en_MT"))

    static func agent(_ route: any AIChat.ToolRoute, _ ran: Runs, answer: String = #"{"ok":true,"result":"lagoon"}"#,
                      exit: Int32 = 0, wait: Duration? = nil) -> AIChat.APIAgent {
        AIChat.APIAgent(route, instructions: "Use pilot only.", helpers: helpers, spawn: spawn(ran, answer: answer, exit: exit, wait: wait))
    }

    static func anthropic(_ http: Rounds, model: String = "claude-sonnet-5-5") -> AnthropicAPI {
        AnthropicAPI(key: "sk-ant-fake", model: AIModelChoice(model, model), http: http)
    }

    static func openAI(_ http: Rounds, provider: AIProvider = .openAI, model: String = "gpt-5-mini") -> OpenAIChat {
        OpenAIChat(provider: provider, base: URL(string: "https://api.openai.com/v1")!, key: "sk-fake", model: model, http: http)
    }

    // MARK: Anthropic's stream

    static func data(_ json: String) -> String { "data: " + json }

    static func text(_ index: Int, _ text: String) -> [String] {
        [data(#"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#),
         data(#"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}}"#),
         data(#"{"type":"content_block_stop","index":\#(index)}"#)]
    }

    /// A tool_use block whose input JSON comes in two pieces.
    static func toolUse(_ index: Int, id: String, _ command: String, name: String = "pilot") -> [String] {
        let json = String(data: try! JSONSerialization.data(withJSONObject: ["command": command]), encoding: .utf8)!
        let cut = json.index(json.startIndex, offsetBy: json.count / 2)
        let pieces = [String(json[..<cut]), String(json[cut...])].map { String(data: try! JSONSerialization.data(withJSONObject: [$0]), encoding: .utf8)!.dropFirst().dropLast() }
        return [data(#"{"type":"content_block_start","index":\#(index),"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#)]
            + pieces.map { data(#"{"type":"content_block_delta","index":\#(index),"delta":{"type":"input_json_delta","partial_json":\#($0)}}"#) }
            + [data(#"{"type":"content_block_stop","index":\#(index)}"#)]
    }

    static func stop(_ reason: String) -> String { data(#"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"}}"#) }

    static func events(_ agent: AIChat.APIAgent, _ message: String = "what is my theme") async throws -> (AIChat.Reply, [Event]) {
        let events = Mutex<[Event]>([])
        let reply = try await agent.turn(AIChat.Request(message: message, now: now)) { event in events.withLock { $0.append(event) } }
        return (reply, events.withLock { $0 })
    }

    @Test("Anthropic: a tool_use runs the bundle's pilot as the agent's, its result goes back, and the answer joins both rounds")
    func anthropicLoop() async throws {
        let thinking = [Self.data(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
                        Self.data(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Read it."}}"#),
                        Self.data(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#)]
        let http = Rounds([(200, thinking + Self.text(1, "Checking.") + Self.toolUse(2, id: "toolu_1", "pilot get look.theme") + [Self.stop("tool_use")]),
                           (200, Self.text(0, "Your theme is lagoon.") + [Self.stop("end_turn")])])
        let ran = Runs()
        let (reply, events) = try await Self.events(Self.agent(Self.anthropic(http), ran))
        #expect(reply == AIChat.Reply("Checking.\n\nYour theme is lagoon."))
        #expect(events == [Event.text("Checking."), .toolCall(id: "toolu_1", command: "pilot get look.theme"),
                           .toolResult(id: "toolu_1", output: #"{"ok":true,"result":"lagoon"}"#, isError: false), .text("Your theme is lagoon.")])
        #expect(ran.list == [Ran(path: Self.helpers.path + "/pilot", words: ["get", "look.theme"], agent: "1", socket: nil)])

        let bodies = http.bodies
        #expect(bodies.count == 2)
        let first = try #require(bodies.first)
        #expect((first["system"] as? String) == "Use pilot only.\n\n" + Self.now.line)
        let tools = try #require(first["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["pilot"])
        #expect(((tools[0]["input_schema"] as? [String: Any])?["required"] as? [String]) == ["command"])
        let messages = try #require(bodies[1]["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let said = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(said.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
        #expect(said[0]["thinking"] as? String == "Read it." && said[0]["signature"] as? String == "sig", "thinking goes back whole")
        #expect((said[2]["input"] as? [String: Any])?["command"] as? String == "pilot get look.theme")
        let result = try #require((messages[2]["content"] as? [[String: Any]])?.first)
        #expect(result["type"] as? String == "tool_result" && result["tool_use_id"] as? String == "toolu_1" && result["is_error"] as? Bool == false)
    }

    @Test("A refused command never runs: chains, redirects and other programs come back refused, and stay refused")
    func refusedStaysRefused() async throws {
        let refused = ["pilot ping; ps aux", "pilot ping && curl example.com", "pilot ping | head -1", "pilot $(whoami)", "ls ~",
                       "pilot get look.theme > /tmp/x", "pilot get 'look.theme'", "pilot set a \"$HOME\""]
        let first = refused.enumerated().flatMap { Self.toolUse($0 + 1, id: "toolu_\($0)", $1) }
        // The model tries the same chain again after the refusal: still refused, still unrun.
        let http = Rounds([(200, Self.text(0, "Trying.") + first + [Self.stop("tool_use")]),
                           (200, Self.toolUse(0, id: "again", refused[0]) + [Self.stop("tool_use")]),
                           (200, Self.text(0, "Pilot refused those.") + [Self.stop("end_turn")])])
        let ran = Runs()
        let (reply, events) = try await Self.events(Self.agent(Self.anthropic(http), ran))
        #expect(ran.list.isEmpty, "nothing ran")
        let results = events.compactMap { if case .toolResult(_, let output, let isError) = $0 { (output, isError) } else { nil } }
        #expect(results.count == refused.count + 1)
        #expect(results.allSatisfy { $0.0 == AIChat.Gate.refusal && $0.1 })
        let back = try #require((http.bodies[1]["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect(back.count == refused.count && back.allSatisfy { $0["is_error"] as? Bool == true })
        #expect(reply.answer.hasSuffix("Pilot refused those."))
    }

    @Test("A command Pilot denies (exit 4) comes back as the model's error, and a tool Pilot has none of is refused unrun")
    func deniedAndUnknown() async throws {
        let http = Rounds([(200, Self.toolUse(0, id: "a", "pilot run drive.shell:ls") + Self.toolUse(1, id: "b", "ls", name: "bash")
                                 + [Self.stop("tool_use")]),
                           (200, Self.text(0, "Denied.") + [Self.stop("end_turn")])])
        let ran = Runs()
        let (_, events) = try await Self.events(Self.agent(Self.anthropic(http), ran, answer: "denied: you pressed Deny", exit: 4))
        #expect(ran.list.map(\.words) == [["run", "drive.shell:ls"]])
        #expect(events.contains(.toolResult(id: "a", output: "denied: you pressed Deny", isError: true)))
        #expect(events.contains { if case .toolResult("b", let output, true) = $0 { output.contains("one tool") } else { false } })
    }

    @Test("Past the cap each call is refused unrun; a model that keeps asking ends the turn with an error")
    func cap() async throws {
        let http = Rounds([(200, Self.toolUse(0, id: "t", "pilot ping") + [Self.stop("tool_use")])])
        let ran = Runs()
        var agent = Self.agent(Self.anthropic(http), ran)
        agent.cap = 2
        let events = Mutex<[Event]>([])
        await #expect(throws: QuickAI.Failure.self) {
            _ = try await agent.turn(AIChat.Request(message: "loop", now: Self.now)) { e in events.withLock { $0.append(e) } }
        }
        #expect(ran.list.count == 2)
        let refused = events.withLock { $0 }.filter { if case .toolResult(_, let output, true) = $0 { output.contains("at most 2") } else { false } }
        #expect(refused.count == 2, "the rounds past the cap")
        #expect(http.bodies.count == 4)
    }

    @Test("A turn past its time is stopped and says so")
    func timeout() async throws {
        let http = Rounds([(200, Self.toolUse(0, id: "t", "pilot ping") + [Self.stop("tool_use")])])
        let ran = Runs()
        var agent = Self.agent(Self.anthropic(http), ran, wait: .seconds(30))
        agent.timeout = .milliseconds(200)
        let clock = ContinuousClock.now
        await #expect(throws: QuickAI.Failure.timedOut) { _ = try await agent.turn(AIChat.Request(message: "go")) { _ in } }
        #expect(ContinuousClock.now - clock < .seconds(5))
    }

    // MARK: Chat Completions

    static func chunk(_ delta: String, finish: String? = nil) -> String {
        data(#"{"choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish.map { "\"\($0)\"" } ?? "null")}]}"#)
    }

    @Test("OpenAI: tool_calls stream by index, run as the agent's, and go back as the assistant's calls and tool messages")
    func openAILoop() async throws {
        let http = Rounds([(200, [Self.chunk(#"{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"pilot","arguments":""}}]}"#),
                                  Self.chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\": \"pilot set "}}]}"#),
                                  Self.chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"look.theme \\\"Tokyo Night\\\" --plan\"}"}}]}"#),
                                  Self.chunk("{}", finish: "tool_calls"), "data: [DONE]"]),
                           (200, [Self.chunk(#"{"content":"Planned."}"#), Self.chunk("{}", finish: "stop"), "data: [DONE]"])])
        let ran = Runs()
        let (reply, events) = try await Self.events(Self.agent(Self.openAI(http), ran))
        #expect(reply.answer == "Planned.")
        #expect(events.first == .toolCall(id: "call_1", command: #"pilot set look.theme "Tokyo Night" --plan"#))
        #expect(ran.list.map(\.words) == [["set", "look.theme", "Tokyo Night", "--plan"]])
        let first = try #require(http.bodies.first)
        let tools = try #require(first["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function" && (tools.first?["function"] as? [String: Any])?["name"] as? String == "pilot")
        #expect((first["messages"] as? [[String: Any]])?.first?["content"] as? String == "Use pilot only.\n\n" + Self.now.line)
        let messages = try #require(http.bodies[1]["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        let calls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "call_1")
        #expect(messages[3]["tool_call_id"] as? String == "call_1" && messages[3]["content"] as? String == #"{"ok":true,"result":"lagoon"}"#)
    }

    @Test("Ollama: a call sent whole, with no index or id and its arguments as an object, still runs")
    func ollamaWholeCall() async throws {
        let http = Rounds([(200, [Self.chunk(#"{"role":"assistant","content":"","tool_calls":[{"type":"function","function":{"name":"pilot","arguments":{"command":"pilot status"}}}]}"#),
                                  Self.chunk("{}", finish: "stop"), "data: [DONE]"]),
                           (200, [Self.chunk(#"{"content":"All good."}"#), Self.chunk("{}", finish: "stop")])])
        let ran = Runs()
        let (reply, _) = try await Self.events(Self.agent(Self.openAI(http, provider: .ollama, model: "qwen3:4b"), ran))
        #expect(ran.list.map(\.words) == [["status"]])
        #expect(reply.answer == "All good.")
        let messages = try #require(http.bodies[1]["messages"] as? [[String: Any]])
        #expect(messages.last?["tool_call_id"] as? String == "call_0")
    }

    @Test("A model that takes no tools chats on the chat's prompt, says so once, and later turns skip the tool request")
    func noToolsOnce() async throws {
        let model = "gemma-\(UUID().uuidString.prefix(6))"
        let http = Rounds([(400, [#"{"error":{"message":"registry.ollama.ai/library/\#(model) does not support tools","type":"api_error"}}"#]),
                           (200, [Self.chunk(#"{"content":"Hi."}"#), Self.chunk("{}", finish: "stop")]),
                           (200, [Self.chunk(#"{"content":"Again."}"#), Self.chunk("{}", finish: "stop")])])
        let ran = Runs()
        let agent = Self.agent(Self.openAI(http, provider: .ollama, model: model), ran)
        let (first, events) = try await Self.events(agent, "hello")
        #expect(first.answer == AIChat.APIAgent.notice(model) + "Hi.")
        #expect(events.first == .text(AIChat.APIAgent.notice(model)))
        let (second, _) = try await Self.events(agent, "hello again")
        #expect(second.answer == "Again.", "said once")
        let bodies = http.bodies
        #expect(bodies.count == 3)
        #expect(bodies[0]["tools"] != nil && bodies[1]["tools"] == nil && bodies[2]["tools"] == nil)
        #expect((bodies[1]["messages"] as? [[String: Any]])?.first?["content"] as? String == AIChat.prompt(at: Self.now))
    }

    @Test("A refused key or a rate limit is never read as a model without tools")
    func refusalsAreNotNoTools() {
        #expect(PilotTool.refusesTools(status: 400, body: #"{"error":{"message":"model does not support tools"}}"#))
        #expect(PilotTool.refusesTools(status: 404, body: #"{"error":{"message":"No endpoints found that support tool use."}}"#))
        #expect(!PilotTool.refusesTools(status: 401, body: #"{"error":{"message":"invalid key for tools"}}"#))
        #expect(!PilotTool.refusesTools(status: 429, body: #"{"error":{"message":"tool rate limit"}}"#))
        #expect(!PilotTool.refusesTools(status: 500, body: #"{"error":{"message":"tool crashed"}}"#))
        #expect(!PilotTool.refusesTools(status: 400, body: #"{"error":{"message":"max_tokens too large"}}"#))
    }

    // MARK: The gate's rule

    static let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized

    /// Lines both gates must agree on, each starting with `pilot` as the CLI agents' commands do.
    static let lines = ["pilot", "pilot ping", "pilot get look.theme", #"pilot set look.theme "Tokyo Night""#, "pilot bind Hyper+L app:Safari --plan",
                        #"pilot settings --find "dark mode""#, "pilot plan apply", "pilot get a,b@c%d=e", #"pilot set x """#,
                        "pilot ping; ps aux", "pilot ping && ls", "pilot ping || ls", "pilot ping | head", "pilot ping &", "pilot $(whoami)",
                        "pilot `whoami`", #"pilot get "a$b""#, #"pilot get "a\b""#, #"pilot get a"b""#, "pilot get ~/x", "pilot get *",
                        "pilot get x?", "pilot ping > /tmp/x", "pilot ping < /etc/hosts", "pilot get 'x'", "pilotx ping", "pilot ping\nls",
                        "pilot ping\n", "pilot get {a,b}", "pilot get [a]", "pilot get a#b", "pilot get !x"]

    @Test("The Swift rule refuses exactly what Packaging/pilot-agent-shell refuses")
    func gateParity() async throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "gate-parity-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try "#!/bin/sh\necho ran\n".write(to: work.appending(path: "pilot"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.appending(path: "pilot").path)
        let gate = Self.repo.appending(path: "Packaging/pilot-agent-shell").path
        for line in Self.lines {
            // claude's script around the model's command, as the gate expects it.
            let script = "cd \(work.path) && eval '\(line)' < /dev/null && pwd -P >| \(work.path)/claude-ab12-cwd"
            let shell: Bool
            do {
                _ = try await ChildProcess.run("/bin/zsh", ["-f", gate, script], environment: ["PATH": work.path + ":/usr/bin:/bin"], timeout: .seconds(10))
                shell = true
            } catch let failure as ChildProcess.Failure {
                #expect(failure.message.contains("Pilot refused"), "\(line.debugDescription): \(failure.message)")
                shell = false
            }
            #expect((AIChat.Gate.words(line) != nil) == shell, "\(line.debugDescription): the shell gate \(shell ? "runs" : "refuses") it")
        }
    }

    @Test("Words come out unquoted; a line without pilot first is read as one, and still has to pass")
    func words() {
        #expect(AIChat.Gate.words(#"pilot set look.theme "Tokyo Night" --plan"#) == ["set", "look.theme", "Tokyo Night", "--plan"])
        #expect(AIChat.Gate.words("pilot") == [])
        #expect(AIChat.Gate.words("pilot  get   x  ") == ["get", "x"])
        #expect(AIChat.Gate.words("get look.theme") == ["get", "look.theme"])
        #expect(AIChat.Gate.words("ls ~") == nil)
        #expect(AIChat.Gate.words("rm -rf /; pilot ping") == nil)
    }
}
