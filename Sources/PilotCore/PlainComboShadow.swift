/// What a plain combo takes from macOS or from typing (story 51): the warning on the Binds screen's Plain combos tab.
/// Data only; Shortcut conflicts (story 101) is what turns the macOS ones off.
public enum PlainComboShadow {
    /// macOS's own shortcuts a plain combo can land on, either side of each modifier.
    static let macOS: [Key: String] = [
        plain(126, .ctrl): "Mission Control", plain(125, .ctrl): "Application windows",
        plain(123, .ctrl): "Move left a space", plain(124, .ctrl): "Move right a space",
        plain(49, .cmd): "Spotlight", plain(49, .ctrl): "Select the previous input source",
        plain(48, .cmd): "App switcher", plain(50, .cmd): "Move focus to the next window",
        plain(20, [.cmd, .shift]): "Screenshot", plain(21, [.cmd, .shift]): "Screenshot of a selection",
        plain(23, [.cmd, .shift]): "Screenshot and recording options",
    ]
    /// The US layout's Option dead keys: the accent the next letter takes.
    static let accents: [Int64: String] = [14: "´", 32: "¨", 34: "ˆ", 45: "˜", 50: "`"]

    /// "Shadows macOS's Spotlight.": a plain combo on one of macOS's own shortcuts.
    public static func shadows(_ name: String) -> String { "Shadows macOS's \(name)." }

    public static func warning(for key: Key) -> String? {
        guard !key.hyper else { return nil }
        let families = key.modifiers.eitherSide
        if let name = macOS[Key(keyCode: key.keyCode, modifiers: families, hyper: false)] { return shadows(name) }
        guard key.keyCode <= 50, KeyNames.name(for: key.keyCode).count == 1 else { return nil }   // a key that types
        if families.contains(.alt), families.isSubset(of: [.alt, .shift]) {
            let types = accents[key.keyCode].map { "the \($0) accent" } ?? "a character"
            switch (key.modifiers.contains(.leftAlt), key.modifiers.contains(.rightAlt)) {
            case (true, true): return "\(key.label) types \(types); this takes it from both Alt keys."
            case (false, true): return "\(key.label) no longer types \(types)."
            default:
                var right = key
                right.modifiers.remove(.leftAlt); right.modifiers.insert(.rightAlt)
                return "\(key.label) no longer types \(types); \(right.label) still does."
            }
        }
        if families == .cmd || families == [.cmd, .shift] { return "\(key.label) is a menu shortcut in most apps; this takes it everywhere." }
        return nil
    }

    private static func plain(_ keyCode: Int64, _ modifiers: Modifiers) -> Key { Key(keyCode: keyCode, modifiers: modifiers, hyper: false) }
}

extension Modifiers {
    /// Each modifier held on either side as both sides: what a macOS shortcut, which ignores sides, sees.
    public var eitherSide: Modifiers {
        [Modifiers.shift, .ctrl, .alt, .cmd].reduce(into: Modifiers()) { all, m in if !isDisjoint(with: m) { all.formUnion(m) } }
    }
}
