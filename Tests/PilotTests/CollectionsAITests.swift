import Foundation
@testable import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// CLI W14: the AI page's providers as `pilot list ai-providers`, and its Sign in, Connect, Refresh and Test as
/// `pilot ai`. The Keychain, the network and the CLIs are AISettingsTests' fakes, the terminal is a recorder and the
/// gate's decider is the test's: nothing signs in, nothing leaves the Mac, no prompt shows and no real key is read.
@MainActor
@Suite("Collections: AI providers and the AI page's buttons")
final class CollectionsAITests {
    let ai: AISettings
    let keys = AISettingsTests.FakeKeys()
    let server = AISettingsTests.FakeServer(list: #"{"data":[{"id":"m1"},{"id":"m2"}]}"#)
    let control = ControlAI()
    let verbs = ControlVerbs()
    var asked: [ControlGate.Ask] = []
    var allow = false
    var ran: [(command: String, title: String, onSuccess: String)] = []
    var clis: [AIProvider: AISettings.CLIStatus] = [.claudeCode: .signedOut(path: "/opt/homebrew/bin/claude"), .codex: .missing]

    static let secret = "sk-t3st"

    init() throws {
        ai = AISettings(defaults: try #require(UserDefaults(suiteName: testSuite())), keys: keys, http: server)
        ai.findCLI = { nil }
        ai.findPlan = { _ in nil }
        ai.checkCLI = { [unowned self] p in clis[p] ?? .missing }
        control.settings = ai
        control.gate = ControlGate(wait: .seconds(5)) { [unowned self] ask, _ in asked.append(ask); return allow }
        control.run = { [unowned self] in ran.append(($0, $1, $2)) }
        verbs.registerAI(control)
    }

    func answer(_ verb: String, _ args: [String]) async -> ControlAnswer {
        await verbs.answer(ControlRequest(id: .number(1), verb: verb, args: args), peer: nil)
    }

    func object(_ verb: String, _ args: [String]) async -> [String: JSONValue] {
        let got = await answer(verb, args)
        guard case .object(let o) = got.result else { Issue.record("\(verb) \(args) gave no object: \(String(describing: got.error))"); return [:] }
        return o
    }

    func providers() async -> [String: [String: JSONValue]] {
        guard case .array(let rows) = await answer("list", ["ai-providers"]).result else { Issue.record("no rows"); return [:] }
        return Dictionary(uniqueKeysWithValues: rows.compactMap { if case .object(let r) = $0, case .string(let id) = r["id"] { (id, r) } else { nil } })
    }

    @Test("list ai-providers reads each provider's state, command, key set or unset (never the key), model and choices, and is read-only")
    func list() async throws {
        try ai.setKey(Self.secret, for: .openAI)
        guard case .array(let ordered) = await answer("list", ["ai-providers"]).result else { Issue.record("no rows"); return }
        #expect(ordered.count == AIProvider.allCases.count)
        let rows = await providers()
        #expect(rows["claudeCode"] == ["id": .string("claudeCode"), "title": .string("Claude subscription"), "name": .string("Claude Code"),
                                      "picked": .bool(true), "ready": .bool(false), "need": .string("signed out"),
                                      "status": .string("signed-out"), "path": .string("/opt/homebrew/bin/claude"), "model": .string("default"),
                                      "models": .array([("default", "Claude Code's default"), ("haiku", "Haiku"), ("sonnet", "Sonnet"), ("opus", "Opus")]
                                          .map { .object(["id": .string($0.0), "title": .string($0.1)]) })])
        #expect(rows["codex"]?["status"] == .string("missing") && rows["codex"]?["need"] == .string("not installed"))
        #expect(rows["codex"]?["install"] == .string("cask:codex") && rows["codex"]?["connecting"] == .bool(false))
        #expect(rows.count == 6)
        #expect(rows["openAI"]?["key"] == .string("set") && rows["openAI"]?["ready"] == .bool(true) && rows["openAI"]?["status"] == nil)
        #expect(rows["anthropicAPI"]?["key"] == .string("unset") && rows["anthropicAPI"]?["need"] == .string("no key"))
        #expect(rows["ollama"]?["key"] == nil && rows["ollama"]?["model"] == .null && rows["ollama"]?["need"] == .string("no model"))
        #expect(rows["openAICompatible"]?["key"] == .string("unset") && rows["openAICompatible"]?["need"] == .string("not set"))
        let wire = String(decoding: try JSONEncoder().encode(JSONValue.array(ordered)), as: UTF8.self)
        #expect(!wire.contains(Self.secret), "a row never carries the key")
        #expect(await answer("add", ["ai-providers", "--id", "x"]).error == ControlError(.badValue, "ai-providers is read-only"))
    }

