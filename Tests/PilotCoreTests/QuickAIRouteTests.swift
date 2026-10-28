import Foundation
import Synchronization
import Testing
@testable import PilotCore

/// Quick AI's API route (task N10): the person's own key, the Messages API streamed. A fake network answers; no key and
/// no request ever leaves the Mac here.
@Suite("Quick AI route")
struct QuickAIRouteTests {
    /// Answers every request with `status` and `lines`, keeping the request it was sent.
    final class FakeHTTP: AIHTTP {
        let status: Int, lines: [String], error: URLError?
        let sent = Mutex<URLRequest?>(nil)
        init(status: Int = 200, _ lines: [String], error: URLError.Code? = nil) {
            self.status = status; self.lines = lines; self.error = error.map { URLError($0) }
        }

        func send(_ request: URLRequest, line: @escaping @Sendable (String) -> Void) async throws -> Int {
            sent.withLock { $0 = request }
            if let error { throw error }
            lines.forEach(line)
            return status
        }

        var request: URLRequest? { sent.withLock { $0 } }
    }

    static func delta(_ text: String) -> String {
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#
    }

    static func stop(_ reason: String) -> String {
        #"data: {"type":"message_delta","delta":{"stop_reason":"\#(reason)"},"usage":{"output_tokens":3}}"#
    }

    static let haiku = AIProvider.anthropicAPI.models[0], opus = AIProvider.anthropicAPI.models[2]

    @Test("The body streams the job's prompt and text on the picked model; low effort except on Haiku, which rejects it")
    func body() throws {
        let opus = AnthropicAPI.body(for: .ask("why"), model: Self.opus)
        #expect(opus["model"] as? String == "claude-opus-5-5" && opus["stream"] as? Bool == true && (opus["system"] as? String)?.hasPrefix(QuickAI.askPrompt) == true)
        #expect((opus["messages"] as? [[String: String]]) == [["role": "user", "content": "why"]])
        #expect((opus["output_config"] as? [String: String]) == ["effort": "low"])
        #expect(opus["thinking"] == nil)
        let haiku = AnthropicAPI.body(for: .fix("teh"), model: Self.haiku)
        #expect(haiku["output_config"] == nil && (haiku["system"] as? String)?.hasPrefix(QuickAI.fixPrompt) == true)
    }

    @Test("A stream's lines give text pieces, the stop reason and errors; event names and pings give nothing")
    func events() {
        #expect(AnthropicAPI.event(Self.delta("Fo")) == .text("Fo"))
        #expect(AnthropicAPI.event(Self.stop("end_turn")) == .stop("end_turn"))
        #expect(AnthropicAPI.event(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .error("Overloaded"))
        #expect(AnthropicAPI.event("event: content_block_delta") == nil)
        #expect(AnthropicAPI.event(#"data: {"type":"ping"}"#) == nil)
        #expect(AnthropicAPI.event(#"data: {"type":"message_start","message":{"id":"msg_1"}}"#) == nil)
    }

