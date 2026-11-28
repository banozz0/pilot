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
        /// How many times holding Hyper put the overlay up, waiting up to `wait` for it: awaited, never a nested run loop,
        /// which would leave the draw the timer queues on the main queue undone.
        func shows(enabled: Bool, wait: Double) async throws -> Int {
            let overlay = HyperOverlay(look: look)
            var ordered = 0
            overlay.order = { _ in ordered += 1 }
            overlay.rows = { _ in SharedLook.InstrumentPanelsTests.overlayRows }
            overlay.delay = { 0.05 }
            overlay.enabled = { enabled }
            overlay.layer(down: true)
            _ = try await SystemSamplerTests.wait(seconds: wait) { ordered > 0 }
            overlay.layer(down: false)
            #expect(overlay.panel?.isVisible != true)
            return ordered
        }
        // Off: three times its delay with nothing shown. On, the same hold shows it once; a long deadline, as the full
        // suite held the main actor past 10 s.
        let off = try await shows(enabled: false, wait: 0.15), on = try await shows(enabled: true, wait: 120)
        #expect(off == 0, "switched off, it showed \(off) times")
        #expect(on == 1, "switched on, it showed \(on) times")
    }
}
