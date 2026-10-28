// Pilot (card agent-bo-95423033): tiled windows glide to their new frames instead of jumping. Each app's AX thread runs
// its own glides on a display link (MacApp.setAxFrame), so the main thread posts one job per layout and never a frame.
// Smooth glide (Sven's Q147, 2026-10-16): the steps follow the display's refresh, and only the position glides; the size
// is set once, shrunk before the move and grown after it, since an app relayouts on every size write (gliding windows
// report: 0.06 ms a move, 1 to 90 ms a resize).
import AppKit
import QuartzCore
import Synchronization

/// The windows of one app gliding to their targets with an ease-out: 180 ms each, the scrolling strip's speed too
/// (Strip.glide), long enough to be seen (Sven's Q148).
struct GlideSet {
    static let duration = Duration.milliseconds(180)
    /// `at`: the frame it was last written at, where a new target starts; `span`, the x it keeps within (FrameSteps);
    /// `sized`, whether the window is at `at`'s size; `then`, where it jumps once it lands (a space-switch slide's hide).
    private struct Glide {
        var from, to, at: Rect; var start: ContinuousClock.Instant; var duration: Duration; var span: ClosedRange<CGFloat>?
        var sized = true; var then: CGPoint? = nil
    }
    private var glides: [UInt32: Glide] = [:]

    var isEmpty: Bool { glides.isEmpty }
    func isGliding(_ id: UInt32) -> Bool { glides[id] != nil }

    /// `id` is to be framed at `to`, and whether it glides there: from `from`, or from where a running glide has it. A
    /// burst of writes retargets the one glide and the same target again leaves it running; without `from` it jumps, and
    /// so does a resize in place, where nothing would glide. `fromCorner`: the window waits in a hide corner at a size of
    /// its own, so its first step sets the size there before it moves; `then`, where it jumps once it lands, which keeps
    /// even a glide that goes nowhere running to the end (a space-switch slide, spaceSlide.swift). A new target drops it.
    mutating func retarget(_ id: UInt32, from: Rect?, to: Rect, now: ContinuousClock.Instant, duration: Duration = Self.duration,
                           span: ClosedRange<CGFloat>? = nil, fromCorner: Bool = false, then: CGPoint? = nil) -> Bool {
        if let running = glides[id], running.to.isClose(to: to), running.then == then { return true }
        guard let from else {
            glides[id] = nil
            return false
        }
        let start = glides[id]?.at ?? from
        guard then != nil || !start.hasTopLeft(closeTo: to) else {
            glides[id] = nil
            return false
        }
        glides[id] = Glide(from: start, to: to, at: start, start: now, duration: duration, span: span,
                           sized: glides[id]?.sized ?? !fromCorner, then: then)
        return true
    }

    /// Another write took over `id` (hidden, fullscreen, minimised, termination).
    mutating func stop(_ id: UInt32) { glides[id] = nil }

    /// Each gliding window's frame at `now`, from the frame it was last written at; one that has arrived gets its target
    /// and leaves the set.
    mutating func step(_ now: ContinuousClock.Instant) -> [GlideStep] {
        var frames: [GlideStep] = []
        for (id, var glide) in glides { // a copy: the set changes below
            let progress = min(1, (now - glide.start) / glide.duration)
            let frame = Self.frame(from: glide.from, to: glide.to, progress: progress)
            frames.append(GlideStep(id: id, from: glide.at, frame: frame, span: glide.span, sizeUnknown: !glide.sized,
                                    then: progress >= 1 ? glide.then : nil))
            glide.at = frame
            glide.sized = true
            glides[id] = progress >= 1 ? nil : glide
        }
        return frames
    }

    /// The frame `progress` (0 to 1) of the way: the top-left eased out (cubic), quick to leave and gentle to land, at the
    /// smaller of the two sizes on each side until it lands at `to`. FrameSteps writes that size once, before the first
    /// move, and the target's after the last.
    static func frame(from: Rect, to: Rect, progress: Double) -> Rect {
        guard progress < 1 else { return to }
        let t = 1 - pow(1 - progress, 3)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return Rect(topLeftX: mix(from.minX, to.minX), topLeftY: mix(from.minY, to.minY),
                    width: min(from.width, to.width), height: min(from.height, to.height))
    }
}

