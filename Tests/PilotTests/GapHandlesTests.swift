import AppKit
import PilotTiler
import Testing
@testable import Pilot

/// Card agent-bo-95423035: a handle over each inner gap the own tiler hands over shows the resize cursor while the mouse
/// is over it or holds it, and passes the press, drags and release on; a fake surface, cursor and tiler.
@MainActor
@Suite("Gap handles")
struct GapHandlesTests {
    final class FakeSurface: GapHandleSurface {
        var placed: [TilerGap] = []
        func place(_ gaps: [TilerGap]) { placed = gaps }
    }

    final class FakeCursor: GapCursor {
        var shown: String = "arrow"
        func resize(vertical: Bool) { shown = vertical ? "left-right" : "up-down" }
        func reset() { shown = "arrow" }
    }

    final class FakeTiler {
        var calls: [String] = []
        var gapUnderMouse = true
    }

    private func handles() -> (GapHandles, FakeSurface, FakeCursor, FakeTiler) {
        let surface = FakeSurface(), cursor = FakeCursor(), tiler = FakeTiler()
        let handles = GapHandles(surface: surface, cursor: cursor, tiler: .init(
            press: { tiler.calls.append("press"); return tiler.gapUnderMouse },
            drag: { tiler.calls.append("drag") },
            release: { tiler.calls.append("release") }))
        return (handles, surface, cursor, tiler)
    }

    private let sideBySide = TilerGap(frame: NSRect(x: 955, y: 1, width: 10, height: 1079), vertical: true)
    private let stacked = TilerGap(frame: NSRect(x: 965, y: 535.5, width: 955, height: 10), vertical: false)

    @Test("Each gap the tiler hands over gets a handle; none once it hands over none")
    func places() {
        let (handles, surface, _, _) = handles()
        handles.update([sideBySide, stacked])
        #expect(surface.placed == [sideBySide, stacked])
        handles.update([])
        #expect(surface.placed.isEmpty)
    }

    @Test("Over a gap the cursor resizes along it, and goes back to the arrow when the mouse leaves")
    func hover() {
        let (handles, _, cursor, tiler) = handles()
        handles.entered(vertical: true)
        #expect(cursor.shown == "left-right")
        handles.exited()
        #expect(cursor.shown == "arrow")
        handles.entered(vertical: false)
        #expect(cursor.shown == "up-down")
        handles.exited()
        #expect(cursor.shown == "arrow" && tiler.calls.isEmpty)
    }

    @Test("A held gap keeps the cursor wherever the mouse runs, and the release outside puts the arrow back")
    func held() {
        let (handles, _, cursor, tiler) = handles()
        handles.entered(vertical: true)
        handles.pressed()
        handles.exited() // the mouse runs ahead of the split
        #expect(cursor.shown == "left-right")
        handles.dragged()
        handles.dragged()
        handles.released()
        #expect(cursor.shown == "arrow")
        #expect(tiler.calls == ["press", "drag", "drag", "release"])
    }

    @Test("A release back over a gap keeps the resize cursor")
    func releasedOver() {
        let (handles, _, cursor, _) = handles()
        handles.entered(vertical: false)
        handles.pressed()
        handles.released()
        #expect(cursor.shown == "up-down")
    }

    @Test("A press the tiler refuses (a stale handle) drags nothing and lets the cursor go")
    func refused() {
        let (handles, _, cursor, tiler) = handles()
        tiler.gapUnderMouse = false
        handles.entered(vertical: true)
        handles.pressed()
        handles.dragged()
        handles.released()
        handles.exited()
        #expect(tiler.calls == ["press"] && cursor.shown == "arrow")
    }

    @Test("The handle panel takes clicks without activating Pilot, stays when Pilot is not active, and sits under every window")
    func panel() {
        let panel = GapHandlePanels.panel()
        #expect(!panel.ignoresMouseEvents && !panel.hidesOnDeactivate && !panel.isOpaque)
        #expect(panel.styleMask.contains(.nonactivatingPanel) && !panel.isVisible)
        #expect(panel.level.rawValue < NSWindow.Level.normal.rawValue)
        #expect(panel.level.rawValue > Int(CGWindowLevelForKey(.desktopIconWindow)))
    }
}
