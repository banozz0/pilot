import AppKit
import CoreGraphics

/// The focused window while the mouse holds it (Sven on build 62, 2026-10-17: the border did not stick to a dragged
/// window, "like veryyyy low fps"). AX moves come as fast as the dragged app sends them and each frame read asks that
/// app again, so the border moved at the app's pace. While the left button is held, a display link ticks every frame
/// and reads the window's bounds from the window server, which is moving it; the release ends it, and EngineObservers
/// settles with one AX read.
///
/// Every frame's work runs on a thread of its own, never the main one (drag-3, Sven on build 3069: "fast dragging finder
/// is still a bit laggy sometimes"): his drags lost 36-44 % of 240 Hz ticks to a busy main thread, and the bounds read,
/// a call into the window server, took 3-6 ms while it moved the window, so 12-33 % of the ticks left found a read
/// still out. Now the border is moved on the tick's thread straight through the window server, by the pointer: the
/// window is where the last read had it plus how far the pointer went since (a read of the pointer is a memory read,
/// 0 us), and each read only corrects that. A read that does not agree with the pointer (a window held at a screen's
/// edge, an app moving its own window) stops the lead until one agrees; a resize, or no border to move, hands each read
/// to the main thread as before, and the line with it.
@MainActor
final class DragFollower {
    /// The window server's bounds for a window (window-server coordinates, top-left), `done` on the reading thread; tests run it in place.
    typealias Reader = @Sendable (_ id: CGWindowID, _ done: @escaping @Sendable (CGRect?) -> Void) -> Void
    /// Calls `tick` once per display frame, on a thread that is not the main one, until the returned stop is called.
    typealias Ticker = @MainActor (_ tick: @escaping @Sendable () -> Void) -> (@MainActor () -> Void)
    /// Moves window `number` so its top-left corner is at `corner` (window-server coordinates), from any thread.
    typealias Mover = @Sendable (_ number: UInt32, _ corner: CGPoint) -> Void
    /// The border panel lent for a drag of window `id`, and how far its corner sits up and left of the window's: nil when
    /// no border is shown above that window, and the main thread lands each read instead. The revoke (focus moved on,
    /// the border hid) stops the drag moving it; `giveBack` returns it at the drag's end, or at its first read the main
    /// thread lands (a resize).
    var border: (_ id: CGWindowID, _ revoke: @escaping () -> Void) -> DragBorder? = { _, _ in nil }
    var giveBack: () -> Void = {}
    typealias DragBorder = (number: UInt32, inset: CGFloat)
    private let reader: Reader
    private let ticker: Ticker
    private let mover: Mover
    private let held: @Sendable () -> Bool
    private let pointer: @Sendable () -> CGPoint
    private let now: @Sendable () -> TimeInterval
    private var window: CGWindowID?
    private var track: Track?
    private var stop: (@MainActor () -> Void)?
    /// One drag's counts, logged at its end: how often AX reported a move against the frames the border followed.
    struct Stats: Equatable {
        var start: TimeInterval, moves = 0, frames = 0, reads = 0, busy = 0, led = 0, readTimes: [TimeInterval] = []
        var readTime: TimeInterval { readTimes.reduce(0, +) }
        /// The read's 95th percentile, seconds.
        var readP95: TimeInterval { readTimes.isEmpty ? 0 : readTimes.sorted()[min(readTimes.count - 1, readTimes.count * 95 / 100)] }
    }
    private(set) var lastDrag: Stats?
    /// A frame read for window `id` (nil: it failed), and the drag's end; both on the main thread.
    var landed: (CGWindowID, CGRect?) -> Void = { _, _ in }
    var ended: () -> Void = {}

    init(reader: @escaping Reader = DragFollower.readOffMain, ticker: @escaping Ticker = DragFollower.threadTicker,
         mover: @escaping Mover = { _ = WindowServerMove.move($0, corner: $1) },
         held: @escaping @Sendable () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
         pointer: @escaping @Sendable () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.reader = reader; self.ticker = ticker; self.mover = mover; self.held = held; self.pointer = pointer; self.now = now
    }

    /// A move or resize while window `id` is focused (AX's, or AppKit's for Pilot's own window): true when the left
    /// button is held and the drag is followed here, so the move needs no read of its own.
    func moved(_ id: CGWindowID?) -> Bool {
        guard let id, held() else { return false }
        if window != id {
            stop?()
            _ = self.track?.finish() // a tick already under way must not move the border for the old window
            window = id
            let track = Track(id: id, start: now(), reader: reader, mover: mover, held: held, pointer: pointer, now: now)
            track.lend(border(id) { [weak track] in track?.revoke() })
            // A read the main thread lands makes the line the main thread's: a resize stops the drag moving it, and lent,
            // those reads left it to the drag, so it stayed where the resize began until the release (be63ce36; Sven on
            // build 3216, a Ghostex page window's and a Finder window's edge resize). A move lands none while lent.
            track.landed = { [weak self] frame in
                self?.giveBack()
                self?.landed(id, frame)
            }
            track.released = { [weak self] in self?.end(id) }
            self.track = track
            stop = ticker { track.frame() }
        }
        track?.moved()
        return true
    }

