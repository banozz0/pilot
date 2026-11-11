import Foundation
import Observation
import PilotCore

/// The AI page (task N10; any provider, 2026-10-10): which provider Quick AI's ask and fix take and on which model; each
/// provider's key in the Keychain, the rest (route, models, fetched lists, addresses) in UserDefaults. Read on every run,
/// so a change applies to the next question. The network is used only by a run, Test or Refresh.
@Observable @MainActor
final class AISettings {
    static let shared = AISettings()

    /// What a CLI route (Claude Code, codex) looks like on this Mac.
    enum CLIStatus: Equatable {
        case checking, missing
        case signedOut(path: String), signedIn(path: String)
    }

    private let defaults: UserDefaults
    @ObservationIgnored let keys: any AIKeyStore
    @ObservationIgnored let http: any AIHTTP
    /// Looked up on every run, so Claude Code installed while Pilot runs is found.
    @ObservationIgnored var findCLI: () -> ClaudeCLI? = { ClaudeCLI.locate(path: ProcessInfo.processInfo.environment["PATH"]) }
    /// Finds codex, looked up on every run and check (story 162).
    @ObservationIgnored var findPlan: (AIProvider) -> PlanCLI? = { PlanCLI.locate($0, path: ProcessInfo.processInfo.environment["PATH"]) }
    /// Stands in for `claude auth status` and `codex login status` in the renders.
    @ObservationIgnored var checkCLI: ((AIProvider) async -> CLIStatus)?
    /// Stands in for claude's `/model` in the renders (ClaudeCLI.models).
    @ObservationIgnored var listClaude: (() async throws(QuickAI.Failure) -> [AIModelChoice])?

    var provider: AIProvider {
        didSet { defaults.set(provider.rawValue, forKey: "ai.provider") }
    }

    /// How long the AI chat sits unused before its next open starts a new chat; 30 minutes on a fresh Mac.
    var chatReset: AIChat.Reset {
        didSet { defaults.set(chatReset.rawValue, forKey: "ai.chatReset") }
    }

    /// The AI that answers when the picked one fails for usage, billing or sign-in (AIFallback, P95); nil is None, a fresh
    /// Mac's.
    var fallback: AIProvider? {
        didSet { defaults.set(fallback?.rawValue, forKey: "ai.fallback") }
    }
    /// Each route's pick, by model id or alias; a route with none runs its default (nil being the CLI's own).
    private var picked: [AIProvider: String] = [:]
    /// Each route's effort; a route with none runs low.
    private var efforts: [AIProvider: AIEffort] = [:]
    /// Each provider's list from its last Refresh.
    private var fetched: [AIProvider: [String]] = [:]
    /// Each row's name from the last Refresh where the list names its models, by id ("" for the CLI's default): claude's
    /// aliases with the version each runs ("Opus 5.5").
    private var titles: [AIProvider: [String: String]] = [:]
    /// The providers whose list was asked for since launch, so the AI page lists codex's by itself once.
    @ObservationIgnored private(set) var asked: Set<AIProvider> = []
    /// Ollama's and the endpoint's address as typed.
    private var addresses: [AIProvider: String] = [:]
    /// The providers with a key saved, read without the secret.
    private(set) var keyed: Set<AIProvider> = []
    /// Each CLI route's status, kept here, not in the page, so a page redrawn or reopened shows the last answer while it
    /// asks again.
    private(set) var clis: [AIProvider: CLIStatus] = [:]
    /// Each Connect still waiting on the browser.
    private var connects: [AIProvider: Task<QuickAI.Failure?, Never>] = [:]

    func connecting(_ provider: AIProvider) -> Bool { connects[provider] != nil }

    func status(_ provider: AIProvider) -> CLIStatus { clis[provider] ?? .checking }
    var cli: CLIStatus { status(.claudeCode) }

