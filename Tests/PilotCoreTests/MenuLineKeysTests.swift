import Foundation
import Testing
@testable import PilotCore

/// Menu-morph T3: Line's ⌘1 to ⌘9 run the list's nth row, as a click on it would; pure, no GUI. PilotMenu maps the keys
/// (LineKeysTests); here the navigator's half.
@Suite("Menu Line keys")
struct MenuLineKeysTests {
    static let entries = [MenuEntry(title: "Notes", target: .app("com.apple.Notes"), home: .apps),
                          MenuEntry(title: "Notes folder", target: .action("notes.folder"), home: .system),
                          MenuEntry(title: "Quick notes", target: .action("notes.toggle"), home: .system)]

    @Test("⌘n at a root search runs the nth row, as clicking it does; past the last row nothing happens")
    func number() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "notes"
        let rows = nav.rows.filter { !$0.target.isSearchOffer }
        #expect(rows.count >= 3)
        var clicked = nav
        #expect(nav.handle(.number(2)) == clicked.click(at: 1))
        #expect(nav.selection == 1)
        var past = nav
        #expect(past.handle(.number(9)) == .handled || nav.rows.count >= 9)
    }

    @Test("While Cmd+K's actions show, ⌘n does nothing to the list")
    func numberWhileActions() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "notes"
        _ = nav.handle(.commandK)
        let actions = nav.actions
        #expect(actions != nil)
        #expect(nav.handle(.number(1)) == .handled)
        #expect(nav.actions == actions)
    }
}
