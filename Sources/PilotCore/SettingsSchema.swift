import Foundation

/// One setting the pilot command reads and changes (`pilot get|set <key>`, ADR 0013): what it holds, its range or
/// choices, its default and its page, for `pilot schema`, and how it reads and writes the live store the page binds to,
/// never UserDefaults behind the store's back, so the page shows a change at once.
public struct SettingKey: Sendable {
    public enum Kind: Sendable, Equatable {
        case bool
        case int(ClosedRange<Int>)
        case number(ClosedRange<Double>)
        case choice([String])
        /// One or more of these, comma-separated, each once (the layer keys).
        case choices([String])
        /// A free word (a folder, a model id, an address); its store checks it.
        case text
        /// "theme" or "#RRGGBB"; with `plain`, "plain" too (no colour picked, ColourChoice.plain).
        case colour(plain: Bool)
        /// A Keychain item: `get` says only whether it is set; `set` takes it from stdin alone (`--stdin`), never as a word.
        case secret
    }

    public typealias Read = @Sendable @MainActor () -> JSONValue
    /// Handed a value already checked against the kind; may still refuse it (bad-value) by the store's own rule. A store
    /// that applies a change later (the tiler's block, the top bar's switch) returns once it has.
    public typealias Write = @Sendable @MainActor (JSONValue) async throws(ControlError) -> Void

    public let key: String
    public let label: String
    /// The AppPage it lives on ("look").
    public let page: String
    public let kind: Kind
    public let standard: JSONValue
    /// Its page confirms a change, so the command waits on the Allow gate too.
    public let confirms: Bool
    let read: Read
    let write: Write
    /// The store's own rule on a parsed value, run with the word, before plan and Allow (the layer keys' one side).
    let check: @Sendable (JSONValue) throws(ControlError) -> Void

    private init(_ key: String, _ label: String, page: String, kind: Kind, standard: JSONValue, confirms: Bool = false,
                 read: @escaping Read, write: @escaping Write, check: @escaping @Sendable (JSONValue) throws(ControlError) -> Void = { _ in }) {
        self.key = key; self.label = label; self.page = page; self.kind = kind; self.standard = standard
        self.confirms = confirms; self.read = read; self.write = write; self.check = check
    }

    /// A Keychain item: `get` answers "set" or "unset" from `isSet`. `set` writes it only through `secret(_:unset:)`, as its page's
    /// Save and Remove do, after Allow; a value typed as a word answers keychain-only. `save` is handed the value
    /// trimmed, nil to remove it.
    public static func secret(_ key: String, _ label: String, page: String, isSet: @escaping @Sendable @MainActor () -> Bool,
                              save: @escaping @Sendable @MainActor (String?) throws -> Void) -> SettingKey {
        SettingKey(key, label, page: page, kind: .secret, standard: .string("unset"), confirms: true, read: { .string(isSet() ? "set" : "unset") },
                   write: { value throws(ControlError) in
                       let secret: String? = if case .string(let s) = value { s } else { nil }
                       // The Keychain's failure is an OSStatus, never the value.
                       do { try save(secret) } catch { throw ControlError(.badValue, "the Keychain did not take \(key): \(error)") }
                   })
    }

