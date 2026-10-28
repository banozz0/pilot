import Testing
import Foundation
import CoreGraphics
@testable import PilotCore

@Suite("Window geometry")
struct WindowGeometryTests {
    let visible = CGRect(x: 0, y: 25, width: 1920, height: 1055)   // 1080p with a menu bar, AX coordinates

    @Test("Placements are fractions of the visible frame")
    func placements() {
        #expect(Placement.leftHalf.frame(in: visible) == CGRect(x: 0, y: 25, width: 960, height: 1055))
        #expect(Placement.rightHalf.frame(in: visible) == CGRect(x: 960, y: 25, width: 960, height: 1055))
        #expect(Placement.lastQuarter.frame(in: visible) == CGRect(x: 1440, y: 25, width: 480, height: 1055))
        #expect(Placement.maximise.frame(in: visible) == visible)
        let centre = Placement.centre.frame(in: visible)
        #expect(centre.midX == visible.midX && abs(centre.midY - visible.midY) < 1)
    }

    @Test("A frame's placement survives the trip to another screen")
    func moveKeepsFraction() {
        let other = CGRect(x: 1920, y: 25, width: 1920, height: 1055)
        let left = Placement.leftHalf.frame(in: visible)
        #expect(WindowGeometry.moved(left, from: visible, to: other) == Placement.leftHalf.frame(in: other))
        let odd = CGRect(x: 100, y: 200, width: 500, height: 400)
        let back = WindowGeometry.moved(WindowGeometry.moved(odd, from: visible, to: other), from: other, to: visible)
        #expect(back == odd)
    }

    @Test("AppKit and AX frames flip about the primary display's height")
    func flip() {
        let appKit = CGRect(x: 0, y: 0, width: 960, height: 1055)     // bottom-left half in AppKit
        let ax = WindowGeometry.flip(appKit, primaryHeight: 1080)
        #expect(ax == CGRect(x: 0, y: 25, width: 960, height: 1055))
        #expect(WindowGeometry.flip(ax, primaryHeight: 1080) == appKit)
    }

    @Test("Nearest window picks by centre, in the direction only, preferring straight ahead")
    func nearest() {
        let focused = CGRect(x: 960, y: 25, width: 960, height: 1055)
        let windows: [(id: String, frame: CGRect)] = [
            ("left", CGRect(x: 0, y: 25, width: 960, height: 1055)),
            ("leftFar", CGRect(x: -1920, y: 25, width: 960, height: 1055)),
            ("upLeft", CGRect(x: 0, y: -1000, width: 960, height: 500)),
            ("self", focused),
            ("behind", CGRect(x: 0, y: 25, width: 1920, height: 1055)),   // full width, under the focused window
        ]
        #expect(WindowGeometry.nearest(from: focused, in: .left, among: windows) == "left")
        #expect(WindowGeometry.nearest(from: focused, in: .right, among: windows) == nil)
        #expect(WindowGeometry.nearest(from: focused, in: .up, among: windows) == "upLeft")
        #expect(WindowGeometry.nearest(from: focused, in: .down, among: windows) == nil)
    }

    @Test("A window covered by one in front of it is hidden, not beside: focus left lands on the window you can see")
    func nearestSkipsHidden() {
        // Card agent-bo-95422737's repro, front to back as the observers list them: Ghostex's Open window ends
        // 15 pt short of the focused centre, so only the Finder window in front of it hides it.
        let documents = CGRect(x: 1720, y: 30, width: 1720, height: 1343)
        let windows: [(id: String, frame: CGRect)] = [
            ("documents", documents),
            ("downloads", CGRect(x: 0, y: 30, width: 1720, height: 1343)),
            ("open", CGRect(x: 874, y: 43, width: 1691, height: 1295)),
        ]
        #expect(WindowGeometry.nearest(from: documents, in: .left, among: windows) == "downloads")
    }

    @Test("The display beside one, by direction, wrapping around the row as the tiler's --wrap-around does")
    func screenBeside() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080), middle = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let right = CGRect(x: 3440, y: 200, width: 1920, height: 1080)
        let row = [middle, left, right]   // NSScreen order: the primary first, the rest in no spatial order
        #expect(WindowGeometry.screen(.left, from: 0, among: row) == 1)
        #expect(WindowGeometry.screen(.right, from: 0, among: row) == 2)
        #expect(WindowGeometry.screen(.left, from: 1, among: row) == 2)
        #expect(WindowGeometry.screen(.right, from: 2, among: row) == 1)
        #expect(WindowGeometry.screen(.left, from: 0, among: [middle]) == nil)
        // Stacked displays have nothing to the left or right.
        let stacked = [middle, CGRect(x: 760, y: -1080, width: 1920, height: 1080)]
        #expect(WindowGeometry.screen(.right, from: 0, among: stacked) == nil)
        #expect(WindowGeometry.screen(.up, from: 0, among: stacked) == 1)
    }

    @Test("Resize steps stay inside the screen and above the minimum")
    func resize() {
        let r = CGRect(x: 1400, y: 25, width: 500, height: 500)
        let grown = WindowGeometry.resized(r, dw: 60, dh: 0, within: visible)
        #expect(grown.width == 560 && grown.maxX == visible.maxX)
        let shrunk = WindowGeometry.resized(r, dw: -1000, dh: -1000, within: visible)
        #expect(shrunk.size == CGSize(width: 200, height: 150))
        let huge = WindowGeometry.resized(r, dw: 5000, dh: 5000, within: visible)
        #expect(huge == visible)
    }

    @Test("The screen holding a window is the one under its centre; a window off every screen has none")
    func screenHolding() {
        // Two displays side by side in AX coordinates: the built-in at the origin, a second to its right.
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -200, width: 2560, height: 1440)]
        #expect(WindowGeometry.screen(holding: CGRect(x: 2000, y: 100, width: 800, height: 600), among: screens) == 1)
        // Straddling the edge, centre on the first.
        #expect(WindowGeometry.screen(holding: CGRect(x: 1000, y: 100, width: 800, height: 600), among: screens) == 0)
        #expect(WindowGeometry.screen(holding: CGRect(x: -5000, y: 0, width: 100, height: 100), among: screens) == nil)
    }
}
