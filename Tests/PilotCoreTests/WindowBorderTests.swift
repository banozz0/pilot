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

    /// Live bug 2026-11-16 (Photo Booth off its tile) and tester bug 9 (2026-11-19: a window left on another Space).
    @Test("As drawn: the server's frame wins, else the app's front drawn window; with neither, not drawn and not ringed")
    func asDrawn() {
        let read = WindowBorder.Window(frame: CGRect(x: 0, y: 30, width: 960, height: 1050), subrole: "AXStandardWindow",
                                       fullScreen: false, minimised: false, windowID: 7)
        let drawn = CGRect(x: 100, y: 200, width: 600, height: 400), front = (id: CGWindowID(9), frame: CGRect(x: 960, y: 30, width: 960, height: 1050))
        #expect(WindowBorder.asDrawn(read, drawn: drawn, front: front).frame == drawn)
        let viaFront = WindowBorder.asDrawn(read, drawn: nil, front: front)
        #expect(viaFront.frame == front.frame && viaFront.windowID == 9 && viaFront.drawn)
        let undrawn = WindowBorder.asDrawn(read, drawn: nil, front: nil)
        #expect(!undrawn.drawn && undrawn.frame == read.frame)
        #expect(frame(undrawn) == nil && frame(read) != nil)
        var numberless = read
        numberless.windowID = nil
        #expect(WindowBorder.asDrawn(numberless, drawn: nil, front: nil) == numberless)
    }

    /// Focus follows mouse (Sven, 2026-11-20): the border goes to the window the pointer rests on, which takes focus;
    /// FocusFollowsMouse decides which, from synthetic frames on the primary screen, front to back.
    @Test("Focus follows mouse focuses the front normal window the pointer rests on, and nothing while held, over a bar or a sliver")
    func focusFollowsMouse() {
        typealias F = FocusFollowsMouse
        let screen = Self.primary
        let cursor = F.Listed(id: 10, layer: 1000, frame: screen, own: true, lookThrough: true)       // Pilot's cursor overlay
        let agent = F.Listed(id: 11, layer: 0, frame: screen, lookThrough: true)                      // an agent's whole-screen cursor
        let menuBar = F.Listed(id: 20, layer: 24, frame: CGRect(x: 0, y: 0, width: 1920, height: 24))
        let topBar = F.Listed(id: 21, layer: 25, frame: CGRect(x: 0, y: 0, width: 1920, height: 36), own: true)
        let dock = F.Listed(id: 22, layer: 20, frame: CGRect(x: 600, y: 1010, width: 720, height: 70))
        let floating = F.Listed(id: 3, layer: 0, frame: CGRect(x: 200, y: 200, width: 600, height: 400))
        let border = F.Listed(id: 9, layer: 0, frame: CGRect(x: -2, y: 34, width: 964, height: 1048), own: true, lookThrough: true)
        let left = F.Listed(id: 1, layer: 0, frame: CGRect(x: 0, y: 36, width: 960, height: 1044))
        let right = F.Listed(id: 2, layer: 0, frame: CGRect(x: 960, y: 36, width: 960, height: 1044))
        let sliver = F.Listed(id: 4, layer: 0, frame: CGRect(x: 1915, y: 36, width: 960, height: 1044))
        let panel = F.Listed(id: 5, layer: 0, frame: CGRect(x: 1200, y: 300, width: 400, height: 300), own: true)
        let menu = F.Listed(id: 12, layer: 101, frame: CGRect(x: 100, y: 24, width: 240, height: 300))
        let world = [cursor, agent, menuBar, topBar, dock, floating, border, left, right]
        func decide(_ name: String, _ x: CGFloat, _ y: CGFloat, _ windows: [F.Listed] = world, focused: Int? = 1,
                    holds: F.Holds = .init(), rested: Double = 0.2) -> F.Decision {
            let d = F.decide(point: CGPoint(x: x, y: y), windows: windows, screens: [screen], focused: focused, holds: holds, moved: 0, now: rested)
            print("focus follows mouse: \(name) -> \(d)")
            return d
        }
        #expect(decide("rests on the right tile, the left focused", 1400, 500) == .focus(2))
        #expect(decide("still moving, 50 ms", 1400, 500, rested: 0.05) == .wait(F.settle - 0.05))
        #expect(decide("rests on the floating window over the left tile", 300, 300) == .focus(3))
        #expect(decide("rests on the left tile beside the floating window", 100, 800, focused: 3) == .focus(1))
        #expect(decide("a button held", 1400, 500, holds: .init(buttons: true)) == .stay(.buttons))
        #expect(decide("a menu open", 1400, 500, [menu] + world) == .stay(.menuOpen))
        let banner = F.Listed(id: 13, layer: 102, frame: CGRect(x: 1560, y: 48, width: 340, height: 90), own: true)
        #expect(decide("Pilot's banner showing in a corner", 1400, 500, [banner] + world) == .focus(2))
        #expect(decide("Hyper+Space open", 1400, 500, holds: .init(pilotPanel: true)) == .stay(.pilotPanel))
        #expect(decide("the focused window shows a sheet", 1400, 500, focused: 1, holds: .init(sheet: true)) == .stay(.sheet))
        #expect(decide("over the menu bar", 500, 10) == .stay(.notAWindow))
        #expect(decide("over the top bar", 500, 30) == .stay(.notAWindow))
        #expect(decide("over the Dock", 900, 1040) == .stay(.notAWindow))
        #expect(decide("over the desktop", 1400, 500, [cursor, menuBar, left]) == .stay(.notAWindow))
        #expect(decide("over Pilot's panel", 1300, 400, [panel] + world) == .stay(.notAWindow))
        #expect(decide("over a strip's sliver", 1917, 500, [sliver, left]) == .stay(.sliver))
        #expect(decide("rests on the focused window", 100, 800) == .stay(.focused))
    }
}
