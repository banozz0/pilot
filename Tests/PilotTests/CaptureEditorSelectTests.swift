#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The editor's Select tool through its real view (Sven, build 54: "the Select tool can't select existing drawings"):
/// each kind of mark is drawn with mouse events on the canvas, then picked with Select, dragged, and deleted. The
/// window sits far off every screen, as the renders' do, and is never shown on Sven's.
extension SharedLook {
@MainActor
@Suite("Capture editor select")
struct CaptureEditorSelectTests {
    static let capture = CaptureGrabTests.image(1000, 900)

    /// The editor at 1:1 in a borderless window off screen, its canvas's top left at `origin` in the window.
    @MainActor final class Rig {
        let model: EditorModel
        let window: NSWindow
        let size: CGSize
        let canvas: CGPoint

        init(panel: Bool = false) {
            let look = Look.shared
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            model = EditorModel(image: CaptureEditorSelectTests.capture, scale: 2, accent: 0x3CD2DB, dark: true)
            size = EditorLayout.window(model.size, fit: 1, tokens: tokens)
            let host = NSHostingView(rootView: CaptureEditorView(model: model).style(tokens).frame(width: size.width, height: size.height))
            host.frame = CGRect(origin: .zero, size: size)
            // The editor's own panel, as CaptureEditor.show makes it, or a plain window.
            window = panel ? EditorPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                : NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            (window as? EditorPanel)?.model = model
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            // The canvas sits centred in the room under the bar, inside the margin.
            let room = CGSize(width: size.width, height: size.height - EditorLayout.bar(tokens) - EditorLayout.foot(tokens) - 2)
            canvas = CGPoint(x: (room.width - model.size.width) / 2, y: EditorLayout.bar(tokens) + 1 + (room.height - model.size.height) / 2)
            settle()
        }

        func settle(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        /// A point on the capture as the window's (bottom-left origin).
        func window(_ p: CGPoint) -> CGPoint { CGPoint(x: canvas.x + p.x, y: size.height - (canvas.y + p.y)) }

        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: window(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            settle(0.02)
        }

        /// A press at `a`, a drag through to `b`, a release there; a click when they are the same.
        func drag(_ a: CGPoint, _ b: CGPoint) {
            send(.leftMouseDown, a)
            if a != b {
                for t in [0.25, 0.5, 0.75, 1.0] { send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
            }
            send(.leftMouseUp, b)
        }

        func close() { window.close() }
    }

    /// Every kind of mark the tools make, drawn as Sven draws it, with a point on it to pick it by.
    static let kinds: [(MarkTool, from: CGPoint, to: CGPoint, on: CGPoint)] = [
        (.arrow, CGPoint(x: 40, y: 40), CGPoint(x: 200, y: 120), CGPoint(x: 120, y: 80)),
        (.rect, CGPoint(x: 220, y: 40), CGPoint(x: 320, y: 120), CGPoint(x: 220, y: 80)),
        (.ellipse, CGPoint(x: 40, y: 150), CGPoint(x: 140, y: 230), CGPoint(x: 90, y: 150)),
        (.pen, CGPoint(x: 160, y: 150), CGPoint(x: 260, y: 220), CGPoint(x: 210, y: 185)),
        (.highlighter, CGPoint(x: 280, y: 160), CGPoint(x: 380, y: 160), CGPoint(x: 330, y: 160)),
        (.blur, CGPoint(x: 40, y: 260), CGPoint(x: 140, y: 320), CGPoint(x: 90, y: 290)),
        (.box, CGPoint(x: 160, y: 260), CGPoint(x: 260, y: 320), CGPoint(x: 210, y: 290)),
        (.spotlight, CGPoint(x: 280, y: 260), CGPoint(x: 380, y: 320), CGPoint(x: 330, y: 290)),
        (.ruler, CGPoint(x: 40, y: 360), CGPoint(x: 200, y: 360), CGPoint(x: 120, y: 360)),
        (.step, CGPoint(x: 260, y: 370), CGPoint(x: 260, y: 370), CGPoint(x: 260, y: 370)),
    ]

    @Test("With two editors open, one click on the editor that is not key selects its mark (build 54)", .pilotFocus)
    func clickIntoSecondEditor() throws {
        testApp()
        let first = Rig(panel: true), second = Rig(panel: true)
        defer { first.close(); second.close() }
        first.model.pick(.rect)
        first.drag(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 120))
        first.model.pick(.select)
        first.model.deselect()
        second.window.makeKey()
        first.settle()
        #expect(!first.window.isKeyWindow)
        first.drag(CGPoint(x: 90, y: 80), CGPoint(x: 90, y: 80))
        #expect(first.model.selected == first.model.document.marks.first?.id, "the first click reached the canvas")
    }