    init(defaults: UserDefaults = .pilot(), keys: any AIKeyStore = KeychainAIKeys(), http: any AIHTTP = URLSessionAIHTTP()) {
        self.defaults = defaults
        self.keys = keys
        self.http = http
        let stored = defaults.string(forKey: "ai.provider"), known = stored.flatMap(AIProvider.init(rawValue:))
        // A pick Pilot no longer offers (gemini or geminiCLI, removed 2026-10-12) is dropped, so Claude is the pick.
        if stored != nil && known == nil { defaults.removeObject(forKey: "ai.provider") }
        provider = known ?? .claudeCode
        chatReset = defaults.string(forKey: "ai.chatReset").flatMap(AIChat.Reset.init(rawValue:)) ?? .standard
        fallback = defaults.string(forKey: "ai.fallback").flatMap(AIProvider.init(rawValue:))
        for route in AIProvider.allCases {
            picked[route] = defaults.string(forKey: Self.modelKey(route))
            efforts[route] = defaults.string(forKey: Self.effortKey(route)).flatMap(AIEffort.init(rawValue:))
            fetched[route] = defaults.stringArray(forKey: Self.listKey(route))
            titles[route] = defaults.dictionary(forKey: Self.titlesKey(route)) as? [String: String]
            addresses[route] = defaults.string(forKey: Self.addressKey(route))
            if route.key != .none && keys.hasKey(route) { keyed.insert(route) }
        }
    }

    static func modelKey(_ provider: AIProvider) -> String { "ai.model.\(provider.rawValue)" }
    static func listKey(_ provider: AIProvider) -> String { "ai.models.\(provider.rawValue)" }
    static func titlesKey(_ provider: AIProvider) -> String { "ai.modelTitles.\(provider.rawValue)" }
    static func effortKey(_ provider: AIProvider) -> String { "ai.effort.\(provider.rawValue)" }
    static func addressKey(_ provider: AIProvider) -> String { "ai.baseURL.\(provider.rawValue)" }

    /// The provider's fixed models, then those its last Refresh listed, each under the name that Refresh gave it.
    func models(for provider: AIProvider) -> [AIModelChoice] {
        let fixed = provider.models, named = titles[provider] ?? [:]
        return fixed.map { AIModelChoice($0.id, named[$0.id ?? ""] ?? $0.title, effort: $0.effort) }
            + (fetched[provider] ?? []).filter { id in !fixed.contains { $0.id == id } }.map { AIModelChoice($0, named[$0] ?? $0, effort: false) }
    }

    /// The pick when it is still offered (the endpoint's typed id always is), else the default; nil when Ollama or the
    /// endpoint has nothing yet.
    func model(for provider: AIProvider) -> AIModelChoice? {
        let offered = models(for: provider)
        if let id = picked[provider] {
            if let choice = offered.first(where: { $0.id == id }) { return choice }
            if provider.typesModel { return AIModelChoice(id, id, effort: false) }
        }
        return offered.first
    }

    func setModel(_ id: String?, for provider: AIProvider) {
        let id = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        picked[provider] = id?.isEmpty == false ? id : nil
        defaults.set(picked[provider], forKey: Self.modelKey(provider))
    }

    func effort(for provider: AIProvider) -> AIEffort { efforts[provider] ?? .low }

    func setEffort(_ effort: AIEffort, for provider: AIProvider) {
        efforts[provider] = effort
        defaults.set(effort.rawValue, forKey: Self.effortKey(provider))
    }

    /// Whether the picked model takes the effort: every claude and codex model, the Anthropic models that accept it, and
    /// OpenAI's reasoning models.
    func takesEffort(_ provider: AIProvider) -> Bool {
        guard provider.takesEffort else { return false }
        switch provider {
        case .anthropicAPI: return model(for: provider)?.effort == true
        case .openAI: return model(for: provider)?.id.map(OpenAIChat.reasons) == true
        default: return true
        }
    }

    /// The address as typed, else the provider's own.
    func address(for provider: AIProvider) -> String { addresses[provider] ?? provider.defaultBaseURL ?? "" }

