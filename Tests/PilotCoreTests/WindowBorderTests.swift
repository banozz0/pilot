import CoreGraphics
import Testing
@testable import PilotCore

/// Card agent-bo-95422950: where the focused window's border goes, and when it hides. AX frames (top-left origin) in,
/// the border panel's AppKit frame (bottom-left origin) out.
@Suite("Window border")
struct WindowBorderTests {
    /// A 1920x1080 primary screen and a second one stacked above it, as AX frames.
    static let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
    static let screens = [primary, above]

    func frame(_ w: WindowBorder.Window?, on: Bool = true, width: Int = 2) -> CGRect? {
        WindowBorder.frame(for: w, on: on, width: width, screens: Self.screens, primaryHeight: 1080)
    }

    func window(_ r: CGRect, subrole: String? = "AXStandardWindow", fullScreen: Bool = false, minimised: Bool = false) -> WindowBorder.Window {
        WindowBorder.Window(frame: r, subrole: subrole, fullScreen: fullScreen, minimised: minimised)
    }

    @Test("The border is the window's frame flipped to AppKit and grown by the width on every side")
    func geometry() {
        #expect(frame(window(CGRect(x: 100, y: 50, width: 800, height: 600))) == CGRect(x: 98, y: 428, width: 804, height: 604))
        #expect(frame(window(CGRect(x: 100, y: -900, width: 800, height: 600))) == CGRect(x: 98, y: 1378, width: 804, height: 604))
        #expect(frame(window(CGRect(x: 100, y: 50, width: 800, height: 600)), width: 6) == CGRect(x: 94, y: 424, width: 812, height: 612))
    }

    @Test("Hidden when off, with no window, in fullscreen, for a dialog, a sliver, or a window parked off screen")
    func hidden() {
        let plain = CGRect(x: 100, y: 50, width: 800, height: 600)
        #expect(frame(window(plain), on: false) == nil)
        #expect(frame(nil) == nil)
        #expect(frame(window(plain, fullScreen: true)) == nil)
        #expect(frame(window(Self.primary)) == nil)
        #expect(frame(window(plain, subrole: "AXDialog")) == nil)
        #expect(frame(window(plain, subrole: nil)) == nil)
        #expect(frame(window(CGRect(x: 100, y: 50, width: 30, height: 500))) == nil)
        // The tiler parks a hidden workspace's windows in a corner, most of them off every screen.
        #expect(frame(window(CGRect(x: 1920 - 300, y: 50, width: 1000, height: 600))) == nil)
    }

    @Test("Shown for a window tiled alone on a screen's visible frame, and one straddling two screens")
    func shown() {
        #expect(frame(window(CGRect(x: 0, y: 33, width: 1920, height: 1047))) != nil)
        #expect(frame(window(CGRect(x: 100, y: -300, width: 800, height: 600))) != nil)
    }

    @Test("A minimised window has no border; the same window back on screen has one (card agent-bo-95422995)")
    func minimised() {
        let plain = CGRect(x: 100, y: 50, width: 800, height: 600)
        #expect(frame(window(plain, minimised: true)) == nil)
        #expect(frame(window(plain)) != nil)
    }

    @Test("The width stays within 1 to 8 points, 2 by default")
    func width() {
        #expect(WindowBorder.defaultWidth == 2)
        #expect(WindowBorder.clamped(0) == 1)
        #expect(WindowBorder.clamped(5) == 5)
        #expect(WindowBorder.clamped(20) == 8)
    }
}
