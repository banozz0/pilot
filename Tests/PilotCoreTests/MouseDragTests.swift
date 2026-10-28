import Testing
import CoreGraphics
@testable import PilotCore

@Suite("MouseDrag")
struct MouseDragTests {
    static let shift = KeyEvent.shiftMask, ctrl = KeyEvent.ctrlMask, alt = KeyEvent.altMask, cmd = KeyEvent.cmdMask, fn = KeyEvent.fnMask
    static let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
    static let window = (id: 42, frame: frame)

    @Test("Only the chosen modifier on its own starts a drag: Alt+Shift, no modifier and Off pass the click on")
    func modifierMatch() {
        let at = CGPoint(x: 300, y: 300)
        #expect(MouseDrag.begin(.left, flags: Self.alt, at: at, modifier: .alt, window: Self.window)?.kind == .move)
        #expect(MouseDrag.begin(.left, flags: Self.alt | Self.shift, at: at, modifier: .alt, window: Self.window) == nil)
        #expect(MouseDrag.begin(.left, flags: 0, at: at, modifier: .alt, window: Self.window) == nil)
        #expect(MouseDrag.begin(.left, flags: Self.alt, at: at, modifier: .off, window: Self.window) == nil)
        #expect(MouseDrag.begin(.left, flags: Self.alt, at: at, modifier: .alt, window: nil) == nil)
        #expect(MouseDrag.begin(.left, flags: Self.cmd, at: at, modifier: .cmd, window: Self.window) != nil)
        #expect(MouseDrag.begin(.left, flags: Self.cmd | Self.ctrl | Self.alt, at: at, modifier: .cmd, window: Self.window) == nil)
        #expect(MouseDrag.begin(.left, flags: Self.fn, at: at, modifier: .fn, window: Self.window) != nil)
        #expect(MouseDrag.begin(.left, flags: Self.fn | Self.alt, at: at, modifier: .fn, window: Self.window) == nil)
        // Fn rides on some keyboards' arrow and function rows; it never stops another modifier's drag.
        #expect(MouseDrag.begin(.left, flags: Self.alt | Self.fn, at: at, modifier: .alt, window: Self.window) != nil)
    }

