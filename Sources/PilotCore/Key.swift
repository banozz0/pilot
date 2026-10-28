import Foundation

/// A trigger (GLOSSARY.md): a key under Hyper plus its sublayer (Hyper+Shift+N moves a window), or a plain combo with
/// no Hyper (left Alt+H). Side-aware from the start, so the bind store's shape never migrates for plain combos.
public struct Key: Hashable, Sendable {
    public var keyCode: Int64
    public var modifiers: Modifiers
    /// False for a plain combo.
    public var hyper: Bool

    public init(keyCode: Int64, modifiers: Modifiers = [], hyper: Bool = true) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.hyper = hyper
    }

    public init(keyCode: Int64, shift: Bool) {
        self.init(keyCode: keyCode, modifiers: shift ? .shift : [])
    }

    /// `hyper: false` for a plain combo, Key("s", .leftAlt, hyper: false).
    public init(_ name: String, _ modifiers: Modifiers = [], hyper: Bool = true) {
        self.init(keyCode: KeyNames.code(for: name) ?? -1, modifiers: modifiers, hyper: hyper)
    }

    public init(_ name: String, shift: Bool) {
        self.init(name, shift ? .shift : [])
    }

    /// "Hyper+Shift+K", "Left Alt+H"
    public var label: String {
        ((hyper ? ["Hyper"] : []) + modifiers.labels + [KeyNames.name(for: keyCode)]).joined(separator: "+")
    }
}

/// Shift, Ctrl, Alt and Cmd, each left and right apart. Under Hyper a sublayer holds both sides of a modifier, since
/// either side picks it; a plain combo may name one side, so right Alt keeps typing accents (ADR 0006).
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftShift = Modifiers(rawValue: 1 << 0), rightShift = Modifiers(rawValue: 1 << 1)
    public static let leftCtrl = Modifiers(rawValue: 1 << 2), rightCtrl = Modifiers(rawValue: 1 << 3)
    public static let leftAlt = Modifiers(rawValue: 1 << 4), rightAlt = Modifiers(rawValue: 1 << 5)
    public static let leftCmd = Modifiers(rawValue: 1 << 6), rightCmd = Modifiers(rawValue: 1 << 7)
    public static let shift: Modifiers = [.leftShift, .rightShift], ctrl: Modifiers = [.leftCtrl, .rightCtrl]
    public static let alt: Modifiers = [.leftAlt, .rightAlt], cmd: Modifiers = [.leftCmd, .rightCmd]

    /// File and label order. A modifier with both sides is written by its plain name, one side as "leftAlt".
    private static let sides: [(name: String, left: Modifiers, right: Modifiers)] = [
        ("shift", .leftShift, .rightShift), ("ctrl", .leftCtrl, .rightCtrl), ("alt", .leftAlt, .rightAlt), ("cmd", .leftCmd, .rightCmd),
    ]

    /// Each modifier held, with its side when only one side is.
    private var held: [(name: String, side: String?)] {
        Self.sides.compactMap { m in
            switch (contains(m.left), contains(m.right)) {
            case (true, true): (m.name, nil)
            case (true, false): (m.name, "left")
            case (false, true): (m.name, "right")
            case (false, false): nil
            }
        }
    }

    /// ["shift", "leftAlt"]
    public var names: [String] { held.map { m in m.side.map { $0 + m.name.capitalized } ?? m.name } }

    /// ["Shift", "Left Alt"]
    public var labels: [String] { held.map { m in (m.side.map { $0.capitalized + " " } ?? "") + m.name.capitalized } }

    /// Any case: "leftAlt", "LeftAlt" and "leftalt" are one side.
    public init?(names: [String]) {
        self = []
        for name in names.map({ $0.lowercased() }) {
            guard let m = Self.sides.first(where: { [$0.name, "left" + $0.name, "right" + $0.name].contains(name) })
            else { return nil }
            if !name.hasPrefix("right") { insert(m.left) }
            if !name.hasPrefix("left") { insert(m.right) }
        }
    }
}

/// US layout virtual key codes, the ones a bind can use.
public enum KeyNames {
    public static let names: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        // The ISO key (§ on Apple's ISO board) and the nav keys Binds' whole keyboard draws (card agent-bo-95423003).
        10: "§", 114: "Insert", 115: "Home", 116: "PageUp", 117: "ForwardDelete", 119: "End", 121: "PageDown",
    ]
    private static let codes: [String: Int64] = Dictionary(uniqueKeysWithValues: names.map { ($1.lowercased(), $0) })

    /// A mouse trigger's name too (MouseKeys), kept out of `names`, which lists the keyboard's keys.
    public static func name(for code: Int64) -> String { names[code] ?? MouseKeys.name(for: code) ?? "key\(code)" }
    /// Spellings a URL or a sentence can use for keys whose name is a symbol.
    public static let aliases: [String: Int64] = [
        "left": 123, "right": 124, "down": 125, "up": 126, "enter": 36, "esc": 53, "minus": 27, "equal": 24,
        "plus": 24, "lbracket": 33, "rbracket": 30, "backtick": 50, "period": 47,
    ]
    /// Also reads back `name(for:)`'s "key<code>" for a key with no name.
    public static func code(for name: String) -> Int64? {
        codes[name.lowercased()] ?? aliases[name.lowercased()] ?? MouseKeys.code(for: name)
            ?? (name.hasPrefix("key") ? Int64(name.dropFirst(3)) : nil)
    }
}
