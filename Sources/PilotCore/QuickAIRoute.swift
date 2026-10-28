import Foundation
import Synchronization

/// How Quick AI reaches a model (task N10, Sven 2026-10-09: "everyone uses their own"; any provider, 2026-10-10: "yes all
/// own key"; every subscription, story 162): the Claude Code or codex CLI on whoever's Claude or ChatGPT login is on
/// this Mac, that person's own Anthropic or OpenAI key from the Keychain, Ollama on this Mac, or any server that speaks
/// OpenAI's chat API. Nothing of Sven's ships. The list is the AI page's: every provider in order, the first being a
/// fresh Mac's.
public enum AIProvider: String, CaseIterable, Sendable {
    case claudeCode, codex, anthropicAPI, openAI, ollama, openAICompatible

    public var title: String {
        switch self {
        case .claudeCode: "Claude subscription"
        case .codex: "ChatGPT subscription"
        case .anthropicAPI: "Anthropic API key"
        case .openAI: "OpenAI"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    /// The provider in a sentence: "No OpenAI API key set".
    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .anthropicAPI: "Anthropic"
        case .openAI: "OpenAI"
        case .ollama: "Ollama"
        case .openAICompatible: "The endpoint"
        }
    }

    public var detail: String {
        switch self {
        case .claudeCode: "Your Claude plan, through the claude app's command line (Claude Code) signed in on this Mac."
        case .codex: "Your ChatGPT plan, through OpenAI's codex command line, connected to your ChatGPT account on this Mac."
        case .anthropicAPI: "Your own key from console.anthropic.com, kept in your Keychain and billed to your account."
        case .openAI: "Your own key from platform.openai.com, kept in your Keychain and billed to your account."
        case .ollama: "Models running on this Mac in Ollama: no key, and nothing leaves the Mac."
        case .openAICompatible: "Any server that speaks OpenAI's chat API, such as OpenRouter or LM Studio, with its key if it needs one."
        }
    }

    public enum Key: Sendable { case none, required, optional }

    /// Whether the route takes a key from the Keychain.
    public var key: Key {
        switch self {
        case .claudeCode, .codex, .ollama: .none
        case .anthropicAPI, .openAI: .required
        case .openAICompatible: .optional
        }
    }

    /// Where the person makes a key.
    public var keyPage: URL? {
        switch self {
        case .anthropicAPI: URL(string: "https://console.anthropic.com/settings/keys")
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .claudeCode, .codex, .ollama, .openAICompatible: nil
        }
    }

