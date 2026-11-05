import Foundation
import PilotCore

extension SettingsSchema {
    /// The AI page's keys on AISettings: the provider and chat reset, then each provider's model, effort and address.
    /// The API keys stay in the Keychain: `get` says only whether one is saved; `set --stdin` saves one as Save does.
    /// The provider and each address ask Allow from the socket (ControlVerbs.aiSettingAsk), as they decide where the chat,
    /// an extension's page and a saved key go; the AI page changes them as it always has.
    @MainActor func registerAI(_ ai: AISettings) {
        ControlVerbs.aiStore = ai
        var keys: [SettingKey] = [
            .choice("ai.provider", "AI uses", page: "ai", AIProvider.allCases, standard: .claudeCode, confirms: true,
                    read: { ai.provider }, write: { ai.provider = $0 }),
            .choice("ai.chatReset", "A new chat after", page: "ai", AIChat.Reset.allCases, standard: .standard,
                    read: { ai.chatReset }, write: { ai.chatReset = $0 }),
        ]
        for provider in AIProvider.allCases {
            let id = provider.rawValue
            // null is no model yet: Ollama or the endpoint before a Refresh or a typed id.
            keys.append(.text("ai.model.\(id)", "\(provider.name)'s model", page: "ai", standard: provider.models.first.map(Self.word),
                              read: { ai.model(for: provider).map(Self.word) },
                              write: { word throws(ControlError) in ai.setModel(try Self.model(word, of: provider, in: ai), for: provider) }))
            if provider.takesEffort {
                keys.append(.choice("ai.effort.\(id)", "\(provider.name)'s effort", page: "ai", AIEffort.allCases, standard: .low,
                                    read: { ai.effort(for: provider) }, write: { ai.setEffort($0, for: provider) }))
            }
            if provider.editsBaseURL {
                keys.append(.text("ai.baseURL.\(id)", "\(provider.name)'s address", page: "ai", standard: provider.defaultBaseURL ?? "", confirms: true,
                                  read: { ai.address(for: provider) },
                                  write: { word throws(ControlError) in try Self.checkAddress(word); ai.setAddress(word, for: provider) }))
            }
            if provider.key != .none {
                keys.append(.secret("ai.key.\(id)", "\(provider.name)'s API key", page: "ai", isSet: { ai.hasKey(provider) },
                                    save: { try ai.setKey($0, for: provider) }))
            }
        }
        register(keys)
    }

    /// A model as the command names it: its id, or "default" for the CLI's own (a nil id).
    private static func word(_ model: AIModelChoice) -> String { model.id ?? "default" }

    /// The id `setModel` takes: any typed id for the endpoint, else one the page offers.
    private static func model(_ word: String, of provider: AIProvider, in ai: AISettings) throws(ControlError) -> String? {
        if provider.typesModel { return word }
        let offered = ai.models(for: provider)
        guard let choice = offered.first(where: { Self.word($0) == word }) else {
            throw ControlError(.badValue, offered.isEmpty
                ? "\(provider.name) lists no models yet: Refresh on the AI page first"
                : "ai.model.\(provider.rawValue) is one of \(offered.map(Self.word).joined(separator: ", ")), not \(word)")
        }
        return choice.id
    }

    /// An http or https address with a host, as AISettings.baseURL calls it; empty goes back to the provider's own.
    private static func checkAddress(_ word: String) throws(ControlError) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw ControlError(.badValue, "\(word) is no http or https address")
        }
    }
}

extension ControlVerbs {
    /// The AI store the schema registered (the app's, or a test's), which the AI keys' questions read.
    static weak var aiStore: AISettings?

    /// The question `set ai.provider` and `set ai.baseURL.<id>` ask, nil for any other key: the old and the new provider
    /// or address, and whether a saved key goes there, so a caller cannot send the chat, a page or a key elsewhere unseen.
    /// Read again after Allow, so a change while it is up denies.
    static func aiSettingAsk(_ key: String, _ shown: String) -> String? {
        guard let ai = aiStore else { return nil }
        if key == "ai.provider" {
            guard let new = AIProvider(rawValue: shown) else { return nil }
            let to = destination(ai, provider: new)
            let saved = new.key != .none && ai.hasKey(new) ? (to.hasSuffix("saved key") ? "" : ", with \(new.name)'s saved key") : "; no saved key goes there"
            return "from \(destination(ai)) to \(to)\(saved)"
        }
        let prefix = "ai.baseURL."
        guard key.hasPrefix(prefix), let p = AIProvider(rawValue: String(key.dropFirst(prefix.count))) else { return nil }
        let typed = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = typed.isEmpty ? p.defaultBaseURL ?? "none" : typed
        let saved = p.key != .none && ai.hasKey(p) ? "\(p.name)'s saved key goes with each request there" : "no saved key goes there"
        let used = ai.provider == p ? "AI uses \(p.name) now" : "AI uses \(ai.provider.name) now, not \(p.name)"
        return "\(p.name)'s address from \(ControlGate.Ask.visible(ai.address(for: p))) to \(ControlGate.Ask.visible(new)); \(saved); \(used)"
    }
}
