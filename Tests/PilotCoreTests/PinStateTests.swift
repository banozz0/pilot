import CoreGraphics
import Testing
@testable import PilotCore

/// A pinned capture's zoom and opacity (spec `capture.html` CP9): scroll zooms 10 % a line within 10 to 400 %, O steps
/// 100, 75, 50 %, and 0 is actual size again.
@Suite("Pin state")
struct PinStateTests {
    @Test("Scrolling zooms from the capture's own size, never past 10 or 400 %")
    func zoom() {
        var pin = PinState(size: CGSize(width: 400, height: 200))
        #expect(pin.frame == CGSize(width: 400, height: 200))
        pin.scrolled(1)
        #expect(abs(pin.zoom - 1.1) < 0.001 && pin.frame == CGSize(width: 440, height: 220))
        for _ in 0..<100 { pin.scrolled(1) }
        #expect(pin.zoom == 4)
        for _ in 0..<100 { pin.scrolled(-1) }
        #expect(pin.zoom == 0.1 && pin.frame == CGSize(width: 40, height: 40), "never under 40 points a side")
        pin.actualSize()
        #expect(pin.zoom == 1)
    }

    @Test("O steps the opacity 100, 75, 50 % and round again; a set opacity it does not offer is 100 %")
    func opacity() {
        var pin = PinState(size: CGSize(width: 10, height: 10))
        pin.nextOpacity(); #expect(pin.opacity == 0.75)
        pin.nextOpacity(); #expect(pin.opacity == 0.5)
        pin.nextOpacity(); #expect(pin.opacity == 1)
        pin.setOpacity(0.3); #expect(pin.opacity == 1)
    }
}
