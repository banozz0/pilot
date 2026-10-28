import CoreGraphics
import Testing
@testable import PilotCore

@Suite("Window rescue")
struct RescueTests {
    /// Sven's two displays in AX coordinates: the main one, and one to its right.
    let screens = [CGRect(x: 0, y: 0, width: 3440, height: 1440), CGRect(x: 3440, y: 0, width: 1920, height: 1080)]

    @Test("A window the tiler parked in a screen's corner is stranded; one on screen, or mostly on, is not")
    func stranded() {
        // The tiler hides a window by leaving one pixel of it in the bottom-right corner of its monitor.
        #expect(Rescue.isStranded(CGRect(x: 3439, y: 1439, width: 1200, height: 800), screens: screens))
        #expect(Rescue.isStranded(CGRect(x: 9000, y: 9000, width: 800, height: 600), screens: screens))
        #expect(!Rescue.isStranded(CGRect(x: 100, y: 100, width: 800, height: 600), screens: screens))
        // Straddling both displays still counts as on screen.
        #expect(!Rescue.isStranded(CGRect(x: 3000, y: 100, width: 800, height: 600), screens: screens))
        // Half off the right edge of the second display is half on screen.
        #expect(!Rescue.isStranded(CGRect(x: 4960, y: 100, width: 800, height: 600), screens: screens))
        #expect(!Rescue.isStranded(.zero, screens: screens))
    }

    @Test("Stranded windows land cascaded inside the visible frame, keeping their size where it fits")
    func placements() {
        let visible = CGRect(x: 0, y: 25, width: 3440, height: 1415)
        let landed = Rescue.placements([CGRect(x: 3439, y: 1439, width: 1200, height: 800),
                                        CGRect(x: 3439, y: 1439, width: 5000, height: 2000)], in: visible)
        #expect(landed == [CGRect(x: 40, y: 65, width: 1200, height: 800),
                           CGRect(x: 0, y: 25, width: 3440, height: 1415)])
        #expect(landed.allSatisfy { visible.contains($0) })
        // Many windows never cascade off the screen.
        let many = Rescue.placements(Array(repeating: CGRect(x: 9000, y: 9000, width: 1200, height: 800), count: 40), in: visible)
        #expect(many.allSatisfy { visible.contains($0) })
    }

}
