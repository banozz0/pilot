import PilotCore
import Testing

/// The bar drops' Escape and toggle rules (spec Bar drops T3, Q93): in the terminal Escape passes on and a second within
/// 400 ms also closes; Ask AI closes on one; a drop's key toggles it; a click outside hides both.
@Suite("Drop keys")
struct DropKeysTests {
    static func opened(_ drops: BarDropKind...) -> DropKeys {
        var keys = DropKeys()
        for drop in drops { keys.toggle(drop) }
        return keys
    }

    @Test("One Escape in the terminal passes on and keeps it open")
    func oneEscape() {
        var keys = Self.opened(.terminal)
        #expect(keys.escape(at: 10) == .init(passes: true, closes: nil))
        #expect(keys.open == [.terminal])
    }

    @Test("A second Escape within 400 ms passes on and closes the terminal")
    func doubleEscape() {
        var keys = Self.opened(.terminal)
        _ = keys.escape(at: 10)
        #expect(keys.escape(at: 10.35) == .init(passes: true, closes: .terminal))
        #expect(keys.open.isEmpty)
        #expect(keys.focused == nil)
    }

    @Test("Escapes further apart than 400 ms never close; each starts a new pair")
    func slowEscapes() {
        var keys = Self.opened(.terminal)
        for time in [10, 10.5, 11, 11.5] {
            #expect(keys.escape(at: time) == .init(passes: true, closes: nil))
        }
        #expect(keys.escape(at: 11.8) == .init(passes: true, closes: .terminal))
    }

    @Test("A key typed between two Escapes is no double")
    func keyBetween() {
        var keys = Self.opened(.terminal)
        _ = keys.escape(at: 10)
        keys.typed()
        #expect(keys.escape(at: 10.1).closes == nil)
        #expect(keys.open == [.terminal])
    }

    @Test("An Escape before a hide never pairs with one after the next open")
    func hideResets() {
        var keys = Self.opened(.terminal)
        _ = keys.escape(at: 10)
        keys.toggle(.terminal)
        keys.toggle(.terminal)
        #expect(keys.escape(at: 10.2).closes == nil)
        #expect(keys.open == [.terminal])
    }

    @Test("Ask AI closes on one Escape, which it keeps")
    func askAIEscape() {
        var keys = Self.opened(.askAI)
        #expect(keys.escape(at: 10) == .init(passes: false, closes: .askAI))
        #expect(keys.open.isEmpty)
    }

    @Test("With both open, Escape acts on the focused drop; Ask AI's close hands the keyboard back")
    func bothOpenEscape() {
        var keys = Self.opened(.terminal, .askAI)
        #expect(keys.focused == .askAI)
        #expect(keys.escape(at: 10) == .init(passes: false, closes: .askAI))
        #expect(keys.open == [.terminal])
        #expect(keys.focused == .terminal)
        #expect(keys.escape(at: 10.1).closes == nil)
    }

    @Test("The key toggles its drop; the other's key opens it beside and gives it the keyboard")
    func toggle() {
        var keys = DropKeys()
        keys.toggle(.terminal)
        #expect(keys.open == [.terminal])
        #expect(keys.focused == .terminal)
        keys.toggle(.askAI)
        #expect(keys.open == [.terminal, .askAI])
        #expect(keys.focused == .askAI)
        keys.toggle(.askAI)
        #expect(keys.open == [.terminal])
        #expect(keys.focused == .terminal)
        keys.toggle(.terminal)
        #expect(keys.open.isEmpty)
        #expect(keys.focused == nil)
    }

    @Test("Closing the unfocused drop leaves the keyboard where it is")
    func closeOther() {
        var keys = Self.opened(.terminal, .askAI)
        keys.toggle(.terminal)
        #expect(keys.open == [.askAI])
        #expect(keys.focused == .askAI)
    }

    @Test("A click in a drop gives it the keyboard and drops a pending Escape")
    func clickIn() {
        var keys = Self.opened(.terminal, .askAI)
        keys.click(in: .terminal)
        #expect(keys.focused == .terminal)
        _ = keys.escape(at: 10)
        keys.click(in: .askAI)
        keys.click(in: .terminal)
        #expect(keys.escape(at: 10.1).closes == nil)
    }

    @Test("A click outside hides both")
    func clickOutside() {
        var keys = Self.opened(.terminal, .askAI)
        keys.clickOutside()
        #expect(keys.open.isEmpty)
        #expect(keys.focused == nil)
    }

    @Test("An Escape with no drop open passes on")
    func nothingOpen() {
        var keys = DropKeys()
        #expect(keys.escape(at: 10) == .init(passes: true, closes: nil))
    }
}
