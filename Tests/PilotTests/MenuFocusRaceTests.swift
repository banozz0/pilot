#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Moody on cef22ca4: out of Cmd+K, before SwiftUI redraws, Cmd+K's filter is still in the panel. A letter in that same
/// run-loop pass must reach the query in every layout (Line, Classic, Rail, Toybox), and when the query already holds the
/// keyboard it keeps it. The real panel, hidden (alpha 0, no mouse); keys through the panel's key monitor's own path
/// (HUD.searchKey with the menu's handle and beforeTyping), then the window, as AppKit would.
extension SharedLook {
@MainActor
@Suite("Menu focus race", .serialized, .pilotFocus)
struct MenuFocusRaceTests {
    func key(_ c: String, code: UInt16 = 8, flags: NSEvent.ModifierFlags = [], menu: PilotMenu, model: MenuModel, panel: NSPanel, pump: Bool = true) {
        PanelTestSupport.key(c, code: code, flags: flags, into: panel, handle: { code, flags, _ in menu.handle(code, flags) },
                             keepsSearch: { model.nav.actions == nil }, beforeTyping: { menu.beforeTyping() })
        if pump { PanelTestSupport.pump(0.1) }
    }

    func fields(_ view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap { fields($0) }
    }

    /// The field whose editor holds the keyboard.
    func holder(_ panel: NSPanel) -> NSTextField? {
        guard let editor = panel.firstResponder as? NSText else { return nil }
        return fields(panel.contentView).first { $0.currentEditor() === editor }
    }

    /// The menu in `layout` (`toybox` draws Toybox's), "notes" typed, Cmd+K open on its first row, "fin" in its filter.
    func steppedIn(_ layout: MenuLayoutStyle, toybox: Bool = false) throws -> (PilotMenu, MenuModel, NSPanel) {
        testApp()
        Look.shared.style = toybox ? .toybox : .instrument
        let model = MenuModel(nav: MenuNavigator(entries: try SharedLook.LineMenuRenders.built()))
        model.layout = layout
        let panel = PanelTestSupport.hide(PilotMenu.makePanel(model))
        let menu = PilotMenu()
        menu.adopt(model, in: panel)
        panel.makeKeyAndOrderFront(nil)
        PanelTestSupport.pump()
        _ = HUD.focusSearch(in: panel)
        for c in "notes" { key(String(c), menu: menu, model: model, panel: panel) }
        key("k", code: 40, flags: .command, menu: menu, model: model, panel: panel)
        PanelTestSupport.pump()
        for c in "fin" { key(String(c), menu: menu, model: model, panel: panel) }
        try #require(model.nav.actions != nil && model.nav.actionQuery == "fin", "\(layout): Cmd+K's filter did not take the keys")
        return (menu, model, panel)
    }

    func escapeThenLetter(_ layout: MenuLayoutStyle, toybox: Bool = false) throws {
        let look = Look.shared, style = look.style
        defer { look.style = style }
        let (menu, model, panel) = try steppedIn(layout, toybox: toybox)
        defer { panel.orderOut(nil) }
        // The filter holds the keyboard; Escape and "!" in one pass, before SwiftUI redraws.
        #expect(holder(panel).map(HUD.isActionsFilter) == true, "\(layout): the filter should hold the keyboard in Cmd+K")
        key("\u{1B}", code: 53, menu: menu, model: model, panel: panel, pump: false)
        key("!", code: 18, flags: .shift, menu: menu, model: model, panel: panel, pump: false)
        #expect(model.nav.actions == nil && model.nav.query == "notes!", "\(layout): the letter went to the filter")
        #expect(holder(panel).map(HUD.isActionsFilter) == false, "\(layout): the filter kept the keyboard")
        PanelTestSupport.pump()
        #expect(model.nav.query == "notes!")
    }

    @Test("Line: Escape out of Cmd+K and a letter in one pass, the filter still drawn: the letter reaches the query")
    func line() throws { try escapeThenLetter(.line) }

    @Test("Classic: the same, through the actions' popover")
    func classic() throws { try escapeThenLetter(.classic) }

    @Test("Rail: the same")
    func rail() throws { try escapeThenLetter(.rail) }

    @Test("Toybox: the same, through its own menu")
    func toybox() throws { try escapeThenLetter(.classic, toybox: true) }

    @Test("Line: the query already holding the keyboard while the filter is still drawn keeps it; the letter adds")
    func queryAlreadyHolds() throws {
        let look = Look.shared, style = look.style
        defer { look.style = style }
        let (menu, model, panel) = try steppedIn(.line)
        defer { panel.orderOut(nil) }
        // SwiftUI handed the query the keyboard early, its text selected whole, the filter still in the tree.
        let query = try #require(fields(panel.contentView).first { !HUD.isActionsFilter($0) })
        try #require(fields(panel.contentView).contains(where: HUD.isActionsFilter))
        #expect(panel.makeFirstResponder(query))
        key("\u{1B}", code: 53, menu: menu, model: model, panel: panel, pump: false)
        key("!", code: 18, flags: .shift, menu: menu, model: model, panel: panel, pump: false)
        #expect(model.nav.query == "notes!", "the keyboard moved to the stale filter or the letter replaced the query")
        #expect(holder(panel) === query)
    }
}
}
#endif
