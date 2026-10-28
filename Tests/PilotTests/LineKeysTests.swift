#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Menu-morph T3: Line's keys in the real panel, hidden (alpha 0, no mouse). ⌘1 to ⌘9 map to the list's rows outside
/// the Files view, which keeps ⌘1 to ⌘3 for its filters; Cmd+K steps into the row, its filter takes the typing, and
/// Escape gives the query back untouched.
@MainActor
@Suite("Line keys", .serialized)
struct LineKeysTests {
    @Test("⌘1 to ⌘9 are row numbers in Line; in the Files view (numbers off) ⌘1 to ⌘3 stay its filters, ⇧ steps back")
    func keyMap() {
        for (n, code) in PilotMenu.digits.enumerated() {
            #expect(PilotMenu.key(code, .command, numbers: true) == .number(n + 1))
        }
        #expect(PilotMenu.key(18, .command) == .filter(.kind, back: false))
        #expect(PilotMenu.key(19, [.command, .shift], numbers: true) == .filter(.place, back: true))
        // A plain digit is typed: the search field's.
        #expect(PilotMenu.key(18, [], numbers: true) == nil)
    }

    /// One key through the panel's key monitor as Pilot runs it (HUD.searchKey with the menu's handle and beforeTyping),
    /// then to the window when the monitor passes it on, as AppKit would.
    func key(_ c: String, code: UInt16 = 8, flags: NSEvent.ModifierFlags = [], menu: PilotMenu, model: MenuModel, panel: NSPanel,
             pump: Bool = true) {
        PanelTestSupport.key(c, code: code, flags: flags, into: panel, handle: { code, flags, _ in menu.handle(code, flags) },
                             keepsSearch: { model.nav.actions == nil }, beforeTyping: { menu.beforeTyping() })
        if pump { PanelTestSupport.pump(0.1) }
    }

    /// The real menu panel in Line, hidden, with a PilotMenu holding it, "notes" typed and Cmd+K's actions filtered.
    func steppedIn() throws -> (PilotMenu, MenuModel, NSPanel, NSResponder?) {
        testApp()
        let model = MenuModel(nav: MenuNavigator(entries: try SharedLook.LineMenuRenders.built()))
        model.layout = .line
        let panel = PanelTestSupport.hide(PilotMenu.makePanel(model))
        let menu = PilotMenu()
        menu.adopt(model, in: panel)
        panel.makeKeyAndOrderFront(nil)
        PanelTestSupport.pump()
        _ = HUD.focusSearch(in: panel)
        for c in "notes" { key(String(c), menu: menu, model: model, panel: panel) }
        let editor = panel.firstResponder
        key("k", code: 40, flags: .command, menu: menu, model: model, panel: panel)
        PanelTestSupport.pump()
        for c in "fin" { key(String(c), menu: menu, model: model, panel: panel) }
        return (menu, model, panel, editor)
    }

    @Test("Cmd+K steps into the row: its filter takes the keys; after Escape the next letter adds to the query, never replaces it", .pilotFocus)
    func stepIntoTheRow() throws {
        testApp()
        let model = MenuModel(nav: MenuNavigator(entries: try SharedLook.LineMenuRenders.built()))
        model.layout = .line
        let panel = PanelTestSupport.hide(PilotMenu.makePanel(model))
        defer { panel.orderOut(nil) }
        let menu = PilotMenu()
        menu.adopt(model, in: panel)
        panel.makeKeyAndOrderFront(nil)
        PanelTestSupport.pump()
        _ = HUD.focusSearch(in: panel)
        for c in "notes" { key(String(c), menu: menu, model: model, panel: panel) }
        #expect(model.nav.query == "notes")
        let editor = panel.firstResponder
        key("k", code: 40, flags: .command, menu: menu, model: model, panel: panel)
        PanelTestSupport.pump()
        #expect(model.nav.actions != nil)
        for c in "fin" { key(String(c), menu: menu, model: model, panel: panel) }
        #expect(model.nav.actionQuery == "fin", "the actions' filter did not get the keys")
        #expect(model.nav.query == "notes")
        // Escape through the monitor; SwiftUI hands the field the keyboard back with "notes" selected, then a letter.
        key("\u{1B}", code: 53, menu: menu, model: model, panel: panel)
        PanelTestSupport.pump()
        #expect(model.nav.actions == nil)
        key("!", code: 18, flags: .shift, menu: menu, model: model, panel: panel)
        #expect(model.nav.query == "notes!", "the letter replaced the query")
        #expect(panel.firstResponder === editor)
    }

    @Test("After Escape out of Cmd+K, a caret the user puts mid-query stays there: the next letter goes in at it", .pilotFocus)
    func caretPutMidQuery() throws {
        let (menu, model, panel, _) = try steppedIn()
        defer { panel.orderOut(nil) }
        key("\u{1B}", code: 53, menu: menu, model: model, panel: panel)
        PanelTestSupport.pump()
        #expect(model.nav.actions == nil)
        // A click between "no" and "tes", as the pointer would put it.
        let editor = try #require(panel.firstResponder as? NSTextView)
        editor.selectedRange = NSRange(location: 2, length: 0)
        key("X", code: 7, flags: .shift, menu: menu, model: model, panel: panel)
        #expect(model.nav.query == "noXtes", "the letter jumped away from the caret")
    }

    @Test("Escape and a letter in the same run-loop pass, before SwiftUI hands the field back: the letter adds, so does the next", .pilotFocus)
    func escapeAndLetterAtOnce() throws {
        let (menu, model, panel, editor) = try steppedIn()
        defer { panel.orderOut(nil) }
        key("\u{1B}", code: 53, menu: menu, model: model, panel: panel, pump: false)
        key("!", code: 18, flags: .shift, menu: menu, model: model, panel: panel, pump: false)
        #expect(model.nav.actions == nil && model.nav.query == "notes!", "the letter went to the actions' filter or replaced the query")
        // Now SwiftUI's own focus for the field lands, late; a letter after it must still add.
        PanelTestSupport.pump()
        key("?", code: 44, flags: .shift, menu: menu, model: model, panel: panel)
        #expect(model.nav.query == "notes!?", "a late refocus selected the query and the letter replaced it")
        #expect(panel.firstResponder === editor)
    }

    @Test("At Line's empty root, where no row wears a number, ⌘1 is not a row number")
    func noNumbersAtTheRoot() throws {
        testApp()
        let model = MenuModel(nav: MenuNavigator(entries: try SharedLook.LineMenuRenders.built()))
        model.layout = .line
        let menu = PilotMenu()
        menu.adopt(model, in: PanelTestSupport.hide(PilotMenu.makePanel(model)))
        #expect(model.atRoot)
        #expect(!menu.handle(18, .command))
        #expect(model.nav.branch == nil && model.atRoot, "⌘1 opened a branch at the root")
    }
}
#endif
