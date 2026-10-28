import AppKit
import CoreGraphics

/// The focused window while the mouse holds it (Sven on build 62, 2026-10-17: the border did not stick to a dragged
/// window, "like veryyyy low fps"). AX moves come as fast as the dragged app sends them and each frame read asks that
/// app again, so the border moved at the app's pace. While the left button is held, a display link ticks every frame
/// and reads the window's bounds from the window server, which is moving it, off the main thread; the release ends it,
/// and EngineObservers settles with one AX read. The key tap's thread only starts a queue hop per frame.
@MainActor
final class DragFollower {
    /// The window server's bounds for a window (AX coordinates), off the main thread, handed back on it; tests run it in place.
    typealias Reader = @MainActor (_ id: CGWindowID, _ done: @escaping @MainActor (CGRect?) -> Void) -> Void
    /// Calls `tick` once per display frame on the main thread until the returned stop is called.
    typealias Ticker = @MainActor (_ tick: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
    private let reader: Reader
    private let ticker: Ticker
    private let held: () -> Bool
    private let now: () -> TimeInterval
    private var window: CGWindowID?
    private var stop: (@MainActor () -> Void)?
    private var reading = false
    /// One drag's counts, logged at its end: how often AX reported a move against the frames the border followed.
    private var stats = Stats(start: 0)
    struct Stats: Equatable { var start: TimeInterval, moves = 0, frames = 0, reads = 0, busy = 0, readTime: TimeInterval = 0 }
    private(set) var lastDrag: Stats?
    /// A frame read for window `id` (nil: it failed), and the drag's end; both on the main thread.
    var landed: (CGWindowID, CGRect?) -> Void = { _, _ in }
    var ended: () -> Void = {}

    init(reader: @escaping Reader = DragFollower.readOffMain, ticker: @escaping Ticker = DragFollower.displayTicker,
         held: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.reader = reader; self.ticker = ticker; self.held = held; self.now = now
    }

    /// An AX move or resize while window `id` is focused: true when the left button is held and the drag is followed
    /// here, so the move needs no read of its own.
    func moved(_ id: CGWindowID?) -> Bool {
        guard let id, held() else { return false }
        if window != id {
            stop?()
            window = id
            stats = Stats(start: now())
            stop = ticker { [weak self] in self?.frame() }
        }
        stats.moves += 1
        return true
    }

    private func frame() {
        guard let id = window else { return }
        guard held() else { return end() }
        stats.frames += 1
        guard !reading else { stats.busy += 1; return }
        reading = true
        let start = now()
        reader(id) { [weak self] frame in
            guard let self else { return }
            reading = false
            guard window == id else { return } // the drag ended meanwhile: the settling read has the last word
            stats.reads += 1
            stats.readTime += now() - start
            landed(id, frame)
        }
    }

    private func end() {
        stop?()
        stop = nil
        window = nil
        let s = stats
        lastDrag = s
        let ms = Int((now() - s.start) * 1000), avg = s.reads == 0 ? 0 : Int(s.readTime / Double(s.reads) * 1_000_000)
        wlog.notice("border drag: \(ms) ms, \(s.moves) AX moves, \(s.frames) frames, \(s.reads) bounds reads (\(avg) us each), \(s.busy) frames with a read still out")
        ended()
    }

    /// The window server's bounds for window `id`: a call to the window server, not to the app being dragged.
    nonisolated static func bounds(of id: CGWindowID) -> CGRect? {
        guard let bounds = description(of: id)?[kCGWindowBounds as String] as! CFDictionary? else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// The window server's layer for window `id`, the same number as its NSWindow.Level (the border stacks at it).
    nonisolated static func layer(of id: CGWindowID) -> Int? { description(of: id)?[kCGWindowLayer as String] as? Int }

    private nonisolated static func description(of id: CGWindowID) -> [String: Any]? {
        var ids: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(id))]
        guard let array = unsafe ids.withUnsafeMutableBufferPointer({ unsafe CFArrayCreate(nil, $0.baseAddress, 1, nil) }) else { return nil }
        return (CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]])?.first
    }

    private static let queue = DispatchQueue(label: "dev.banozz.pilot.drag-follower", qos: .userInteractive)

    static func readOffMain(_ id: CGWindowID, _ done: @escaping @MainActor (CGRect?) -> Void) {
        queue.async {
            let frame = bounds(of: id)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(frame) } }
        }
    }

    /// The display link of the screen under the mouse, on the main run loop in every mode.
    static func displayTicker(_ tick: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) { displayTicker(rate: 120, tick) }

    /// At most `rate` frames a second: the ring aims well at 60 (P74).
    static func displayTicker(rate: Float, _ tick: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let target = LinkTarget(tick)
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return {} }
        let link = screen.displayLink(target: target, selector: #selector(LinkTarget.step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        return { link.invalidate() } // the link holds its target until then
    }

    /// The link calls it on the run loop it was added to, the main one.
    @MainActor private final class LinkTarget: NSObject {
        let tick: @MainActor () -> Void
        init(_ tick: @escaping @MainActor () -> Void) { self.tick = tick }
        @objc func step(_: CADisplayLink) { tick() }
    }
}