    /// Saves a typed address, trimmed and without a trailing slash; an empty one goes back to the default.
    func setAddress(_ text: String, for provider: AIProvider) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        addresses[provider] = trimmed.isEmpty ? nil : trimmed
        defaults.set(addresses[provider], forKey: Self.addressKey(provider))
    }

    /// The address as a URL Pilot can call: http or https with a host.
    func baseURL(for provider: AIProvider) -> URL? {
        guard let url = URL(string: address(for: provider)), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
        return url
    }

    func hasKey(_ provider: AIProvider) -> Bool { keyed.contains(provider) }

    /// Saves a pasted key, trimmed; an empty one removes it. Never logged.
    func setKey(_ key: String?, for provider: AIProvider) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try keys.setKey(trimmed.isEmpty ? nil : trimmed, for: provider)
        if trimmed.isEmpty { keyed.remove(provider) } else { keyed.insert(provider) }
        ailog.notice("quick AI: \(provider.rawValue, privacy: .public) key \(trimmed.isEmpty ? "removed" : "saved", privacy: .public)")
    }

    /// What the provider still lacks for a run, as far as Pilot can tell without the network, as its chip; nil when
    /// it is ready.
    func need(_ provider: AIProvider) -> String? {
        switch provider {
        case .claudeCode, .codex:
            switch status(provider) {
            case .checking: "checking"
            case .missing: "not installed"
            case .signedOut: provider.isPlan ? "not connected" : "signed out"
            case .signedIn: nil
            }
        case .anthropicAPI, .openAI: hasKey(provider) ? nil : "no key"
        case .ollama: model(for: provider) == nil ? "no model" : nil
        case .openAICompatible: baseURL(for: provider) != nil && model(for: provider) != nil ? nil : "not set"
        }
    }

    func ready(_ provider: AIProvider) -> Bool { need(provider) == nil }

    /// The key from the Keychain and the API's address an API call needs, or what is missing.
    private func access(_ provider: AIProvider) -> Result<(key: String?, base: URL?), QuickAI.Failure> {
        let key = provider.key == .none ? nil : keys.key(provider)
        if provider.key == .required && key?.isEmpty != false { return .failure(.noKey(provider)) }
        let base = baseURL(for: provider)
        if provider != .anthropicAPI && base == nil {
            return .failure(.notSetUp(provider, "Add the API's address on the AI page, such as \(provider.addressExample)."))
        }
        return .success((key, base))
    }

    /// The fallback a run may use: none when it is unset or is the picked provider (picked after it was set).
    var fallbackInUse: AIProvider? { fallback == provider ? nil : fallback }

    /// What the Fallback picker offers: every other provider that is set up, and the one already picked though it is not
    /// (a CLI still being checked, a key just removed).
    var fallbackChoices: [AIProvider] { AIProvider.allCases.filter { $0 != provider && (ready($0) || $0 == fallback) } }

    /// The runner for the picked provider with its fallback behind it, or why there is none; `told` hears when the fallback
    /// answered, a tip unless the surface has a line of its own. `effort` given runs it at that effort whatever the AI page
    /// picks (the bind editor's Suggest with AI: low, Q124).
    func runner(effort: AIEffort? = nil, told: @escaping AIFallback.Tell = AISettings.tip) -> Result<QuickAI.Runner, QuickAI.Failure> {
        routeWithFallback(effort: effort, told: told).map { $0.run(_:text:) }
    }

    /// AI chat's runner for the picked provider (story 166) with its fallback behind it, or why there is none. The reply
    /// carries the notice.
    func chatRunner() -> Result<AIChat.Runner, QuickAI.Failure> { routeWithFallback(told: { _ in }).map { $0.chat(_:text:) } }

    /// The picked provider's route, with the fallback's behind it when one is in use.
    private func routeWithFallback(effort: AIEffort? = nil, told: @escaping AIFallback.Tell) -> Result<any AIChat.Route, QuickAI.Failure> {
        let chosen = provider
        return route(of: chosen, effort: effort).map { first -> any AIChat.Route in
            guard let second = fallbackInUse else { return first }
            return AIFallback.Route(first: first, chosen: chosen, second: second, told: told) { self.route(of: second, effort: effort) }
        }
    }

    /// `provider` set up from the AI page: its CLI or its API.
    func route(of provider: AIProvider, effort fixed: AIEffort? = nil) -> Result<any AIChat.Route, QuickAI.Failure> {
        if provider == .claudeCode {
            guard var cli = findCLI() else { return .failure(.missing) }
            cli.model = model(for: .claudeCode)?.id
            cli.effort = fixed ?? effort(for: .claudeCode)
            return .success(cli)
        }
        if provider.isPlan {
            guard var plan = findPlan(provider) else { return .failure(.notInstalled(provider)) }
            plan.model = model(for: provider)?.id
            plan.effort = fixed ?? effort(for: provider)
            return .success(plan)
        }
        let (key, base): (String?, URL?)
        switch access(provider) {
        case .success(let got): (key, base) = got
        case .failure(let why): return .failure(why)
        }
        guard let model = model(for: provider), let id = model.id else {
            return .failure(.notSetUp(provider, provider.typesModel
                ? "Type the model's id on the AI page, or press Refresh to list the endpoint's."
                : "Pick a model on the AI page; Refresh lists the ones \(provider.name) has (ollama pull adds one)."))
        }
        if provider == .anthropicAPI { return .success(AnthropicAPI(key: key ?? "", model: model, effort: fixed ?? effort(for: provider), http: http)) }
        guard let base else { return .failure(.notSetUp(provider, "Add the API's address on the AI page.")) }
        return .success(OpenAIChat(provider: provider, base: provider.apiBase(base), key: key, model: id, effort: fixed ?? effort(for: provider), http: http))
    }

    /// Refresh: the provider's model list, kept for the picker; nil when it came back. claude's names the version each
    /// alias runs, codex's comes from its own catalog, an API's over the network.
    func refreshModels(for provider: AIProvider) async -> QuickAI.Failure? {
        asked.insert(provider)
        do throws(QuickAI.Failure) {
            let ids: [String]
            if provider == .claudeCode {
                let rows: [AIModelChoice]
                if let listClaude { rows = try await listClaude() } else {
                    guard let found = findCLI() else { throw .notInstalled(provider) }
                    rows = try await found.models()
                }
                ids = rows.compactMap(\.id)
                titles[provider] = Dictionary(rows.map { ($0.id ?? "", $0.title) }, uniquingKeysWith: { a, _ in a })
                defaults.set(titles[provider], forKey: Self.titlesKey(provider))
            } else if provider == .codex {
                guard let plan = findPlan(provider) else { throw .notInstalled(provider) }
                ids = try await plan.models()
            } else {
                let (key, base) = try access(provider).get()
                ids = try await AIModelList.fetch(provider, base: base, key: key, http: http)
            }
            fetched[provider] = ids
            defaults.set(ids, forKey: Self.listKey(provider))
            ailog.notice("quick AI: \(provider.rawValue, privacy: .public) lists \(ids.count) models")
            return nil
        } catch {
            ailog.notice("quick AI model list failed: \(error.message, privacy: .public)")
            return error
        }
    }

    /// Finds the CLI and asks it whether it is signed in.
    func refreshCLI(_ provider: AIProvider = .claudeCode) async {
        if let checkCLI { return clis[provider] = await checkCLI(provider) }
        if provider.isPlan {
            guard let plan = findPlan(provider) else { return clis[provider] = .missing }
            clis[provider] = await plan.signedIn() ? .signedIn(path: plan.path) : .signedOut(path: plan.path)
            return
        }
        guard let found = findCLI() else { return clis[provider] = .missing }
        clis[provider] = await found.signedIn() ? .signedIn(path: found.path) : .signedOut(path: found.path)
    }

    /// Every CLI route's status at once, for the list's chips.
    func refreshCLIs() async {
        await withDiscardingTaskGroup { group in
            for provider in AIProvider.allCases where provider.command != nil { group.addTask { await self.refreshCLI(provider) } }
        }
    }

    /// Connect: the subscription's own sign-in, which opens the provider's page in the browser, then its status again;
    /// nil when it took. A second press while one waits joins it.
    func connect(_ provider: AIProvider) async -> QuickAI.Failure? {
        if let running = connects[provider] { return await running.value }
        guard let plan = findPlan(provider) else {
            clis[provider] = .missing
            return .notInstalled(provider)
        }
        ailog.notice("quick AI: \(provider.rawValue, privacy: .public) sign-in started")
        let task = Task<QuickAI.Failure?, Never> {
            do throws(QuickAI.Failure) { try await plan.connect(); return nil } catch { return error }
        }
        connects[provider] = task
        let failed = await task.value
        connects[provider] = nil
        ailog.notice("quick AI: \(provider.rawValue, privacy: .public) sign-in \(failed?.message ?? "done", privacy: .public)")
        // connect() ends on the login check, so a success needs no second one.
        if failed == nil { clis[provider] = .signedIn(path: plan.path) } else { await refreshCLI(provider) }
        return failed
    }

    /// Stops a Connect still waiting on the browser.
    func cancelConnect(_ provider: AIProvider) { connects[provider]?.cancel() }

    /// Test: one tiny question through the picked provider alone, so a provider out of usage says so; nil when it answered.
    func test() async -> QuickAI.Failure? {
        do throws(QuickAI.Failure) {
            _ = try await route(of: provider).get().run(.ask("Reply with the single word OK.")) { _ in }
            ailog.notice("quick AI test passed on \(self.provider.rawValue, privacy: .public)")
            return nil
        } catch {
            ailog.notice("quick AI test failed: \(error.message, privacy: .public)")
            return error
        }
    }
}
