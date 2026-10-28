import Foundation
import Security

/// Where an extension's passwords live (card agent-bo-95423246): the Keychain in Pilot, a fake in tests.
public protocol ExtensionKeychain: Sendable {
    /// The password saved for preference `name` of extension `id`.
    func password(extension id: String, preference name: String) -> String?
    /// Saves `password`, or removes the item when it is nil.
    func setPassword(_ password: String?, extension id: String, preference name: String) throws
    /// Whether a password is saved for preference `name` of extension `id`, asked without reading it. No default: a keychain
    /// that forgot it would say none and let a run's output be read back.
    func hasPassword(extension id: String, preference name: String) -> Bool
}

/// One generic password in the login Keychain, made by Pilot so its own signature reads it back: an extension's
/// password preference, or Quick AI's API key.
public struct KeychainItem: Sendable {
    public struct Failure: Error, Equatable { public let status: OSStatus }

    let service: String, account: String, label: String

    public init(service: String, account: String, label: String) {
        self.service = service; self.account = account; self.label = label
    }

    private var query: [CFString: Any] { [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] }

    public func read() -> String? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether the item is there, asked without the secret: attributes need no unlock and raise no prompt.
    public func exists() -> Bool {
        var query = query
        query[kSecReturnAttributes] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Saves `value`, or removes the item when it is nil.
    public func write(_ value: String?) throws {
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrLabel] = label
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}

/// The login Keychain: a generic password per extension preference, service `dev.banozz.pilot.ext.<id>` and account the
/// preference's name.
public struct SystemKeychain: ExtensionKeychain {
    public typealias Failure = KeychainItem.Failure

    public init() {}

    private func item(_ id: String, _ name: String) -> KeychainItem {
        KeychainItem(service: "dev.banozz.pilot.ext.\(id)", account: name, label: "Pilot extension \(id): \(name)")
    }

    public func password(extension id: String, preference name: String) -> String? { item(id, name).read() }

    public func setPassword(_ password: String?, extension id: String, preference name: String) throws {
        try item(id, name).write(password)
    }

    public func hasPassword(extension id: String, preference name: String) -> Bool { item(id, name).exists() }
}

/// What Pilot keeps for its extensions (card agent-bo-95423246, ADR 0010): each one's preference values in
/// `ExtensionData/<id>/preferences.json`, saved as they change, passwords in the Keychain instead; its own data folder
/// beside them and a cache folder in Pilot's caches, both made on its first run. Removing an extension's folder leaves
/// all of it, so putting the folder back finds its settings.
public struct ExtensionStorage: Sendable {
    /// ~/Library/Application Support/Pilot/ExtensionData
    public static let dataFolder = PilotFolder.support.appending(path: "ExtensionData")
    /// ~/Library/Caches/dev.banozz.pilot/Extensions
    public static let cacheFolder = URL.cachesDirectory.appending(path: "dev.banozz.pilot/Extensions")

    /// A required preference with no value: the run does not start.
    public struct Unset: Error, Equatable {
        public let preference: Extension.Preference
        public init(preference: Extension.Preference) { self.preference = preference }

        /// What the HUD says.
        public func message(in ext: Extension) -> String { "\(ext.title) needs \(preference.title) set first." }
    }

    private let data: URL, cache: URL, keychain: any ExtensionKeychain

    public init(data: URL = dataFolder, cache: URL = cacheFolder, keychain: any ExtensionKeychain = SystemKeychain()) {
        self.data = data; self.cache = cache; self.keychain = keychain
    }

    private func file(_ id: String) -> JSONFile<[String: JSONValue]> { JSONFile(url: data.appending(path: "\(id)/preferences.json")) }

    /// Every preference's value by name: the saved one when it still fits, else its default; a checkbox with neither is
    /// false, any other type is left out. Passwords are read from the Keychain, only when the extension declares one.
    public func values(of ext: Extension) -> [String: JSONValue] {
        let saved = (try? file(ext.id).load(or: [:])) ?? [:]
        var values: [String: JSONValue] = [:]
        for preference in ext.preferences {
            values[preference.name] = preference.resolved(preference.kind == .password
                ? keychain.password(extension: ext.id, preference: preference.name).map(JSONValue.string) : saved[preference.name])
        }
        return values
    }

    /// What may be shown of `ext`'s preferences without a secret (the pilot command, CLI W15): every value but a
    /// password's as `values(of:)` resolves it, and the password preferences that have one saved, asked of the Keychain
    /// without reading it.
    public func shown(of ext: Extension) -> (values: [String: JSONValue], passwordsSet: Set<String>) {
        let saved = (try? file(ext.id).load(or: [:])) ?? [:]
        var values: [String: JSONValue] = [:], set: Set<String> = []
        for preference in ext.preferences {
            if preference.kind == .password {
                if keychain.hasPassword(extension: ext.id, preference: preference.name) { set.insert(preference.name) }
            } else {
                values[preference.name] = preference.resolved(saved[preference.name])
            }
        }
        return (values, set)
    }

    /// Saves `value` for `preference` of `ext`, or clears it when nil: a password in the Keychain (an empty one clears
    /// it), the rest in preferences.json, which throws rather than overwrite a file that does not read.
    public func set(_ value: JSONValue?, for preference: Extension.Preference, of ext: Extension) throws {
        if preference.kind == .password {
            let text = if case .string(let s)? = value, !s.isEmpty { s } else { String?.none }
            return try keychain.setPassword(text, extension: ext.id, preference: preference.name)
        }
        let file = file(ext.id)
        var saved = try file.load(or: [:])
        saved[preference.name] = value
        try file.save(saved)
    }

    /// What every run of `ext` is handed: its values and its folders, made now if missing. Throws Unset for the first
    /// required preference without a value, an empty string counting as none.
    public func inputs(for ext: Extension) throws -> ExtensionRun.Inputs {
        let values = values(of: ext)
        if let unset = ext.preferences.first(where: { $0.isMissing(values[$0.name]) }) {
            throw Unset(preference: unset)
        }
        let inputs = ExtensionRun.Inputs(preferences: values, data: data.appending(path: "\(ext.id)/data"), cache: cache.appending(path: ext.id))
        for folder in [inputs.data, inputs.cache] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return inputs
    }
}
