import Foundation
import Synchronization
import Testing
@testable import PilotCore

/// The ChatGPT subscription (story 162): codex as a child, every run faked through PlanCLI's spawn seam, so nothing
/// logs in, runs a CLI or touches the network. The lines are codex's own: `codex exec --json` 0.162.1 as run on
/// 2026-10-10.
@Suite("Plan CLIs")
struct PlanCLITests {
    /// What a fake child was handed.
    struct Call: Sendable { let arguments: [String], environment: [String: String], input: Data?, timeout: Duration }

    final class Calls: Sendable {
        let all = Mutex<[Call]>([])
        var list: [Call] { all.withLock { $0 } }
    }

    /// A CLI whose run prints `lines` and then exits with `exit` (0 returns), and whose `codex login status` exits
    /// `status`.
    static func cli(_ provider: AIProvider, lines: [String] = [], exit: Int32 = 0, status: Int32 = 0,
                    thrown: (any Error & Sendable)? = nil, calls: Calls = Calls()) -> PlanCLI {
        PlanCLI(provider, path: "/opt/homebrew/bin/\(provider.command ?? "")", spawn: { _, arguments, environment, input, timeout, line in
            calls.all.withLock { $0.append(Call(arguments: arguments, environment: environment, input: input, timeout: timeout)) }
            if arguments == ["login", "status"] {
                guard status == 0 else { throw ChildProcess.Failure(tool: "codex", status: status, message: "Not logged in") }
                return "Logged in using ChatGPT"
            }
            lines.forEach(line)
            if let thrown { throw thrown }
            guard exit == 0 else { throw ChildProcess.Failure(tool: provider.command ?? "", status: exit, message: "something\nthe last line") }
            return ""
        })
    }

    static let codexAnswer = [#"{"type":"thread.started","thread_id":"01a1"}"#, #"{"type":"turn.started"}"#,
                              #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"the cat sat"}}"#,
                              #"{"type":"turn.completed","usage":{"input_tokens":20645,"output_tokens":7}}"#]

    @Test("The subscription is listed after Claude's, with no key, a CLI, an account and the Homebrew package Install offers")
    func providers() {
        #expect(Array(AIProvider.allCases.prefix(2)) == [.claudeCode, .codex] && AIProvider.codex.title == "ChatGPT subscription")
        #expect(AIProvider.codex.key == .none && AIProvider.codex.isPlan && !AIProvider.codex.listsModels && AIProvider.codex.keyPage == nil)
        #expect(AIProvider.codex.command == "codex" && AIProvider.claudeCode.command == "claude" && AIProvider.codex.installPackage == "cask:codex")
        #expect(!AIProvider.claudeCode.isPlan && AIProvider.openAI.command == nil && AIModelList.request(.codex, base: nil, key: nil) == nil)
        #expect(AIProvider.allCases.filter(\.isPlan) == [.codex])
        #expect(AIProvider.allCases.filter(\.takesEffort) == [.claudeCode, .codex, .anthropicAPI, .openAI])
    }

    @Test("codex runs exec as JSON lines, saving nothing, read-only, outside the person's config, the text never in its arguments")
    func codexArguments() {
        let args = PlanCLI.arguments(.codex, for: .fix("teh secret text"))
        #expect(args.starts(with: ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--sandbox", "read-only"]))
        #expect(args.contains(#"model_reasoning_effort="low""#) && !args.contains("--model"))
        #expect(args.last?.hasPrefix(QuickAI.fixPrompt) == true && args.last?.contains("<stdin>") == true)
        #expect(!args.contains { $0.contains("secret") })
        #expect(PlanCLI.arguments(.codex, for: .ask("hi"), effort: .high).contains(#"model_reasoning_effort="high""#))
        let picked = PlanCLI.arguments(.codex, for: .ask("hi"), model: "gpt-5.5")
        #expect(picked.firstIndex(of: "--model").map { picked[$0 + 1] } == "gpt-5.5" && picked.last?.hasPrefix(QuickAI.askPrompt) == true)
    }

    @Test("codex's models are its own catalog's listed ones in its order")
    func models() async throws {
        let catalog = #"{"models":[{"slug":"gpt-b","visibility":"list","priority":2},{"slug":"hidden","visibility":"hide","priority":0},"#
            + #"{"slug":"gpt-a","visibility":"list","priority":1}]}"#
        #expect(PlanCLI.models(catalog) == ["gpt-a", "gpt-b"] && PlanCLI.models("not json") == nil)
        let ran = Mutex<[[String]]>([])
        let codex = PlanCLI(.codex, path: "/opt/homebrew/bin/codex", spawn: { _, arguments, _, _, _, _ in
            ran.withLock { $0.append(arguments) }
            return catalog
        })
        #expect(try await codex.models() == ["gpt-a", "gpt-b"] && ran.withLock { $0 } == [["debug", "models"]])
    }

    @Test("codex gets the tool PATH, its own folder first")
    func environments() {
        let codex = PlanCLI.environment("/opt/homebrew/Caskroom/codex/0.162.1/bin/codex")
        #expect(codex["PATH"]?.hasPrefix("/opt/homebrew/Caskroom/codex/0.162.1/bin:") == true)
    }

    @Test("codex's lines read as text, a stop or an error; its retries are not parsed")
    func events() {
        #expect(Self.codexAnswer.compactMap { PlanCLI.event(.codex, $0) } == [.text("the cat sat"), .stop("done")])
        #expect(PlanCLI.event(.codex, #"{"type":"error","message":"Reconnecting... 2/5"}"#) == nil)
        #expect(PlanCLI.event(.codex, #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Falling back"}}"#) == nil)
        let wrapped = #"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'x' model is not supported when using Codex with a ChatGPT account.\"}}"}}"#
        #expect(PlanCLI.event(.codex, wrapped) == .error("The 'x' model is not supported when using Codex with a ChatGPT account."))
        #expect(PlanCLI.event(.codex, #"{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized"}}"#)
            == .error("unexpected status 401 Unauthorized"))
        #expect(PlanCLI.event(.codex, "Do you want to continue? [Y/n]: ") == nil)
    }