    /// The OpenAI-shaped API's address, as the person sees it; Ollama's and the endpoint's are theirs to change, the
    /// endpoint having none until they type it.
    public var defaultBaseURL: String? {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .ollama: "http://localhost:11434"
        case .claudeCode, .codex, .anthropicAPI, .openAICompatible: nil
        }
    }

    public var editsBaseURL: Bool { self == .ollama || self == .openAICompatible }

    /// Where `/chat/completions` and `/models` hang: Ollama serves OpenAI's API under `/v1` of its own address.
    public func apiBase(_ baseURL: URL) -> URL { self == .ollama ? baseURL.appendingPathComponent("v1") : baseURL }

    /// The models offered before any list is fetched, the first being the route's default: the CLI keeps today's route
    /// (no --model, nil), the APIs start on a fast model, quick fixes being the main use. Ollama and the endpoint offer
    /// what their server lists, or, for the endpoint, the id typed.
    public var models: [AIModelChoice] {
        switch self {
        case .claudeCode: [.init(nil, "Claude Code's default"), .init("haiku", "Haiku"), .init("sonnet", "Sonnet"), .init("opus", "Opus")]
        case .codex: [.init(nil, "Codex's default")]
        case .anthropicAPI: [.init("claude-haiku-4-5", "Haiku 4.5", effort: false), .init("claude-sonnet-5-5", "Sonnet 5.5"),
                             .init("claude-opus-5-5", "Opus 5.5")]
        case .openAI: [.init("gpt-5-mini", "GPT-5 mini")]
        case .ollama, .openAICompatible: []
        }
    }

    /// Whether the provider has a list of models to fetch over its API.
    public var listsModels: Bool { command == nil }

    /// Whether Refresh lists more models: an API's list, or codex's own catalog (PlanCLI.models).
    public var refreshesModels: Bool { listsModels || self == .codex }

    /// Whether the route takes an effort (AIEffort): claude's and codex's flags, the Anthropic and OpenAI APIs' fields.
    /// Ollama and the endpoints have no shared field for it.
    public var takesEffort: Bool { [.claudeCode, .codex, .anthropicAPI, .openAI].contains(self) }

    /// The command line a subscription runs through.
    public var command: String? {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        default: nil
        }
    }

    /// A subscription Connect signs in to (PlanCLI); Claude Code keeps its own sign-in.
    public var isPlan: Bool { account != nil }

    /// Whose account Connect signs in with.
    public var account: String? {
        switch self {
        case .codex: "ChatGPT"
        default: nil
        }
    }

    /// The Homebrew package Install offers when the command is missing (`brew info`, 2026-10-10: codex is a cask).
    public var installPackage: String? {
        switch self {
        case .codex: "cask:codex"
        default: nil
        }
    }

    /// Whether the person types the model's id: an endpoint may list none.
    public var typesModel: Bool { self == .openAICompatible }

    /// An address to show in an empty field and in the hint for a missing one.
    public var addressExample: String { defaultBaseURL ?? "https://openrouter.ai/api/v1" }
}

/// How hard the model thinks before it answers (Sven 2026-10-10): claude's `--effort`, codex's `model_reasoning_effort`,
/// the Anthropic API's `output_config.effort`, OpenAI's `reasoning_effort`. Low, the default, keeps a quick fix quick.
public enum AIEffort: String, CaseIterable, Sendable {
    case low, medium, high

    public var title: String { rawValue.capitalized }
}

public struct AIModelChoice: Hashable, Sendable {
    /// The CLI's alias or the API's model id; nil is the CLI's own default.
    public let id: String?
    public let title: String
    /// Takes the Anthropic API's effort setting; Haiku 4.5 rejects it (claude-api skill, 2026-10-09). The CLI handles
    /// its own; a model fetched from a list is sent none.
    public let effort: Bool

    public init(_ id: String?, _ title: String, effort: Bool = true) { self.id = id; self.title = title; self.effort = effort }
}

/// Where the API keys live: the Keychain in Pilot, a fake in tests. Never UserDefaults, a file or the log.
public protocol AIKeyStore: Sendable {
    func key(_ provider: AIProvider) -> String?
    /// Whether a key is saved, read without the secret (attributes need no unlock and raise no prompt).
    func hasKey(_ provider: AIProvider) -> Bool
    /// Saves `key`, or removes it when nil.
    func setKey(_ key: String?, for provider: AIProvider) throws
}

/// The login Keychain: one item per provider, the Anthropic one kept where it always was.
public struct KeychainAIKeys: AIKeyStore {
    static func item(_ provider: AIProvider) -> KeychainItem {
        let account = switch provider {
        case .anthropicAPI: "anthropic-api-key"
        case .openAI: "openai-api-key"
        default: "\(provider.rawValue)-api-key"
        }
        return KeychainItem(service: "dev.banozz.pilot.ai", account: account, label: "Pilot Quick AI: \(provider.title) key")
    }

    public init() {}

    public func key(_ provider: AIProvider) -> String? { Self.item(provider).read() }
    public func hasKey(_ provider: AIProvider) -> Bool { Self.item(provider).exists() }
    public func setKey(_ key: String?, for provider: AIProvider) throws { try Self.item(provider).write(key) }
}

