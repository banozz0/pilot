import Foundation
import PilotCore

extension SettingsSchema {
    /// The AI page's keys on AISettings: the provider and chat reset, then each provider's model, effort and address.
    /// The API keys stay in the Keychain: `get` says only whether one is saved; `set --stdin` saves one as Save does.
    func registerAI(_ ai: AISettings) {
        var keys: [SettingKey] = [
            .choice("ai.provider", "AI uses", page: "ai", AIProvider.allCases, standard: .claudeCode,
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
                keys.append(.text("ai.baseURL.\(id)", "\(provider.name)'s address", page: "ai", standard: provider.defaultBaseURL ?? "",
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
