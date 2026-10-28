import CoreGraphics

/// The key held to move or resize a window with the mouse (yabai's mouse_modifier, card agent-bo-95422930).
public enum DragModifier: String, CaseIterable, Sendable {
    case off, alt, ctrl, cmd, fn, hyper

    /// Alt, as Sven's yabairc had it.
    public static let `default`: DragModifier = .alt

    public var label: String { rawValue.capitalized }

    /// Exactly this modifier among Shift, Ctrl, Alt and Cmd, so Alt+Shift+click still reaches the app. Fn counts only when
    /// it is the one picked: some keyboards report it with other keys. Hyper is Pilot's layer, no flag: `hyper` is the
    /// layer's own answer (HyperLayer.isHeldAlone).
    public func matches(flags: UInt64, hyper: Bool = false) -> Bool {
        let held = flags & (KeyEvent.chordMask | KeyEvent.shiftMask)
        switch self {
        case .off: return false
        case .alt: return held == KeyEvent.altMask
        case .ctrl: return held == KeyEvent.ctrlMask
        case .cmd: return held == KeyEvent.cmdMask
        case .fn: return held == 0 && flags & KeyEvent.fnMask != 0
        case .hyper: return hyper
        }
    }
}

/// One modifier-drag of a window: left moves it, right resizes it from the quadrant clicked. Frames and points are in
/// AX coordinates (top-left origin), as CGEvent locations are.
public struct MouseDrag: Sendable, Equatable {
    public enum Button: Sendable { case left, right }
    public enum Kind: Sendable, Equatable { case move, resize(left: Bool, top: Bool) }

    public let button: Button
    public let kind: Kind
    public let windowID: Int
    public let start: CGPoint
    public let frame: CGRect

    /// The window a click lands on, by index into an on-screen list ordered front to back: the front one under the point.
    /// Nil when that is not another app's normal window: a menu, a panel or the Dock (not layer 0), one of Pilot's own
    /// windows, or a fullscreen one (its frame is a whole screen's; AX cannot move it). Invisible windows are looked
    /// through, and so are Pilot's click-through ones, which the caller leaves out of the list, and any window above the
    /// apps that covers a whole screen: the Dock keeps a see-through one over the main screen at its level.
    public static func hit(_ point: CGPoint, among windows: [(layer: Int, alpha: Double, frame: CGRect, own: Bool)],
                           screens: [CGRect]) -> Int? {
        guard let i = windows.firstIndex(where: {
            $0.alpha > 0 && $0.frame.contains(point) && !($0.layer != 0 && screens.contains($0.frame))
        }),
              windows[i].layer == 0, !windows[i].own, !screens.contains(windows[i].frame) else { return nil }
        return i
    }

    /// Nil when the click is not a drag: wrong modifiers, the setting off, or no window under the cursor.
    public static func begin(_ button: Button, flags: UInt64, hyper: Bool = false, at point: CGPoint, modifier: DragModifier,
                             window: (id: Int, frame: CGRect)?) -> MouseDrag? {
        guard modifier.matches(flags: flags, hyper: hyper), let window else { return nil }
        let kind: Kind = button == .left ? .move
            : .resize(left: point.x < window.frame.midX, top: point.y < window.frame.midY)
        return MouseDrag(button: button, kind: kind, windowID: window.id, start: point, frame: window.frame)
    }

    /// The window's frame with the cursor at `point`. A resize moves only the clicked edges and stops at WindowGeometry.minimumSize.
    public func frame(at point: CGPoint) -> CGRect {
        let dx = point.x - start.x, dy = point.y - start.y
        guard case .resize(let left, let top) = kind else { return frame.offsetBy(dx: dx, dy: dy) }
        var r = frame
        if left {
            r.size.width = max(frame.width - dx, WindowGeometry.minimumSize.width)
            r.origin.x = frame.maxX - r.width
        } else {
            r.size.width = max(frame.width + dx, WindowGeometry.minimumSize.width)
        }
        if top {
            r.size.height = max(frame.height - dy, WindowGeometry.minimumSize.height)
            r.origin.y = frame.maxY - r.height
        } else {
            r.size.height = max(frame.height + dy, WindowGeometry.minimumSize.height)
        }
        return r
    }

    /// A tiled window's resize at `point`: only the edges the tiler can move, each inside its reach, the rest where they were.
    public func frame(at point: CGPoint, within reach: EdgeReach) -> CGRect { reach.clamp(frame(at: point), from: frame) }

    /// The left mouse-up goes on to the tiler, which ends its own mouse handling there, unless the tap keeps it for a tiled
    /// move it hands the tiler itself (TilerDrag). A right drag's up is swallowed, as its down was, so no context menu opens.
    public var passesMouseUp: Bool { button == .left }
}

/// Where a tiled window's edges can go under a resize (story 119), in AX coordinates: each edge's range, nil for an edge
/// with no tile beyond it to give or take, which stays where it is (a window alone in its column keeps its height). The
/// tiler answers it once per drag and lands the release inside it, so the outline is exactly the result.
public struct EdgeReach: Sendable, Equatable {
    public var left, right, top, bottom: ClosedRange<CGFloat>?

