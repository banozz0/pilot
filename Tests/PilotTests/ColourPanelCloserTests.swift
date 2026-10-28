import Testing
@testable import Pilot

/// The Colors panel closes on Esc and on a click outside it; a click in the panel or on a well leaves it (Sven, 2026-10-17).
@Suite("Colour panel closer")
struct ColourPanelCloserTests {
    @Test func escCloses() {
        #expect(ColourPanelCloser.closes(.key(53)))
        #expect(!ColourPanelCloser.closes(.key(36)))
    }

    @Test func clickOutsideCloses() {
        #expect(ColourPanelCloser.closes(.click(inPanel: false, onWell: false)))
        #expect(!ColourPanelCloser.closes(.click(inPanel: true, onWell: false)))
        #expect(!ColourPanelCloser.closes(.click(inPanel: false, onWell: true)))
    }
}
