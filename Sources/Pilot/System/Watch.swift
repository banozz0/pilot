import Foundation

/// A running watch on the Mac's state (sound devices, Bluetooth's and Location's answers) or a timer: cancelling it takes
/// its listeners away or stops the timer. The Setup page holds its watches only while it shows on screen.
@MainActor
final class Watch {
    /// Runs `fire` after a delay unless cancelled first: keep-awake's end, a display mode's way back. The tests pass a
    /// fake clock instead.
    typealias After = (TimeInterval, @escaping @MainActor () -> Void) -> Watch

    private let stop: () -> Void
    init(stop: @escaping () -> Void) { self.stop = stop }
    func cancel() { stop() }

    /// The real timer: a task that sleeps, cancelled with the watch.
    static let after: After = { seconds, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { fire() }
        }
        return Watch { task.cancel() }
    }
}
