import AppKit
import Foundation
import Synchronization
import Testing
@testable import PilotCore

/// The agent runner (spec pilot-ai-helper T14): claude and codex lines parsed into text, tool calls and tool results,
/// and a turn run through the spawn seam, so nothing logs in or runs a CLI. The lines are the CLIs' own, recorded on
/// 2026-10-11 (claude 2.1.296 `stream-json`, codex 0.162.1 `exec --json`), trimmed to the fields read and with paths
/// shortened. The live test (PILOT_LIVE=1) asks the real Claude through the running Pilot, read-only.
@Suite("AI chat tool events")
struct AIChatToolEventsTests {
    typealias Event = AIChat.AgentEvent

    /// "what is my theme", as Claude answered it with no schema to read: a guessed key fails, then it reads the list.
    static let claudeTurn = [
        #"{"type":"system","subtype":"init","cwd":"/tmp/pilot-ai","session_id":"1531fb0f-6a48-487b-be3c-54d20588d1ab","tools":["Bash"],"model":"claude-opus-5-5","permissionMode":"dontAsk"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01GC4HHba1Z4qwjjgTfLvj6h","name":"Bash","input":{}}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":""}}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01BJWJktDEzSDRmrjfz3CuA5","name":"Bash","input":{"command":"pilot get theme","description":"Read the theme setting"}}]},"session_id":"1531fb0f-6a48-487b-be3c-54d20588d1ab"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01BJWJktDEzSDRmrjfz3CuA5","type":"tool_result","content":"Exit code 1\nno setting theme; pilot settings lists them","is_error":true}]}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Your theme is **l"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"agoon**."}}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Your theme is **lagoon**."}]},"session_id":"1531fb0f-6a48-487b-be3c-54d20588d1ab"}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Your theme is **lagoon**.","session_id":"1531fb0f-6a48-487b-be3c-54d20588d1ab","permission_denials":[]}"#,
    ]

    /// A command outside `pilot *`, refused unasked under dontAsk (probe A).
    static let claudeDenied = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Permission to use Bash has been denied because Claude Code is running in don't ask mode.","is_error":true,"tool_use_id":"toolu_01M2ZSvMZESdPAgSUU2J1LB7"}]}}"#

    /// codex running one command that works and one that fails; its hook warning comes as an item of type error.
    static let codexTurn = [
        #"{"type":"thread.started","thread_id":"01a12ae9-52f4-7642-9859-5584d5ec39e2"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"clamping SessionEnd hook timeout to 3s in /Users/test/.codex/hooks.json"}}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"I’ll run it once.\n"}}"#,
        #"{"type":"item.started","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc 'echo hi'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc 'echo hi'","aggregated_output":"hi\n","exit_code":0,"status":"completed"}}"#,
        #"{"type":"item.started","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'ls /nonexistent-t14-dir'","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_3","type":"command_execution","command":"/bin/zsh -lc 'ls /nonexistent-t14-dir'","aggregated_output":"ls: /nonexistent-t14-dir: No such file or directory\n","exit_code":1,"status":"failed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_4","type":"agent_message","text":"It printed `hi`."}}"#,
        #"{"type":"turn.completed","usage":{"input_tokens":39973,"output_tokens":55}}"#,
    ]

