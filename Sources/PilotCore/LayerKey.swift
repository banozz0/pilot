import Foundation

/// The physical key that is Hyper. Caps Lock reaches the tap as F18 (remapped at the HID level). A modifier that is a
/// layer key is Hyper by itself and loses its own role while held, so its other side keeps it and at most one side is
/// on (P68): left Command picked, Cmd+C, Cmd+V and Cmd+Tab need right Command.
public enum LayerKey: String, CaseIterable, Codable, Identifiable, Sendable {
    case capsLock, leftControl, rightControl, leftOption, rightOption, leftCommand, rightCommand

    public var id: String { rawValue }

    /// The key's own sign on a key cap (design round 4): Caps Lock's ⇪, Control's ⌃, Option's ⌥, Command's ⌘.
    public var symbol: String {
        switch self {
        case .capsLock: "⇪"
        case .leftControl, .rightControl: "⌃"
        case .leftOption, .rightOption: "⌥"
        case .leftCommand, .rightCommand: "⌘"
        }
    }

    /// The same sign as an SF Symbol, for the dropdown's Hyper switch (card agent-bo-95422986).
    public var systemImage: String {
        switch self {
        case .capsLock: "capslock"
        case .leftControl, .rightControl: "control"
        case .leftOption, .rightOption: "option"
        case .leftCommand, .rightCommand: "command"
        }
    }

    public var label: String {
        switch self {
        case .capsLock: "Caps Lock"
        case .leftControl: "Left Control"
        case .rightControl: "Right Control"
        case .leftOption: "Left Option"
        case .rightOption: "Right Option"
        case .leftCommand: "Left Command"
        case .rightCommand: "Right Command"
        }
    }

    /// The virtual key code the tap sees for this key.
    public var keyCode: Int64 {
        switch self {
        case .capsLock: KeyCode.f18
        case .leftControl: KeyCode.leftControl
        case .rightControl: KeyCode.rightControl
        case .leftOption: KeyCode.leftOption
        case .rightOption: KeyCode.rightOption
        case .leftCommand: KeyCode.leftCommand
        case .rightCommand: KeyCode.rightCommand
        }
    }

    /// The modifier side the key is; nil for Caps Lock.
    public var side: Modifiers? {
        switch self {
        case .capsLock: nil
        case .leftControl: .leftCtrl
        case .rightControl: .rightCtrl
        case .leftOption: .leftAlt
        case .rightOption: .rightAlt
        case .leftCommand: .leftCmd
        case .rightCommand: .rightCmd
        }
    }

    /// Modifier keys arrive as flagsChanged; the device-specific flag (NX_DEVICELCTLKEYMASK and so on) says whether the
    /// key is down. With the key code it tells left from right: a flagsChanged carries the key that changed, the bit
    /// whether that side is down now.
    public var deviceFlag: UInt64? { side.flatMap(KeyEvent.bits(of:))?.device }

    /// The modifier the key sets (CGEventFlags maskControl, maskAlternate, maskCommand); nil for Caps Lock.
    public var modifierMask: UInt64? { side.flatMap(KeyEvent.bits(of:))?.mask }

    /// What the key no longer does as Hyper, one plain line for the picker (P68): the rule for every modifier is that
    /// the picked side is Hyper alone and the other side stays itself.
    public var note: String {
        switch self {
        case .capsLock: "Caps Lock is Hyper while Pilot runs and goes back to Caps Lock when it quits."
        case .leftControl: "Left Control is Hyper by itself; Control shortcuts need right Control, which a MacBook keyboard lacks."
        case .rightControl: "Right Control is Hyper by itself; left Control stays normal."
        case .leftOption: "Left Option is Hyper by itself; right Option still types accents and Option shortcuts."
        case .rightOption: "Right Option is Hyper by itself; left Option stays normal."
        case .leftCommand: "Left Command is Hyper by itself; Cmd+C, Cmd+V and Cmd+Tab then need right Command."
        case .rightCommand: "Right Command is Hyper by itself; left Command stays normal, so Cmd+C still copies."
        }
    }

    public var needsCapsLockRemap: Bool { self == .capsLock }

    /// The other side of the same modifier, when it can be a layer key too. At most one of a pair is on, so the other
    /// stays that modifier and the note's promise holds.
    public var twin: LayerKey? {
        switch self {
        case .leftControl: .rightControl
        case .rightControl: .leftControl
        case .leftOption: .rightOption
        case .rightOption: .leftOption
        case .leftCommand: .rightCommand
        case .rightCommand: .leftCommand
        case .capsLock: nil
        }
    }

    /// Whether `keys` holds both sides of one modifier.
    public static func hasTwins(_ keys: [LayerKey]) -> Bool { keys.contains { $0.twin.map(keys.contains) ?? false } }