    @Test("Hyper drags only while the layer is held alone; the drag uses the layer, so its release sends no quick-tap Escape")
    func hyper() throws {
        let at = CGPoint(x: 300, y: 300)
        var layer = HyperLayer(layerKey: .capsLock, quickTapEscape: true)
        func begin(_ button: MouseDrag.Button, flags: UInt64 = 0, modifier: DragModifier = .hyper) -> MouseDrag? {
            MouseDrag.begin(button, flags: flags, hyper: layer.isHeldAlone(flags: flags), at: at, modifier: modifier, window: Self.window)
        }
        #expect(begin(.left) == nil)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 0), isBound: { _ in true }) == .layerOn)
        #expect(begin(.left)?.kind == .move)
        #expect(begin(.right)?.kind == .resize(left: true, top: true))
        // Shift or Cmd with it is a sublayer, never a drag; the layer counts only for the Hyper choice.
        #expect(begin(.left, flags: Self.shift) == nil)
        #expect(begin(.left, flags: Self.cmd) == nil)
        #expect(begin(.left, modifier: .alt) == nil)
        layer.markUsed()
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 0.1), isBound: { _ in true }) == .layerOff(quickTap: false))
        #expect(begin(.left) == nil)

        // Right Option as the layer key carries its own Alt flag; left Option with it is the Alt sublayer.
        var option = HyperLayer(layerKey: .rightOption)
        let right = Self.alt | LayerKey.rightOption.deviceFlag!
        _ = option.handle(.init(kind: .flagsChanged, keyCode: LayerKey.rightOption.keyCode, flags: right), isBound: { _ in true })
        #expect(option.isHeldAlone(flags: right))
        #expect(!option.isHeldAlone(flags: right | KeyEvent.leftAltDeviceMask))
        // A keyboard's cmd+ctrl+alt chord is Hyper too, without Shift; and nothing is Hyper while Hyper is off.
        var chord = HyperLayer(layerKey: .capsLock)
        #expect(chord.isHeldAlone(flags: KeyEvent.chordMask))
        #expect(!chord.isHeldAlone(flags: KeyEvent.chordMask | Self.shift))
        chord.isOn = false
        #expect(!chord.isHeldAlone(flags: KeyEvent.chordMask))
    }

    @Test("A move follows the cursor exactly")
    func move() throws {
        let drag = try #require(MouseDrag.begin(.left, flags: Self.alt, at: CGPoint(x: 300, y: 300), modifier: .alt, window: Self.window))
        #expect(drag.frame(at: CGPoint(x: 350, y: 280)) == CGRect(x: 150, y: 80, width: 800, height: 600))
        #expect(drag.frame(at: CGPoint(x: 300, y: 300)) == Self.frame)
    }

    @Test("A right-drag resizes from the quadrant clicked, never below 200 by 150")
    func resize() throws {
        let bottomRight = try #require(MouseDrag.begin(.right, flags: Self.alt, at: CGPoint(x: 800, y: 600), modifier: .alt, window: Self.window))
        #expect(bottomRight.kind == .resize(left: false, top: false))
        #expect(bottomRight.frame(at: CGPoint(x: 850, y: 630)) == CGRect(x: 100, y: 100, width: 850, height: 630))
        let topLeft = try #require(MouseDrag.begin(.right, flags: Self.alt, at: CGPoint(x: 150, y: 150), modifier: .alt, window: Self.window))
        #expect(topLeft.kind == .resize(left: true, top: true))
        #expect(topLeft.frame(at: CGPoint(x: 130, y: 140)) == CGRect(x: 80, y: 90, width: 820, height: 610))
        // Dragged past the far edge: the size stops at the minimum and the fixed edge stays put.
        #expect(topLeft.frame(at: CGPoint(x: 1500, y: 1500)) == CGRect(x: 700, y: 550, width: 200, height: 150))
        #expect(bottomRight.frame(at: CGPoint(x: 0, y: 0)) == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    /// Sven on build 19 (2026-10-10): the outline followed the mouse both ways, the release changed only the width.
    @Test("A tiled window's resize moves only the edges the tiler can move, each inside its reach")
    func tiledResize() throws {
        // Alone in its column: tiles to the right only, so the right edge moves (to 1300 at most) and the height stays.
        let column = EdgeReach(right: 300...1300)
        let bottomRight = try #require(MouseDrag.begin(.right, flags: Self.alt, at: CGPoint(x: 800, y: 600), modifier: .alt, window: Self.window))
        #expect(bottomRight.frame(at: CGPoint(x: 860, y: 640), within: column) == CGRect(x: 100, y: 100, width: 860, height: 600))
        #expect(bottomRight.frame(at: CGPoint(x: 2000, y: 900), within: column) == CGRect(x: 100, y: 100, width: 1200, height: 600))
        // Its left and top edges have nothing beyond them: dragging them leaves the frame as it was.
        let topLeft = try #require(MouseDrag.begin(.right, flags: Self.alt, at: CGPoint(x: 150, y: 150), modifier: .alt, window: Self.window))
        #expect(topLeft.frame(at: CGPoint(x: 100, y: 140), within: column) == Self.window.frame)
        // A tile above it: the top edge moves, down to its own minimum height.
        let stacked = EdgeReach(top: 0...(700 - WindowGeometry.minimumSize.height))
        #expect(topLeft.frame(at: CGPoint(x: 100, y: 120), within: stacked) == CGRect(x: 100, y: 70, width: 800, height: 630))
        #expect(topLeft.frame(at: CGPoint(x: 100, y: 1500), within: stacked) == CGRect(x: 100, y: 550, width: 800, height: 150))
    }

    @Test("The left mouse-up passes on, so the tiler re-tiles; a right drag's mouse-up is swallowed")
    func mouseUp() throws {
        let left = try #require(MouseDrag.begin(.left, flags: Self.alt, at: CGPoint(x: 300, y: 300), modifier: .alt, window: Self.window))
        let right = try #require(MouseDrag.begin(.right, flags: Self.alt, at: CGPoint(x: 300, y: 300), modifier: .alt, window: Self.window))
        #expect(left.passesMouseUp)
        #expect(!right.passesMouseUp)
    }

    @Test("Alt is the default modifier, as yabai's mouse_modifier was; the setting reads back what was saved")
    func setting() {
        #expect(DragModifier.default == .alt)
        #expect(DragModifier(rawValue: DragModifier.cmd.rawValue) == .cmd)
        #expect(DragModifier.allCases.map(\.label) == ["Off", "Alt", "Ctrl", "Cmd", "Fn", "Hyper"])
    }

    @Test("A click hits the front window under it; a menu on top, Pilot's own window, a fullscreen one or no window is no hit")
    func hit() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let back = (layer: 0, alpha: 1.0, frame: CGRect(x: 0, y: 0, width: 500, height: 500), own: false)
        let front = (layer: 0, alpha: 1.0, frame: CGRect(x: 100, y: 100, width: 200, height: 200), own: false)
        let menu = (layer: 101, alpha: 1.0, frame: CGRect(x: 0, y: 0, width: 300, height: 30), own: false)
        let ghost = (layer: 0, alpha: 0.0, frame: CGRect(x: 0, y: 0, width: 500, height: 500), own: false)
        let pilot = (layer: 0, alpha: 1.0, frame: CGRect(x: 0, y: 0, width: 400, height: 400), own: true)
        let fullscreen = (layer: 0, alpha: 1.0, frame: screen, own: false)
        #expect(MouseDrag.hit(CGPoint(x: 150, y: 150), among: [front, back], screens: [screen]) == 0)
        #expect(MouseDrag.hit(CGPoint(x: 50, y: 50), among: [front, back], screens: [screen]) == 1)
        #expect(MouseDrag.hit(CGPoint(x: 50, y: 10), among: [menu, back], screens: [screen]) == nil)
        #expect(MouseDrag.hit(CGPoint(x: 50, y: 50), among: [ghost, back], screens: [screen]) == 1)
        #expect(MouseDrag.hit(CGPoint(x: 50, y: 50), among: [pilot, back], screens: [screen]) == nil)
        #expect(MouseDrag.hit(CGPoint(x: 50, y: 50), among: [fullscreen], screens: [screen]) == nil)
        #expect(MouseDrag.hit(CGPoint(x: 900, y: 900), among: [front, back], screens: [screen]) == nil)
    }

    /// No modifier drag started at all (Sven 2026-10-10, Fn and Alt alike): the Dock keeps a see-through window over the
    /// whole main screen at its level (20), in front of every app window, and the hit stopped there.
    @Test("A see-through window over a whole screen above the apps (the Dock's) is looked through; a real panel is not")
    func screenOverlay() {
        let screen = CGRect(x: 0, y: 0, width: 3440, height: 1440)
        let dock = (layer: 20, alpha: 1.0, frame: screen, own: false)
        let app = (layer: 0, alpha: 1.0, frame: CGRect(x: 1731, y: 51, width: 1688, height: 1301), own: false)
        let panel = (layer: 3, alpha: 1.0, frame: CGRect(x: 1700, y: 40, width: 600, height: 400), own: false)
        #expect(MouseDrag.hit(CGPoint(x: 2000, y: 600), among: [dock, app], screens: [screen]) == 1)
        #expect(MouseDrag.hit(CGPoint(x: 1800, y: 100), among: [dock, panel, app], screens: [screen]) == nil)
        #expect(MouseDrag.hit(CGPoint(x: 100, y: 600), among: [dock, app], screens: [screen]) == nil, "the desktop, no window")
    }

    @Test("A drag keeps its press and its drags from the app; the left mouse-up goes on, the right one does not; the rest passes")
    func passes() throws {
        let left = try #require(MouseDrag.begin(.left, flags: Self.alt, at: CGPoint(x: 300, y: 300), modifier: .alt, window: Self.window))
        var t = DragTracker()
        // passes(_:) mutates the tracker, so each answer is taken before it is checked.
        func pass(_ e: DragTracker.Event) -> Bool { t.passes(e) }
        var a = pass(.down(.left, begun: nil)); #expect(a, "a press that starts nothing reaches the app")
        a = pass(.dragged(.left)); #expect(a)
        a = pass(.up(.left)); #expect(a)
        a = pass(.down(.left, begun: left)); #expect(!a)
        a = pass(.dragged(.left)); #expect(!a)
        a = pass(.dragged(.right)); #expect(a, "the other button is not the drag's")
        a = pass(.down(.right, begun: left)); #expect(a, "no second drag while one is live")
        a = pass(.up(.left)); #expect(a && t.released)
        a = pass(.dragged(.left)); #expect(a, "nothing after the release belongs to the drag")
        a = pass(.up(.left)); #expect(a)
        t.end()
        let right = try #require(MouseDrag.begin(.right, flags: Self.alt, at: CGPoint(x: 300, y: 300), modifier: .alt, window: Self.window))
        a = pass(.down(.right, begun: right)); #expect(!a)
        a = pass(.dragged(.right)); #expect(!a)
        a = pass(.up(.right)); #expect(!a && t.released)
    }

    @Test("A session moves by position, frames a floating window's resize, and outlines a tiled one's for the tiler")
    func session() throws {
        let move = try #require(MouseDrag.begin(.left, flags: Self.alt, at: CGPoint(x: 300, y: 300), modifier: .alt, window: Self.window))
        var moving = DragSession(move)
        #expect(moving.effect(at: CGPoint(x: 310, y: 290)) == .position(CGPoint(x: 110, y: 90)))
        let resize = try #require(MouseDrag.begin(.right, flags: Self.alt, at: CGPoint(x: 800, y: 600), modifier: .alt, window: Self.window))
        var floating = DragSession(resize)
        #expect(floating.effect(at: CGPoint(x: 820, y: 600)) == .frame(CGRect(x: 100, y: 100, width: 820, height: 600)))
        var tiled = DragSession(resize)
        tiled.tile(within: EdgeReach(right: 300...1000, bottom: 250...1000))
        // Held: an outline of the new frame, nothing sent to the tiler; released: that frame, once, for the tiler.
        #expect(tiled.effect(at: CGPoint(x: 820, y: 600)) == .outline(CGRect(x: 100, y: 100, width: 820, height: 600)))
        #expect(tiled.effect(at: CGPoint(x: 860, y: 640)) == .outline(CGRect(x: 100, y: 100, width: 860, height: 640)))
        #expect(tiled.finish() == .tiled(CGRect(x: 100, y: 100, width: 860, height: 640)))
        #expect(tiled.finish() == .none, "once")
        // A floating resize and a move write as they go; the release adds nothing.
        let floatingEnd = floating.finish(), movingEnd = moving.finish()
        #expect(floatingEnd == .none && movingEnd == .none)
    }
}

