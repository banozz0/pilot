import AppKit
import ApplicationServices
import PilotCore
import Testing
@testable import Pilot

/// Sven's report 2026-10-17: the focused-window border lagged a dragged window, and a fast drag lagged the whole screen.
/// Each AX move re-read the focused window on the main thread (eight AX calls into the dragged app, on the key tap's
/// thread); FrameFollower reads the moved window's frame alone, off the main thread, at most once per display frame.
/// A fake clock and a fake reader: no real window is read, framed or drawn.
@MainActor
@Suite("Frame follower")
struct FrameFollowerTests {
    /// What a drag costs: AX calls on the main thread and off it, full reads, border redraws.
    final class Costs {
        var mainAX = 0, offMainAX = 0, fullReads = 0, frameReads = 0, shows = 0, boundsReads = 0
    }

    final class CountingSurface: WindowBorderSurface {
        var shown: CGRect?
        let costs: Costs
        init(_ costs: Costs) { self.costs = costs }
        func show(frame: CGRect, width: Int, color: UInt32, above: CGWindowID?) { shown = frame; costs.shows += 1 }
        func hide() { shown = nil }
    }

    /// A clock the test moves, and the work FrameFollower parks until a time on it.
    @MainActor final class Clock {
        var now: TimeInterval = 0
        var due: [(at: TimeInterval, work: @MainActor () -> Void)] = []
        func advance(to t: TimeInterval) {
            now = t
            while let i = due.firstIndex(where: { $0.at <= t }) { due.remove(at: i).work() }
        }
    }

    /// Stand-ins for two windows: distinct AX elements, never asked anything.
    static let dragged = AXUIElementCreateApplication(1), other = AXUIElementCreateApplication(2)
    /// AX calls in one full read of the focused window (EngineObservers.axFocusedWindow): the focused window, subrole,
    /// position, size, title, AXFullScreen, AXMinimized, _AXUIElementGetWindow. A frame read is one (FrameFollower.frame).
    static let fullReadCalls = 8

    /// The left button and the display link DragFollower would start: the test ticks it.
    @MainActor final class Mouse {
        var held = false
        var tick: (@MainActor () -> Void)?
        var links = 0
    }

    struct Rig {
        let observers: EngineObservers, clock: Clock, costs: Costs, surface: CountingSurface, mouse: Mouse
        /// Where the dragged window is now.
        let frame: () -> CGRect
        let move: (CGRect) -> Void
    }

    static func rig(frame fps: Double = 120) -> Rig {
        let clock = Clock(), costs = Costs()
        var current = CGRect(x: 100, y: 50, width: 800, height: 600)
        let follower = FrameFollower(reader: { element, done in
            costs.offMainAX += 1; costs.frameReads += 1
            done(CFEqual(element, dragged) ? current : nil)
        }, now: { clock.now }, after: { delay, work in clock.due.append((clock.now + delay, work)) }, frame: 1 / fps)
        let mouse = Mouse()
        let drag = DragFollower(reader: { id, done in costs.boundsReads += 1; done(id == 7 ? current : nil) },
                                ticker: { tick in mouse.tick = tick; mouse.links += 1; return { mouse.tick = nil } },
                                held: { mouse.held }, now: { clock.now })
        let observers = EngineObservers(follower: follower, drag: drag)
        observers.seed(focusedApp: .current)
        observers.readFocusedWindow = { _ in
            costs.mainAX += fullReadCalls; costs.fullReads += 1
            return ("Editor", WindowBorder.Window(frame: current, subrole: "AXStandardWindow", fullScreen: false, minimised: false, windowID: 7), dragged)
        }
        let surface = CountingSurface(costs)
        let border = WindowBorderController(surface: surface, look: WindowBorderControllerTests.look(),
                                            screens: { [CGRect(x: 0, y: 0, width: 3840, height: 2160)] }, primaryHeight: { 2160 })
        observers.onFocusedWindow = { border.update($0) }
        observers.refreshFocusedWindow() // focus lands on it, as kAXFocusedWindowChanged does
        return Rig(observers: observers, clock: clock, costs: costs, surface: surface, mouse: mouse, frame: { current }, move: { current = $0 })
    }