    private func end(_ id: CGWindowID) {
        guard window == id, let track else { return }
        stop?()
        (stop, window, self.track) = (nil, nil, nil)
        let (s, placed) = track.finish()
        giveBack()
        lastDrag = s
        let ms = Int((now() - s.start) * 1000), avg = s.reads == 0 ? 0 : Int(s.readTime / Double(s.reads) * 1_000_000)
        wlog.notice("border drag: \(ms) ms, \(s.moves) AX moves, \(s.frames) frames, \(s.reads) bounds reads (\(avg) us each, p95 \(Int(s.readP95 * 1_000_000)) us), \(s.busy) frames with a read still out, \(s.led) led by the pointer")
        // The border's last spot to the main thread's record of the window, so it starts from where the panel is.
        if let placed { landed(id, placed) }
        ended()
    }

    /// One drag's frames, on the ticker's thread; its reads on the reader's. All state behind one lock.
    final class Track: @unchecked Sendable {
        private let lock = NSLock()
        private let id: CGWindowID
        private var border: DragBorder?
        private let reader: Reader, mover: Mover, held: @Sendable () -> Bool, pointer: @Sendable () -> CGPoint, now: @Sendable () -> TimeInterval
        private var stats: Stats
        /// The last read and the pointer straight after it; whether the reads move with the pointer; the drag's first size.
        private var anchor: (frame: CGRect, pointer: CGPoint)?
        private var led = true
        /// The read the lead is next checked against, and how long before it may be.
        private var check: (frame: CGRect, pointer: CGPoint, time: TimeInterval)?
        static let checkSpan: TimeInterval = 0.04
        private var size: CGSize?
        private var resized = false
        private var reading = false
        private var done = false
        /// The window's frame the border was last moved for.
        private var placed: CGRect?
        /// Main-thread hops: a read the main thread lands (no border to move, or a resize), and the release.
        var landed: @MainActor (CGRect?) -> Void = { _ in }
        var released: @MainActor () -> Void = {}

        init(id: CGWindowID, start: TimeInterval, reader: @escaping Reader, mover: @escaping Mover,
             held: @escaping @Sendable () -> Bool, pointer: @escaping @Sendable () -> CGPoint, now: @escaping @Sendable () -> TimeInterval) {
            self.id = id; self.reader = reader; self.mover = mover; self.held = held; self.pointer = pointer; self.now = now
            stats = Stats(start: start)
        }

        func moved() { lock.withLock { stats.moves += 1 } }

        /// The border this drag moves, from its first frame; the revoke takes it back for good, and reads go to the main thread.
        func lend(_ border: DragBorder?) { lock.withLock { self.border = border } }
        func revoke() { lock.withLock { border = nil } }

        /// A display frame: the border to where the pointer has the window, then a read if none is out.
        func frame() {
            let up = !held(), at = pointer()
            var move: (UInt32, CGPoint)?, read = false
            let release: Bool = lock.withLock {
                guard !done else { return false }
                if up { done = true; return true }
                stats.frames += 1
                if let border, let anchor, !resized {
                    var frame = anchor.frame
                    if led { frame.origin.x += at.x - anchor.pointer.x; frame.origin.y += at.y - anchor.pointer.y }
                    if frame != placed {
                        placed = frame
                        move = (border.number, CGPoint(x: frame.minX - border.inset, y: frame.minY - border.inset))
                        if led { stats.led += 1 }
                    }
                }
                if reading { stats.busy += 1 } else { (reading, read) = (true, true) }
                return false
            }
            if release { return hop { $0.released() } }
            if let (number, corner) = move { mover(number, corner) }
            if read {
                let start = now()
                reader(id) { [self] frame in landedRead(frame, pointer(), since: start) }
            }
        }

        /// A read: the anchor the next frames lead from; the main thread's when the border cannot be moved from here.
        private func landedRead(_ frame: CGRect?, _ at: CGPoint, since start: TimeInterval) {
            let toMain: Bool = lock.withLock {
                reading = false
                guard !done else { return false }
                let t = now()
                stats.reads += 1
                stats.readTimes.append(t - start)
                guard let frame else { return border == nil }
                if size == nil { size = frame.size }
                if frame.size != size { resized = true }
                // The window went as far as the pointer did over the last 40 ms or more, give or take a quarter: one read
                // to the next, a mouse event between the read and the pointer's (a step of up to 40 pt at 125 Hz) would
                // fail it. A wrong lead costs at most the pointer's way during one read: the anchor is the latest read.
                if let ref = check, t - ref.time >= Self.checkSpan {
                    let px = at.x - ref.pointer.x, py = at.y - ref.pointer.y
                    let dx = frame.minX - ref.frame.minX - px, dy = frame.minY - ref.frame.minY - py
                    let slack = max(8, 0.25 * hypot(px, py))
                    led = abs(dx) <= slack && abs(dy) <= slack
                }
                if check.map({ t - $0.time >= Self.checkSpan }) ?? true { check = (frame, at, t) }
                anchor = (frame, at)
                return border == nil || resized
            }
            if toMain { hop { $0.landed(frame) } }
        }

