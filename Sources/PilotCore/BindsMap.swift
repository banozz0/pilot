import Foundation

/// Binds › More › Export and import's Save map (Sven, 2026-10-19, Q328): every bind of the active preset as one picture to keep
/// beside the keyboard. Its layers are the binds' own, read from the store rather than from the Binds page's tabs: Hyper,
/// then each sublayer in the page's order, then any other set of modifiers under Hyper (Hyper+Ctrl+Alt), then the plain
/// combos as one layer, each key with its own modifiers. A layer with no binds is left out.
public enum BindsMap {
    /// What a bind does, as the map colours it: the four kinds Q328 names.
    public enum Kind: Int, CaseIterable, Sendable {
        case app, window, capture, tool

        /// The map's legend, one word each (spec pilot-1-1 T30).
        public var title: String {
            switch self {
            case .app: "Apps"
            case .window: "Windows"
            case .capture: "Captures"
            case .tool: "Tools"
            }
        }

        /// From an action's module, as the Binds keyboard groups it (`BindsKeyboard.module`): Apps (with AI, notes, the
        /// terminal and drive routes), Windows and Workspaces as one, Captures, and System, media and Pilot's own as tools.
        public init(module: String) {
            switch BindsKeyboard.module(module) {
            case 1, 2: self = .window
            case 3: self = .capture
            case 4, 5: self = .tool
            default: self = .app
            }
        }
    }

    /// One bind on a layer: its key, the modifiers it adds (a plain combo's own; none on a Hyper layer) and its action.
    public struct Entry: Equatable, Sendable {
        public let code: Int64
        public let modifiers: Modifiers
        public let action: String
    }

    /// One layer of the map: Hyper with a set of modifiers, or the plain combos.
    public struct Layer: Equatable, Sendable {
        public let hyper: Bool
        /// The modifiers held with Hyper; empty for the plain combos, whose keys carry their own.
        public let modifiers: Modifiers
        /// Its binds in board order (key code, then modifiers).
        public let entries: [Entry]

        /// "Hyper", "Hyper + Shift", "Hyper + Ctrl + Alt", "Without Hyper".
        public var title: String { hyper ? (["Hyper"] + modifiers.labels).joined(separator: " + ") : AppSection.plainCombos.title }

        /// The signs a key in this layer is pressed with after the layer key: "⇧", "⌃⌥"; empty for Hyper and Plain.
        public var signs: String { Self.signs(modifiers) }

        /// How to press a key in it, `layerKey` naming the layer key ("Caps Lock").
        public func how(layerKey: String) -> String {
            guard hyper else { return "No Hyper: the combo alone" }
            let held = modifiers.labels
            return switch held.count {
            case 0: "Hold \(layerKey) and press"
            case 1: "Hold \(layerKey) and \(held[0]), then press"
            default: "Hold \(layerKey), \(held.dropLast().joined(separator: ", ")) and \(held[held.count - 1]), then press"
            }
        }

        /// Each key's first action, by key code, as a board draws it (a plain layer may hold two combos on one key).
        public var byKey: [Int64: Entry] {
            Dictionary(entries.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        }

        /// ⇧ ⌃ ⌥ ⌘ for each modifier held, either side.
        public static func signs(_ modifiers: Modifiers) -> String {
            [(Modifiers.shift, "⇧"), (.ctrl, "⌃"), (.alt, "⌥"), (.cmd, "⌘")].filter { !modifiers.isDisjoint(with: $0.0) }.map(\.1).joined()
        }
    }

    /// The map's layers from a store's key binds, empty ones left out: Hyper, the sublayers in the Binds page's order,
    /// other Hyper sets (fewest modifiers first), then the plain combos.
    public static func layers(_ binds: [Key: String]) -> [Layer] {
        var hyper: [Modifiers: [Entry]] = [:], plain: [Entry] = []
        for (key, action) in binds where !MouseKeys.isMouse(key.keyCode) {
            if key.hyper { hyper[key.modifiers, default: []].append(Entry(code: key.keyCode, modifiers: [], action: action)) }
            else { plain.append(Entry(code: key.keyCode, modifiers: key.modifiers, action: action)) }
        }
        let named = BindsPage.Sublayer.allCases.map(\.modifiers)
        let others = hyper.keys.filter { !named.contains($0) }.sorted { ($0.labels.count, $0.rawValue) < ($1.labels.count, $1.rawValue) }
        func sorted(_ entries: [Entry]) -> [Entry] {
            entries.sorted { ($0.code, $0.modifiers.rawValue, $0.action) < ($1.code, $1.modifiers.rawValue, $1.action) }
        }
        var out = (named + others).compactMap { mods in hyper[mods].map { Layer(hyper: true, modifiers: mods, entries: sorted($0)) } }
        if !plain.isEmpty { out.append(Layer(hyper: false, modifiers: [], entries: sorted(plain))) }
        return out
    }

    /// A run of numbered actions on the number keys: three or more neighbouring digit keys each running one action with
    /// its own digit ("workspaces.go:1" on 1, "workspaces.go:2" on 2), which the map labels once across the run.
    public struct Run: Equatable, Sendable {
        /// The family, the action id before its number: "workspaces.go".
        public let family: String
        public let codes: [Int64]
        public let first: Int, last: Int
    }

    /// The runs on `layer`'s number keys.
    public static func runs(_ layer: Layer) -> [Run] {
        let digits: [(n: Int, code: Int64)] = (0...9).compactMap { n in KeyNames.code(for: String(n)).map { (n, $0) } }
        let byKey = layer.byKey
        func family(_ n: Int, _ code: Int64) -> String? {
            guard let action = byKey[code]?.action, let colon = action.lastIndex(of: ":"), action[action.index(after: colon)...] == String(n)
            else { return nil }
            return String(action[..<colon])
        }
        // 1 to 9 then 0, as the keys sit.
        let order = digits.filter { $0.n != 0 } + digits.filter { $0.n == 0 }
        var out: [Run] = [], run: [(n: Int, code: Int64)] = [], current: String?
        func close() {
            if run.count >= 3, let current, let a = run.first, let b = run.last {
                out.append(Run(family: current, codes: run.map(\.code), first: a.n, last: b.n))
            }
            run = []
        }
        for d in order {
            let f = family(d.n, d.code)
            if f == nil || f != current { close() }
            current = f
            if f != nil { run.append(d) }
        }
        close()
        return out
    }
}