    @Test("A run sends the key in its header only, streams each piece and returns the whole answer")
    func run() async throws {
        let http = FakeHTTP([#"event: message_start"#, Self.delta("Fo"), Self.delta("ur"), Self.stop("end_turn")])
        let pieces = QuickAITests.Pieces()
        let answer = try await AnthropicAPI(key: "sk-test", model: Self.haiku, http: http).run(.ask("2+2")) { pieces.add($0) }
        #expect(answer == "Four" && pieces.joined == "Four")
        let sent = try #require(http.sent.withLock { $0 })
        #expect(sent.url == AnthropicAPI.endpoint && sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-test" && sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(!String(decoding: sent.httpBody ?? Data(), as: UTF8.self).contains("sk-test"))
    }

    @Test("A refused key, a refusal, an error status and a cut-off stream each fail with words that say what to fix")
    func failures() async {
        func failure(_ http: FakeHTTP) async -> QuickAI.Failure? {
            do throws(QuickAI.Failure) {
                _ = try await AnthropicAPI(key: "k", model: Self.opus, http: http).run(.ask("x")) { _ in }
                return nil
            } catch { return error }
        }
        let rejected = await failure(FakeHTTP(status: 401, [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#]))
        #expect(rejected == .keyRejected(.anthropicAPI) && rejected?.title == "Anthropic API key rejected")
        #expect(await failure(FakeHTTP([Self.stop("refusal")])) == .api(.anthropicAPI, "The model declined this request."))
        #expect(await failure(FakeHTTP(status: 400, [#"{"type":"error","error":{"type":"invalid_request_error","message":"bad model"}}"#]))
            == .api(.anthropicAPI, "bad model (HTTP 400)"))
        #expect(await failure(FakeHTTP([Self.delta("Fo")])) == .api(.anthropicAPI, "the answer broke off"))
        #expect(QuickAI.Failure.noKey(.anthropicAPI).title == "No Anthropic API key set" && QuickAI.Failure.noKey(.openAI).hint?.contains("AI page") == true)
    }

    @Test("The CLI gets --model only when one is picked; none keeps the person's own default")
    func cliModel() {
        #expect(!QuickAI.arguments(for: .ask("x")).contains("--model"))
        let args = QuickAI.arguments(for: .ask("x"), model: "haiku")
        #expect(args.suffix(2) == ["--model", "haiku"])
    }

    @Test("Each route offers its models, the CLI's own default first and the API's fastest model first")
    func models() {
        #expect(AIProvider.claudeCode.models.map(\.id) == [nil, "haiku", "sonnet", "opus"])
        #expect(AIProvider.anthropicAPI.models.map(\.id) == ["claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5"])
        #expect(AIProvider.anthropicAPI.models.map(\.effort) == [false, true, true])
        #expect(AIProvider.openAI.models.map(\.id) == ["gpt-5-mini"])
        #expect(AIProvider.ollama.models.isEmpty && AIProvider.openAICompatible.models.isEmpty)
        #expect(AIProvider.allCases.filter { $0.key == .required } == [.anthropicAPI, .openAI])
    }

    @Test("Each keyed provider has its own Keychain item; the Anthropic one stays where story 133 put it")
    func keychainItems() {
        let accounts = AIProvider.allCases.map { KeychainAIKeys.item($0).account }
        #expect(KeychainAIKeys.item(.anthropicAPI).account == "anthropic-api-key" && Set(accounts).count == accounts.count)
        #expect(AIProvider.allCases.allSatisfy { KeychainAIKeys.item($0).service == "dev.banozz.pilot.ai" })
    }

    // MARK: OpenAI-shaped providers

    static func chunk(_ text: String) -> String {
        #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"\#(text)"},"finish_reason":null}]}"#
    }

    static let finish = #"data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#

    static func chat(_ provider: AIProvider, base: String, key: String?, model: String, _ http: FakeHTTP) -> OpenAIChat {
        OpenAIChat(provider: provider, base: provider.apiBase(URL(string: base)!), key: key, model: model, http: http)
    }

    @Test("The chat body sends the prompt as the system message and the text as the user's; low reasoning only on OpenAI's reasoning models")
    func chatBody() {
        let body = OpenAIChat.body(for: .fix("teh"), model: "gpt-5-mini", provider: .openAI)
        #expect(body["model"] as? String == "gpt-5-mini" && body["stream"] as? Bool == true && body["reasoning_effort"] as? String == "low")
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.map { $0["role"] } == ["system", "user"] && messages?.last?["content"] == "teh")
        #expect(messages?.first?["content"]?.hasPrefix(QuickAI.fixPrompt) == true)
        #expect(OpenAIChat.body(for: .ask("x"), model: "o4-mini", provider: .openAI)["reasoning_effort"] as? String == "low")
        #expect(OpenAIChat.body(for: .ask("x"), model: "gpt-4.1-mini", provider: .openAI)["reasoning_effort"] == nil)
        #expect(OpenAIChat.body(for: .ask("x"), model: "gpt-5-mini", provider: .openAICompatible)["reasoning_effort"] == nil)
        #expect(OpenAIChat.body(for: .ask("x"), model: "llama3.2", provider: .ollama)["reasoning_effort"] == nil)
    }

    @Test("A chat stream's lines give text, the finish reason, [DONE] and errors; the role-only first chunk gives nothing")
    func chatEvents() {
        #expect(OpenAIChat.event(Self.chunk("Fo")) == .text("Fo"))
        #expect(OpenAIChat.event(Self.finish) == .stop("stop"))
        #expect(OpenAIChat.event("data: [DONE]") == .stop("done"))
        #expect(OpenAIChat.event(#"data: {"choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#) == nil)
        #expect(OpenAIChat.event(#"data: {"error":{"message":"overloaded"}}"#) == .error("overloaded"))
        #expect(OpenAIChat.event(": keep-alive") == nil)
    }

    @Test("OpenAI, Ollama and an endpoint each get their own address; the key only as a bearer header, none without one")
    func chatRequests() async throws {
        let lines = [Self.chunk("Fo"), Self.chunk("ur"), Self.finish, "data: [DONE]"]
        let openAI = FakeHTTP(lines), pieces = QuickAITests.Pieces()
        let answer = try await Self.chat(.openAI, base: "https://api.openai.com/v1", key: "test-openai-key", model: "gpt-5-mini", openAI)
            .run(.ask("2+2")) { pieces.add($0) }
        #expect(answer == "Four" && pieces.joined == "Four")
        let sent = try #require(openAI.request)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions" && sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-openai-key")
        #expect(!String(decoding: sent.httpBody ?? Data(), as: UTF8.self).contains("test-openai-key"))

        let ollama = FakeHTTP(lines)
        _ = try await Self.chat(.ollama, base: "http://localhost:11434", key: nil, model: "llama3.2", ollama).run(.ask("x")) { _ in }
        #expect(ollama.request?.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(ollama.request?.value(forHTTPHeaderField: "Authorization") == nil)

        let endpoint = FakeHTTP([Self.chunk("ok"), "data: [DONE]"])
        #expect(try await Self.chat(.openAICompatible, base: "http://localhost:1234/v1", key: "", model: "qwen", endpoint).run(.ask("x")) { _ in } == "ok")
        #expect(endpoint.request?.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(endpoint.request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A refused key (a 400 naming the key too), a missing Ollama model, a filtered answer and nothing listening each say what to fix")
    func chatFailures() async {
        func failure(_ provider: AIProvider, _ http: FakeHTTP, base: String = "https://api.example.test/v1") async -> QuickAI.Failure? {
            do throws(QuickAI.Failure) {
                _ = try await Self.chat(provider, base: base, key: "k", model: "m", http).run(.ask("x")) { _ in }
                return nil
            } catch { return error }
        }
        #expect(await failure(.openAI, FakeHTTP(status: 401, [#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#]))
            == .keyRejected(.openAI))
        #expect(await failure(.openAICompatible, FakeHTTP(status: 400, [#"[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}]"#]))
            == .keyRejected(.openAICompatible))
        #expect(await failure(.ollama, FakeHTTP(status: 404, [#"{"error":"model \"m\" not found, try pulling it first"}"#]), base: "http://localhost:11434")
            == .api(.ollama, #"model "m" not found, try pulling it first (HTTP 404)"#))
        #expect(await failure(.openAI, FakeHTTP(status: 429, [#"{"error":{"message":"You exceeded your current quota"}}"#]))
            == .api(.openAI, "You exceeded your current quota"))
        #expect(await failure(.openAI, FakeHTTP([#"data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#, "data: [DONE]"]))
            == .api(.openAI, "The model declined this request."))
        #expect(await failure(.openAICompatible, FakeHTTP([Self.chunk("Fo")])) == .api(.openAICompatible, "the answer broke off"))
        let down = await failure(.ollama, FakeHTTP([], error: .cannotConnectToHost), base: "http://localhost:11434")
        #expect(down == .unreachable(.ollama, "http://localhost:11434") && down?.title == "Ollama did not answer")
        #expect(down?.hint?.contains("ollama serve") == true)
        #expect(await failure(.openAI, FakeHTTP([], error: .timedOut)) == .timedOut)
        #expect(await failure(.openAI, FakeHTTP([], error: .cancelled)) == .cancelled)
    }

    // MARK: Model lists

    @Test("Refresh asks each provider's own list address with its key; the CLI has none")
    func listRequests() throws {
        let anthropic = try #require(AIModelList.request(.anthropicAPI, base: nil, key: "test-anthropic-key"))
        #expect(anthropic.url == AnthropicAPI.models && "test-anthropic-key" == anthropic.value(forHTTPHeaderField: "x-api-key")
            && anthropic.httpMethod == "GET")
        let openAI = try #require(AIModelList.request(.openAI, base: URL(string: AIProvider.openAI.defaultBaseURL!), key: "test-openai-key"))
        #expect(openAI.url?.absoluteString == "https://api.openai.com/v1/models" && openAI.value(forHTTPHeaderField: "Authorization") == "Bearer test-openai-key")
        let ollama = try #require(AIModelList.request(.ollama, base: URL(string: "http://localhost:11434"), key: nil))
        #expect(ollama.url?.absoluteString == "http://localhost:11434/v1/models" && ollama.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(AIModelList.request(.claudeCode, base: nil, key: nil) == nil)
        #expect(AIModelList.request(.openAICompatible, base: nil, key: nil) == nil)
    }

