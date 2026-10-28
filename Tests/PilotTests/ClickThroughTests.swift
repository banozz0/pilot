import AppKit
import Testing
@testable import Pilot

/// Pilot's click-through overlays, skipped from the window list (card agent-bo-95423302).
@MainActor
@Suite("Click-through windows")
struct ClickThroughTests {
    @Test("A click-through panel not shown yet has no window number and is skipped, not a crash")
    func notShownYet() {
        // BarHover's panel: deferred, so it has no window-server window (windowNumber -1) until it first shows.
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.ignoresMouseEvents = true
        #expect(panel.windowNumber <= 0)
        #expect(EngineObservers.clickThrough([panel]).isEmpty)
    }
}
