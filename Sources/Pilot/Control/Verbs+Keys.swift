import Foundation
import PilotCore

extension ControlVerbs {
    /// `keys --free` and `key <combo>` (Ask Pilot G2, G3): which keys are free to bind and what one runs, read from the
    /// bind store and, for a plain combo, macOS's own shortcuts. A Hyper key never clashes with macOS: the tap swallows it
    /// (SymbolicHotKeys.Clash). `conflicts` reads com.apple.symbolichotkeys; a test hands in a fake one.
    func registerKeys(_ app: ControlActions, conflicts: @escaping @Sendable @MainActor () -> ShortcutConflicts = { .shared }) {
        register(ControlVerb("keys", help: "Keys free to bind: --free lists the Hyper keys no action holds at --mods (none: Hyper+<key>); --plain lists plain combos that clash with nothing; --base reads a new preset on that base instead of the active one.",
                             usage: "pilot keys --free [--mods shift,ctrl,alt,cmd] [--plain] [--base pilot]",
                             flags: [.init("free", help: "the keys no action holds", takesValue: false),
                                     .init("mods", help: "the sublayer: shift, ctrl, alt, cmd; with --plain the combo's modifiers"),
                                     .init("plain", help: "plain combos outside Hyper, minus macOS's shortcuts and keys that type; needs cmd, ctrl or alt", takesValue: false),
                                     .init("base", help: "the keys a new preset on this base leaves free, as pilot add presets --base makes it; nothing is made")]) { call throws(ControlError) in
            let args = call.arguments()
            guard args.has("free") else { throw ControlError(.badRequest, "pilot keys --free [--mods …] [--plain]: free is the one list there is") }
            var store = try app.running().binds.store
            if let word = args.value("base") {
                // A copy: the new preset is only read, never made.
                guard let base = BindStore.Base(rawValue: word), store.addPreset(named: word, base: base) != nil else {
                    throw ControlError(.badValue, "no base \(word); pilot list presets names the built-in ones")
                }
            }
            let plain = args.has("plain")
            let mods = try Self.mods(args, plain: plain)
            let held = Set(store.binds.keys.map { Self.family($0) })
            let keys = Self.bindable.map { Key(keyCode: $0, modifiers: mods, hyper: !plain) }.filter { !held.contains(Self.family($0)) }
            let macOS = plain ? Self.macOSClashes(keys, conflicts()) : [:]
            var free: [String] = [], shadowed: [JSONValue] = []
            for key in keys {
                if let why = macOS[key] ?? (plain ? PlainComboShadow.warning(for: key) : nil) {
                    shadowed.append(.object(["key": .string(key.label), "why": .string(why)]))
                } else {
                    free.append(KeyNames.name(for: key.keyCode))
                }
            }
            let layer = ((plain ? [] : ["Hyper"]) + mods.labels).joined(separator: "+")
            var answer: [String: JSONValue] = ["layer": .string(layer), "free": .array(free.map(JSONValue.string)),
                                               "held": .number(Double(Self.bindable.count - keys.count))]
            if plain { answer["shadowed"] = .array(shadowed) }
            return .object(answer)
        })
        register(ControlVerb("key", help: "What a key runs: its action, whether the preset gave it or it was set by hand, and any macOS shortcut a plain combo clashes with.",
                             usage: "pilot key <combo>: hyper+k, hyper+shift+n, k (Hyper is the default), leftAlt+h (a plain combo)", flags: []) { call throws(ControlError) in
            let key = try Self.combo(call.arguments().word(0, "key"))
            let engine = try app.running()
            let store = engine.binds.store
            var answer: [String: JSONValue] = ["key": .string(key.label), "preset": .string(store.preset.id)]
            if let id = Self.holder(of: key, in: store) {
                answer["action"] = .string(id)
                answer["label"] = .string(engine.action(id)?.label ?? id)
                answer["from"] = .string(store.isCustom(id) ? "set by hand" : "\(store.preset.title)'s default")
                if store.isDisabled(id) { answer["off"] = .bool(true) }
            }
            answer["free"] = .bool(answer["action"] == nil)
            if !key.hyper { answer["clash"] = (Self.macOSClashes([key], conflicts())[key] ?? PlainComboShadow.warning(for: key)).map(JSONValue.string) }
            return .object(answer)
        })
    }

    /// The keys `keys --free` offers: letters, digits, punctuation, Space, Return, Tab, Delete, the arrows and F1–F12, in
    /// that order; not Escape, § or the nav keys a laptop lacks.
    static let bindable: [Int64] = {
        let left: Set<Int64> = [53, 10, 114, 115, 116, 117, 119, 121]
        func rank(_ code: Int64) -> (Int, String) {
            let name = KeyNames.name(for: code)
            if name.count == 1, name.first!.isLetter { return (0, name) }
            if name.count == 1, name.first!.isNumber { return (1, name) }
            if name.count == 1 { return (2, name) }
            if name.hasPrefix("F"), let n = Int(name.dropFirst()) { return (4, String(format: "%02d", n)) }
            return (3, name)
        }
        return KeyNames.names.keys.filter { !left.contains($0) }.sorted { rank($0) < rank($1) }
    }()

    /// The action holding `key`, either side of each modifier counting for a plain combo.
    static func holder(of key: Key, in store: BindStore) -> String? {
        store.action(for: key) ?? store.binds.first { family($0.key) == family(key) }?.value
    }

    /// `key` with each modifier on both sides: one side held counts as the key being held.
    private static func family(_ key: Key) -> Key { Key(keyCode: key.keyCode, modifiers: key.modifiers.eitherSide, hyper: key.hyper) }

    /// The macOS shortcut each plain combo of `keys` lands on, by name.
    private static func macOSClashes(_ keys: [Key], _ conflicts: ShortcutConflicts) -> [Key: String] {
        let plain = keys.filter { !$0.hyper }
        guard !plain.isEmpty else { return [:] }
        let byFamily = Dictionary(plain.map { (family($0), $0) }, uniquingKeysWith: { a, _ in a })
        let clashes = conflicts.clashes(binds: Dictionary(plain.map { ($0, "") }, uniquingKeysWith: { a, _ in a }))
        return Dictionary(clashes.compactMap { c in c.hotkey.key.flatMap { byFamily[$0] }.map { ($0, PlainComboShadow.shadows(c.hotkey.name)) } },
                          uniquingKeysWith: { a, _ in a })
    }

    /// "hyper+shift+k", "k", "leftAlt+h": the key last, Hyper unless the word leaves it out and names cmd, ctrl or alt.
    static func combo(_ text: String) throws(ControlError) -> Key {
        var words = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        let hyper = words.contains { $0.lowercased() == "hyper" }
        words.removeAll { $0.lowercased() == "hyper" }
        guard var key = Key(spelling: words.joined(separator: "+")) else {
            throw ControlError(.badValue, "\(text) is no key: the key last, as hyper+k, hyper+shift+n or leftAlt+h")
        }
        key.hyper = hyper || key.modifiers.isDisjoint(with: [.ctrl, .alt, .cmd])
        return key
    }
}
