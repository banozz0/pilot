import Foundation
import PilotCore

/// The Extensions page's preference fields (CLI W15), one row per preference of every installed extension, read and
/// written through ExtensionStorage as the page's fields are. A password is never read: its row says only whether one is
/// set (asked of the Keychain without the secret), it is set on the page, and clearing it asks Allow.
extension ControlVerbs {
    func registerExtensionPrefs(_ tools: ExtensionTools) {
        register(ControlCollection("ext-prefs", help: "Every installed extension's preferences (the Extensions page's fields): kind, options, required, missing, value. add sets one (--pref <extension>.<name> --value …: on/off for a checkbox, an option's value for a dropdown, an existing path for app, file and folder, empty text for the default); remove puts its default back. A password shows only set or unset: it is set on the page, never here, and clearing it asks Allow.",
                                   fields: [.init("pref", help: "<extension>.<name>, as list ext-prefs names the row"),
                                            .init("value", help: "the new value; empty text puts a text preference's default back")],
                                   rowKey: "pref", asks: [.remove],
                                   list: { await .array(tools.prefRows().map(Self.prefRow)) },
                                   askerAdd: { args, _ throws(ControlError) in
            let (ext, preference) = try await tools.preference(args.value("pref")!)
            try await tools.save(try Self.prefValue(args.value("value")!, for: preference, of: ext), for: preference, of: ext)
            return Self.prefRow(await tools.prefRow(preference, of: ext))
        }, askerRemove: { args, peer throws(ControlError) in
            let (ext, preference) = try await tools.preference(try args.word(0, "pref"))
            let row = await tools.prefRow(preference, of: ext)
            // A password set is deleted from the Keychain only after Allow; anything else goes back to its default as the page's field does.
            if row.passwordSet == true {
                let ask = ControlGate.Ask("Clear extension password", "\(ExtensionTools.named(ext))'s \(ControlGate.Ask.visible(preference.title)) (\(ext.id).\(preference.name)) is deleted from your Keychain")
                try await tools.gate.allow(ask, peer: peer) { () throws(ControlError) in try await tools.save(nil, for: preference, of: ext) }
            } else if row.passwordSet == nil {
                try await tools.save(nil, for: preference, of: ext)
            }
            return Self.prefRow(row.passwordSet == false ? row : await tools.prefRow(preference, of: ext))
        }))
    }

    /// The value `text` stands for as `preference` takes it, as the page's field would save it: nil (the default) for
    /// empty text, a bool for a checkbox, an option's value for a dropdown, an existing path for an app, file or folder.
    /// A password is keychain-only.
    static func prefValue(_ text: String, for preference: Extension.Preference, of ext: Extension) throws(ControlError) -> JSONValue? {
        let name = "\(ext.id).\(preference.name)"
        switch preference.kind {
        case .password:
            throw ControlError(.keychainOnly, "\(name) is a password, kept in your Keychain: set it on the Extensions page (pilot ext open \(ext.id) --card); list ext-prefs says set or unset")
        case .text:
            return text.isEmpty ? nil : .string(text)
        case .checkbox:
            switch text.lowercased() {
            case "on", "true", "yes", "1": return .bool(true)
            case "off", "false", "no", "0": return .bool(false)
            default: throw ControlError(.badValue, "\(name) is a checkbox: on or off")
            }
        case .dropdown(let options):
            guard let option = options.first(where: { $0.value == text }) ?? options.first(where: { $0.title.caseInsensitiveCompare(text) == .orderedSame }) else {
                throw ControlError(.badValue, "\(name) takes one of: \(options.map { "\($0.value) (\($0.title))" }.joined(separator: ", "))")
            }
            return .string(option.value)
        case .app, .file, .folder:
            let path = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL.path
            guard text.hasPrefix("/") || text.hasPrefix("~") else { throw ControlError(.badValue, "\(name) takes a full path (/… or ~/…)") }
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { throw ControlError(.badValue, "\(name): nothing at \(path)") }
            switch preference.kind {
            case .app where !(folder.boolValue && path.hasSuffix(".app")): throw ControlError(.badValue, "\(name) takes an app: \(path) is not one")
            case .folder where !folder.boolValue: throw ControlError(.badValue, "\(name) takes a folder: \(path) is a file")
            case .file where folder.boolValue: throw ControlError(.badValue, "\(name) takes a file: \(path) is a folder")
            default: return .string(path)
            }
        }
    }