    /// A 200 ms drag sending AX a move per millisecond (a 1000 Hz mouse), the window 4 points further each time.
    /// `perMove` is what Pilot does with each move; returns the costs and the main thread's time for the whole drag.
    static func drag(_ rig: Rig, moves: Int = 200, perMove: (Rig) -> Void) -> (costs: Costs, main: Duration) {
        rig.costs.fullReads = 0; rig.costs.mainAX = 0; rig.costs.shows = 0 // the focus read before the drag
        let clock = ContinuousClock()
        let main = clock.measure {
            for i in 1...moves {
                rig.clock.advance(to: Double(i) / 1000)
                rig.move(CGRect(x: 100 + 4 * i, y: 50, width: 800, height: 600))
                perMove(rig)
            }
            rig.clock.advance(to: Double(moves) / 1000 + 1) // the drag stops: whatever is parked runs
        }
        return (rig.costs, main)
    }

    /// The border's panel frame for a window frame: AppKit coordinates, grown by the 2-point line.
    static func border(_ f: CGRect) -> CGRect { CGRect(x: f.minX - 2, y: 2160 - f.maxY - 2, width: f.width + 4, height: f.height + 4) }

    @Test("A 200-move drag: before, 200 full reads on the main thread (1600 AX calls); after, one frame read per 120 Hz frame, none on the main thread")
    func dragCost() {
        let before = Self.drag(Self.rig()) { $0.observers.refreshFocusedWindow() } // what the AX callback did with each move
        let after = Self.drag(Self.rig()) { $0.observers.windowMoved(Self.dragged) }
        print("[border-drag] before: \(before.costs.mainAX) AX calls on main in \(before.costs.fullReads) full reads, \(before.costs.shows) border moves, main \(before.main)")
        print("[border-drag] after: \(after.costs.mainAX) AX calls on main, \(after.costs.offMainAX) off main in \(after.costs.frameReads) frame reads, \(after.costs.shows) border moves, main \(after.main)")
        #expect(before.costs.mainAX == 200 * Self.fullReadCalls && before.costs.shows == 200)
        #expect(after.costs.mainAX == 0 && after.costs.fullReads == 0)
        // 200 ms at one read per 8.3 ms frame: 24 frames, plus the first move's read at once
        #expect(after.costs.frameReads <= 26 && after.costs.frameReads >= 24, "\(after.costs.frameReads)")
        #expect(after.costs.shows == after.costs.frameReads)
    }

    /// Sven on build 62: the border did not stick to a dragged window. A 200 ms drag whose app reports a move only every
    /// 50 ms (the pace a busy app may send AX moves at; the real pace is unmeasured): through AX the border moves at
    /// the app's pace; held by the mouse it moves every display frame, from the window server, and never asks the app.
    @Test("Held by the mouse, the border moves every display frame from the window server, whatever pace AX reports moves at")
    func heldFollowsEveryFrame() {
        func run(held: Bool) -> (costs: Costs, rig: Rig) {
            let rig = Self.rig()
            rig.mouse.held = held
            rig.costs.fullReads = 0; rig.costs.mainAX = 0; rig.costs.shows = 0
            var nextFrame = 1.0 / 120
            for ms in 1...200 {
                rig.clock.advance(to: Double(ms) / 1000)
                rig.move(CGRect(x: 100 + 4 * ms, y: 50, width: 800, height: 600))
                if ms % 50 == 1 { rig.observers.windowMoved(Self.dragged) }
                if rig.clock.now >= nextFrame { rig.mouse.tick?(); nextFrame += 1.0 / 120 }
            }
            rig.mouse.held = false
            rig.mouse.tick?() // the frame after the release ends the drag
            rig.clock.advance(to: 1)
            return (rig.costs, rig)
        }
        let ax = run(held: false), held = run(held: true)
        print("[border-drag] AX moves every 50 ms, through AX: \(ax.costs.shows) border moves in 200 ms")
        print("[border-drag] held: \(held.costs.shows) border moves, \(held.costs.boundsReads) window server reads, \(held.costs.frameReads) AX frame reads (the release's), \(held.costs.mainAX) AX calls on main")
        #expect(ax.costs.shows == 4)
        #expect(held.costs.boundsReads == 24 && held.costs.shows == 24, "every 120 Hz frame")
        #expect(held.costs.mainAX == 0 && held.costs.frameReads == 1, "the app is asked once, at the release")
        #expect(held.rig.surface.shown == Self.border(held.rig.frame()))
        #expect(held.rig.mouse.tick == nil && held.rig.mouse.links == 1, "one display link per drag, stopped at the release")
        #expect(held.rig.observers.drag.lastDrag?.moves == 4)
    }

    @Test("The border ends exactly on the window when the drag stops")
    func settlesOnTheLastMove() {
        let rig = Self.rig()
        _ = Self.drag(rig, moves: 37) { $0.observers.windowMoved(Self.dragged) }
        #expect(rig.surface.shown == Self.border(rig.frame()))
        #expect(rig.observers.focusedWindowFrame == rig.frame())
        #expect(rig.clock.due.isEmpty, "idle once the drag stopped")
    }