    @Test("ai signin asks Allow, then runs claude auth login in a terminal; denied runs nothing; signed in or missing runs nothing")
    func signIn() async {
        #expect(await answer("ai", ["signin"]).error?.code == .denied && ran.isEmpty)
        #expect(asked == [ControlGate.Ask("Sign in to Claude", "'/opt/homebrew/bin/claude' auth login, in a terminal window")])
        allow = true
        let signed = await object("ai", ["signin"])
        #expect(ran.map(\.command) == ["'/opt/homebrew/bin/claude' auth login"] && ran.first?.title == "Sign in to Claude" && ran.first?.onSuccess == "true")
        #expect(signed["ok"] == .bool(true) && signed["status"] == .string("signed-out") && signed["ran"] == .string("'/opt/homebrew/bin/claude' auth login"))
        clis[.claudeCode] = .signedIn(path: "/opt/homebrew/bin/claude")
        let already = await object("ai", ["signin"])
        #expect(already["note"] == .string("already signed in") && already["ready"] == .bool(true) && asked.count == 2 && ran.count == 1)
        clis[.claudeCode] = .missing
        #expect(await answer("ai", ["signin"]).error?.code == .notReady && asked.count == 2)
    }

    @Test("ai connect asks Allow, waits for the browser sign-in and answers the row connected; not installed, Claude Code and an API refuse")
    func connect() async {
        let fake = AISettingsTests.FakePlan()
        ai.checkCLI = nil
        ai.findPlan = { $0 == .codex ? fake.cli(.codex) : nil }
        #expect(await answer("ai", ["connect", "codex"]).error?.code == .denied && fake.ran.withLock { $0 }.isEmpty)
        #expect(asked == [ControlGate.Ask("Connect ChatGPT", "codex login: opens ChatGPT's sign-in in your browser")])
        allow = true
        let connected = await object("ai", ["connect", "codex"])
        #expect(connected["ok"] == .bool(true) && connected["status"] == .string("signed-in") && connected["path"] == .string("/opt/homebrew/bin/codex"))
        #expect(fake.ran.withLock { $0 }.contains(["login"]))
        ai.findPlan = { _ in nil }
        #expect(await answer("ai", ["connect", "codex"]).error == ControlError(.notReady, "Codex is not installed; pilot install pick cask:codex installs it"))
        #expect(await answer("ai", ["connect", "claudeCode"]).error == ControlError(.badValue, "Claude Code signs in with pilot ai signin"))
        #expect(await answer("ai", ["connect", "openAI"]).error?.code == .badValue)
        #expect(await answer("ai", ["connect", "codex", "--cancel"]).error == ControlError(.notReady, "no Connect for Codex is waiting"))
    }

