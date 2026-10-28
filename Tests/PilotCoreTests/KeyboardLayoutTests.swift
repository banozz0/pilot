import Testing
@testable import PilotCore

/// The keyboard layout setting (story 111, card agent-bo-95422793): only the keyboard layouts and input methods macOS
/// already has enabled and can select are offered, the current one marked, and a pick selects that one only. A fake
/// stands in for macOS's Text Input Sources; nothing here reads or changes the real input source.
@Suite("Keyboard layout")
@MainActor
struct KeyboardLayoutTests {
    final class FakeSources: InputSourceSystem {
        var sources: [InputSource]
        var selected: [String] = []
        init(_ sources: [InputSource]) { self.sources = sources }
        func all() -> [InputSource] { sources }
        func select(_ id: String) throws { selected.append(id) }
    }

    static func source(_ id: String, _ name: String, keyboard: Bool = true, enabled: Bool = true, selectable: Bool = true,
                       current: Bool = false) -> InputSource {
        InputSource(id: id, name: name, isKeyboard: keyboard, isEnabled: enabled, isSelectable: selectable, isCurrent: current)
    }

    static let mac = [
        source("com.apple.keylayout.British-PC", "British – PC", current: true),
        source("com.apple.keylayout.Spanish-ISO", "Spanish – ISO"),
        source("com.apple.keylayout.Dvorak", "Dvorak", enabled: false),
        source("com.apple.CharacterPaletteIM", "Emoji & Symbols", keyboard: false),
        source("com.apple.inputmethod.ironwood", "Dictation", selectable: false),
        source("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "Hiragana"),
    ]

    @Test("Only enabled keyboard layouts and input methods macOS can select are listed, by name, the current one marked")
    func listed() {
        let layouts = KeyboardLayouts(system: FakeSources(Self.mac))
        #expect(layouts.choices.map(\.name) == ["British – PC", "Hiragana", "Spanish – ISO"])
        #expect(layouts.choices.filter(\.isCurrent).map(\.id) == ["com.apple.keylayout.British-PC"])
    }

    @Test("A pick selects that source once and nothing else; picking the current one or an unlisted one selects nothing")
    func pick() throws {
        let system = FakeSources(Self.mac)
        let layouts = KeyboardLayouts(system: system)
        let listed = layouts.choices
        #expect(try layouts.pick("com.apple.keylayout.Spanish-ISO", from: listed))
        #expect(system.selected == ["com.apple.keylayout.Spanish-ISO"])
        #expect(try !layouts.pick("com.apple.keylayout.British-PC", from: listed))
        try layouts.pick("com.apple.keylayout.Dvorak", from: listed)
        try layouts.pick("com.apple.CharacterPaletteIM", from: listed)
        #expect(system.selected == ["com.apple.keylayout.Spanish-ISO"])
    }
}