    @Test("A move read while focus went to another window is dropped; a move of another window re-reads the focused one, once per frame")
    func staleAndOtherWindows() {
        let rig = Self.rig()
        rig.costs.fullReads = 0
        // Another window of the app moves (the tiler laying it out): the focused one is re-read whole, coalesced
        for i in 1...8 { // within one 8.3 ms frame
            rig.clock.advance(to: Double(i) / 1000)
            rig.observers.windowMoved(Self.other)
        }
        rig.clock.advance(to: 1)
        #expect(rig.costs.fullReads == 2, "the first at once, the other seven a frame later")
        // A read lands after focus moved on: the border keeps the new focused window
        rig.observers.readFocusedWindow = { _ in
            ("Other", WindowBorder.Window(frame: CGRect(x: 1000, y: 50, width: 800, height: 600), subrole: "AXStandardWindow",
                                          fullScreen: false, minimised: false, windowID: 8), Self.other)
        }
        rig.observers.refreshFocusedWindow()
        rig.observers.windowMoved(Self.dragged) // its frame read lands for a window no longer focused
        rig.clock.advance(to: 2)
        #expect(rig.surface.shown == Self.border(CGRect(x: 1000, y: 50, width: 800, height: 600)))
    }

    @Test("FrameFollower: one read in flight, a pending move waits for it, and the last move is always read")
    func oneAtATime() {
        let clock = Clock()
        var parked: [@MainActor (CGRect?) -> Void] = [], landed: [CGRect?] = []
        let f = FrameFollower(reader: { _, done in parked.append(done) }, now: { clock.now },
                              after: { d, w in clock.due.append((clock.now + d, w)) }, frame: 0.01)
        f.landed = { _, frame in landed.append(frame) }
        f.moved(.frame(Self.dragged))
        f.moved(.frame(Self.dragged))
        clock.advance(to: 0.002)
        #expect(parked.count == 1, "the second move waits for the read in flight")
        parked.removeFirst()(CGRect(x: 1, y: 1, width: 50, height: 50))
        #expect(landed.count == 1 && parked.count == 0)
        clock.advance(to: 0.009)
        #expect(parked.count == 0, "no sooner than a frame after the last read began, at 0")
        clock.advance(to: 0.01)
        #expect(parked.count == 1, "the pending move is read")
        parked.removeFirst()(nil)
        #expect(landed.count == 2 && landed[1] == nil)
        clock.advance(to: 1)
        #expect(parked.isEmpty && clock.due.isEmpty, "idle")
    }

    /// The window server's bounds for a real on-screen window: what a held drag's frame read costs. Reads only, no
    /// Accessibility needed. `PILOT_LIVE=1 swift test --filter FrameFollowerTests`.
    @Test("Live: the window server's bounds of an on-screen window, and their cost",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func liveBounds() throws {
        let window = try #require(EngineObservers.onScreen().first { $0.layer == 0 && $0.info.frame.width > 100 }?.info)
        let clock = ContinuousClock(), n = 500
        let cost = clock.measure { for _ in 0..<n { _ = DragFollower.bounds(of: window.id) } }
        #expect(DragFollower.bounds(of: window.id) == window.frame)
        print("[border-drag] live: window server bounds read \(cost / n) each")
    }

    /// Real AX against the focused window of the frontmost app: what one full read and one frame read cost on this Mac.
    /// Reads only; needs the test runner to have Accessibility. `PILOT_LIVE=1 swift test --filter FrameFollowerTests`.
    @Test("Live: a full read and a frame read of the frontmost app's focused window",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func liveCost() throws {
        try #require(AXIsProcessTrusted(), "the test runner has no Accessibility")
        let app = try #require(NSWorkspace.shared.frontmostApplication)
        let pid = app.processIdentifier
        let read = try #require(EngineObservers.axFocusedWindow(pid))
        let element = try #require(read.element)
        let clock = ContinuousClock(), n = 200
        let full = clock.measure { for _ in 0..<n { _ = EngineObservers.axFocusedWindow(pid) } }
        let frame = clock.measure { for _ in 0..<n { _ = FrameFollower.frame(of: element) } }
        #expect(FrameFollower.frame(of: element) == read.window.frame)
        print("[border-drag] live, \(app.localizedName ?? "?"): full read \(full / n) each, frame read \(frame / n) each")
    }
}