        /// The drag's counts and the window frame the border was left at (nil: the main thread placed it).
        func finish() -> (Stats, CGRect?) {
            lock.withLock {
                done = true
                return (stats, resized || border == nil ? nil : placed)
            }
        }

        private func hop(_ work: @escaping @MainActor (Track) -> Void) {
            if Thread.isMainThread { return MainActor.assumeIsolated { work(self) } }
            DispatchQueue.main.async { MainActor.assumeIsolated { work(self) } }
        }
    }

    /// The window server's bounds for window `id`: a call to the window server, not to the app being dragged.
    nonisolated static func bounds(of id: CGWindowID) -> CGRect? {
        guard let bounds = description(of: id)?[kCGWindowBounds as String] as! CFDictionary? else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// The window server's bounds for window `id` while it draws it: nil when it is off screen or see-through.
    nonisolated static func drawnBounds(of id: CGWindowID) -> CGRect? {
        guard let info = description(of: id), info[kCGWindowIsOnscreen as String] as? Bool == true,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let bounds = info[kCGWindowBounds as String] as! CFDictionary? else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// The window server's layer for window `id`, the same number as its NSWindow.Level (the border stacks at it).
    nonisolated static func layer(of id: CGWindowID) -> Int? { description(of: id)?[kCGWindowLayer as String] as? Int }

    private nonisolated static func description(of id: CGWindowID) -> [String: Any]? {
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let array = unsafe ids.withUnsafeMutableBufferPointer({ unsafe CFArrayCreate(nil, $0.baseAddress, 1, nil) }) else { return nil }
        return (CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]])?.first
    }

    private nonisolated static let queue = DispatchQueue(label: "dev.banozz.pilot.drag-follower", qos: .userInteractive)

    /// The bounds read on its own queue, so a frame never waits for one: 3-6 ms on Sven's Mac while the window server
    /// moves the window (drag-3), against a 4.17 ms frame.
    nonisolated static func readOffMain(_ id: CGWindowID, _ done: @escaping @Sendable (CGRect?) -> Void) {
        queue.async {
            let frame = bounds(of: id)
            done(frame)
        }
    }

    /// The display link of the screen under the mouse at that screen's every frame, on a thread of its own: a busy main
    /// thread cannot drop its frames (drag-3). The thread ends with the link.
    static func threadTicker(_ tick: @escaping @Sendable () -> Void) -> (@MainActor () -> Void) {
        let target = LinkThread(tick)
        guard let link = link(rate: nil, target: target, selector: #selector(LinkThread.step)) else { return {} }
        target.link = link
        let thread = Thread { target.run() }
        thread.name = "dev.banozz.pilot.drag-frames"
        thread.qualityOfService = .userInteractive
        thread.start()
        return { target.stop() }
    }

    /// At most `rate` frames a second on the main run loop, in every mode (nil: the screen's most): the ring aims well at 60 (P74).
    static func displayTicker(rate: Float?, _ tick: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let target = LinkTarget(tick)
        guard let link = link(rate: rate, target: target, selector: #selector(LinkTarget.step)) else { return {} }
        link.add(to: .main, forMode: .common)
        return { link.invalidate() } // the link holds its target until then
    }

    /// The display link of the screen under the mouse, at most `rate` frames a second (nil: the screen's most): at 120 a
    /// 240 Hz screen's border trailed a drag by 2 frames (2026-11-20).
    private static func link(rate: Float?, target: NSObject, selector: Selector) -> CADisplayLink? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return nil }
        let rate = rate ?? Float(screen.maximumFramesPerSecond)
        let link = screen.displayLink(target: target, selector: selector)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        return link
    }

    /// The link's target on its own thread's run loop; stop invalidates the link there, and the run loop, left with no
    /// source, returns.
    private final class LinkThread: NSObject, @unchecked Sendable {
        let tick: @Sendable () -> Void
        var link: CADisplayLink?
        private let lock = NSLock()
        private var loop: CFRunLoop?
        private var stopped = false
        init(_ tick: @escaping @Sendable () -> Void) { self.tick = tick }
        @objc func step(_: CADisplayLink) { tick() }

        func run() {
            let go: Bool = lock.withLock {
                loop = CFRunLoopGetCurrent()
                return !stopped
            }
            guard go else { return link?.invalidate() ?? () }
            link?.add(to: .current, forMode: .default)
            while RunLoop.current.run(mode: .default, before: .distantFuture) {}
        }

        func stop() {
            let loop: CFRunLoop? = lock.withLock {
                stopped = true
                return self.loop
            }
            guard let loop else { return } // not running yet: run() sees stopped
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [link] in link?.invalidate() }
            CFRunLoopWakeUp(loop)
        }
    }

    /// The link calls it on the run loop it was added to, the main one.
    @MainActor private final class LinkTarget: NSObject {
        let tick: @MainActor () -> Void
        init(_ tick: @escaping @MainActor () -> Void) { self.tick = tick }
        @objc func step(_: CADisplayLink) { tick() }
    }
}