    /// Whether General's switch for `key` is greyed: the last key on stays on, and a key whose twin is on cannot join
    /// it. A store holding both twins (old or hand-edited) greys neither, so either can be turned off.
    public static func isLocked(_ key: LayerKey, in keys: [LayerKey]) -> Bool {
        keys == [key] || !keys.contains(key) && key.twin.map(keys.contains) == true
    }

    /// The key a pilot://press `layer=` word names (pressWord).
    public init?(pressWord: String) {
        guard let key = Self.allCases.first(where: { $0.pressWord == pressWord }) else { return nil }
        self = key
    }

    /// pilot://press's `layer=` word for the key (PilotApp's application(_:open:)).
    public var pressWord: String {
        switch self {
        case .capsLock: "capslock"
        case .leftControl: "lctl"
        case .rightControl: "rctl"
        case .leftOption: "lopt"
        case .rightOption: "ropt"
        case .leftCommand: "lcmd"
        case .rightCommand: "rcmd"
        }
    }

    /// The key's HID usage (page 7), the number UserKeyMapping entries use.
    public var hidUsage: Int {
        switch self {
        case .capsLock: 0x7_0000_0039
        case .leftControl: 0x7_0000_00E0
        case .rightControl: 0x7_0000_00E4
        case .leftOption: 0x7_0000_00E2
        case .rightOption: 0x7_0000_00E6
        case .leftCommand: 0x7_0000_00E3
        case .rightCommand: 0x7_0000_00E7
        }
    }

    /// F18's HID usage: what Caps Lock becomes while Pilot runs.
    public static let f18Usage = 0x7_0000_006D
}

public enum KeyCode {
    public static let f18: Int64 = 79
    public static let leftControl: Int64 = 59, rightControl: Int64 = 62
    public static let leftOption: Int64 = 58, rightOption: Int64 = 61
    public static let leftCommand: Int64 = 55, rightCommand: Int64 = 54
    public static let escape: Int64 = 53
    /// Return and the keypad's Enter: a scrolling capture ends on either.
    public static let returnKey: Int64 = 36
    public static let keypadEnter: Int64 = 76
    public static let k: Int64 = 40
    public static let q: Int64 = 12
    public static let tab: Int64 = 48
    public static let v: Int64 = 9
    public static let c: Int64 = 8
    /// Delete (backspace) and the left arrow: a snippet erases its keyword and puts the caret at {cursor}.
    public static let delete: Int64 = 51
    public static let leftArrow: Int64 = 123
    public static let rightArrow: Int64 = 124
    public static let forwardDelete: Int64 = 117
    public static let downArrow: Int64 = 125
    public static let upArrow: Int64 = 126
    public static let space: Int64 = 49
}

/// Where a layer-key change came from, for its log line (card agent-bo-95422775). No pilot:// route sets the key.
public enum LayerKeySource: String, Sendable { case settings, onboarding }

extension LayerKey {
    /// Turning Caps Lock off as a layer key asks first: it loses Escape on a tap and Hyper moves (card agent-bo-95422775).
    /// Adding a key never asks.
    public static func asksFirst(from old: [LayerKey], to new: [LayerKey]) -> Bool { old.contains(.capsLock) && !new.contains(.capsLock) }

    public static func changeLine(_ old: [LayerKey], _ new: [LayerKey], _ source: LayerKeySource) -> String {
        "layer keys \(old.rawValues) -> \(new.rawValues) (\(source.rawValue))"
    }

    /// `keys` in the one order Pilot shows them, Caps Lock first, each once; nil when none is left (Sven 2026-10-12: more
    /// than one layer key, each alone Hyper).
    public static func ordered(_ keys: some Sequence<LayerKey>) -> [LayerKey]? {
        let set = Set(keys)
        return set.isEmpty ? nil : allCases.filter(set.contains)
    }

    /// The stored words as keys: unknown words dropped, nil when none is left.
    public static func parse(_ words: [String]) -> [LayerKey]? { ordered(words.compactMap(LayerKey.init(rawValue:))) }
}

/// The layer keys in use, Caps Lock first: each alone is Hyper. A key cap shows one sign, the first's; text names them all.
extension [LayerKey] {
    public var primary: LayerKey { first ?? .capsLock }
    /// "Caps Lock or right Command".
    public var label: String {
        spokenList(enumerated().map { $0.offset == 0 || $0.element == .capsLock ? $0.element.label
                       : $0.element.label.prefix(1).lowercased() + $0.element.label.dropFirst() },
                   joiner: "or")
    }
    public var symbol: String { primary.symbol }
    public var rawValues: String { map(\.rawValue).joined(separator: ",") }
}