    public init(left: ClosedRange<CGFloat>? = nil, right: ClosedRange<CGFloat>? = nil,
                top: ClosedRange<CGFloat>? = nil, bottom: ClosedRange<CGFloat>? = nil) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom
    }

    /// `frame` with each edge inside its range, and an edge without one where it is in `from`.
    public func clamp(_ frame: CGRect, from: CGRect) -> CGRect {
        func edge(_ value: CGFloat, _ range: ClosedRange<CGFloat>?, _ kept: CGFloat) -> CGFloat {
            range.map { min(max(value, $0.lowerBound), $0.upperBound) } ?? kept
        }
        let minX = edge(frame.minX, left, from.minX), maxX = edge(frame.maxX, right, from.maxX)
        let minY = edge(frame.minY, top, from.minY), maxY = edge(frame.maxY, bottom, from.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// One drag from press to release: what each cursor point does to the window. A move is always a position. A resize
/// frames a floating window as it goes; a tiled one (tile(within:), set before the first point) shows an outline of the
/// new frame inside the tiler's reach while the button is held and hands that frame to the tiler once at the release
/// (finish), since each tiler resize lays the whole workspace out and cannot follow the mouse.
public struct DragSession: Sendable {
    public enum Effect: Sendable, Equatable { case none, position(CGPoint), frame(CGRect), outline(CGRect), tiled(CGRect) }

    public let drag: MouseDrag
    /// A tiled resize's reach; nil while the window floats.
    private var reach: EdgeReach?
    /// A tiled resize's latest point, applied at the release.
    private var last: CGPoint?

    public init(_ drag: MouseDrag) { self.drag = drag }

    /// The tiler tiles the window: where its edges can go.
    public mutating func tile(within reach: EdgeReach) { self.reach = reach }

    public mutating func effect(at point: CGPoint) -> Effect {
        guard case .resize = drag.kind else { return .position(drag.frame(at: point).origin) }
        guard let reach else { return .frame(drag.frame(at: point)) }
        last = point
        return .outline(drag.frame(at: point, within: reach))
    }

    /// The release: a tiled resize's frame for the tiler, the outline's last, once; nothing for any other drag.
    public mutating func finish() -> Effect {
        guard let reach, let point = last else { return .none }
        last = nil
        let frame = drag.frame(at: point, within: reach)
        return frame == drag.frame ? .none : .tiled(frame)
    }
}

/// Which mouse events a drag keeps from the app: the press that starts it and its drags; the left mouse-up goes on to
/// the tiler (passesMouseUp), the right one is kept. Every other event passes untouched.
public struct DragTracker: Sendable {
    public enum Event: Sendable { case down(MouseDrag.Button, begun: MouseDrag?), dragged(MouseDrag.Button), up(MouseDrag.Button) }

    public private(set) var session: DragSession?
    /// The button came up: the drag's last point is still to apply, and no later event belongs to it.
    public private(set) var released = false

    public init() {}

    /// True when the event goes on to the app.
    public mutating func passes(_ event: Event) -> Bool {
        switch event {
        case .down(_, let begun):
            guard session == nil, let begun else { return true }
            session = DragSession(begun)
            return false
        case .dragged(let button):
            return !isLive(button)
        case .up(let button):
            guard isLive(button), let drag = session?.drag else { return true }
            released = true
            return drag.passesMouseUp
        }
    }

    private func isLive(_ button: MouseDrag.Button) -> Bool { session?.drag.button == button && !released }

    public mutating func effect(at point: CGPoint) -> DragSession.Effect { session?.effect(at: point) ?? .none }
    public mutating func tile(within reach: EdgeReach) { session?.tile(within: reach) }
    public mutating func finish() -> DragSession.Effect { session?.finish() ?? .none }

    public mutating func end() { session = nil; released = false }
}

/// A drag's writes to the window: one in flight at a time, at most one per display frame, and always the newest point, so
/// the window follows the mouse at the screen's rate whatever the mouse sends (a 1000 Hz mouse, a slow app's AX) and
/// never trails behind a queue of stale frames. Times are seconds on any monotonic clock.
public struct LatestWins<Value: Sendable & Equatable>: Sendable {
    public enum Step: Sendable, Equatable { case write(Value), wait(Double), idle }

    public let interval: Double
    private var pending: Value?
    private var inFlight = false
    private var waiting = false
    private var lastStart = -Double.infinity

    public init(interval: Double) { self.interval = interval }

    /// Nothing pending, in flight or waiting for its frame.
    public var isIdle: Bool { pending == nil && !inFlight && !waiting }

    /// A new value; it replaces one not yet written.
    public mutating func offer(_ value: Value, now: Double) -> Step { pending = value; return next(now) }
    /// The write in flight is done.
    public mutating func written(now: Double) -> Step { inFlight = false; return next(now) }
    /// The wait a step asked for is over.
    public mutating func woke(now: Double) -> Step { waiting = false; return next(now) }

    private mutating func next(_ now: Double) -> Step {
        guard !inFlight, !waiting, let value = pending else { return .idle }
        if now < lastStart + interval { waiting = true; return .wait(lastStart + interval - now) }
        pending = nil; inFlight = true; lastStart = now
        return .write(value)
    }
}