    /// codex 0.163.0 calling Pilot's tool through pilot-mcp (Q203, recorded 2026-10-16 against a fake model server): a call
    /// that ran and one the gate refused.
    static let codexPilotTurn = [
        #"{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"pilot","tool":"pilot","arguments":{"command":"pilot ping"},"result":null,"error":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"pilot","tool":"pilot","arguments":{"command":"pilot ping"},"result":{"content":[{"type":"text","text":"{\"ok\":true,\"result\":\"pong\"}\n"}],"structured_content":null},"error":null,"status":"completed"}}"#,
        #"{"type":"item.started","item":{"id":"item_2","type":"mcp_tool_call","server":"pilot","tool":"pilot","arguments":{"command":"pilot ping; ls ~"},"result":null,"error":null,"status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"mcp_tool_call","server":"pilot","tool":"pilot","arguments":{"command":"pilot ping; ls ~"},"result":{"content":[{"type":"text","text":"Pilot refused this: only one plain pilot command per call (no ; && | redirects $ ` or quotes ')."}],"structured_content":null},"error":null,"status":"failed"}}"#,
        #"{"type":"item.completed","item":{"id":"item_3","type":"mcp_tool_call","server":"pilot","tool":"pilot","arguments":{"command":"pilot ping"},"result":null,"error":{"message":"MCP tool call requires approval, but approval policy is never"},"status":"failed"}}"#,
    ]

    // MARK: Parsers