    @Test("ai connect --cancel stops a Connect waiting on the browser; a second connect while it waits joins it without asking")
    func cancel() async throws {
        ai.checkCLI = nil
        ai.findPlan = { p in
            PlanCLI(p, path: "/opt/homebrew/bin/codex", spawn: { _, arguments, _, _, _, _ in
                if arguments == ["login"] { try await Task.sleep(for: .seconds(30)) }
                throw ChildProcess.Failure(tool: "codex", status: 1, message: "Not logged in")
            })
        }
        allow = true
        let first = Task { await object("ai", ["connect", "codex"]) }
        while !ai.connecting(.codex) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await providers()["codex"]?["connecting"] == .bool(true))
        let second = Task { await object("ai", ["connect", "codex"]) }
        // Lets the second request reach the waiting Connect before the cancel.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await object("ai", ["connect", "codex", "--cancel"]) == ["id": .string("codex"), "cancelled": .bool(true)])
        let stopped = await first.value, joined = await second.value
        #expect(stopped["ok"] == .bool(false) && stopped["problem"] == .string("Stopped") && joined["ok"] == .bool(false))
        #expect(asked.count == 1, "the joined request asked nothing")
    }

    @Test("ai models lists the choices by the word set takes; --refresh names claude's versions, fills codex's catalog and an endpoint's list, asking first when the key goes to a settable address")
    func models() async throws {
        #expect(await object("ai", ["models", "claudeCode"])["models"] == .array(["default", "haiku", "sonnet", "opus"].enumerated().map { i, id in
            .object(["id": .string(id), "title": .string(AIProvider.claudeCode.models[i].title)]) }))
        ai.listClaude = { [AIModelChoice(nil, "Claude Code's default · Opus 5.5"), AIModelChoice("opus", "Opus 5.5")] }
        let claude = await object("ai", ["models", "claudeCode", "--refresh"])
        #expect(claude["ok"] == .bool(true) && claude["models"] == .array(zip(["default", "haiku", "sonnet", "opus"], ["Claude Code's default · Opus 5.5", "Haiku", "Sonnet", "Opus 5.5"])
            .map { .object(["id": .string($0), "title": .string($1)]) }))
        ai.findPlan = { p in
            PlanCLI(p, path: "/opt/homebrew/bin/codex", spawn: { _, arguments, _, _, _, _ in
                arguments == ["debug", "models"] ? #"{"models":[{"slug":"gpt-6-sol","visibility":"list","priority":1}]}"# : ""
            })
        }
        let codex = await object("ai", ["models", "codex", "--refresh"])
        #expect(codex["ok"] == .bool(true) && codex["models"] == .array([.object(["id": .string("default"), "title": .string("Codex's default")]),
                                                                          .object(["id": .string("gpt-6-sol"), "title": .string("gpt-6-sol")])]))
        #expect(asked.isEmpty, "codex sends no key")

        try ai.setKey(Self.secret, for: .openAICompatible)
        let unset = await object("ai", ["models", "openAICompatible", "--refresh"])
        #expect(unset["ok"] == .bool(false) && unset["problem"] == .string("The endpoint is not set up") && asked.isEmpty, "no address: nothing to send, so nothing asked")
        ai.setAddress("https://example.invalid/v1", for: .openAICompatible)
        #expect(await answer("ai", ["models", "openAICompatible", "--refresh"]).error?.code == .denied && server.sent.withLock { $0 }.isEmpty)
        #expect(asked == [ControlGate.Ask("Send AI key", "Refresh sends The endpoint's saved key to https://example.invalid/v1")])
        allow = true
        let listed = await object("ai", ["models", "openAICompatible", "--refresh"])
        #expect(listed["ok"] == .bool(true) && listed["models"] == .array(["m1", "m2"].map { .object(["id": .string($0), "title": .string($0)]) }))
        #expect(server.last?.url?.absoluteString == "https://example.invalid/v1/models")
        #expect(await answer("ai", ["models", "nope"]).error?.code == .badValue)
        #expect(await answer("ai", ["models", "codex", "--cancel"]).error?.code == .unknownFlag)
    }

    @Test("ai test asks the picked provider one tiny question: ok, or the page's problem and hint; Refresh's flag is refused")
    func test() async throws {
        ai.provider = .anthropicAPI
        let failed = await object("ai", ["test"])
        #expect(failed["id"] == .string("anthropicAPI") && failed["ok"] == .bool(false))
        #expect(failed["problem"] == .string("No Anthropic API key set") && failed["hint"] != nil)
        ai.provider = .openAI
        try ai.setKey(Self.secret, for: .openAI)
        let works = await object("ai", ["test"])
        #expect(works["ok"] == .bool(true) && works["problem"] == nil && asked.isEmpty)
        #expect(server.last?.url?.host == "api.openai.com")
        #expect(await answer("ai", ["test", "--refresh"]).error?.code == .unknownFlag)
        #expect(await answer("ai", ["nosuch"]).error?.code == .badValue)
        #expect(await answer("ai", []).error?.code == .badRequest)
    }
}
