import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The tip with an action (card agent-bo-95423211): Convert's progress tip with Cancel, its finished tip with Reveal. The
/// real tip as HUD.tip sets it up, hidden (alpha 0, no mouse) and never key, clicked through the panel as the window
/// server sends a click.
@MainActor
@Suite("Tip", .serialized)
struct TipTests {
    final class Presses { var count = 0 }

    /// The tip set up as HUD.tip does, hidden, shown but not key: a non-activating panel Sven has not clicked yet.
    func tip(_ text: String, seconds: TimeInterval = .infinity, action: HUD.TipAction?) -> NSPanel {
        testApp()
        let panel = PanelTestSupport.hide(HUD.prepareTip(text, seconds: seconds, action: action))
        panel.orderFrontRegardless()
        PanelTestSupport.pump()
        return panel
    }

    /// A point on the button (it sits against the right edge) and one on the words, in window coordinates.
    func points(_ panel: NSPanel) -> (button: CGPoint, words: CGPoint) {
        let size = panel.frame.size
        return (CGPoint(x: size.width - 24, y: size.height / 2), CGPoint(x: 30, y: size.height / 2))
    }

    @Test("The button takes the first click on the unkeyed panel: the tip closes, then its action runs once")
    func press() throws {
        defer { HUD.dismissTip() }
        let presses = Presses()
        let panel = tip("Converting 2 of 5 to JPG…", action: HUD.TipAction(title: "Cancel") { presses.count += 1 })
        #expect(!panel.isKeyWindow)
        let host = try #require((panel.contentView as? MaterialBackdrop)?.content)
        let (button, words) = points(panel)
        for (name, point) in [("button", button), ("words", words)] {
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            #expect(host.acceptsFirstMouse(for: down), "the \(name) waits for a click that makes the panel key")
        }
        PanelTestSupport.click(panel, at: button)
        #expect(presses.count == 1)
        #expect(!panel.isVisible, "the tip stayed up after its button")
    }

    @Test("A tip the action raises stays up: the old one closes before the action runs")
    func actionRaisesTip() {
        defer { HUD.dismissTip() }
        // The action's tip set up as HUD.tip would, never shown.
        let cancel = HUD.TipAction(title: "Cancel") { _ = HUD.prepareTip("Conversion cancelled", seconds: 3, action: nil) }
        let panel = tip("Converting 2 of 5 to JPG…", action: cancel)
        PanelTestSupport.click(panel, at: points(panel).button)
        #expect(!panel.isVisible)
        #expect(HUD.tipTimer != nil, "the action's own tip was closed with the old one")
    }

    @Test("A click on the words closes the tip without running its action")
    func clickElsewhere() {
        defer { HUD.dismissTip() }
        let presses = Presses()
        let panel = tip("3 files converted to JPG", seconds: 8, action: HUD.TipAction(title: "Reveal") { presses.count += 1 })
        PanelTestSupport.click(panel, at: points(panel).words)
        #expect(presses.count == 0)
        #expect(!panel.isVisible)
        #expect(HUD.tipTimer == nil, "the closed tip's fade is still scheduled")
    }

    @Test("updateTip changes its tip's words in the same panel, refitted about the centre it opened on with its fade untouched; once another tip replaced it, it does nothing")
    func update() throws {
        defer { HUD.dismissTip() }
        let panel = tip("Converting 2 of 5 to JPG…", action: HUD.TipAction(title: "Cancel") {})
        let shown = try #require(HUD.tipModel)
        let opened = panel.frame
        HUD.updateTip("Converting 3 of 5 to JPG…", on: shown)
        PanelTestSupport.pump(0.1)
        // Tabular digits: the next file's count is the same width.
        #expect(panel.frame == opened, "one digit for another moved the tip: \(opened) → \(panel.frame)")
        // Wider, narrower, wider again: each the words' own size, centred where the tip opened (a window's frame is in
        // whole points, so within half of one), never walking off it.
        var widths: [CGFloat] = []
        for text in ["Converting 10 of 12 to WebP…", "Converting 11 of 12 to JPG…", "Converting 12 of 12 to WebP…"] {
            HUD.updateTip(text, on: shown)
            PanelTestSupport.pump(0.1)
            let f = panel.frame
            widths.append(f.width)
            #expect(abs(f.midX - opened.midX) <= 0.5 && abs(f.midY - opened.midY) <= 0.5, "\(text): the centre moved, \(opened) → \(f)")
        }
        #expect(widths[0] > opened.width && widths[1] < widths[0] && widths[2] == widths[0], "widths \(opened.width) then \(widths)")
        #expect(panel.isVisible && panel.alphaValue == 0, "the tip faded in again or closed")
        let last = panel.frame
        HUD.dismissTip()
        HUD.updateTip("Converting 4 of 5 to JPG…", on: shown)
        PanelTestSupport.pump(0.1)
        #expect(panel.frame == last && !panel.isVisible)
        let other = HUD.prepareTip("Workspace 2 saved", seconds: 3, action: nil)
        _ = PanelTestSupport.hide(other)
        HUD.updateTip("Converting 5 of 5 to JPG…", on: shown)
        #expect(HUD.tipModel?.text == "Workspace 2 saved", "another tip's words were overwritten")
    }

    @Test("A lasting tip schedules no timer; a timed one fades on its own")
    func timers() throws {
        defer { HUD.dismissTip() }
        _ = HUD.prepareTip("Converting 2 of 5 to JPG…", seconds: .infinity, action: nil)
        #expect(HUD.tipTimer == nil)
        _ = HUD.prepareTip("Workspace 2 saved: 3 windows", seconds: 3, action: nil)
        let fire = try #require(HUD.tipTimer?.fireDate.timeIntervalSinceNow)
        #expect(fire > 2.5 && fire <= 3)
        HUD.dismissTip()
        #expect(HUD.tipTimer == nil)
    }

    @Test("The tip has no shadow in any style, neither the window server's nor drawn margins, as the menu (Sven 2026-10-09)",
          arguments: PilotStyle.allCases)
    func noShadow(_ style: PilotStyle) throws {
        testApp()
        let saved = Look.shared.style
        defer { HUD.dismissTip(); Look.shared.style = saved }
        Look.shared.style = style
        let panel = try #require(PanelTestSupport.hide(HUD.prepareTip("Fixed · original in clipboard", seconds: .infinity, action: nil)) as? KeyPanel)
        #expect(!panel.hasShadow && NSEdgeInsetsEqual(panel.margins, NSEdgeInsetsZero), "\(style): the tip has a shadow")
    }
}
}
