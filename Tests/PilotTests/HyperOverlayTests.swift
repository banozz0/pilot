import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The hold-Hyper overlay's panel (2026-10-10, idle CPU): built once and kept, never put on Sven's screen here.
@MainActor
@Suite("Hyper overlay")
struct HyperOverlayTests {
    @Test("The panel is built at the first show and kept: each page fits it as a fresh panel would; a Look change builds it afresh")
    func panelKept() async throws {
        testApp()
        let (look, _) = LookPageTests().look()
        let all = SharedLook.InstrumentPanelsTests.overlayRows, few = Array(all.prefix(2))
        let overlay = HyperOverlay(look: look)
        overlay.order = { _ in }
        overlay.rows = { $0 == .hyper ? few : all }
        func fresh(_ page: BindsPage.Sublayer) -> CGSize {
            HUD.makePanel(OverlayView(title: page.title, rows: overlay.rows(page)) {}, surface: .overlay, look: look).frame.size
        }
        overlay.draw(.hyper)
        let first = try #require(overlay.panel)
        #expect(first.frame.size == fresh(.hyper))
        overlay.draw(.shift)
        #expect(overlay.panel === first)
        #expect(first.frame.size == fresh(.shift))
        #expect(first.frame.size != fresh(.hyper))
        overlay.draw(.hyper)
        #expect(overlay.panel === first)
        #expect(first.frame.size == fresh(.hyper))
        look.themeID = look.themeID == "porcelain" ? "tokyo-night" : "porcelain"
        // The change reaches the overlay on the main actor's next turn.
        try await Task.sleep(for: .milliseconds(50))
        overlay.draw(.hyper)
        #expect(overlay.panel !== first)
        #expect(overlay.panel?.frame.size == fresh(.hyper))
    }

    @Test("Switched off, holding Hyper past its delay shows no overlay; on, it shows once: off still showed it (Sven, 2026-10-30)")
    func offShowsNothing() async throws {
        testApp()
        let (look, _) = LookPageTests().look()
        final class Shown { var times = 0 }
        /// An overlay with Hyper held down, counting the times it is put up.
        func held(enabled: Bool) -> (overlay: HyperOverlay, shown: Shown) {
            let overlay = HyperOverlay(look: look), shown = Shown()
            overlay.order = { _ in shown.times += 1 }
            overlay.rows = { _ in SharedLook.InstrumentPanelsTests.overlayRows }
            overlay.delay = { 0.05 }
            overlay.enabled = { enabled }
            overlay.layer(down: true)
            return (overlay, shown)
        }
        // The same hold, off first: a show it wrongly makes is timed and queued ahead of the on one's, so once the on one
        // shows, the off one's count is final, however long a busy suite holds the main actor (past 10 s in one run).
        // Awaited, never a nested run loop, which leaves the draws the timers queue undone.
        let off = held(enabled: false), on = held(enabled: true)
        _ = try await SystemSamplerTests.wait(seconds: 120) { on.shown.times > 0 }
        for hold in [off, on] {
            hold.overlay.layer(down: false)
            #expect(hold.overlay.panel?.isVisible != true)
        }
        #expect(off.shown.times == 0, "switched off, it showed \(off.shown.times) times")
        #expect(on.shown.times == 1, "switched on, it showed \(on.shown.times) times")
    }
}
