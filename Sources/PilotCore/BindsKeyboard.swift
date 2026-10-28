import Foundation

/// Binds as a keyboard (design round 4, card agent-bo-95422894; the artifact's KB rows): each key coloured by what its
/// bind does on the sublayer picked, free keys hollow, the layer key held. Plain is the last tab, after the sublayers.
public enum BindsKeyboard {
    /// One key: its legend, the key code Pilot binds (nil for Shift and the layer key) and its width in key units.
    public struct Cap: Equatable, Sendable {
        public let legend: String
        public let code: Int64?
        public let width: Double
        public let isLayerKey: Bool
    }

    private static func cap(_ legend: String, _ width: Double = 1) -> Cap {
        let layer = legend == "Caps"
        return Cap(legend: layer ? "Hyper" : legend, code: layer || legend == "Shift" ? nil : KeyNames.code(for: legend), width: width,
                   isLayerKey: layer)
    }

    /// Every key code on the board.
    public static let codes: [Int64] = rows.joined().compactMap(\.code)

    /// The artifact's five rows, an ANSI board from Esc to Space.
    public static let rows: [[Cap]] = [
        [cap("Esc", 1.5)] + "1234567890".map { cap(String($0)) } + [cap("-"), cap("=")],
        [cap("Tab", 1.5)] + "QWERTYUIOP".map { cap(String($0)) } + [cap("["), cap("]")],
        [cap("Caps", 1.75)] + "ASDFGHJKL".map { cap(String($0)) } + [cap(";"), cap("Return", 1.75)],
        [cap("Shift", 2.25)] + "ZXCVBNM".map { cap(String($0)) } + [cap(","), cap("."), cap("/"), cap("Shift", 1.25)],
        [cap("Space", 13.5)],
    ]

    /// Return and Delete on the picked key (card agent-bo-95422993, G4), the keys the inspector's ↵ and ⌫ name: Return
    /// rebinds the picked key's bind or binds the free key, Delete clears its bind; Delete on a free key does nothing.
    public enum Command: Equatable, Sendable {
        case rebind(String), bind(Int64), clear(String)

        /// `bound` is the tab's keys and their actions, as the board draws them.
        public init?(returnKey: Bool, picked: Int64?, bound: [Int64: [String]]) {
            guard let picked else { return nil }
            switch (returnKey, bound[picked]?.first) {
            case (true, let action?): self = .rebind(action)
            case (true, nil): self = .bind(picked)
            case (false, let action?): self = .clear(action)
            case (false, nil): return nil
            }
        }
    }

    /// The keyboard's tabs: Hyper and its four sublayers, then the plain combos.
    public enum Layer: CaseIterable, Sendable {
        case hyper, shift, ctrl, alt, shiftCtrl, plain

        public var title: String {
            switch self {
            case .hyper: "Hyper"
            case .shift: "+ Shift"
            case .ctrl: "+ Ctrl"
            case .alt: "+ Alt"
            case .shiftCtrl: "+ Shift Ctrl"
            case .plain: "Plain"
            }
        }

        /// The modifier signs a compact key cap shows after the layer key's: "⇧", "⇧⌃"; none for Hyper and Plain.
        public var signs: String {
            switch self {
            case .hyper, .plain: ""
            case .shift: "⇧"
            case .ctrl: "⌃"
            case .alt: "⌥"
            case .shiftCtrl: "⇧⌃"
            }
        }

        /// The Binds list's tab this keyboard tab shows.
        public var tab: BindsPage.Tab { sublayer.map { .layer($0) } ?? .plain }

        /// Toybox's line under the Binds title (card agent-bo-95423182): how many binds the tab holds, and how to press them.
        public func summary(count: Int, layerKeys: [LayerKey]) -> String {
            guard let sublayer else { return "\(count) plain combo\(count == 1 ? "" : "s") · no Hyper, just the combo" }
            let name = self == .hyper ? "Hyper" : "Hyper \(title)"
            let held = sublayer.modifiers.labels
            let how = switch held.count {
            case 0: "hold \(layerKeys.label) and press"
            case 1: "hold \(layerKeys.label) and \(held[0]), then press"
            default: "hold \(layerKeys.label), \(held.dropLast().joined(separator: ", ")) and \(held[held.count - 1]), then press"
            }
            return (count == 0 ? "Nothing on \(name) yet" : "\(count) on \(name)") + " · " + how
        }

        /// The tab a Hyper press shows: its sublayer's; nil for a set of modifiers no tab has.
        public init?(hyper key: Key) {
            guard let sublayer = BindsPage.Sublayer(modifiers: key.modifiers), let layer = Self.allCases.first(where: { $0.sublayer == sublayer }) else { return nil }
            self = layer
        }