/// Right-drag to resize did nothing (Sven 2026-10-10, Fn as the modifier): the drag ended at the release while the tiler
/// had not answered. The tap now reads the tiler's reach before the first point, so a release ends the drag at once.
@Suite("Mouse resize")
struct MouseResizeTests {
    static let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test("A tiled resize released where it started, or with no edge free that way, hands the tiler nothing")
    func releaseWithNothingToDo() throws {
        let resize = try #require(MouseDrag.begin(.right, flags: KeyEvent.fnMask, at: CGPoint(x: 800, y: 600), modifier: .fn,
                                                  window: (id: 42, frame: Self.frame)))
        var t = DragTracker()
        var a = t.passes(.down(.right, begun: resize)); #expect(!a)
        t.tile(within: EdgeReach(left: 0...700))
        #expect(t.effect(at: CGPoint(x: 850, y: 640)) == .outline(Self.frame), "the right and bottom edges have no tiles beyond")
        a = t.passes(.up(.right)); #expect(!a && t.released)
        #expect(t.finish() == .none)
    }
}

/// Moving and resizing lagged (Sven 2026-10-10: "so laggy, not smooth at all"): every drag event queued its own write. A
/// drag's writes now go one at a time, at most once per display frame, newest point first.
@Suite("Drag frames")
struct DragFramesTests {
    /// Runs `events` points `spacing` seconds apart through a LatestWins whose writes each take `latency`; returns the
    /// points written, in order, and the most writes ever in flight at once.
    static func simulate(events: Int, spacing: Double, latency: Double, interval: Double) -> (written: [Int], maxInFlight: Int) {
        var frames = LatestWins<CGPoint>(interval: interval)
        var timeline: [(at: Double, what: String, value: Int)] = (0..<events).map { (Double($0) * spacing, "event", $0) }
        var written: [Int] = [], inFlight = 0, maxInFlight = 0
        func handle(_ step: LatestWins<CGPoint>.Step, _ now: Double) {
            switch step {
            case .idle: break
            case .wait(let d): timeline.append((now + d, "wake", 0))
            case .write(let p): written.append(Int(p.x)); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); timeline.append((now + latency, "done", 0))
            }
        }
        while let i = timeline.indices.min(by: { timeline[$0].at < timeline[$1].at }) {
            let e = timeline.remove(at: i)
            switch e.what {
            case "event": handle(frames.offer(CGPoint(x: e.value, y: 0), now: e.at), e.at)
            case "wake": handle(frames.woke(now: e.at), e.at)
            default: inFlight -= 1; handle(frames.written(now: e.at), e.at)
            }
        }
        #expect(frames.isIdle)
        return (written, maxInFlight)
    }

    @Test("A 1000 Hz mouse for a second: at most one write per 120 Hz frame, one in flight, the last point always written")
    func screenRate() {
        let fast = Self.simulate(events: 1000, spacing: 0.001, latency: 0.002, interval: 1.0 / 120)
        #expect(fast.written.count <= 121 && fast.written.count >= 110, "\(fast.written.count) writes")
        #expect(fast.maxInFlight == 1)
        #expect(fast.written.last == 999)
        #expect(fast.written == fast.written.sorted(), "never an older point after a newer one")
        // A slow app (25 ms per AX write) gets one write per answer, never a queue: about 40 a second, still ending on the last point.
        let slow = Self.simulate(events: 1000, spacing: 0.001, latency: 0.025, interval: 1.0 / 120)
        #expect(slow.written.count <= 41 && slow.written.count >= 35, "\(slow.written.count) writes")
        #expect(slow.maxInFlight == 1 && slow.written.last == 999)
    }
}
