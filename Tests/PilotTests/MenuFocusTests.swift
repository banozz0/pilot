import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Card agent-bo-95422762: typing in the menu must reach its search field every time the menu shows. The real panel and
/// view, never drawn: alpha 0 and no mouse, so nothing shows on Sven's screen.
@MainActor
@Suite("Menu focus", .serialized, .pilotFocus)
struct MenuFocusTests {
    /// The real menu panel, hidden: alpha 0 and no mouse.
    func hiddenMenu() -> (MenuModel, NSPanel) {
        testApp()
        let model = MenuModel(nav: MenuNavigator(entries: []))
        return (model, PanelTestSupport.hide(PilotMenu.makePanel(model)))
    }

    /// Each letter goes through the panel's key monitor's own path (HUD.searchKey), as Pilot runs it: SwiftUI's focus from
    /// onAppear no longer reaches a hidden panel's first responder, so letters sent straight to the window dropped (OW P4),
    /// while the monitor hands the search field the keyboard before a letter passes on. While the screen is locked the
    /// login window holds the keyboard and no panel of ours becomes key: skipped then.
    @Test("The menu's panel takes the keyboard without activating Pilot, as the clipboard panel does, so it is key at once",
          .disabled(if: ScreenEvents.isLocked(), "the screen is locked (CGSSessionScreenIsLocked): no panel can take the keyboard"))
    func nonActivating() {
        let (model, panel) = hiddenMenu()
        defer { panel.orderOut(nil) }
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        panel.makeKeyAndOrderFront(nil)
        PanelTestSupport.pump()
        #expect(panel.isKeyWindow)
        for c in "calc" { PanelTestSupport.key(String(c), into: panel) }
        PanelTestSupport.pump(0.1)
        #expect(model.nav.query == "calc")
    }

    @Test("A panel whose search field lost the keyboard drops letters; focusSearch hands it back, caret at the end")
    func lostFocus() {
        let (model, panel) = hiddenMenu()
        defer { panel.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        PanelTestSupport.pump()
        // Lane 1's live state: the panel is the window, its first responder is not the search field.
        panel.makeFirstResponder(nil)
        PanelTestSupport.type("x", into: panel)
        #expect(model.nav.query == "")
        #expect(HUD.focusSearch(in: panel) == .given)
        #expect(HUD.focusSearch(in: panel) == .had)
        PanelTestSupport.type("calc", into: panel)
        #expect(model.nav.query == "calc")
        // Focus lost again mid-search: handed back with the caret at the end, the next letter adds to the search.
        panel.makeFirstResponder(nil)
        #expect(HUD.focusSearch(in: panel) == .given)
        PanelTestSupport.type("s", into: panel)
        #expect(model.nav.query == "calcs")
        #expect(HUD.focusSearch(in: NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)) == .noField)
    }
}