    @Test("Overlapping marks: a click picks the one drawn under the pointer, not a later one whose box only surrounds it (build 54)")
    func overlapping() throws {
        testApp()
        let rig = Rig()
        defer { rig.close() }
        let m = rig.model
        // An arrow, then a box drawn round it (outline only), then a step in the box's corner, then an arrow across.
        m.pick(.arrow); rig.drag(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 160))
        m.pick(.rect); rig.drag(CGPoint(x: 60, y: 60), CGPoint(x: 260, y: 220))
        m.pick(.text); rig.drag(CGPoint(x: 120, y: 200), CGPoint(x: 120, y: 200)); m.typed = "Here"; _ = m.key(.enter)
        m.pick(.arrow); rig.drag(CGPoint(x: 20, y: 300), CGPoint(x: 360, y: 40))
        let ids = m.document.marks.map(\.id)
        m.pick(.select)
        rig.drag(CGPoint(x: 150, y: 130), CGPoint(x: 150, y: 130))
        #expect(m.selected == ids[0], "the arrow inside the box, under the box and the long arrow's rectangles")
        rig.drag(CGPoint(x: 60, y: 140), CGPoint(x: 60, y: 140))
        #expect(m.selected == ids[1], "the box, on its edge")
        rig.drag(CGPoint(x: 130, y: 190), CGPoint(x: 130, y: 190))
        #expect(m.selected == ids[2], "the text, inside the box")
        rig.drag(CGPoint(x: 230, y: 130), CGPoint(x: 230, y: 130))
        #expect(m.selected == nil, "empty room inside an outline box is nothing")
    }

    @Test("A drag over empty canvas picks every mark it touches; the group moves, recolours and deletes as one; Shift adds")
    func marquee() throws {
        testApp()
        let rig = Rig()
        defer { rig.close() }
        let m = rig.model
        m.pick(.rect)
        for x in [40.0, 160, 400] { rig.drag(CGPoint(x: x, y: 40), CGPoint(x: x + 80, y: 100)) }
        let ids = m.document.marks.map(\.id)
        #expect(ids.count == 3)
        m.pick(.select)
        rig.drag(CGPoint(x: 20, y: 20), CGPoint(x: 300, y: 130))
        #expect(m.picked == [ids[0], ids[1]], "the two boxes in the drag, not the one past it")
        #expect(m.marquee == nil, "the rectangle goes on release")
        let before = m.document.marks.map(\.bounds)
        rig.drag(CGPoint(x: 40, y: 70), CGPoint(x: 60, y: 80))
        let after = m.document.marks.map(\.bounds)
        #expect(after[0] == before[0].offsetBy(dx: 20, dy: 10) && after[1] == before[1].offsetBy(dx: 20, dy: 10) && after[2] == before[2],
                "a drag on one picked mark moved the group")
        m.undo()
        #expect(m.document.marks.map(\.bounds) == before, "one undo step")
        m.begin(CGPoint(x: 20, y: 20))
        m.drag(CGPoint(x: 300, y: 130))
        m.end(CGPoint(x: 300, y: 130))
        m.setColour(3)
        #expect(m.document.marks.map(\.colour) == [m.palette[3], m.palette[3], m.palette[1]], "the group recoloured, the third not")
        // Shift adds: a marquee round the third keeps the two.
        m.begin(CGPoint(x: 380, y: 20), shift: true)
        m.drag(CGPoint(x: 500, y: 130))
        m.end(CGPoint(x: 500, y: 130))
        #expect(Set(m.picked) == Set(ids))
        // Shift-click takes one out again.
        m.begin(CGPoint(x: 160, y: 70), shift: true)
        m.end(CGPoint(x: 160, y: 70))
        #expect(Set(m.picked) == [ids[0], ids[2]])
        #expect(m.key(.delete))
        #expect(m.document.marks.map(\.id) == [ids[1]] && m.picked.isEmpty)
        m.undo()
        #expect(m.document.marks.count == 3, "the group's delete is one undo step")
        rig.drag(CGPoint(x: 600, y: 600), CGPoint(x: 600, y: 600))
        #expect(m.picked.isEmpty, "a click on empty canvas picks nothing")
    }