    @Test("A run hands the text on stdin and the answer on as it comes, within the timeout")
    func runs() async throws {
        let calls = Calls(), pieces = Mutex<[String]>([])
        let codex = Self.cli(.codex, lines: Self.codexAnswer, calls: calls)
        #expect(try await codex.run(.fix("teh cat sat")) { p in pieces.withLock { $0.append(p) } } == "the cat sat")
        #expect(calls.list.first?.input == Data("teh cat sat".utf8) && calls.list.first?.timeout == .seconds(120))
        #expect(pieces.withLock { $0 } == ["the cat sat"])
        let twice = Self.cli(.codex, lines: [Self.codexAnswer[2], Self.codexAnswer[2], Self.codexAnswer[3]])
        #expect(try await twice.run(.ask("q")) { _ in } == "the cat sat\n\nthe cat sat")
    }

    @Test("Failures name the provider and the fix: not connected, the CLI's own words, broken off, out of time, stopped")
    func failures() async {
        func failure(_ cli: PlanCLI) async -> QuickAI.Failure? {
            do throws(QuickAI.Failure) { _ = try await cli.run(.ask("q")) { _ in }; return nil } catch { return error }
        }
        let failed = #"{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized"}}"#
        #expect(await failure(Self.cli(.codex, lines: [failed], exit: 1, status: 1)) == .notConnected(.codex))
        #expect(await failure(Self.cli(.codex, lines: [failed], exit: 1)) == .api(.codex, "unexpected status 401 Unauthorized"))
        #expect(await failure(Self.cli(.codex, exit: 2)) == .api(.codex, "the last line"))
        #expect(await failure(Self.cli(.codex, lines: Array(Self.codexAnswer.prefix(3)))) == .api(.codex, "the answer broke off"))
        #expect(await failure(Self.cli(.codex, thrown: ChildProcess.TimedOut(tool: "codex"))) == .timedOut)
        #expect(await failure(Self.cli(.codex, thrown: CancellationError())) == .cancelled)
        #expect(QuickAI.Failure.notConnected(.codex).message == "Codex is not connected. Press Connect on the AI page to sign in with your ChatGPT account, then try again.")
        #expect(QuickAI.Failure.notInstalled(.codex).message == "Codex is not installed. Pilot found no codex command; press Install on the AI page.")
    }

    @Test("Login state: codex login status exits 0 signed in and 1 not, anything else cannot tell")
    func loginState() async {
        #expect(await Self.cli(.codex).signedIn())
        #expect(await !Self.cli(.codex, status: 1).signedIn())
        #expect(await Self.cli(.codex, status: 2).signedIn())
    }

    @Test("Connect runs codex login, then asks whether it took")
    func connect() async throws {
        let calls = Calls()
        try await Self.cli(.codex, calls: calls).connect()
        #expect(calls.list.map(\.arguments) == [["login"], ["login", "status"]] && calls.list.first?.input == nil)
        #expect(calls.list.first?.timeout == .seconds(600))
    }

    @Test("A Connect that did not take says so: still signed out, the CLI's words, stopped")
    func connectFails() async {
        func failure(_ cli: PlanCLI) async -> QuickAI.Failure? {
            do throws(QuickAI.Failure) { try await cli.connect(); return nil } catch { return error }
        }
        #expect(await failure(Self.cli(.codex, status: 1)) == .notConnected(.codex))
        #expect(await failure(Self.cli(.codex, exit: 1, status: 1)) == .api(.codex, "Sign-in did not finish: the last line"))
        #expect(await failure(Self.cli(.codex, lines: [#"{"type":"turn.failed","error":{"message":"Authentication cancelled by user."}}"#],
                                       exit: 1, status: 1)) == .api(.codex, "Sign-in did not finish: Authentication cancelled by user."))
        #expect(await failure(Self.cli(.codex, status: 1, thrown: CancellationError())) == .cancelled)
        #expect(await failure(Self.cli(.codex, status: 1, thrown: ChildProcess.TimedOut(tool: "codex"))) == .notConnected(.codex))
    }

    @Test("codex is found on the PATH, else in Homebrew's folders; never for a provider with no CLI")
    func locate() {
        let found = PlanCLI.locate(.codex, path: "/usr/bin:/somewhere/bin") { $0 == "/somewhere/bin/codex" }
        #expect(found?.path == "/somewhere/bin/codex" && found?.provider == .codex)
        #expect(PlanCLI.locate(.codex, path: nil) { $0 == "/opt/homebrew/bin/codex" }?.path == "/opt/homebrew/bin/codex")
        #expect(PlanCLI.locate(.codex, path: "/usr/bin") { _ in false } == nil)
        #expect(PlanCLI.locate(.openAI, path: "/usr/bin") { _ in true } == nil && PlanCLI.locate(.claudeCode, path: "/usr/bin") { _ in true } == nil)
    }
}