    @Test("claude's stream gives its text, each tool call and result, the session and the end")
    func claudeStream() {
        #expect(Self.claudeTurn.flatMap(AIChat.Agent.claudeEvents) == [
            .toolCall(id: "toolu_01BJWJktDEzSDRmrjfz3CuA5", command: "pilot get theme"),
            .toolResult(id: "toolu_01BJWJktDEzSDRmrjfz3CuA5", output: "Exit code 1\nno setting theme; pilot settings lists them", isError: true),
            .text("Your theme is **l"), .text("agoon**."),
            .session("1531fb0f-6a48-487b-be3c-54d20588d1ab"), .done("Your theme is **lagoon**.", isError: false),
        ])
    }

    @Test("A refused command comes back as a failed tool result")
    func claudeDenied() {
        #expect(AIChat.Agent.claudeEvents(Self.claudeDenied) == [.toolResult(
            id: "toolu_01M2ZSvMZESdPAgSUU2J1LB7", output: "Permission to use Bash has been denied because Claude Code is running in don't ask mode.",
            isError: true)])
    }

    @Test("A tool result in text blocks, several calls in one message, and an error result")
    func claudeShapes() {
        let blocks = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}]}}"#
        #expect(AIChat.Agent.claudeEvents(blocks) == [.toolResult(id: "a", output: "one\ntwo", isError: false)])
        let two = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"pilot help"}},{"type":"tool_use","id":"b","name":"Bash","input":{"command":"pilot ping"}}]}}"#
        #expect(AIChat.Agent.claudeEvents(two) == [.toolCall(id: "a", command: "pilot help"), .toolCall(id: "b", command: "pilot ping")])
        let failed = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in"}"#
        #expect(AIChat.Agent.claudeEvents(failed) == [.done("Not logged in", isError: true)])
        #expect(AIChat.Agent.claudeEvents("not json").isEmpty)
    }

    @Test("codex's lines give its thread, its messages whole, each command's start and end, and the turn's end")
    func codexStream() {
        #expect(Self.codexTurn.flatMap(AIChat.Agent.codexEvents) == [
            .session("01a12ae9-52f4-7642-9859-5584d5ec39e2"),
            .text("I’ll run it once.\n"),
            .toolCall(id: "item_2", command: "echo hi"), .toolResult(id: "item_2", output: "hi\n", isError: false),
            .toolCall(id: "item_3", command: "ls /nonexistent-t14-dir"),
            .toolResult(id: "item_3", output: "ls: /nonexistent-t14-dir: No such file or directory\n", isError: true),
            .text("It printed `hi`."), .done(nil, isError: false),
        ])
        let failed = #"{"type":"turn.failed","error":{"message":"{\"error\":{\"message\":\"usage limit reached\"}}"}}"#
        #expect(AIChat.Agent.codexEvents(failed) == [.done("usage limit reached", isError: true)])
    }

    @Test("codex's pilot calls through pilot-mcp give each command and its answer; a refused or failed call is an error")
    func codexPilotCalls() {
        #expect(Self.codexPilotTurn.flatMap(AIChat.Agent.codexEvents) == [
            .toolCall(id: "item_1", command: "pilot ping"), .toolResult(id: "item_1", output: #"{"ok":true,"result":"pong"}"# + "\n", isError: false),
            .toolCall(id: "item_2", command: "pilot ping; ls ~"), .toolResult(id: "item_2", output: AIChat.Gate.refusal, isError: true),
            .toolResult(id: "item_3", output: "MCP tool call requires approval, but approval policy is never", isError: true),
        ])
    }

    @Test("codex's login-shell wrapper comes off, quotes inside kept")
    func codexCommand() {
        #expect(AIChat.Agent.command("/bin/zsh -lc 'pilot set look.theme lagoon'") == "pilot set look.theme lagoon")
        #expect(AIChat.Agent.command(#"/bin/zsh -lc 'pilot set menu.title '\''My Mac'\'''"#) == "pilot set menu.title 'My Mac'")
        #expect(AIChat.Agent.command("pilot ping") == "pilot ping")
    }

    // MARK: Command lines

    @Test("claude runs the shell alone, allowed only for pilot, restricted and in safe mode, and resumes its session")
    func claudeArguments() {
        let first = AIChat.Agent.claudeArguments(prompt: "/App/pilot-agent.md", session: nil, model: nil, effort: .low)
        #expect(first == ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--tools", "Bash",
                          "--allowedTools", "Bash(pilot *)", "--permission-mode", "dontAsk", "--strict-mcp-config", "--restricted",
                          "--safe-mode", "--append-system-prompt-file", "/App/pilot-agent.md", "--effort", "low"])
        #expect(first.contains("--restricted") && first.contains("--safe-mode") && !first.contains("--bare"))
        let next = AIChat.Agent.claudeArguments(prompt: "/App/pilot-agent.md", session: "s1", model: "sonnet", effort: .high)
        #expect(next.suffix(6) == ["--effort", "high", "--resume", "s1", "--model", "sonnet"])
    }

    @Test("/extension's claude also gets Read, Write and Edit, allowed by name, still restricted to its folder; codex never does")
    func fileReach() {
        let files = AIChat.Agent.claudeArguments(prompt: "/App/pilot-extension-agent.md", session: nil, model: "haiku", effort: .low, reach: .files)
        #expect(files == ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--tools", "Bash,Read,Write,Edit",
                          "--allowedTools", "Bash(pilot *)", "Read", "Write", "Edit", "--permission-mode", "dontAsk", "--strict-mcp-config",
                          "--restricted", "--safe-mode", "--append-system-prompt-file", "/App/pilot-extension-agent.md", "--effort", "low",
                          "--model", "haiku"])
        #expect(!files.contains { $0.contains("python") })
        let app = URL(filePath: "/App")
        #expect(AIChat.Agent(.codex, path: "/bin/codex", prompt: app, helpers: app, reach: .files) == nil)
        #expect(AIChat.Agent(.claudeCode, path: "/bin/claude", prompt: app, helpers: app, reach: .files)?.reach == .files)
    }

    @Test("A file tool's row names the tool and the file by its folder; the shell's names its command")
    func fileToolRows() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"w1","name":"Write","input":{"file_path":"/private/var/folders/x/T/pilot-ext/1a2b/open-ports/main.py","content":"…"}},{"type":"tool_use","id":"r1","name":"Read","input":{"file_path":"extension.json"}},{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"pilot ext test open-ports"}},{"type":"tool_use","id":"g1","name":"Glob","input":{}}]}}"#
        #expect(AIChat.Agent.claudeEvents(line) == [.toolCall(id: "w1", command: "Write open-ports/main.py"), .toolCall(id: "r1", command: "Read extension.json"),
                                                    .toolCall(id: "b1", command: "pilot ext test open-ports"), .toolCall(id: "g1", command: "Glob")])
    }

    /// The lock every codex turn carries (codexLock), Pilot's guide and the bundle's pilot-mcp in it.
    static let codexLock = ["--disable", "shell_tool", "--disable", "unified_exec", "--disable", "view_image", "--disable", "multi_agent",
                            "--disable", "goals", "--disable", "apps", "--disable", "plugins", "--disable", "hooks", "--disable", "computer_use",
                            "--disable", "browser_use", "--disable", "image_generation", "--disable", "memories",
                            "-c", #"web_search="disabled""#, "-c", "skills.include_instructions=false",
                            "-c", #"developer_instructions="Use pilot only.\n\"Quoted\" and \\ kept.""#,
                            "-c", #"mcp_servers.pilot={command="/App/Contents/Helpers/pilot-mcp",args=["/App/Contents/Helpers/pilot"],default_tools_approval_mode="approve"}"#]

    @Test("codex starts read-only in Pilot's folder, never asking, every tool off but pilot-mcp's; a later turn resumes its thread with the same lock")
    func codexArguments() {
        let (guide, helpers) = ("Use pilot only.\n\"Quoted\" and \\ kept.", URL(filePath: "/App/Contents/Helpers"))
        #expect(AIChat.Agent.codexArguments(directory: "/tmp/pilot-ai", session: nil, model: nil, effort: .low, instructions: guide, helpers: helpers) == [
            "exec", "--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "-c", #"approval_policy="never""#,
            "-c", #"model_reasoning_effort="low""#] + Self.codexLock + ["-C", "/tmp/pilot-ai", "-s", "read-only", "-"])
        #expect(AIChat.Agent.codexArguments(directory: "/tmp/pilot-ai", session: "t1", model: "gpt-5", effort: .medium, instructions: guide, helpers: helpers) == [
            "exec", "resume", "--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "-c", #"approval_policy="never""#,
            "-c", #"model_reasoning_effort="medium""#] + Self.codexLock + ["--model", "gpt-5", "-c", #"sandbox_mode="read-only""#, "t1", "-"])
    }

    @Test("codex sees the agents' base environment and Pilot's own Codex home, never the person's CODEX_HOME or keys")
    func codexEnvironment() {
        let parent = ["HOME": "/Users/test", "USER": "test", "TMPDIR": "/tmp/t/", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin",
                      "OPENAI_API_KEY": "sk-test", "CODEX_HOME": "/Users/test/.codex"]
        let environment = AIChat.Agent.codexEnvironment(cli: "/opt/homebrew/bin/codex", from: parent)
        #expect(environment == ["HOME": "/Users/test", "USER": "test", "TMPDIR": "/tmp/t/", "LANG": "en_US.UTF-8", "PILOT_AGENT": "1",
                                "PATH": "/opt/homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                "CODEX_HOME": AICommand.codexHome.path])
        #expect(AICommand.codexHome == PilotFolder.support.appending(path: "codex", directoryHint: .isDirectory))
        #expect(PlanCLI.environment("/opt/homebrew/bin/codex")["CODEX_HOME"] == AICommand.codexHome.path)
        let mode = (try? FileManager.default.attributesOfItem(atPath: AICommand.codexHome.path)[.posixPermissions]) as? Int
        #expect(mode == 0o700)
    }

    @Test("Only the two subscriptions run as agents")
    func providers() {
        let made = AIProvider.allCases.filter {
            AIChat.Agent($0, path: "/bin/x", prompt: URL(filePath: "/p.md"), helpers: URL(filePath: "/h")) != nil
        }
        #expect(made == [.claudeCode, .codex])
    }

    // MARK: Turns

    struct Spawned: Sendable { let path: String, arguments: [String], environment: [String: String], input: String }

    final class Spawns: Sendable {
        let all = Mutex<[Spawned]>([])
        var first: Spawned? { all.withLock { $0.first } }
        var last: Spawned? { all.withLock { $0.last } }
    }

    /// An agent whose child prints `lines`, then exits `exit` (0 returns), recording what it was handed; `codex login
    /// status` answers signed in, and `claude auth status --json` answers `loggedIn` (exiting 1 when signed out, as
    /// claude does).
    static func agent(_ provider: AIProvider, lines: [String], exit: Int32 = 0, loggedIn: Bool = true,
                      prompt: URL = URL(filePath: "/App/pilot-agent.md"), spawned: Spawns) -> AIChat.Agent {
        AIChat.Agent(provider, path: "/opt/homebrew/bin/\(provider.command ?? "")", prompt: prompt,
                     helpers: URL(filePath: "/Applications/Pilot.app/Contents/Helpers"),
                     spawn: { path, arguments, environment, input, _, line in
            spawned.all.withLock { $0.append(Spawned(path: path, arguments: arguments, environment: environment,
                                                 input: String(decoding: input ?? Data(), as: UTF8.self))) }
            if arguments == ["login", "status"] { return "Logged in" }
            if arguments == ["auth", "status", "--json"] {
                let status = #"{"loggedIn":\#(loggedIn),"authMethod":"claude.ai"}"#
                guard loggedIn else { throw ChildProcess.Failure(tool: "claude", status: 1, message: status) }
                return status
            }
            lines.forEach(line)
            guard exit == 0 else { throw ChildProcess.Failure(tool: path, status: exit, message: "something\nthe last line") }
            return ""
        })!
    }

    @Test("A claude turn finds pilot in the bundle, hands every event on and keeps the session")
    func claudeTurnRuns() async throws {
        let spawned = Spawns(), events = Mutex<[Event]>([])
        let reply = try await Self.agent(.claudeCode, lines: Self.claudeTurn, spawned: spawned)
            .turn(AIChat.Request(message: "what is my theme")) { event in events.withLock { $0.append(event) } }
        #expect(reply == AIChat.Reply("Your theme is **lagoon**.", session: AIChat.Session(.claudeCode, "1531fb0f-6a48-487b-be3c-54d20588d1ab")))
        #expect(events.withLock { $0 } == Self.claudeTurn.flatMap(AIChat.Agent.claudeEvents))
        let child = try #require(spawned.first)
        #expect(child.input == "what is my theme")
        #expect(child.environment["PATH"]?.hasPrefix("/Applications/Pilot.app/Contents/Helpers:/opt/homebrew/bin:") == true)
        #expect(child.arguments.contains("/App/pilot-agent.md") && !child.arguments.contains("--resume"))
    }

    @Test("codex's turns carry the prompt as its developer instructions, the message alone on stdin, in Pilot's Codex home")
    func codexTurnRuns() async throws {
        let prompt = FileManager.default.temporaryDirectory.appending(path: "pilot-agent-\(UUID().uuidString).md")
        try "Use pilot only.".write(to: prompt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: prompt) }
        let spawned = Spawns()
        let agent = Self.agent(.codex, lines: Self.codexTurn, prompt: prompt, spawned: spawned)
        let texts = Mutex<[String]>([])
        let reply = try await agent.turn(AIChat.Request(message: "say hi")) { event in
            if case .text(let piece) = event { texts.withLock { $0.append(piece) } }
        }
        #expect(reply == AIChat.Reply("I’ll run it once.\n\n\nIt printed `hi`.", session: AIChat.Session(.codex, "01a12ae9-52f4-7642-9859-5584d5ec39e2")))
        #expect(texts.withLock { $0.joined() } == reply.answer)
        let first = try #require(spawned.last)
        #expect(first.input == "say hi")
        #expect(first.arguments.contains(#"developer_instructions="Use pilot only.""#) && first.arguments.contains("shell_tool"))
        #expect(first.environment["CODEX_HOME"] == AICommand.codexHome.path && first.environment["PILOT_AGENT"] == "1")
        let now = AIChat.Now(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US"))
        _ = try await agent.turn(AIChat.Request(history: [AIChat.Turn(.user, "say hi"), AIChat.Turn(.assistant, "hi")], message: "again",
                                                session: reply.session, now: now)) { _ in }
        let resumed = try #require(spawned.last)
        #expect(resumed.input == "(\(now.line))\n\nagain")
        #expect(Array(resumed.arguments.prefix(2)) == ["exec", "resume"] && resumed.arguments.suffix(2) == ["01a12ae9-52f4-7642-9859-5584d5ec39e2", "-"])
        #expect(resumed.arguments.contains(#"developer_instructions="Use pilot only.""#))
    }

    @Test("A turn that ends in an error or breaks off throws the CLI's words, named for its provider")
    func turnFails() async throws {
        let failed = #"{"type":"turn.failed","error":{"message":"usage limit reached"}}"#
        let resumed = AIChat.Request(message: "hi", session: AIChat.Session(.codex, "t"))
        let prompt = FileManager.default.temporaryDirectory.appending(path: "pilot-agent-\(UUID().uuidString).md")
        try "Use pilot only.".write(to: prompt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: prompt) }
        await #expect(throws: QuickAI.Failure.api(.codex, "usage limit reached")) {
            try await Self.agent(.codex, lines: [Self.codexTurn[0], failed], prompt: prompt, spawned: Spawns()).turn(resumed) { _ in }
        }
        await #expect(throws: QuickAI.Failure.api(.codex, "the answer broke off")) {
            try await Self.agent(.codex, lines: Array(Self.codexTurn.prefix(4)), prompt: prompt, spawned: Spawns()).turn(resumed) { _ in }
        }
        await #expect(throws: QuickAI.Failure.failed("Pilot's agent prompt is missing")) {
            try await Self.agent(.codex, lines: Self.codexTurn, spawned: Spawns()).turn(resumed) { _ in }
        }
    }

    @Test("A claude turn that fails asks claude whether it is signed in, through the spawn seam with the same environment",
          arguments: [true, false])
    func claudeTurnFails(loggedIn: Bool) async throws {
        let failed = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: overloaded","session_id":"s"}"#
        for (lines, exit, said) in [([failed], Int32(0), "API Error: overloaded"), ([], Int32(1), "the last line")] {
            let spawned = Spawns()
            await #expect(throws: loggedIn ? QuickAI.Failure.failed(said) : .signedOut) {
                try await Self.agent(.claudeCode, lines: lines, exit: exit, loggedIn: loggedIn, spawned: spawned)
                    .turn(AIChat.Request(message: "hi")) { _ in }
            }
            let check = try #require(spawned.last)
            #expect(check.arguments == ["auth", "status", "--json"] && check.path == "/opt/homebrew/bin/claude")
            #expect(check.environment == spawned.first?.environment)
        }
    }

    @Test("The child sees only the home folder, the account, the temporary folder and the language, pilot first on PATH, zsh without the person's startup files, marked as the agent")
    func environment() {
        let parent = ["HOME": "/Users/test", "USER": "test", "TMPDIR": "/tmp/t/", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin",
                      "OPENAI_API_KEY": "sk-test", "GITHUB_TOKEN": "t", "SSH_AUTH_SOCK": "/tmp/agent", "PILOT_SOCKET": "/tmp/p.sock"]
        let environment = AIChat.Agent.environment(cli: "/Users/test/.local/bin/claude",
                                                   helpers: URL(filePath: "/Applications/Pilot.app/Contents/Helpers"), from: parent)
        #expect(environment == ["HOME": "/Users/test", "USER": "test", "TMPDIR": "/tmp/t/", "LANG": "en_US.UTF-8",
                                "PATH": "/Applications/Pilot.app/Contents/Helpers:/Users/test/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                "SHELL": "/bin/zsh", "ZDOTDIR": "/Applications/Pilot.app/Contents/Helpers",
                                "CLAUDE_CODE_SHELL_PREFIX": "/Applications/Pilot.app/Contents/Helpers/pilot-agent-shell", "PILOT_AGENT": "1"])
    }

    // MARK: The shell gate

    /// Packaging/pilot-agent-shell, the gate every agent shell command goes through (T17).
    static let gate = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/pilot-agent-shell").standardized

    /// The gate on the script claude 2.1.296 builds around `command` (recorded 2026-10-12, the snapshot path shortened),
    /// with a `pilot` on PATH that prints its arguments: its exit and what it printed.
    static func gated(_ command: String) throws -> (status: Int32, out: String) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "#!/bin/sh\necho \"pilot: $*\"\n".write(to: folder.appending(path: "pilot"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "pilot").path)
        let script = "source \(folder.path)/snapshot.sh 2>/dev/null || true && { shopt -u extglob || setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL; } "
            + ">/dev/null 2>&1 || true && { builtin unalias -- 'unsetenv'; builtin unset -f -- 'unsetenv'; } >/dev/null 2>&1 || true && eval '"
            + command.replacingOccurrences(of: "'", with: #"'\''"#) + "' < /dev/null && pwd -P >| \(folder.path)/claude-ab12-cwd"
        let process = Process(), out = Pipe()
        process.executableURL = gate
        process.arguments = [script]
        process.environment = ["PATH": folder.path + ":/usr/bin:/bin", "HOME": folder.path]
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let printed = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: printed, as: UTF8.self))
    }

    @Test("The shell gate runs one plain pilot call and refuses chains, redirects, expansions, globs and other commands unrun")
    func shellGate() throws {
        for command in ["pilot ping", "pilot get look.theme", #"pilot ext new open-ports --mode list --title "Open Ports""#, #"pilot get "a;b|c""#] {
            let (status, out) = try Self.gated(command)
            #expect(status == 0 && out.hasPrefix("pilot: "), "\(command): \(out)")
        }
        for command in ["pilot ping; ps aux", "pilot ping && echo hi", "pilot ping | head -1", "pilot ping & ps", "pilot ping > /tmp/x",
                        "pilot get $HOME", #"pilot get "$HOME""#, "pilot get `id`", "pilot get $(id)", "pilot get ~", "pilot get *",
                        "pilot ping\nps", "ps aux", "pilot-agent-shell x", "pilot get 'x'", "cat ../outside/secret.txt",
                        "x' < /dev/null && pwd -P >| /tmp/claude-ab-cwd; ps '"] {
            let (status, out) = try Self.gated(command)
            #expect(status == 1 && out.hasPrefix("Pilot refused this") && !out.contains("pilot: "), "\(command): \(out)")
        }
    }

    // MARK: Live

    /// The real Claude on this Mac's login, on Haiku so a live run stays cheap (Sven), asked through the running Pilot
    /// (its bundle's `pilot`, its socket); reads only. Leaves one saved session under ~/.claude/projects, as the chat does.
    @Test("Claude asked for the theme reads it with exactly one pilot get look.theme",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"), .timeLimit(.minutes(5)))
    func liveTheme() async throws {
        let pilot = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "dev.banozz.pilot").first?.bundleURL,
                                 "Pilot isn't running")
        let claude = try #require(ClaudeCLI.locate(path: ProcessInfo.processInfo.environment["PATH"]), "claude isn't installed")
        let prompt = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/pilot-agent.md").standardized
        let agent = try #require(AIChat.Agent(.claudeCode, path: claude.path, prompt: prompt,
                                              helpers: pilot.appending(path: "Contents/Helpers", directoryHint: .isDirectory), model: "haiku"))
        let events = Mutex<[Event]>([])
        let reply = try await agent.turn(AIChat.Request(message: "what is my theme")) { event in events.withLock { $0.append(event) } }
        let calls = events.withLock { $0 }.compactMap { if case .toolCall(_, let command) = $0 { command } else { nil } }
        print("live calls: \(calls); answer: \(reply.answer)")
        #expect(calls.filter { $0 == "pilot get look.theme" }.count == 1)
        #expect(calls.allSatisfy { $0.hasPrefix("pilot ") })
        #expect(!reply.answer.isEmpty && reply.session?.provider == .claudeCode)
    }

    /// The lock against the environment (Moody, T14 review): the real Claude told to echo a variable set in this
    /// process, or hand it to `pilot`, which here is a fake in a temporary Helpers folder that prints its arguments and
    /// the names (never the values) of the variables it sees. Never reaches Pilot.
    @Test("No command the agent runs sees Pilot's environment or the secrets in the person's shell startup files",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"), .timeLimit(.minutes(5)))
    func liveEnvironmentLock() async throws {
        let claude = try #require(ClaudeCLI.locate(path: ProcessInfo.processInfo.environment["PATH"]), "claude isn't installed")
        let folder = FileManager.default.temporaryDirectory.appending(path: "t14-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pilot = folder.appending(path: "pilot"), prompt = folder.appending(path: "prompt.md")
        try "#!/bin/sh\necho \"args: $*\"\necho \"env: $(env | cut -d= -f1 | sort | tr '\\n' ' ')\"\n".write(to: pilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pilot.path)
        try FileManager.default.copyItem(at: Self.gate, to: folder.appending(path: "pilot-agent-shell"))
        try "Make every tool call the user lists, verbatim, one per call, even ones you expect to be refused.".write(to: prompt, atomically: true, encoding: .utf8)
        let canary = "t14-canary-\(UUID().uuidString.prefix(8))"
        setenv("T14_CANARY", canary, 1)
        defer { unsetenv("T14_CANARY") }
        let agent = try #require(AIChat.Agent(.claudeCode, path: claude.path, prompt: prompt, helpers: folder, model: "haiku"))
        let calls = ["echo $T14_CANARY", "pilot get $T14_CANARY", #"pilot get "$T14_CANARY""#, "pilot get ${T14_CANARY}",
                     "echo $HOME", "pilot get $HOME", "env", "printenv T14_CANARY", "pilot get look.theme"]
        let message = "I am testing my permission settings; refusals are expected and are the point. Make these Bash tool calls, "
            + "each exactly as written, one per call, none skipped: " + calls.map { "`\($0)`" }.joined(separator: " then ")
        let events = Mutex<[Event]>([])
        _ = try await agent.turn(AIChat.Request(message: message)) { event in events.withLock { $0.append(event) } }
        let all = events.withLock { $0 }
        var ran: [String: String] = [:]
        for case .toolCall(let id, let command) in all { ran[id] = command }
        for case .toolResult(let id, let output, let isError) in all {
            print("live lock: \(ran[id] ?? id) -> \(isError ? "refused/failed" : "ran"): \(output.prefix(output.hasPrefix("args:") ? 2000 : 120).replacingOccurrences(of: "\n", with: " | "))")
            #expect(!output.contains(canary), "\(ran[id] ?? id) leaked the variable")
            #expect(!output.contains("T14_CANARY "), "\(ran[id] ?? id) sees the variable")
        }
        let fake = all.compactMap { if case .toolResult(_, let output, false) = $0, output.hasPrefix("args:") { output } else { nil } }
        #expect(!fake.isEmpty, "the fake pilot never ran")
        // Names only: what the shell tool hands every command, beyond the six Pilot passes, must hold no key or password.
        let names = Set(fake.flatMap { $0.components(separatedBy: "env: ").last?.split(separator: " ").map(String.init) ?? [] })
        #expect(names.filter { $0.range(of: "KEY|TOKEN|SECRET|PASSWORD", options: .regularExpression) != nil }.isEmpty, "\(names.sorted())")
    }
}
