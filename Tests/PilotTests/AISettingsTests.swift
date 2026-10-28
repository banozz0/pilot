import Foundation
@testable import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// Pilot › AI (task N10; any provider, 2026-10-10): the provider Quick AI takes, with a fake Keychain and a fake
/// network, so no real key is read or written and nothing is sent.
@Suite("AI settings")
@MainActor
struct AISettingsTests {
    final class FakeKeys: AIKeyStore {
        let saved = Mutex<[AIProvider: String]>([:])
        func key(_ provider: AIProvider) -> String? { saved.withLock { $0[provider] } }
        func hasKey(_ provider: AIProvider) -> Bool { saved.withLock { $0[provider] != nil } }
        func setKey(_ key: String?, for provider: AIProvider) throws { saved.withLock { $0[provider] = key } }
    }

    struct NoNetwork: AIHTTP {
        func send(_ request: URLRequest, line: @escaping @Sendable (String) -> Void) async throws -> Int {
            Issue.record("sent a request")
            return 500
        }
    }

    /// Answers a model list or a chat with what each asks for, keeping every request.
    final class FakeServer: AIHTTP {
        let list: String
        let sent = Mutex<[URLRequest]>([])
        init(list: String = #"{"data":[]}"#) { self.list = list }

        func send(_ request: URLRequest, line: @escaping @Sendable (String) -> Void) async throws -> Int {
            sent.withLock { $0.append(request) }
            if request.url?.lastPathComponent == "models" {
                line(list)
            } else {
                [#"data: {"choices":[{"delta":{"content":"OK"},"finish_reason":null}]}"#, "data: [DONE]"].forEach(line)
            }
            return 200
        }

        var last: URLRequest? { sent.withLock { $0.last } }
    }

    func settings(_ defaults: UserDefaults, keys: FakeKeys = FakeKeys(), http: any AIHTTP = NoNetwork()) -> AISettings {
        let settings = AISettings(defaults: defaults, keys: keys, http: http)
        settings.findCLI = { nil }
        settings.findPlan = { _ in nil }
        return settings
    }

    func failure(_ route: Result<QuickAI.Runner, QuickAI.Failure>) -> QuickAI.Failure? {
        if case .failure(let why) = route { why } else { nil }
    }

    @Test("A fresh Mac uses the Claude subscription on the CLI's own default; each API starts on a fast model, Ollama on localhost")
    func defaults() throws {
        let ai = settings(try #require(UserDefaults(suiteName: testSuite())))
        #expect(ai.provider == .claudeCode && ai.model(for: .claudeCode)?.id == nil && ai.model(for: .anthropicAPI)?.id == "claude-haiku-4-5")
        #expect(ai.model(for: .openAI)?.id == "gpt-5-mini")
        #expect(ai.model(for: .ollama) == nil && ai.model(for: .openAICompatible) == nil && ai.keyed.isEmpty)
        #expect(ai.address(for: .ollama) == "http://localhost:11434" && ai.address(for: .openAICompatible) == "")
        #expect(!AIProvider.allCases.contains(where: ai.ready))
    }

    @Test("The chat starts over after 30 minutes unused on a fresh Mac; the pick is kept across launches")
    func chatReset() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let ai = settings(defaults)
        #expect(ai.chatReset == .minutes30)
        ai.chatReset = .hour1
        #expect(settings(defaults).chatReset == .hour1 && defaults.string(forKey: "ai.chatReset") == "hour1")
        defaults.set("gone", forKey: "ai.chatReset")
        #expect(settings(defaults).chatReset == .minutes30, "an unknown value falls back to 30 minutes")
    }

    @Test("Each provider not ready says what it lacks: Claude Code missing, no key, no model, no address")
    func missing() throws {
        let ai = settings(try #require(UserDefaults(suiteName: testSuite())))
        #expect(failure(ai.runner()) == .missing)
        for keyed in [AIProvider.anthropicAPI, .openAI] {
            ai.provider = keyed
            #expect(failure(ai.runner()) == .noKey(keyed))
        }
        ai.provider = .ollama
        #expect(failure(ai.runner())?.title == "Ollama is not set up" && failure(ai.runner())?.hint?.contains("Refresh") == true)
        ai.provider = .openAICompatible
        ai.setModel("some/model", for: .openAICompatible)
        #expect(failure(ai.runner())?.hint?.contains("address") == true)
    }

    @Test("A saved key goes to its provider's store item trimmed, never into UserDefaults; an empty one removes it")
    func key() throws {
        let suite = testSuite(), defaults = try #require(UserDefaults(suiteName: suite)), keys = FakeKeys()
        let ai = settings(defaults, keys: keys)
        ai.provider = .openAI
        try ai.setKey("  test-openai-sample\n", for: .openAI)
        #expect(keys.key(.openAI) == "test-openai-sample" && ai.hasKey(.openAI) && !ai.hasKey(.anthropicAPI) && ai.ready(.openAI))
        #expect(failure(ai.runner()) == nil)
        try ai.setKey("test-anthropic-sample", for: .anthropicAPI)
        #expect(settings(defaults, keys: keys).keyed == [.openAI, .anthropicAPI])
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(!stored.values.contains { "\($0)".contains("sample") })
        try ai.setKey("   ", for: .openAI)
        #expect(keys.key(.openAI) == nil && !ai.hasKey(.openAI) && keys.key(.anthropicAPI) == "test-anthropic-sample")
    }

    @Test("The provider, every model, the fetched lists and the addresses are kept across launches; a model gone falls back")
    func persists() throws {
        let suite = testSuite(), defaults = try #require(UserDefaults(suiteName: suite))
        let ai = settings(defaults)
        ai.provider = .anthropicAPI
        ai.setModel("claude-opus-5-5", for: .anthropicAPI)
        ai.setModel("haiku", for: .claudeCode)
        ai.setAddress(" https://openrouter.example.test/api/v1/ ", for: .openAICompatible)
        ai.setModel(" vendor/model-x ", for: .openAICompatible)
        let again = settings(defaults)
        #expect(again.provider == .anthropicAPI && again.model(for: .anthropicAPI)?.id == "claude-opus-5-5"
            && again.model(for: .claudeCode)?.id == "haiku")
        #expect(again.address(for: .openAICompatible) == "https://openrouter.example.test/api/v1" && again.model(for: .openAICompatible)?.id == "vendor/model-x")
        defaults.set("claude-gone-1", forKey: AISettings.modelKey(.anthropicAPI))
        #expect(settings(defaults).model(for: .anthropicAPI)?.id == "claude-haiku-4-5")
        again.setAddress("", for: .ollama)
        #expect(again.address(for: .ollama) == "http://localhost:11434")
        again.setAddress("not a url", for: .openAICompatible)
        #expect(again.baseURL(for: .openAICompatible) == nil)
    }

    @Test("Refresh keeps Ollama's list, offers it and picks its first; a run then goes to Ollama's /v1 with no key")
    func ollama() async throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let server = FakeServer(list: #"{"object":"list","data":[{"id":"qwen3:4b"},{"id":"llama3.2:latest"}]}"#)
        let ai = settings(defaults, http: server)
        ai.provider = .ollama
        #expect(await ai.refreshModels(for: .ollama) == nil)
        #expect(server.last?.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(ai.models(for: .ollama).map(\.id) == ["llama3.2:latest", "qwen3:4b"] && ai.ready(.ollama))
        #expect(settings(defaults).model(for: .ollama)?.id == "llama3.2:latest")
        ai.setModel("qwen3:4b", for: .ollama)
        #expect(await ai.test() == nil)
        let sent = try #require(server.last)
        #expect(sent.url?.absoluteString == "http://localhost:11434/v1/chat/completions" && sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(String(decoding: sent.httpBody ?? Data(), as: UTF8.self).contains(#""model":"qwen3:4b""#))
    }

    @Test("Refresh adds the fetched models after the fixed ones; a keyed provider with no key fetches nothing")
    func refresh() async throws {
        let keys = FakeKeys(), server = FakeServer(list: #"{"data":[{"id":"gpt-5-mini"},{"id":"gpt-5"},{"id":"text-embedding-3-large"}]}"#)
        let ai = settings(try #require(UserDefaults(suiteName: testSuite())), keys: keys, http: server)
        #expect(await ai.refreshModels(for: .openAI) == .noKey(.openAI))
        #expect(server.sent.withLock { $0.isEmpty })
        try ai.setKey("test-openai-sample", for: .openAI)
        #expect(await ai.refreshModels(for: .openAI) == nil)
        #expect(ai.models(for: .openAI).map(\.id) == ["gpt-5-mini", "gpt-5"])
        #expect(server.last?.value(forHTTPHeaderField: "Authorization") == "Bearer test-openai-sample")
    }

    @Test("The endpoint runs on its typed address and model, with its key as a bearer header when one is saved")
    func endpoint() async throws {
        let keys = FakeKeys(), server = FakeServer()
        let ai = settings(try #require(UserDefaults(suiteName: testSuite())), keys: keys, http: server)
        ai.provider = .openAICompatible
        ai.setAddress("http://localhost:1234/v1", for: .openAICompatible)
        ai.setModel("local-model", for: .openAICompatible)
        #expect(ai.ready(.openAICompatible))
        #expect(await ai.test() == nil)
        #expect(server.last?.url?.absoluteString == "http://localhost:1234/v1/chat/completions" && server.last?.value(forHTTPHeaderField: "Authorization") == nil)
        try ai.setKey("test-router-sample", for: .openAICompatible)
        #expect(await ai.test() == nil)
        #expect(server.last?.value(forHTTPHeaderField: "Authorization") == "Bearer test-router-sample")
    }

    @Test("Test reports the route's failure without running anything when it is not ready")
    func test() async throws {
        let ai = settings(try #require(UserDefaults(suiteName: testSuite())))
        ai.provider = .anthropicAPI
        #expect(await ai.test() == .noKey(.anthropicAPI))
        ai.provider = .openAI
        #expect(await ai.test() == .noKey(.openAI))
        await ai.refreshCLI()
        #expect(ai.cli == .missing)
    }

    /// A codex whose every run answers OK, logged in once `login` runs, keeping every command line.
    final class FakePlan: Sendable {
        let login = Mutex(false), ran = Mutex<[[String]]>([])

        func cli(_ provider: AIProvider) -> PlanCLI {
            PlanCLI(provider, path: "/opt/homebrew/bin/\(provider.command ?? "")", spawn: { [self] _, arguments, _, _, _, line in
                ran.withLock { $0.append(arguments) }
                if arguments == ["login", "status"] {
                    guard login.withLock({ $0 }) else { throw ChildProcess.Failure(tool: "codex", status: 1, message: "Not logged in") }
                    return "Logged in using ChatGPT"
                }
                if arguments == ["login"] { login.withLock { $0 = true }; return "" }
                line(#"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"OK"}}"#)
                line(#"{"type":"turn.completed","usage":{}}"#)
                return ""
            })
        }
    }

    @Test("Refresh on codex lists its catalog; the picked model and effort reach codex's run")
    func codexModelsAndEffort() async throws {
        let suite = testSuite()
        let ai = settings(try #require(UserDefaults(suiteName: suite)))
        let ran = Mutex<[[String]]>([])
        ai.findPlan = { provider in
            PlanCLI(provider, path: "/opt/homebrew/bin/codex", spawn: { _, arguments, _, _, _, line in
                ran.withLock { $0.append(arguments) }
                if arguments == ["debug", "models"] {
                    return #"{"models":[{"slug":"gpt-6-sol","visibility":"list","priority":1},{"slug":"gpt-x","visibility":"hide"}]}"#
                }
                line(#"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"OK"}}"#)
                line(#"{"type":"turn.completed","usage":{}}"#)
                return ""
            })
        }
        ai.provider = .codex
        #expect(await ai.refreshModels(for: .codex) == nil && ai.asked == [.codex])
        #expect(ai.models(for: .codex).map(\.id) == [nil, "gpt-6-sol"])
        ai.setModel("gpt-6-sol", for: .codex)
        #expect(ai.effort(for: .codex) == .low && ai.takesEffort(.codex) && !ai.takesEffort(.ollama))
        ai.setEffort(.high, for: .codex)
        #expect(await ai.test() == nil)
        let run = try #require(ran.withLock { $0 }.last)
        #expect(run.firstIndex(of: "--model").map { run[$0 + 1] } == "gpt-6-sol" && run.contains(#"model_reasoning_effort="high""#))
        let again = settings(try #require(UserDefaults(suiteName: suite)))
        #expect(again.effort(for: .codex) == .high && again.model(for: .codex)?.id == "gpt-6-sol", "the pick and effort outlive the page")
    }

    @Test("The effort shows only where the picked model takes it, and reaches the APIs' bodies")
    func effort() throws {
        let ai = settings(try #require(UserDefaults(suiteName: testSuite())))
        #expect(!ai.takesEffort(.anthropicAPI), "Haiku 4.5, the default, rejects effort")
        ai.setModel("claude-opus-5-5", for: .anthropicAPI)
        #expect(ai.takesEffort(.anthropicAPI) && ai.takesEffort(.openAI))
        #expect(!OpenAIChat.reasons("gpt-4.1-mini"), "a model that does not reason gets no effort")
        let opus = AnthropicAPI.body(for: .ask("x"), model: AIModelChoice("claude-opus-5-5", "Opus"), effort: .medium)
        #expect((opus["output_config"] as? [String: String]) == ["effort": "medium"])
        #expect(OpenAIChat.body(for: .ask("x"), model: "gpt-5-mini", provider: .openAI, effort: .high)["reasoning_effort"] as? String == "high")
    }

    @Test("The ChatGPT subscription: missing says not installed, signed out not connected; Connect makes codex ready and a run answers")
    func subscriptions() async throws {
        let ai = settings(try #require(UserDefaults(suiteName: testSuite())))
        ai.provider = .codex
        #expect(failure(ai.runner()) == .notInstalled(.codex) && ai.need(.codex) == "checking")
        await ai.refreshCLI(.codex)
        #expect(ai.need(.codex) == "not installed" && failure(ai.runner())?.hint?.contains("Install") == true)
        #expect(await ai.connect(.codex) == .notInstalled(.codex) && ai.status(.codex) == .missing)
        let fake = FakePlan()
        ai.findPlan = { $0 == .codex ? fake.cli(.codex) : nil }
        ai.provider = .codex
        await ai.refreshCLI(.codex)
        #expect(ai.status(.codex) == .signedOut(path: "/opt/homebrew/bin/codex") && ai.need(.codex) == "not connected")
        #expect(await ai.connect(.codex) == nil)
        #expect(ai.status(.codex) == .signedIn(path: "/opt/homebrew/bin/codex") && ai.ready(.codex) && !ai.connecting(.codex))
        #expect(fake.ran.withLock { $0 }.contains(["login"]))
        #expect(await ai.test() == nil)
        #expect(ai.models(for: .codex).map(\.id) == [nil] && !AIProvider.codex.listsModels)
    }

    @Test("A stored Gemini pick (gemini or geminiCLI, removed 2026-10-12) loads as Claude and is dropped from the defaults")
    func removedGemini() throws {
        for stored in ["gemini", "geminiCLI"] {
            let defaults = try #require(UserDefaults(suiteName: testSuite()))
            defaults.set(stored, forKey: "ai.provider")
            let ai = settings(defaults)
            #expect(ai.provider == .claudeCode && defaults.string(forKey: "ai.provider") == nil)
            #expect(failure(ai.runner()) == .missing, "the runner is Claude Code's, not found in the test")
        }
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        defaults.set("codex", forKey: "ai.provider")
        #expect(settings(defaults).provider == .codex && defaults.string(forKey: "ai.provider") == "codex")
    }
}