        /// The sublayer this tab shows; nil for Plain.
        public var sublayer: BindsPage.Sublayer? {
            switch self {
            case .hyper: .hyper
            case .shift: .shift
            case .ctrl: .ctrl
            case .alt: .alt
            case .shiftCtrl: .shiftCtrl
            case .plain: nil
            }
        }
    }

    /// The legend's colours: Apps, Windows, Workspaces, Captures, System, Pilot (the theme's module colours, in order).
    public static let modules = ["Apps", "Windows", "Workspaces", "Captures", "System", "Pilot"]

    /// Which of the six an action module colours as: drive routes with Apps, media with System, the engine as Pilot.
    public static func module(_ module: String) -> Int {
        switch module {
        case "windows": 1
        case "workspaces": 2
        case "captures": 3
        case "system", "media": 4
        case "engine": 5
        default: 0
        }
    }

    /// Toybox's Free keys card (card agent-bo-95423182): one key, or a run of them shown as one range that picks its first.
    public struct FreeRun: Equatable, Sendable {
        public let label: String
        public let codes: [Int64]
    }

    /// Past this many, a row's runs of typed keys fold into ranges too.
    public static let freeLimit = 24

    /// The keys `board` leaves free on a tab, in board order: a run of three or more free F-keys as one range, every named
    /// key (Esc, Delete, Home, the arrows) alone, no modifier; past `freeLimit`, a row's run of three or more free typed
    /// keys (one character each) as one range too.
    public static func free(on board: Board, bound: [Int64: [String]]) -> [FreeRun] {
        enum Kind { case function, typed, named }
        let spots = board.spots.filter { $0.code != nil && $0.modifier == nil && bound[$0.code ?? -1] == nil }
        func kind(_ spot: Spot) -> Kind {
            if spot.isFunctionKey { return .function }
            // The arrows and Forward Delete print one sign, but are named keys.
            return spot.legend.count == 1 && ![117, 123, 124, 125, 126].contains(spot.code) ? .typed : .named
        }
        // Each free spot's place on the board, so a run is the next key on the board, not just the next free one.
        let place = Dictionary(board.spots.enumerated().map { ($1.code ?? -1, $0) }, uniquingKeysWith: { a, _ in a })
        func adjacent(_ a: Spot, _ b: Spot) -> Bool { place[b.code ?? -1].map { $0 == (place[a.code ?? -1] ?? -2) + 1 } ?? false }
        func runs(folding typed: Bool) -> [FreeRun] {
            var out: [FreeRun] = [], run: [Spot] = []
            func close() {
                guard let first = run.first, let last = run.last else { return }
                if run.count >= 3 { out.append(FreeRun(label: "\(first.legend) – \(last.legend)", codes: run.compactMap(\.code))) }
                else { out += run.map { FreeRun(label: $0.legend, codes: $0.code.map { [$0] } ?? []) } }
                run = []
            }
            for spot in spots {
                let k = kind(spot)
                let folds = k == .function || (typed && k == .typed)
                // A run is unbroken keys of one kind in one row.
                if let last = run.last, !(folds && kind(last) == k && last.row == spot.row && adjacent(last, spot)) { close() }
                if folds { run.append(spot) } else { close(); out.append(FreeRun(label: spot.legend, codes: spot.code.map { [$0] } ?? [])) }
            }
            close()
            return out
        }
        let plain = runs(folding: false)
        return plain.count > freeLimit ? runs(folding: true) : plain
    }

    /// The actions on each key in `layer`, by key code: Hyper with the sublayer's modifiers, or for Plain every plain combo
    /// on that key whatever its modifiers.
    public static func bound(store: BindStore, layer: Layer) -> [Int64: [String]] {
        var keys: [Int64: [String]] = [:]
        for (key, action) in store.binds where layer.tab.holds(key) { keys[key.keyCode, default: []].append(action) }
        return keys.mapValues { $0.sorted() }
    }
}

/// Each bind's short name on its key (card agent-bo-95422992; Sven kept the mockup's "short names on the keys"): a word or
/// two that fits a key cap, the mockup's words for the built-in actions, an app's or site's name for an app or URL route.
extension BindsKeyboard {
    static let shortNames: [String: String] = [
        "apps.terminal": "Terminal", "apps.clipboard": "Clips", "apps.editor": "Editor", "apps.emoji": "Emoji",
        "apps.files": "Files", "apps.launcher": "Pilot menu", "apps.passwords": "Passwords",
        "captures.area": "Area", "captures.fullscreen": "Screen", "captures.ocr": "Text", "captures.scrolling": "Scrolling",
        "engine.sheet": "Keys", "system.lock": "Lock",
        "windows.close": "Close", "windows.firstThreeQuarters": "¾ left", "windows.lastQuarter": "¼ right", "windows.flipSplit": "Flip split",
        "windows.cycleColumnWidth": "Width", "windows.cycleColumnWidthBack": "Width back", "windows.centreColumn": "Centre",
        "windows.maximiseColumn": "Full", "windows.leaveStack": "Unstack",
        "windows.focusNext": "Next", "windows.growWidth": "Widen", "windows.shrinkWidth": "Narrow", "windows.focusLeft": "Left",
        "windows.focusRight": "Right", "windows.focusUp": "Up", "windows.focusDown": "Down",
        "windows.focusPrevious": "Previous", "windows.focusDisplayLeft": "← Display", "windows.focusDisplayRight": "Display →",
        "workspaces.former": "Last",
        "media.mute": "Mute", "media.next": "Next", "media.playPause": "Play", "media.previous": "Back", "media.volumeDown": "Vol −",
        "media.volumeUp": "Vol +",
    ]
    /// Sites whose name is not just its first letter raised.
    static let brands = ["youtube": "YouTube", "github": "GitHub", "chatgpt": "ChatGPT", "linkedin": "LinkedIn", "whatsapp": "WhatsApp"]
    /// The most a short name holds before it keeps only its first word.
    static let longest = 11

