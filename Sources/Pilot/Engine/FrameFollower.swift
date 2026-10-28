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
    /// A window's frame read (nil: the read failed), and a whole re-read; both on the main thread.
    var landed: (AXUIElement, CGRect?) -> Void = { _, _ in }
    var full: () -> Void = {}

    init(reader: @escaping Reader = FrameFollower.readOffMain, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         after: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = FrameFollower.mainAfter,
         frame: TimeInterval = FrameFollower.displayFrame()) {
        self.reader = reader; self.now = now; self.after = after; self.frame = frame
    }

    /// A move or resize: `.full` outranks a frame read until it runs.
    func moved(_ read: Read) {
        if case .full = pending {} else { pending = read }
        if !busy { next() }
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
            let frame = frame(of: element)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(frame) } }
        }
    }

    static func mainAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }

    /// The fastest screen's frame: a 120 Hz screen gets a read per 8 ms.
    static func displayFrame() -> TimeInterval { 1 / Double(max(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60, 60)) }
}