    /// A secret's new value as `set --stdin` read it, trimmed as its page trims a paste, or nil for `--unset`; bad-value
    /// for a key that is no secret, or nothing on stdin, so an empty pipe never removes a key.
    public func secret(_ input: String?, unset: Bool) throws(ControlError) -> JSONValue {
        guard kind == .secret else { throw ControlError(.badValue, "\(key) is no secret: pilot set \(key) <value>") }
        if unset { return .null }
        let trimmed = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw ControlError(.badValue, "nothing on stdin for \(key): \(Self.piped(key))") }
        return .string(trimmed)
    }

    /// Writes a value `value(_:)` made and answers what the store holds after, which a store may have clamped or
    /// swapped (translate's pair).
    @MainActor public func apply(_ value: JSONValue) async throws(ControlError) -> JSONValue {
        try await write(value)
        return read()
    }

    /// The command's word as this setting's value, or bad-value / out-of-range saying what it takes.
    public func value(_ word: String) throws(ControlError) -> JSONValue {
        switch kind {
        case .bool:
            switch word.lowercased() {
            case "true", "on", "yes", "1": return .bool(true)
            case "false", "off", "no", "0": return .bool(false)
            default: throw ControlError(.badValue, "\(key) is on or off, not \(word)")
            }
        case .int(let range):
            guard let n = Int(word) else { throw ControlError(.badValue, "\(key) is a whole number, not \(word)") }
            guard range.contains(n) else { throw ControlError(.outOfRange, "\(key) is \(range.lowerBound) to \(range.upperBound), not \(n)") }
            return .number(Double(n))
        case .number(let range):
            guard let n = Double(word), n.isFinite else { throw ControlError(.badValue, "\(key) is a number, not \(word)") }
            guard range.contains(n) else { throw ControlError(.outOfRange, "\(key) is \(range.lowerBound) to \(range.upperBound), not \(word)") }
            return .number(n)
        case .choice(let choices):
            guard choices.contains(word) else { throw ControlError(.badValue, "\(key) is one of \(choices.joined(separator: ", ")), not \(word)") }
            return .string(word)
        case .choices(let choices):
            let words = word.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !words.isEmpty, words.allSatisfy(choices.contains) else {
                throw ControlError(.badValue, "\(key) is one or more of \(choices.joined(separator: ", ")), comma-separated, not \(word)")
            }
            let value = JSONValue.array(choices.filter(words.contains).map(JSONValue.string))
            try check(value)
            return value
        case .text:
            return .string(word)
        case .colour(let plain):
            guard ColourChoice(rawValue: word) != nil || plain && word == ColourChoice.plain else {
                throw ControlError(.badValue, "\(key) is \(plain ? "plain, " : "")theme or #RRGGBB, not \(word)")
            }
            return .string(word)
        case .secret:
            throw Self.keychainOnly(key)
        }
    }

    /// A secret given as a word: refused before it is stored, named by its key alone, never the word.
    static func keychainOnly(_ key: String) -> ControlError {
        ControlError(.keychainOnly, "\(key) lives in the Keychain and is never a word (shell history keeps those): \(piped(key))")
    }

    /// How a secret is set and removed, for its refusals and its help.
    public static func piped(_ key: String) -> String { "pbpaste | pilot set \(key) --stdin; pilot set \(key) --unset removes it" }

    /// Its part of `pilot schema` and `pilot settings`, with the value it holds now.
    @MainActor public var described: JSONValue {
        var entry: [String: JSONValue] = ["key": .string(key), "label": .string(label), "page": .string(page),
                                          "default": standard, "value": read()]
        switch kind {
        case .bool: entry["type"] = .string("bool")
        case .int(let range):
            entry["type"] = .string("int")
            entry["range"] = .array([.number(Double(range.lowerBound)), .number(Double(range.upperBound))])
        case .number(let range):
            entry["type"] = .string("number")
            entry["range"] = .array([.number(range.lowerBound), .number(range.upperBound)])
        case .choice(let choices):
            entry["type"] = .string("choice")
            entry["choices"] = .array(choices.map(JSONValue.string))
        case .choices(let choices):
            entry["type"] = .string("choices")
            entry["choices"] = .array(choices.map(JSONValue.string))
        case .text: entry["type"] = .string("text")
        case .colour(let plain):
            entry["type"] = .string("colour")
            if plain { entry["plain"] = .bool(true) }
        case .secret:
            entry["type"] = .string("secret")
            entry["secret"] = .bool(true)
        }
        if confirms { entry["confirms"] = .bool(true) }
        return .object(entry)
    }
}

/// Every setting the command reaches. Each page's family registers its own keys from its own file, as modules register
/// their actions, so no family edits another's.
@MainActor
public final class SettingsSchema {
    public private(set) var keys: [String: SettingKey] = [:]

    public init() {}

    /// A second key on one name is a bug, caught by the first test that builds the schema.
    public func register(_ settings: [SettingKey]) {
        for setting in settings {
            precondition(keys[setting.key] == nil, "setting \(setting.key) registered twice")
            keys[setting.key] = setting
        }
    }

    public var sorted: [SettingKey] { keys.values.sorted { $0.key < $1.key } }

    public func setting(_ key: String) throws(ControlError) -> SettingKey {
        guard let setting = keys[key] else { throw ControlError(.unknownKey, "no setting \(key); pilot settings lists them") }
        return setting
    }

    public func get(_ key: String) throws(ControlError) -> JSONValue { try setting(key).read() }
}

extension SettingKey {
    // Typed makers, so a family reads and writes its store's own types; the value is checked against the kind first.

    public static func bool(_ key: String, _ label: String, page: String, standard: Bool, confirms: Bool = false,
                            read: @escaping @Sendable @MainActor () -> Bool,
                            write: @escaping @Sendable @MainActor (Bool) async throws(ControlError) -> Void) -> SettingKey {
        SettingKey(key, label, page: page, kind: .bool, standard: .bool(standard), confirms: confirms,
                   read: { .bool(read()) }, write: { value throws(ControlError) in if case .bool(let b) = value { try await write(b) } })
    }

    public static func int(_ key: String, _ label: String, page: String, range: ClosedRange<Int>, standard: Int,
                           read: @escaping @Sendable @MainActor () -> Int,
                           write: @escaping @Sendable @MainActor (Int) async throws(ControlError) -> Void) -> SettingKey {
        SettingKey(key, label, page: page, kind: .int(range), standard: .number(Double(standard)),
                   read: { .number(Double(read())) }, write: { value throws(ControlError) in if case .number(let n) = value { try await write(Int(n)) } })
    }

