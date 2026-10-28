import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// No Pilot pop-up wears the window server's drop shadow (Sven on build 29: the bar's edit shelf still did; the menu's
/// went in B5): every panel builder, in every style with Glass on and off. The app window keeps its own.
@MainActor
@Suite("Popup shadow")
struct PopupShadowTests {
    static let popups: [StyleSurface] = [.hud, .menu, .clipboard, .overlay, .notes, .quickAI]

    /// `body` once per style with each of `glass`, on `look`, put back after.
    static func everyLook(_ look: Look = PanelLookTests.look(), glass: [Bool] = [false, true], _ body: (Look, String) throws -> Void) rethrows {
        testApp()
        let saved = (look.style, look.glass)
        defer { (look.style, look.glass) = saved }
        for style in PilotStyle.allCases {
            for glass in glass {
                (look.style, look.glass) = (style, glass)
                try body(look, "\(style) glass \(glass)")
            }
        }
    }

    @Test("HUD.makePanel: the HUDs, the menu, the clipboard panel, the overlay, quick notes and Quick AI have no window shadow")
    func hudPanels() {
        Self.everyLook { look, name in
            for surface in Self.popups {
                let panel = HUD.makePanel(Text("Pop-up").padding(20), surface: surface, look: look)
                defer { panel.close() }
                #expect(!panel.hasShadow, "\(surface) in \(name)")
            }
            let tip = HUD.makePanel(Text("Tip"), look: look, shadow: false)
            defer { tip.close() }
            #expect(!tip.hasShadow, "the tip in \(name)")
        }
    }

    @Test("The bar's popovers and a panel on the top bar's surface with margins have no window shadow", .pilotFocus)
    func barPanels() {
        // These read Look.shared and are shown, so off every screen, once per style: Glass changes only their backdrop.
        let away = NSRect(x: -20_000, y: -20_000, width: 10, height: 10)
        Self.everyLook(.shared, glass: [false]) { look, name in
            let popover = BarPanelWindow.keyPanel(Text("Popover"), surface: .barPopovers, level: .popUpMenu) {
                NSRect(origin: away.origin, size: $0)
            }
            defer { popover.close() }
            #expect(!popover.hasShadow, "a bar popover in \(name)")
            let margined = BarPanelWindow.keyPanel(Text("Top bar panel"), surface: .topBar, margins: look.chromeMargins(.topBar),
                                                level: TopBarWindows.aboveMenuBar) { NSRect(origin: away.origin, size: $0) }
            defer { margined.close() }
            #expect(!margined.hasShadow, "a top bar panel in \(name)")
        }
    }

    @Test("The AI chat panel has no window shadow")
    func aiChat() {
        Self.everyLook { look, name in
            let panel = AIChatPanel.makePanel(NSView(), look: look)
            defer { panel.close() }
            #expect(!panel.hasShadow, "the AI chat in \(name)")
        }
    }

    @Test("The app window keeps its normal shadow")
    func appWindow() {
        testApp()
        let window = AppWindowController.makeWindow(content: NSView())
        defer { window.close() }
        #expect(window.hasShadow)
    }
}
}
