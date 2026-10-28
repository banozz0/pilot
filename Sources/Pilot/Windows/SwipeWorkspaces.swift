@preconcurrency import Cocoa
import PilotCore

/// Swipe between workspaces (card agent-bo-95422973): the trackpad's touches, read by a gesture tap, fed to PilotCore's
/// WorkspaceSwipe; a fire is next or previous workspace. Not live-tested: the Mac mini it was built on has no trackpad.
@MainActor
final class SwipeWorkspaces {
    private let tap: GestureTap
    private var swipe = WorkspaceSwipe()
    private(set) var isRunning = false
    var onSwipe: (WorkspaceSwipe.Fire) -> Void = { _ in }

    init(tap: GestureTap = TrackpadGestureTap()) { self.tap = tap }

    /// On: the tap runs (tried again on the next update when it could not be made). Off: no tap.
    func update(on: Bool) {
        if on, !isRunning {
            isRunning = tap.start { [unowned self] xs in frame(xs) }
            if isRunning { wlog.notice("swipe tap installed") } else { wlog.error("swipe: gesture tap not created") }
        } else if !on, isRunning {
            tap.stop()
            isRunning = false
            swipe = WorkspaceSwipe()
        }
    }

    /// One gesture event's touches, as their normalised x.
    private func frame(_ xs: [Double]) {
        guard let fire = swipe.frame(xs) else { return }
        wlog.notice("swipe: \(fire == .next ? "next" : "previous", privacy: .public) workspace")
        onSwipe(fire)
    }
}

/// Where the touches come from: the trackpad's gesture events, a fake in the tests.
@MainActor
protocol GestureTap: AnyObject {
    /// False when the tap could not be made; `frame` gets each gesture event's touching fingers' normalised x.
    func start(_ frame: @escaping ([Double]) -> Void) -> Bool
    func stop()
}

/// A listen-only tap on gesture events (NSEvent type gesture, CGEventType 29), the way SwipeAeroSpace (MIT,
/// https://github.com/MediosZ/SwipeAeroSpace) reads three-finger swipes: it never holds or changes an event, so the macOS
/// Spaces swipe and every app's own gestures go on as before.
@MainActor
final class TrackpadGestureTap: GestureTap {
    private let tap = ListenOnlyTap(mask: CGEventMask(1) << NSEvent.EventType.gesture.rawValue)

    func start(_ frame: @escaping ([Double]) -> Void) -> Bool {
        tap.start { event in
            guard let touches = NSEvent(cgEvent: event)?.touches(matching: .touching, in: nil) else { return }
            frame(touches.map { Double($0.normalizedPosition.x) })
        }
    }

    func stop() { tap.stop() }
}