    public static func number(_ key: String, _ label: String, page: String, range: ClosedRange<Double>, standard: Double,
                              read: @escaping @Sendable @MainActor () -> Double,
                              write: @escaping @Sendable @MainActor (Double) async throws(ControlError) -> Void) -> SettingKey {
        SettingKey(key, label, page: page, kind: .number(range), standard: .number(standard),
                   read: { .number(read()) }, write: { value throws(ControlError) in if case .number(let n) = value { try await write(n) } })
    }

    /// One of `choices`, by its raw value.
    public static func choice<T: RawRepresentable<String>>(_ key: String, _ label: String, page: String, _ choices: [T], standard: T,
                                                           confirms: Bool = false, read: @escaping @Sendable @MainActor () -> T,
                                                           write: @escaping @Sendable @MainActor (T) async throws(ControlError) -> Void) -> SettingKey {
        choice(key, label, page: page, choices.map(\.rawValue), standard: standard.rawValue, confirms: confirms,
               read: { read().rawValue }, write: { word throws(ControlError) in if let value = T(rawValue: word) { try await write(value) } })
    }

    public static func choice(_ key: String, _ label: String, page: String, _ choices: [String], standard: String, confirms: Bool = false,
                              read: @escaping @Sendable @MainActor () -> String,
                              write: @escaping @Sendable @MainActor (String) async throws(ControlError) -> Void) -> SettingKey {
        SettingKey(key, label, page: page, kind: .choice(choices), standard: .string(standard), confirms: confirms,
                   read: { .string(read()) }, write: { value throws(ControlError) in if case .string(let s) = value { try await write(s) } })
    }

    /// One or more of `choices`, by raw value, in `choices`' order: `pilot set <key> a,b`; one word is a list of one.
    public static func choices<T: RawRepresentable<String>>(_ key: String, _ label: String, page: String, _ choices: [T], standard: [T],
                                                            confirms: Bool = false, read: @escaping @Sendable @MainActor () -> [T],
                                                            write: @escaping @Sendable @MainActor ([T]) async throws(ControlError) -> Void,
                                                            check: @escaping @Sendable ([T]) throws(ControlError) -> Void = { _ in }) -> SettingKey {
        func json(_ values: [T]) -> JSONValue { .array(values.map { .string($0.rawValue) }) }
        @Sendable func typed(_ value: JSONValue) -> [T] {
            guard case .array(let items) = value else { return [] }
            return items.compactMap { $0.string.flatMap(T.init(rawValue:)) }
        }
        return SettingKey(key, label, page: page, kind: .choices(choices.map(\.rawValue)), standard: json(standard), confirms: confirms,
                          read: { json(read()) }, write: { value throws(ControlError) in
                              guard case .array = value else { return }
                              try await write(typed(value))
                          }, check: { value throws(ControlError) in try check(typed(value)) })
    }

    /// "theme" or "#RRGGBB".
    public static func colour(_ key: String, _ label: String, page: String, read: @escaping @Sendable @MainActor () -> ColourChoice,
                              write: @escaping @Sendable @MainActor (ColourChoice) async throws(ControlError) -> Void) -> SettingKey {
        SettingKey(key, label, page: page, kind: .colour(plain: false), standard: .string(ColourChoice.theme.rawValue), read: { .string(read().rawValue) },
                   write: { value throws(ControlError) in
                       if case .string(let s) = value, let colour = ColourChoice(rawValue: s) { try await write(colour) }
                   })
    }

    /// "plain" (nil, the default), "theme" or "#RRGGBB".
    public static func colour(_ key: String, _ label: String, page: String, plain read: @escaping @Sendable @MainActor () -> ColourChoice?,
                              write: @escaping @Sendable @MainActor (ColourChoice?) async throws(ControlError) -> Void) -> SettingKey {
        SettingKey(key, label, page: page, kind: .colour(plain: true), standard: .string(ColourChoice.plain),
                   read: { .string(read()?.rawValue ?? ColourChoice.plain) },
                   write: { value throws(ControlError) in
                       guard case .string(let s) = value else { return }
                       try await write(ColourChoice(rawValue: s))
                   })
    }

    /// A free word its store checks; nil reads as JSON null (no model picked yet).
    public static func text(_ key: String, _ label: String, page: String, standard: String?, confirms: Bool = false,
                            read: @escaping @Sendable @MainActor () -> String?,
                            write: @escaping @Sendable @MainActor (String) async throws(ControlError) -> Void) -> SettingKey {
        SettingKey(key, label, page: page, kind: .text, standard: standard.map(JSONValue.string) ?? .null, confirms: confirms,
                   read: { read().map(JSONValue.string) ?? .null },
                   write: { value throws(ControlError) in if case .string(let s) = value { try await write(s) } })
    }
}