    @Test("A list keeps the chat models: a models/ prefix dropped, embeddings and speech left out, Anthropic's order kept")
    func listParsing() {
        let openAI = #"{"object":"list","data":[{"id":"gpt-5-mini"},{"id":"text-embedding-3-small"},{"id":"gpt-4.1"},{"id":"tts-1"},{"id":"whisper-1"}]}"#
        #expect(AIModelList.ids(openAI, provider: .openAI) == ["gpt-4.1", "gpt-5-mini"])
        let prefixed = #"{"object":"list","data":[{"id":"models/flash-latest"},{"id":"models/text-embedding-001"},{"id":"models/pro-2"}]}"#
        #expect(AIModelList.ids(prefixed, provider: .openAICompatible) == ["flash-latest", "pro-2"])
        let anthropic = #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"},{"id":"claude-haiku-4-5"}],"has_more":false}"#
        #expect(AIModelList.ids(anthropic, provider: .anthropicAPI) == ["claude-opus-5-5", "claude-haiku-4-5"])
        #expect(AIModelList.ids(#"{"models":[]}"#, provider: .ollama) == nil)
    }

    @Test("Fetching a list reads the whole body; a refused key and nothing listening fail with words")
    func listFetch() async throws {
        let ids = try await AIModelList.fetch(.ollama, base: URL(string: "http://localhost:11434"), key: nil,
                                              http: FakeHTTP([#"{"object":"list","#, #""data":[{"id":"llama3.2:latest"},{"id":"nomic-embed-text"}]}"#]))
        #expect(ids == ["llama3.2:latest"])
        func failure(_ http: FakeHTTP) async -> QuickAI.Failure? {
            do throws(QuickAI.Failure) { _ = try await AIModelList.fetch(.openAI, base: URL(string: "https://api.openai.com/v1"), key: "k", http: http); return nil }
            catch { return error }
        }
        #expect(await failure(FakeHTTP(status: 401, [#"{"error":{"message":"bad key"}}"#])) == .keyRejected(.openAI))
        #expect(await failure(FakeHTTP([], error: .cannotFindHost)) == .unreachable(.openAI, "https://api.openai.com"))
        #expect(await failure(FakeHTTP(["<html>"])) == .api(.openAI, "The model list came back in a shape Pilot does not read."))
    }
}
