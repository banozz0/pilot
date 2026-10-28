import CoreGraphics
import Testing
@testable import PilotCore

/// The capture overlay's model (spec `capture.html` CP3): a drag takes an area on release, a click takes the window
/// under it, Space switches to windows, arrows move the pointer, and Escape closes from any state.
@Suite("Capture selection")
struct CaptureSelectionTests {
    static let size = CGSize(width: 1512, height: 982)
    static let windows = [CaptureSelection.Window(id: 7, frame: CGRect(x: 100, y: 100, width: 400, height: 300)),
                          CaptureSelection.Window(id: 9, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))]

    @Test("A drag takes its area, in whole points, whichever way it goes")
    func drag() {
        var s = CaptureSelection(size: Self.size)
        s.press(at: CGPoint(x: 300.4, y: 200.6))
        s.move(to: CGPoint(x: 120.2, y: 90.9))
        #expect(s.isDragging)
        #expect(s.release(at: CGPoint(x: 120.2, y: 90.9)) == .area(CGRect(x: 120, y: 90, width: 181, height: 111)))
        #expect(!s.isDragging)
    }

    @Test("A drag stops at the display's edge")
    func clamped() {
        var s = CaptureSelection(size: Self.size)
        s.press(at: CGPoint(x: 1400, y: 900))
        #expect(s.release(at: CGPoint(x: 2000, y: 1200)) == .area(CGRect(x: 1400, y: 900, width: 112, height: 82)))
    }

    @Test("A click takes the front window under it; on bare desktop it takes nothing")
    func click() {
        var s = CaptureSelection(size: Self.size, windows: Self.windows)
        s.press(at: CGPoint(x: 150, y: 150))
        #expect(s.release(at: CGPoint(x: 151, y: 152)) == .window(7))
        var bare = CaptureSelection(size: Self.size)
        bare.press(at: CGPoint(x: 150, y: 150))
        #expect(bare.release(at: CGPoint(x: 150, y: 150)) == CaptureSelection.Outcome.none)
    }

    @Test("Space switches to windows: the hovered one is ringed, a click or Return takes it, Space again goes back")
    func windowMode() {
        var s = CaptureSelection(size: Self.size, windows: Self.windows, pointer: CGPoint(x: 600, y: 600))
        #expect(s.key(.space) == CaptureSelection.Outcome.none)
        #expect(s.mode == .window)
        #expect(s.hovered?.id == 9)
        s.move(to: CGPoint(x: 120, y: 130))
        #expect(s.hovered?.id == 7)
        #expect(s.key(.enter) == .window(7))
        s.press(at: CGPoint(x: 700, y: 700))
        #expect(s.release(at: CGPoint(x: 700, y: 700)) == .window(9))
        _ = s.key(.space)
        #expect(s.mode == .area)
    }

    @Test("A turns smart on: a click or Return takes the UI element under the pointer, A again or Space turns it off")
    func smart() {
        var s = CaptureSelection(size: Self.size, windows: Self.windows, mode: .window, pointer: CGPoint(x: 150, y: 150))
        #expect(s.key(.smart) == CaptureSelection.Outcome.none)
        #expect(s.smart && s.mode == .area)
        let button = CGRect(x: 140, y: 140, width: 60, height: 24)
        s.element = button
        #expect(s.key(.enter) == .area(button))
        s.press(at: CGPoint(x: 150, y: 150))
        #expect(s.release(at: CGPoint(x: 151, y: 150)) == .area(button))
        // A drag still takes its area; the overlay snaps it.
        s.press(at: CGPoint(x: 120, y: 120))
        #expect(s.release(at: CGPoint(x: 300, y: 260)) == .area(CGRect(x: 120, y: 120, width: 180, height: 140)))
        _ = s.key(.smart)
        #expect(!s.smart && s.element == nil)
        s.press(at: CGPoint(x: 150, y: 150))
        #expect(s.release(at: CGPoint(x: 150, y: 150)) == .window(7))
        _ = s.key(.smart)
        _ = s.key(.space)
        #expect(!s.smart && s.mode == .window)
    }

    @Test("Escape closes from every state: idle, mid-drag, window mode")
    func escape() {
        var idle = CaptureSelection(size: Self.size)
        #expect(idle.key(.escape) == .close)
        var dragging = CaptureSelection(size: Self.size)
        dragging.press(at: CGPoint(x: 10, y: 10))
        dragging.move(to: CGPoint(x: 300, y: 300))
        #expect(dragging.key(.escape) == .close)
        var windows = CaptureSelection(size: Self.size, windows: Self.windows, mode: .window)
        #expect(windows.key(.escape) == .close)
    }

    @Test("Return with nothing dragged takes the whole display; Tab copies the colour under the pointer")
    func enterAndTab() {
        var s = CaptureSelection(size: Self.size, pointer: CGPoint(x: 40, y: 50))
        #expect(s.key(.enter) == .area(CGRect(origin: .zero, size: Self.size)))
        #expect(s.key(.tab) == .colour(CGPoint(x: 40, y: 50)))
    }

    @Test("Arrows nudge the pointer a point, Shift ten, and a drag follows it")
    func nudge() {
        var s = CaptureSelection(size: Self.size, pointer: CGPoint(x: 100, y: 100))
        #expect(s.key(.right) == .pointer(CGPoint(x: 101, y: 100)))
        #expect(s.key(.down, shift: true) == .pointer(CGPoint(x: 101, y: 110)))
        s.press(at: s.pointer)
        _ = s.key(.right, shift: true)
        _ = s.key(.down, shift: true)
        #expect(s.area == CGRect(x: 101, y: 110, width: 10, height: 10))
        #expect(s.key(.left, shift: true) == .pointer(CGPoint(x: 101, y: 120)))
        var edge = CaptureSelection(size: Self.size, pointer: .zero)
        #expect(edge.key(.up, shift: true) == .pointer(.zero))
    }

    @Test("An area in points is whole pixels of a 2x image, never past its edge")
    func pixels() {
        let pixels = CaptureSelection.pixels(CGRect(x: 10.25, y: 5, width: 100, height: 50.5), scale: 2, within: CGSize(width: 3024, height: 1964))
        #expect(pixels == CGRect(x: 20, y: 10, width: 201, height: 101))
        #expect(CaptureSelection.pixels(CGRect(x: 1500, y: 970, width: 100, height: 100), scale: 2, within: CGSize(width: 3024, height: 1964))
            == CGRect(x: 3000, y: 1940, width: 24, height: 24))
    }

    @Test("Two displays: a window on the second is in that display's points, clipped, and a sliver is left out")
    func twoDisplays() {
        let second = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let global = [CaptureSelection.Window(id: 1, frame: CGRect(x: 1600, y: 0, width: 800, height: 600)),
                      CaptureSelection.Window(id: 2, frame: CGRect(x: 1400, y: 100, width: 300, height: 300)),
                      CaptureSelection.Window(id: 3, frame: CGRect(x: 100, y: 100, width: 300, height: 300)),
                      CaptureSelection.Window(id: 4, frame: CGRect(x: 1500, y: 100, width: 20, height: 300))]
        let local = CaptureSelection.windows(global, on: second)
        #expect(local == [CaptureSelection.Window(id: 1, frame: CGRect(x: 88, y: 200, width: 800, height: 600)),
                          CaptureSelection.Window(id: 2, frame: CGRect(x: 0, y: 300, width: 188, height: 300))])
    }
}
