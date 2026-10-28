import Foundation

extension Extension.Item.Action {
    /// A key an action runs on in Hyper+Space (To-do B, ADR 0010 amended 2026-10-17): `"key": "cmd+e"`, modifiers then one
    /// key, joined by `+`. Pressed on a row of an extension's list, the selected row's action with that key runs, as
    /// Return runs its first; Cmd+K lists each action with its key. A key needs Command, Control or Option (a plain or
    /// shifted one is typing), and one the search field or Pilot already owns is refused: ⌘A ⌘C ⌘V ⌘X (editing), ⌘K
    /// (actions), ⌘Q ⌘W ⌘H ⌘M (the app's), ⌘1 to ⌘9 (Line's rows), an Option letter or digit (it types a character), and
    /// ← → (the field's caret). Keys: a letter, a digit, return, delete, up, down.
    public struct Key: Hashable, Sendable {
        public let command: Bool, option: Bool, control: Bool, shift: Bool
        /// The key's US-layout virtual key code (KeyNames).
        public let code: UInt16
        /// As macOS writes it: "⌘E", "⌥↑", "⌘⌫", "⇧⌘C".
        public let symbol: String

        private static let words: Set<String> = ["return", "enter", "delete", "backspace", "up", "down"]
        private static let owned: Set<String> = ["a", "c", "v", "x", "k", "q", "w", "h", "m"]

        /// A key line ("cmd+shift+c", "opt+up", "cmd+delete"); nil for any other text or a key it may not take.
        public init?(_ line: String) {
            var parts = line.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.popLast() else { return nil }
            let character = name.count == 1 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            guard character || Self.words.contains(name), let code = KeyNames.code(for: name == "backspace" ? "delete" : name) else { return nil }
            var command = false, option = false, control = false, shift = false
            for part in parts {
                switch part {
                case "cmd", "command": command = true
                case "opt", "option", "alt": option = true
                case "ctrl", "control": control = true
                case "shift": shift = true
                default: return nil
                }
            }
            guard command || option || control else { return nil }
            let plainCommand = command && !option && !control && !shift
            if plainCommand, Self.owned.contains(name) || character && name != "0" && name.first!.isNumber { return nil }
            if option, !command, !control, character { return nil }
            self.command = command; self.option = option; self.control = control; self.shift = shift
            self.code = UInt16(code)
            // Menu items' own way of writing a key (⌃⌥⇧⌘), with ↵ and ⌫ for the two keys KeyNames spells out.
            let mask = (shift ? 1 : 0) | (option ? 2 : 0) | (control ? 4 : 0) | (command ? 0 : 8)
            symbol = MenuItemSearch.key(char: [36: "↵", 51: "⌫"][code], modifiers: mask, virtualKey: Int(code)) ?? name
        }

        /// The key pressed: its key code and whether each modifier is held.
        public func matches(code: UInt16, command: Bool, option: Bool, control: Bool, shift: Bool) -> Bool {
            self.code == code && self.command == command && self.option == option && self.control == control && self.shift == shift
        }
    }
}