    static func prefRow(_ row: ExtensionTools.PrefRow) -> JSONValue {
        let p = row.preference
        var o: [String: JSONValue] = ["pref": .string("\(row.ext.id).\(p.name)"), "extension": .string(row.ext.id), "name": .string(p.name),
                                      "title": .string(p.title), "kind": .string(p.kind.word), "required": .bool(p.required), "missing": .bool(row.missing)]
        o["description"] = p.description.map(JSONValue.string)
        if case .dropdown(let options) = p.kind {
            o["options"] = .array(options.map { .object(["value": .string($0.value), "title": .string($0.title)]) })
        }
        if let set = row.passwordSet {
            o["set"] = .bool(set)
        } else {
            o["value"] = row.value
            o["default"] = p.default
        }
        return .object(o)
    }
}

extension ExtensionTools {
    /// What may be shown of an extension's preferences: every value but a password's, and the passwords set.
    typealias Shown = (values: [String: JSONValue], passwordsSet: Set<String>)

    /// One preference as the pilot command shows it: its value, or for a password only whether one is set.
    struct PrefRow {
        let ext: Extension, preference: Extension.Preference, value: JSONValue?, passwordSet: Bool?

        init(_ preference: Extension.Preference, of ext: Extension, _ shown: Shown) {
            self.ext = ext; self.preference = preference
            value = shown.values[preference.name]
            passwordSet = preference.kind == .password ? shown.passwordsSet.contains(preference.name) : nil
        }

        /// The page's Needed: a set password stands in as a value, so the page's own rule decides.
        var missing: Bool { preference.isMissing(passwordSet == true ? .string("set") : value) }
    }

    var storage: ExtensionStorage { ExtensionStorage(data: data, cache: cache, keychain: keychain) }

    /// The Extensions folder read off the main actor, which runs the key tap.
    func found() async -> Extension.Found {
        let folder = extensions
        return await Task.detached { Extension.find(in: folder) }.value
    }

    /// The installed extension `id`, or bad-value naming the ones installed.
    func require(_ id: String) async throws(ControlError) -> Extension {
        let found = await found()
        guard let ext = found.extensions.first(where: { $0.id == id }) else {
            let ids = found.extensions.map(\.id)
            throw ControlError(.badValue, "no extension \(id) is installed; \(ids.isEmpty ? "none is" : "installed: " + ids.joined(separator: ", "))")
        }
        return ext
    }

    /// What may be shown of `ext`'s preferences, read off the main actor (a file and a Keychain query per password).
    func shown(_ ext: Extension) async -> Shown {
        let storage = storage
        return await Task.detached { storage.shown(of: ext) }.value
    }

    func prefRows() async -> [PrefRow] {
        let (extensions, storage) = (await found().extensions, storage)
        let shown = await Task.detached { extensions.map { storage.shown(of: $0) } }.value
        return zip(extensions, shown).flatMap { ext, shown in ext.preferences.map { PrefRow($0, of: ext, shown) } }
    }

    func prefRow(_ preference: Extension.Preference, of ext: Extension) async -> PrefRow { PrefRow(preference, of: ext, await shown(ext)) }

    /// The installed extension and preference `pref` (`<extension>.<name>`) names, or bad-value saying what is there.
    func preference(_ pref: String) async throws(ControlError) -> (Extension, Extension.Preference) {
        let parts = pref.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ControlError(.badValue, "\(pref): name a preference as <extension>.<name>; pilot list ext-prefs lists them") }
        let ext = try await require(parts[0])
        guard let preference = ext.preferences.first(where: { $0.name == parts[1] }) else {
            let names = ext.preferences.map(\.name)
            throw ControlError(.badValue, "\(ext.id) has no preference \(parts[1]); it has \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
        return (ext, preference)
    }

    /// Saves as the page does, off the main actor (a file or the Keychain), or bad-value with why it was not saved.
    func save(_ value: JSONValue?, for preference: Extension.Preference, of ext: Extension) async throws(ControlError) {
        let storage = storage
        let failed = await Task.detached { () -> String? in
            do { try storage.set(value, for: preference, of: ext); return nil } catch { return error.localizedDescription }
        }.value
        if let failed { throw ControlError(.badValue, "\(ext.id).\(preference.name) not saved: \(failed)") }
        log.notice("ext-prefs: \(ext.id, privacy: .public).\(preference.name, privacy: .public) \(value == nil ? "cleared" : "set", privacy: .public), from the pilot command")
    }
}

extension Extension.Preference.Kind {
    /// The manifest's word for it.
    var word: String {
        switch self {
        case .text: return "text"
        case .password: return "password"
        case .checkbox: return "checkbox"
        case .dropdown: return "dropdown"
        case .app: return "app"
        case .file: return "file"
        case .folder: return "folder"
        }
    }
}
