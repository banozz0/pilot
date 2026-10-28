import Foundation

/// macOS's own shortcuts (stories 34, 35 and 101; SPEC.md, Conflicts): the AppleSymbolicHotKeys table of
/// com.apple.symbolichotkeys, a private preference and not a public API, so a macOS update can change it. Pure: the app
/// reads and writes the domain; this finds the clashes, switches rows off and puts them back exactly.
public enum SymbolicHotKeys {
    public struct HotKey: Equatable, Sendable {
        public let id: Int, enabled: Bool, key: Key?, name: String
    }

    /// A macOS shortcut on the trigger of one of Pilot's plain combos. A Hyper bind never clashes: the tap swallows it.
    public struct Clash: Equatable, Sendable {
        public let hotkey: HotKey, action: String
    }

    /// Every row a Pilot plain combo can land on (PlainComboShadow's macOS shortcuts, and the Shift and Option variants
    /// beside them), with macOS's own keys for it: a missing row is on with these. Rows 32, 60, 61, 64, 65, 79 and 81 are
    /// as this Mac's table held them on 2026-10-05; 27, 28, 30, 33 and 184 are cleared or missing there, so their keys
    /// are macOS's defaults, unverified on this Mac.
    static let known: [Int: (name: String, parameters: [Int])] = [
        27: ("Move focus to the next window", [96, 50, 1048576]), 28: ("Screenshot", [51, 20, 1179648]),
        30: ("Screenshot of a selection", [52, 21, 1179648]), 33: ("Application windows", [65535, 125, 8650752]),
        184: ("Screenshot and recording options", [53, 23, 1179648]),
        32: ("Mission Control", [65535, 126, 8650752]),
        60: ("Select the previous input source", [32, 49, 262144]), 61: ("Select the next input source", [32, 49, 786432]),
        64: ("Spotlight", [32, 49, 1048576]), 65: ("Finder search window", [32, 49, 1572864]),
        79: ("Move left a space", [65535, 123, 8650752]), 81: ("Move right a space", [65535, 124, 8650752]),
    ]

    public static func hotKeys(in table: [String: Any]) -> [HotKey] {
        var rows = table
        for (id, k) in known where rows[String(id)] == nil { rows[String(id)] = row(k.parameters) }
        return rows.compactMap { id, row -> HotKey? in
            guard let n = Int(id), let row = row as? [String: Any] else { return nil }
            return HotKey(id: n, enabled: (row["enabled"] as? NSNumber)?.boolValue ?? false, key: key(row), name: name(n))
        }
        .sorted { $0.id < $1.id }
    }

    public static func name(_ id: Int) -> String {
        known[id]?.name ?? ((118...126).contains(id) ? "Switch to Desktop \(id - 117)" : "macOS shortcut \(id)")
    }

    /// `parameters` is [character, key code, modifier flags]; 65535 is no key.
    static func key(_ row: [String: Any]) -> Key? {
        guard let p = (row["value"] as? [String: Any])?["parameters"] as? [NSNumber], p.count >= 3, p[1].int64Value != 65535
        else { return nil }
        let flags = p[2].int64Value
        let mods = [(KeyEvent.shiftMask, Modifiers.shift), (KeyEvent.ctrlMask, .ctrl), (KeyEvent.altMask, .alt), (KeyEvent.cmdMask, .cmd)]
            .reduce(into: Modifiers()) { m, f in if UInt64(bitPattern: flags) & f.0 != 0 { m.formUnion(f.1) } }
        return Key(keyCode: p[1].int64Value, modifiers: mods, hyper: false)
    }

    /// Each row that is on and holds the trigger of one of Pilot's plain combos, either side of each modifier.
    public static func clashes(in table: [String: Any], binds: [Key: String]) -> [Clash] {
        let plain = Dictionary(binds.filter { !$0.key.hyper }.map { (Key(keyCode: $0.key.keyCode, modifiers: $0.key.modifiers.eitherSide, hyper: false), $0.value) },
                               uniquingKeysWith: { a, _ in a })
        return hotKeys(in: table).compactMap { h in
            guard h.enabled, let key = h.key, let action = plain[key] else { return nil }
            return Clash(hotkey: h, action: action)
        }
    }

    /// The table with each row switched off, and the backup grown by what each row was, or that it had none (`absent`).
    /// A row already in the backup keeps its first value, so restore always gives back the table before any switch-off.
    public static func switchOff(_ ids: [Int], in table: [String: Any], backup: [String: Any]) -> (table: [String: Any], backup: [String: Any]) {
        var table = table, entries = backup["entries"] as? [String: Any] ?? [:], absent = Set(backup["absent"] as? [String] ?? [])
        for n in ids {
            let id = String(n), old = table[id] as? [String: Any]
            if entries[id] == nil && !absent.contains(id) { if let old { entries[id] = old } else { absent.insert(id) } }
            guard var off = old ?? known[n].map({ row($0.parameters) }) else { continue }
            off["enabled"] = false
            table[id] = off
        }
        return (table, ["entries": entries, "absent": absent.sorted()])
    }

    /// The rows a backup can put back, by id.
    public static func ids(in backup: [String: Any]) -> [Int] {
        ((backup["entries"] as? [String: Any] ?? [:]).keys + (backup["absent"] as? [String] ?? [])).compactMap(Int.init).sorted()
    }

    public static func restore(_ backup: [String: Any], in table: [String: Any]) -> [String: Any] {
        var table = table
        for (id, old) in backup["entries"] as? [String: Any] ?? [:] { table[id] = old }
        for id in backup["absent"] as? [String] ?? [] { table[id] = nil }
        return table
    }

    private static func row(_ parameters: [Int]) -> [String: Any] {
        ["enabled": true, "value": ["parameters": parameters, "type": "standard"] as [String: Any]]
    }
}