/// One tick of a window's glide: the frame it was written at last, the next, and the x it keeps within; whether the
/// window is at another size than `from`'s (out of a hide corner), and where it jumps after the step that lands.
struct GlideStep {
    let id: UInt32
    let from, frame: Rect
    let span: ClosedRange<CGFloat>?
    var sizeUnknown = false
    var then: CGPoint? = nil
}

/// Pilot (scrolling layout, Moody on T1): one frame write as AX takes it, the size and the position apart, the window
/// drawn between the two. What shrinks goes first, at the old place, then the move, then what grows, so no moment covers
/// ground outside both frames (size first had a column growing leftward reach onto the display beside it). With `span`,
/// the window's x keeps inside it at the width the app took: an app with a minimum width keeps that width, and the
/// window moves back from a bordered edge instead of reaching over it.
struct FrameSteps {
    /// The window's frame now; nil when unknown, which sizes first as AeroSpace always did.
    var current: Rect?
    var target: Rect
    var span: ClosedRange<CGFloat>? = nil
    /// The narrowest an earlier write found the app lets this window be.
    var minWidth: CGFloat = 0
    /// The size again after the move even when it did not change: a move can resize (AeroSpace #143, #335).
    var resetSize = true

    /// Runs the writes; `setSize` is told whether its answer is wanted (after the shrink only, where an app's minimum
    /// shows) and answers the size the app took, or nil when it is not read back. Returns the narrowest width the app is
    /// now known to allow.
    func run(setSize: (_ size: CGSize, _ readBack: Bool) throws -> CGSize?, setPosition: (CGPoint) throws -> Void) rethrows -> CGFloat {
        var minWidth = minWidth
        let first = current.map { CGSize(width: min($0.width, target.width), height: min($0.height, target.height)) } ?? target.size
        if first != current?.size, let took = try setSize(first, true), took.width > first.width + 0.5 { minWidth = max(minWidth, took.width) }
        var x = target.minX
        if let span { x = max(min(x, span.upperBound - max(target.width, minWidth)), span.lowerBound) }
        try setPosition(CGPoint(x: x, y: target.minY))
        if resetSize || target.size != first { _ = try setSize(target.size, false) }
        return minWidth
    }
}

/// Reduce Motion, read once per layout pass (LayoutContext); tests swap it.
@MainActor var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
/// Low Power Mode, read with it: glides cost CPU, so they jump (as Loop does).
@MainActor var lowPowerMode: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
/// Whether tiling glides run at all: Glide windows on, neither Reduce Motion nor Low Power Mode, no gap held (its
/// neighbours follow the mouse at once). Layout glides and space-switch slides both ask it.
@MainActor var glidesAllowed: Bool { config.glide && !reduceMotion() && !lowPowerMode() && gapDrag == nil }

/// The windows gliding now, in every app: their own moves and resizes are not news (movedObs, resizedObs, Pilot's window
/// border), or each glide would set off a refresh and a focused-window read per frame.
private let glidingWindowIds = Mutex<Set<UInt32>>([])

func isGliding(_ windowId: UInt32?) -> Bool {
    guard let windowId else { return false }
    return glidingWindowIds.withLock { $0.contains(windowId) }
}

/// Whether the window `element` belongs to is gliding: Pilot's own AX observers skip its moves and resizes. With nothing
/// gliding (the tiler off, or between glides) it asks nothing of AX.
public func tilerIsGliding(_ element: AXUIElement) -> Bool {
    glidingWindowIds.withLock { !$0.isEmpty } && isGliding(element.containingWindowId())
}

/// Windows whose frame the tiler has just finished writing: a glide that landed, or a jump. A glide's own moves are
/// skipped (tilerIsGliding) and the last one can reach Pilot before the gliding mark is gone, so Pilot's window border
/// re-reads the focused window here, not on AX alone (Sven's test 2026-10-09: it stayed at the old tile).
public enum TilerFrames {
    @MainActor public static var landed: @MainActor (Set<UInt32>) -> Void = { _ in }