    @Test("A marquee picks a mark as soon as it touches its drawing (build 62), never an arrow's empty corner")
    func touches() {
        let m = EditorModel(image: Self.capture, scale: 2, accent: 0x3CD2DB, dark: true)
        for (tool, a, b) in [(MarkTool.arrow, CGPoint(x: 40, y: 40), CGPoint(x: 240, y: 240)), (.rect, CGPoint(x: 300, y: 40), CGPoint(x: 400, y: 140)),
                             (.ellipse, CGPoint(x: 40, y: 300), CGPoint(x: 140, y: 400)), (.pen, CGPoint(x: 300, y: 300), CGPoint(x: 400, y: 380))] {
            m.pick(tool); m.begin(a); m.drag(CGPoint(x: (a.x + b.x) / 2, y: a.y + 10)); m.end(b)
        }
        let ids = m.document.marks.map(\.id)
        #expect(ids.count == 4)
        m.pick(.select)
        func marquee(_ a: CGPoint, _ b: CGPoint) -> [Int] { m.begin(a); m.drag(b); m.end(b); return m.picked }
        #expect(marquee(CGPoint(x: 130, y: 130), CGPoint(x: 150, y: 150)) == [ids[0]], "a small box over the arrow's middle")
        #expect(marquee(CGPoint(x: 180, y: 50), CGPoint(x: 230, y: 90)).isEmpty, "the arrow's empty corner is nothing")
        #expect(marquee(CGPoint(x: 380, y: 120), CGPoint(x: 460, y: 200)) == [ids[1]], "over the box's corner only")
        #expect(marquee(CGPoint(x: 320, y: 60), CGPoint(x: 380, y: 120)).isEmpty, "inside an outline box, touching no edge")
        #expect(marquee(CGPoint(x: 130, y: 340), CGPoint(x: 200, y: 360)) == [ids[2]], "over the ellipse's right edge")
        #expect(marquee(CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 600)) == ids, "everything in a big one")
    }

    @Test("⌘A selects every mark, whichever tool is picked")
    func selectAll() {
        let m = EditorModel(image: Self.capture, scale: 2, accent: 0x3CD2DB, dark: true)
        m.pick(.rect)
        for x in [40.0, 200, 360] { m.begin(CGPoint(x: x, y: 40)); m.end(CGPoint(x: x + 100, y: 120)) }
        m.pick(.pen)
        #expect(m.key(.char("a", command: true)))
        #expect(m.tool == .select && m.picked == m.document.marks.map(\.id) && m.picked.count == 3)
        #expect(m.key(.delete) && m.document.marks.isEmpty)
    }

    @Test("Select picks, moves and deletes every kind of mark through the canvas, text too")
    func selectEveryKind() throws {
        testApp()
        let rig = Rig()
        defer { rig.close() }
        let m = rig.model
        for kind in Self.kinds {
            m.pick(kind.0)
            rig.drag(kind.from, kind.to)
        }
        // Text: a click places it, words are typed, Return keeps it.
        m.pick(.text)
        rig.drag(CGPoint(x: 300, y: 420), CGPoint(x: 300, y: 420))
        m.typed = "Look here"
        _ = m.key(.enter)
        #expect(m.document.marks.count == Self.kinds.count + 1, "every mark was drawn: \(m.document.marks.map(\.kind))")
        let spots = Self.kinds.map(\.on) + [CGPoint(x: 310, y: 415)]
        m.pick(.select)
        for (i, spot) in spots.enumerated() {
            let id = m.document.marks[i].id, before = m.document.marks[i].bounds
            rig.drag(spot, spot)
            #expect(m.selected == id, "a click on mark \(i) (\(m.document.marks[i].kind)) selects it")
            rig.drag(spot, CGPoint(x: spot.x + 10, y: spot.y + 6))
            let after = m.document.marks.first { $0.id == id }?.bounds ?? .null
            #expect(abs(after.minX - before.minX - 10) < 0.5 && abs(after.minY - before.minY - 6) < 0.5, "mark \(i) moved by the drag")
        }
        for spot in spots.reversed() {
            let moved = CGPoint(x: spot.x + 10, y: spot.y + 6)
            rig.drag(moved, moved)
            _ = m.key(.delete)
        }
        #expect(m.document.marks.isEmpty, "Delete removed each selected mark: \(m.document.marks.map(\.kind))")
    }
}
}
#endif
