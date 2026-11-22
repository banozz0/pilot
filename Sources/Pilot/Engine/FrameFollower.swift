import AppKit
import ApplicationServices

/// The focused window's moves and resizes, at most one read per display frame (Sven's report 2026-10-17: the border
/// lagged a dragged window and a fast drag lagged the whole screen). A drag sends AX a move per mouse event, and each
/// used to re-read the focused window on the main thread, eight AX calls into the app being dragged, on the thread the
/// key tap and the mouse taps run on. Here a move only marks the window; the read runs off the main thread, one at a
/// time, no sooner than a frame after the last one began, and the last move is always read, so the border ends on it.
@MainActor
final class FrameFollower {
    /// What the next read is: the moved window's frame alone, or the whole focused window (EngineObservers decides).
    enum Read { case frame(AXUIElement), full }

    /// Runs `read` off the main thread and hands its frame back on it; tests run it in place.
    typealias Reader = @MainActor (_ element: AXUIElement, _ done: @escaping @MainActor (CGRect?) -> Void) -> Void
    private let reader: Reader
    /// Seconds since some fixed point, and `work` run on the main thread after `delay` seconds; tests pass a fake clock.
    private let now: () -> TimeInterval
    private let after: @MainActor (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void
    private let frame: TimeInterval
    /// The latest move not read yet, a read in flight or one waiting for its frame, and when the last one began.
    private var pending: Read?
    private var busy = false
    private var lastStart = -TimeInterval.infinity
    /// The window server's frame for window `id` while it draws it, off the main thread, handed back on it; tests run it in place.
    typealias BoundsReader = @MainActor (_ id: CGWindowID, _ done: @escaping @MainActor (CGRect?) -> Void) -> Void
    private let bounds: BoundsReader
    /// After the focused window was read (a move, a whole read), its frame is read again from the window server this
    /// long after the last such read, then this much later again (tester bug 9, 2026-11-19): AX has an app's frame at
    /// once, the window server only once the app commits it, and it alone knows a window drawn off its AX frame
    /// (Photo Booth, 2026-11-16). One call to the window server each, none into the app.
    static let settleDelays: [TimeInterval] = [0.1, 0.5]
    private let settleGaps: [TimeInterval]
    /// The window the settle reads are for, the gaps before each read left, and when the next is due; one timer at a
    /// time, its deadline pushed out by each read until the reads stop.
    private var settling: (id: CGWindowID, gaps: ArraySlice<TimeInterval>, due: TimeInterval)?
    private var settleArmed = false
    /// A window's frame read (nil: the read failed), a whole re-read, and a settle read; all on the main thread.
    var landed: (AXUIElement, CGRect?) -> Void = { _, _ in }
    var full: () -> Void = {}
    var settled: (CGWindowID, CGRect?) -> Void = { _, _ in }

    init(reader: @escaping Reader = FrameFollower.readOffMain, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         after: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = FrameFollower.mainAfter,
         frame: TimeInterval = FrameFollower.displayFrame(), bounds: @escaping BoundsReader = FrameFollower.drawnOffMain,
         settleDelays: [TimeInterval] = FrameFollower.settleDelays) {
        self.reader = reader; self.now = now; self.after = after; self.frame = frame; self.bounds = bounds
        settleGaps = zip(settleDelays, [0] + settleDelays).map { $0 - $1 }
    }

    /// A move or resize: `.full` outranks a frame read until it runs.
    func moved(_ read: Read) {
        if case .full = pending {} else { pending = read }
        if !busy { next() }
    }

    /// Window `id`, the focused one, was just read: settle reads follow once the reads stop.
    func settle(_ id: CGWindowID) {
        guard let first = settleGaps.first else { return }
        settling = (id, settleGaps.dropFirst(), now() + first)
        armSettle()
    }

    /// The mouse holds the window: DragFollower reads the window server every frame, and the release settles anew.
    func cancelSettle() { settling = nil }

    private func armSettle() {
        guard let due = settling?.due, !settleArmed else { return }
        settleArmed = true
        after(max(due - now(), 0)) { [weak self] in self?.settleDue() }
    }

    private func settleDue() {
        settleArmed = false
        guard let s = settling else { return }
        guard now() >= s.due else { return armSettle() } // a later read pushed it out
        settling = s.gaps.first.map { (s.id, s.gaps.dropFirst(), now() + $0) }
        bounds(s.id) { [weak self] frame in self?.settled(s.id, frame) }
        armSettle()
    }

    /// The pending read, now or a frame after the last one began; idle once nothing is pending.
    private func next() {
        guard pending != nil else { busy = false; return }
        busy = true
        let wait = lastStart + frame - now()
        guard wait <= 0 else { return after(wait) { [weak self] in self?.fire() } }
        fire()
    }

    private func fire() {
        guard let read = pending else { busy = false; return }
        pending = nil
        lastStart = now()
        switch read {
        case .full:
            full()
            next()
        case .frame(let element):
            reader(element) { [weak self] frame in
                guard let self else { return }
                landed(element, frame)
                next()
            }
        }
    }

    /// One AX window's frame in one call into its app, off the main thread: the dragged app is busy and the main thread
    /// carries the key tap.
    nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        var values: CFArray?
        let names = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let list = values as? [AnyObject], list.count == 2,
              CFGetTypeID(list[0]) == AXValueGetTypeID(), CFGetTypeID(list[1]) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(list[0] as! AXValue, .cgPoint, &p), AXValueGetValue(list[1] as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static let axQueue = DispatchQueue(label: "dev.banozz.pilot.frame-follower", qos: .userInteractive)

    static func readOffMain(_ element: AXUIElement, _ done: @escaping @MainActor (CGRect?) -> Void) {
        nonisolated(unsafe) let element = element
        axQueue.async {
            // The app's own frame, which it has the moment it posts the move; the window server's comes in the settle reads
            let frame = frame(of: element)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(frame) } }
        }
    }

    /// Window `id`'s frame while the window server draws it (nil: not on screen), off the main thread.
    static func drawnOffMain(_ id: CGWindowID, _ done: @escaping @MainActor (CGRect?) -> Void) {
        axQueue.async {
            let frame = DragFollower.drawnBounds(of: id)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(frame) } }
        }
    }

    static func mainAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }

    /// The fastest screen's frame: a 120 Hz screen gets a read per 8 ms.
    static func displayFrame() -> TimeInterval { 1 / Double(max(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60, 60)) }
}
