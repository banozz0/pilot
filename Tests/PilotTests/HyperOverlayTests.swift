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
        look.style = look.style == .instrument ? .toybox : .instrument
        // The change reaches the overlay on the main actor's next turn.
        try await Task.sleep(for: .milliseconds(50))
        overlay.draw(.hyper)
        #expect(overlay.panel !== first)
        #expect(overlay.panel?.frame.size == fresh(.hyper))
    }
}