/// The network under the API routes: URLSession in Pilot, a fake in tests.
public protocol AIHTTP: Sendable {
    /// Sends `request`, handing each line of the body to `line` as it arrives; returns the HTTP status once the body ends.
    func send(_ request: URLRequest, line: @escaping @Sendable (String) -> Void) async throws -> Int
}

public struct URLSessionAIHTTP: AIHTTP {
    /// Ephemeral: no cache, cookies or credentials on disk.
    static let session = URLSession(configuration: .ephemeral)

    public init() {}

    public func send(_ request: URLRequest, line: @escaping @Sendable (String) -> Void) async throws -> Int {
        let (bytes, response) = try await Self.session.bytes(for: request)
        for try await text in bytes.lines { line(text) }
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// What a line of any provider's stream says.
public enum AIStreamEvent: Equatable, Sendable {
    case text(String)
    /// Why the answer ended: Anthropic's stop_reason, OpenAI's finish_reason, or `[DONE]`.
    case stop(String)
    /// An error event in the stream (overloaded, say).
    case error(String)
}

/// The parts every API route shares: the streamed run, a failed status in words, the error body's message.
public enum AIStream {
    /// Sends `request` and reads its server-sent events with `parse`, handing each piece of the answer to `text` as it
    /// arrives; returns the whole answer.
    static func run(_ request: URLRequest, provider: AIProvider, http: any AIHTTP, parse: @escaping @Sendable (String) -> AIStreamEvent?,
                    text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> String {
        let (status, got) = try await stream(request, provider: provider, http: http, parse: parse, text: text)
        try check(status: status, got, provider: provider)
        return got.answer
    }

    /// The body read to its end, each line parsed once as it arrives, with the status; `object` also hears each event's
    /// JSON (the tool loop's calls, AIChat.APIAgent). A thrown network error as Quick AI's failure.
    static func stream(_ request: URLRequest, provider: AIProvider, http: any AIHTTP, parse: @escaping @Sendable (String) -> AIStreamEvent?,
                       object: (@Sendable ([String: Any]) -> Void)? = nil,
                       text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> (status: Int, read: Read.Result) {
        let read = Read(parse)
        let status: Int
        do {
            status = try await http.send(request) { line in
                if case .text(let piece) = read.add(line) { text(piece) }
                if let object, line.hasPrefix("data:"),
                   let json = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] { object(json) }
            }
        } catch {
            throw failure(error, provider: provider, url: request.url)
        }
        return (status, read.result)
    }

    /// A read stream's failure, if it has one: a failed status, an error event, a refusal, or no end.
    static func check(status: Int, _ got: Read.Result, provider: AIProvider) throws(QuickAI.Failure) {
        guard status == 200 else { throw failure(status: status, body: got.body, provider: provider) }
        if let why = got.error { throw .api(provider, why) }
        if got.stop == "refusal" || got.stop == "content_filter" { throw .api(provider, "The model declined this request.") }
        guard got.stop != nil else { throw .api(provider, "the answer broke off") }
    }

    /// A thrown network error as Quick AI's failure: nothing listening is the address's fault, so it says which.
    static func failure(_ error: any Error, provider: AIProvider, url: URL?) -> QuickAI.Failure {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        let address = url.flatMap { u in u.host.map { "\(u.scheme ?? "http")://\($0)\(u.port.map { ":\($0)" } ?? "")" } } ?? "that address"
        switch (error as? URLError)?.code {
        case .cancelled?: return .cancelled
        case .timedOut?: return .timedOut
        case .cannotConnectToHost?, .cannotFindHost?, .networkConnectionLost?, .dnsLookupFailed?: return .unreachable(provider, address)
        case .appTransportSecurityRequiresSecureConnection?:
            return .api(provider, "Pilot reaches \(address) only over https; use an https address, or one on this Mac.")
        default: return .api(provider, error.localizedDescription)
        }
    }

    /// A failed status as Quick AI's failure, the API's own words when its body has them. A 400 that names the API key
    /// is a refused key too.
    public static func failure(status: Int, body: String, provider: AIProvider) -> QuickAI.Failure {
        let said = message(body)
        switch status {
        case 401, 403: return .keyRejected(provider)
        case 400 where said?.localizedCaseInsensitiveContains("api key") == true: return .keyRejected(provider)
        case 429: return .api(provider, said ?? "Rate limited; wait a moment and try again.")
        default: return .api(provider, said.map { "\($0) (HTTP \(status))" } ?? "HTTP \(status)")
        }
    }

    /// An error body's own words: `{"error":{"message":…}}` (Anthropic, OpenAI), the same in a one-item array,
    /// or `{"error":"…"}` (Ollama).
    static func message(_ body: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { return nil }
        let object = (json as? [Any])?.first as? [String: Any] ?? json as? [String: Any]
        return object.flatMap(message(in:))
    }

    static func message(in object: [String: Any]) -> String? {
        let error = object["error"]
        if let error = error as? [String: Any] { return error["message"] as? String }
        return error as? String
    }

    /// What the body said so far, each line parsed once as it arrives: the answer, the first stop reason, a stream
    /// error, and the lines that are no event (an error status's JSON body).
    final class Read: Sendable {
        struct Result { var answer = "", stop: String?, error: String?, body = "" }
        private let state = Mutex(Result())
        private let parse: @Sendable (String) -> AIStreamEvent?

        init(_ parse: @escaping @Sendable (String) -> AIStreamEvent?) { self.parse = parse }

        func add(_ line: String) -> AIStreamEvent? {
            let event = parse(line)
            state.withLock { r in
                switch event {
                case .text(let piece): r.answer += piece
                case .stop(let reason): r.stop = r.stop ?? reason
                case .error(let why): r.error = r.error ?? why
                case nil: if !line.hasPrefix("event:") && !line.hasPrefix("data:") { r.body += line }
                }
            }
            return event
        }

        var result: Result { state.withLock { $0 } }
    }
}

/// The Messages API with the person's own key, streamed (curl shape in the claude-api skill, 2026-10-09): Quick AI's
/// prompts as the system prompt, the text as the one user message, the AI page's effort where the model takes it.
public struct AnthropicAPI: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let models = URL(string: "https://api.anthropic.com/v1/models?limit=100")!

    let key: String, model: AIModelChoice, effort: AIEffort, http: any AIHTTP

    public init(key: String, model: AIModelChoice, effort: AIEffort = .low, http: any AIHTTP = URLSessionAIHTTP()) {
        self.key = key; self.model = model; self.effort = effort; self.http = http
    }

    /// Thinking is left adaptive: it cannot be turned off on Opus 5.5.
    public static func body(for job: QuickAI.Job, model: AIModelChoice, effort: AIEffort = .low) -> [String: Any] {
        body(system: job.prompt, turns: [AIChat.Turn(.user, job.text)], model: model, effort: effort)
    }

    /// The chat's whole history as the messages, oldest first (story 166).
    public static func body(system: String, turns: [AIChat.Turn], model: AIModelChoice, effort: AIEffort = .low) -> [String: Any] {
        body(system: system, messages: messages(turns), model: model, effort: effort)
    }

    /// The body round messages already in the API's shape: the chat's, or a tool turn's (AIChat.APIAgent).
    static func body(system: String, messages: [[String: Any]], model: AIModelChoice, effort: AIEffort) -> [String: Any] {
        var body: [String: Any] = ["model": model.id ?? "", "max_tokens": 8192, "stream": true, "system": system, "messages": messages]
        if model.effort { body["output_config"] = ["effort": effort.rawValue] }
        return body
    }

    static func messages(_ turns: [AIChat.Turn]) -> [[String: Any]] { turns.map { ["role": $0.role.rawValue, "content": content($0)] } }

    /// A turn's text, or its picture's image block then the text (story 191).
    static func content(_ turn: AIChat.Turn) -> Any {
        guard let image = turn.image else { return turn.text }
        return [image.anthropicBlock, ["type": "text", "text": turn.text]]
    }

    /// The headers every Anthropic call carries; the key in its own header, never the body.
    static func request(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    func request(_ body: [String: Any]) -> URLRequest {
        var request = Self.request(Self.endpoint, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// One server-sent event line; nil for event names, pings and the blocks' start and stop.
    public static func event(_ line: String) -> AIStreamEvent? {
        guard line.hasPrefix("data:"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { return nil }
        let delta = object["delta"] as? [String: Any]
        switch object["type"] as? String {
        case "content_block_delta":
            guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String else { return nil }
            return .text(text)
        case "message_delta":
            return (delta?["stop_reason"] as? String).map(AIStreamEvent.stop)
        case "error":
            return .error(AIStream.message(in: object) ?? "the stream broke off")
        default:
            return nil
        }
    }

    /// Runs the job, handing each piece of the answer to `text` as it arrives; returns the whole answer.
    public func run(_ job: QuickAI.Job, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> String {
        try await AIStream.run(request(Self.body(for: job, model: model, effort: effort)), provider: .anthropicAPI, http: http,
                               parse: Self.event, text: text)
    }

    /// One chat turn: the whole history sent again.
    public func chat(_ chat: AIChat.Request, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> AIChat.Reply {
        let body = Self.body(system: chat.prompt, turns: chat.turns, model: model, effort: effort)
        return AIChat.Reply(try await AIStream.run(request(body), provider: .anthropicAPI, http: http, parse: Self.event, text: text))
    }
}

/// OpenAI's Chat Completions API, streamed, which OpenAI, Ollama (`/v1`) and
/// the endpoints people point Pilot at all speak: Quick AI's prompt as the system message, the text as the user's.
public struct OpenAIChat: Sendable {
    let provider: AIProvider, base: URL, key: String?, model: String, effort: AIEffort, http: any AIHTTP

    /// `base` is the API's (AIProvider.apiBase), under which `/chat/completions` hangs; `key` nil sends no
    /// Authorization (Ollama, a local server).
    public init(provider: AIProvider, base: URL, key: String?, model: String, effort: AIEffort = .low, http: any AIHTTP = URLSessionAIHTTP()) {
        self.provider = provider; self.base = base; self.key = key; self.model = model; self.effort = effort; self.http = http
    }

    /// The AI page's effort (low by default) on OpenAI's own reasoning models (GPT-5 and the o series), which think at
    /// medium by default and would make a quick fix slow; every other model, and every other server, is sent none.
    public static func body(for job: QuickAI.Job, model: String, provider: AIProvider, effort: AIEffort = .low) -> [String: Any] {
        body(system: job.prompt, turns: [AIChat.Turn(.user, job.text)], model: model, provider: provider, effort: effort)
    }

    /// The system message, then the chat's whole history, oldest first (story 166).
    public static func body(system: String, turns: [AIChat.Turn], model: String, provider: AIProvider, effort: AIEffort = .low) -> [String: Any] {
        body(system: system, messages: messages(turns), model: model, provider: provider, effort: effort)
    }

    /// The system message, then messages already in the API's shape: the chat's, or a tool turn's (AIChat.APIAgent).
    static func body(system: String, messages: [[String: Any]], model: String, provider: AIProvider, effort: AIEffort) -> [String: Any] {
        var body: [String: Any] = ["model": model, "stream": true, "messages": [["role": "system", "content": system]] + messages]
        if provider == .openAI && reasons(model) { body["reasoning_effort"] = effort.rawValue }
        return body
    }

    static func messages(_ turns: [AIChat.Turn]) -> [[String: Any]] { turns.map { ["role": $0.role.rawValue, "content": content($0)] } }

    /// A turn's text, or the text then its picture as a data URL (story 191): OpenAI's models read it; Ollama and an
    /// endpoint only on a model that reads images, a text-only one answering with its own refusal.
    static func content(_ turn: AIChat.Turn) -> Any {
        guard let image = turn.image else { return turn.text }
        return [["type": "text", "text": turn.text], ["type": "image_url", "image_url": ["url": image.dataURL]]]
    }

    public static func reasons(_ model: String) -> Bool {
        (model.hasPrefix("gpt-5") && !model.contains("chat")) || (model.first == "o" && model.dropFirst().first?.isNumber == true)
    }

    /// The bearer header when there is a key.
    static func request(_ url: URL, key: String?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 120)
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func request(_ body: [String: Any]) -> URLRequest {
        var request = Self.request(base.appendingPathComponent("chat/completions"), key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// One server-sent event line: a choice's text, its finish_reason, `[DONE]`, or an error object; nil otherwise.
    public static func event(_ line: String) -> AIStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return .stop("done") }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return nil }
        if object["error"] != nil { return .error(AIStream.message(in: object) ?? "the stream broke off") }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return nil }
        if let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty { return .text(text) }
        return (choice["finish_reason"] as? String).map(AIStreamEvent.stop)
    }

    /// Runs the job, handing each piece of the answer to `text` as it arrives; returns the whole answer.
    public func run(_ job: QuickAI.Job, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> String {
        try await AIStream.run(request(Self.body(for: job, model: model, provider: provider, effort: effort)), provider: provider, http: http,
                               parse: Self.event, text: text)
    }

    /// One chat turn: the whole history sent again.
    public func chat(_ chat: AIChat.Request, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> AIChat.Reply {
        let body = Self.body(system: chat.prompt, turns: chat.turns, model: model, provider: provider, effort: effort)
        return AIChat.Reply(try await AIStream.run(request(body), provider: provider, http: http, parse: Self.event, text: text))
    }
}

/// A provider's model list, fetched only when the person presses Refresh: Anthropic's `/v1/models`, or `/models` under
/// an OpenAI-shaped API's address, each `{"data":[{"id":…}]}`.
public enum AIModelList {
    /// The request for `provider`'s list; nil for the CLI, which has none.
    public static func request(_ provider: AIProvider, base: URL?, key: String?) -> URLRequest? {
        guard provider.listsModels else { return nil }
        switch provider {
        case .anthropicAPI: return AnthropicAPI.request(AnthropicAPI.models, key: key ?? "")
        default: return base.map { OpenAIChat.request(provider.apiBase($0).appendingPathComponent("models"), key: key) }
        }
    }

    /// Words in the id of a model that does not chat: embeddings, speech, pictures, moderation.
    static let notChat = ["embed", "tts", "whisper", "dall-e", "audio", "realtime", "transcribe", "moderation", "image", "imagen",
                          "veo", "davinci", "babbage", "search", "aqa", "sora"]

    /// The chat models' ids in a list's body: a `models/` prefix dropped, Anthropic's newest-first order kept,
    /// every other list sorted. Nil when the body is no list.
    public static func ids(_ body: String, provider: AIProvider) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let data = object["data"] as? [[String: Any]] else { return nil }
        let ids = data.compactMap { $0["id"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .filter { id in let id = id.lowercased(); return !notChat.contains { id.contains($0) } }
        return provider == .anthropicAPI ? ids : ids.sorted()
    }

    /// Fetches the list.
    public static func fetch(_ provider: AIProvider, base: URL?, key: String?, http: any AIHTTP) async throws(QuickAI.Failure) -> [String] {
        guard let request = request(provider, base: base, key: key) else { return [] }
        let body = Mutex("")
        let status: Int
        do {
            status = try await http.send(request) { line in body.withLock { $0 += line + "\n" } }
        } catch {
            throw AIStream.failure(error, provider: provider, url: request.url)
        }
        let text = body.withLock { $0 }
        guard status == 200 else { throw AIStream.failure(status: status, body: text, provider: provider) }
        guard let ids = Self.ids(text, provider: provider) else { throw .api(provider, "The model list came back in a shape Pilot does not read.") }
        return ids
    }
}