    /// From an app's AX thread, after the write.
    static func announce(_ ids: Set<UInt32>) {
        guard !ids.isEmpty else { return }
        Task.startUnstructured { @MainActor in landed(ids) }
    }
}

/// One app's glides and the display link that runs them, on its AX thread only (MacApp runs each tick).
final class Glider {
    private var glides = GlideSet()
    private var ticker: GlideTicker?
    /// Landed since the last `takeLanded`.
    private var landed: Set<UInt32> = []
    /// The app's enhanced UI (an AX setting that animates frame writes) was on when the glides began: back on at the end.
    var enhancedUIWasOn = false

    var isRunning: Bool { ticker != nil }

    /// The narrowest each window's app let it be (FrameSteps), learned from the writes.
    var minWidths: [UInt32: CGFloat] = [:]

    func retarget(_ id: UInt32, from: Rect?, to: Rect, now: ContinuousClock.Instant, duration: Duration = GlideSet.duration,
                  span: ClosedRange<CGFloat>? = nil, fromCorner: Bool = false, then: CGPoint? = nil) -> Bool {
        let gliding = glides.retarget(id, from: from, to: to, now: now, duration: duration, span: span, fromCorner: fromCorner, then: then)
        mark(id, gliding: gliding)
        return gliding
    }

    func stop(_ id: UInt32) {
        glides.stop(id)
        mark(id, gliding: false)
    }

    /// One timer tick: `write` gets each gliding window's step; a window that lands is no longer gliding. Whether every
    /// glide has landed.
    func tick(_ now: ContinuousClock.Instant, _ write: (GlideStep) -> Void) -> Bool {
        for step in glides.step(now) {
            write(step)
            if !glides.isGliding(step.id) {
                mark(step.id, gliding: false)
                landed.insert(step.id)
            }
        }
        return glides.isEmpty
    }

    /// The windows that landed since the last call, for TilerFrames.
    func takeLanded() -> Set<UInt32> {
        defer { landed = [] }
        return landed
    }

    /// `tick` on every refresh of `screen` up to 120 Hz (every other one of a 240 Hz panel, evenly) until `stopTicking`;
    /// at 60 Hz on a timer when no screen is known.
    func startTicking(on screen: NSScreen?, _ tick: @escaping () -> Void) {
        ticker = GlideTicker(screen: screen, tick)
    }

    func stopTicking() {
        ticker?.stop()
        ticker = nil
    }

    private func mark(_ id: UInt32, gliding: Bool) {
        glidingWindowIds.withLock { if gliding { $0.insert(id) } else { $0.remove(id) } }
    }

    deinit { ticker?.stop() }
}

/// What paces a glide on the current thread's run loop: the display link of the screen it glides on, else a timer.
private final class GlideTicker: NSObject {
    private let tick: () -> Void
    private var link: CADisplayLink?
    private var timer: Timer?

    init(screen: NSScreen?, _ tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        if let screen {
            let link = screen.displayLink(target: self, selector: #selector(step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .current, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in tick() }
            timer.tolerance = 0.002
            RunLoop.current.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    @objc private func step(_: CADisplayLink) { tick() }

    /// The link holds its target: it must be stopped, not only dropped.
    func stop() {
        link?.invalidate()
        timer?.invalidate()
        link = nil
        timer = nil
    }
}

/// The screen whose refresh paces a glide: the workspace monitor's, picked once per layout pass on the main thread and
/// handed to the app's AX thread, which only makes its display link from it.
struct GlideScreen: @unchecked Sendable {
    let screen: NSScreen

    /// Nil while the displays change under the monitor list.
    @MainActor init?(_ monitor: MonitorInfo) {
        let screens = NSScreen.screens, index = monitor.monitorAppKitNsScreenScreensId - 1
        guard screens.indices.contains(index) else { return nil }
        screen = screens[index]
    }
}

extension Rect {
    /// Within half a point on every side: layout's sums drift by fractions.
    func isClose(to other: Rect) -> Bool {
        hasTopLeft(closeTo: other) && abs(width - other.width) < 0.5 && abs(height - other.height) < 0.5
    }

    func hasTopLeft(closeTo other: Rect) -> Bool { abs(minX - other.minX) < 0.5 && abs(minY - other.minY) < 0.5 }
}