    /// `id`'s short name, `label` being its full one; `workspaceName` names a numbered workspace when it has a name.
    public static func short(_ id: String, label: String, workspaceName: (String) -> String? = { _ in nil }) -> String {
        if let name = shortNames[id] { return name }
        if let number = id.split(separator: ":", maxSplits: 1).last.map(String.init), id.hasPrefix("workspaces.go:") {
            return workspaceName(number) ?? number
        }
        let url = id.hasPrefix("apps.url:") ? id.split(separator: ":", maxSplits: 2).last.map(String.init)
            : id.hasPrefix("drive.url:") ? String(id.dropFirst("drive.url:".count))
            : id.hasPrefix("apps.web:") ? String(id.dropFirst("apps.web:".count)) : nil
        if let site = url.flatMap(URL.init(string:)).flatMap(siteName) { return site }
        var words = label
        for prefix in ["Pick: ", "Shortcut: ", "Shell: ", "Open "] where words.hasPrefix(prefix) { words.removeFirst(prefix.count) }
        for article in ["a ", "an ", "the "] where words.lowercased().hasPrefix(article) { words.removeFirst(article.count) }
        if words.count > longest { words = (words.split(separator: " ").first.map(String.init) ?? words).trimmingCharacters(in: .punctuationCharacters) }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A web address's site, "Spotify" for open.spotify.com; another scheme's app, "Obsidian" for obsidian://new.
    private static func siteName(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let name = ["http", "https"].contains(scheme) ? url.host()?.split(separator: ".").dropLast().last.map(String.init) : scheme
        guard let name, !name.isEmpty else { return nil }
        return brands[name.lowercased()] ?? name.prefix(1).uppercased() + name.dropFirst()
    }
}

extension BindsKeyboard.Spot {
    /// F1 to F12 (and on): a legend of F and a number.
    public var isFunctionKey: Bool { legend.count > 1 && legend.hasPrefix("F") && Int(legend.dropFirst()) != nil }
}

extension BindsKeyboard {
    /// Whether `spot` is a layer key on `layer`'s board, drawn held: Caps Lock, a Control, an Option or a Command, each that
    /// `layerKeys` holds; none on Plain, where no layer key is held.
    public static func isLayerKey(_ spot: Spot, layerKeys: [LayerKey], layer: Layer) -> Bool {
        guard layer != .plain else { return false }
        let key: LayerKey? = switch (spot.modifier, spot.side) {
        case (.caps, _): .capsLock
        case (.ctrl, .left): .leftControl
        case (.ctrl, .right): .rightControl
        case (.alt, .left): .leftOption
        case (.alt, .right): .rightOption
        case (.cmd, .left): .leftCommand
        case (.cmd, .right): .rightCommand
        default: nil
        }
        return key.map(layerKeys.contains) ?? false
    }

    /// Whether `spot` is one of `layer`'s held modifiers (Shift on the Shift tab, either side), drawn held with the layer key.
    public static func isHeld(_ spot: Spot, layer: Layer) -> Bool {
        spot.modifier.map { !(layer.sublayer?.modifiers ?? []).isDisjoint(with: $0.both) } ?? false
    }

    /// A key's legend as the restyled boards print it: a letter, sign or F-key as it is, a word in lower case ("esc",
    /// "shift", "return").
    public static func printed(_ spot: Spot) -> String {
        spot.legend.count > 1 && !spot.isFunctionKey ? spot.legend.lowercased() : spot.legend
    }
}

extension BindsKeyboard.Spot {
    /// On a board's function row (each half's first).
    public var onFunctionRow: Bool { row % BindsKeyboard.Board.rowsPerHalf == 0 }
}

extension BindsKeyboard.Board {
    /// A key's caption on this board's layout, as the board prints it; its US name off the board.
    public func caption(_ code: Int64) -> String { spots.first { $0.code == code }?.legend ?? KeyNames.name(for: code) }
}
