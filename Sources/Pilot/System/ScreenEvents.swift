import AppKit
import CoreGraphics

/// A reader that stops while nobody can see the screen and reads afresh when someone can again.
@MainActor
protocol ScreenPausing: AnyObject {
    func pause()
    func resume()
}

/// Whether anyone can see the screen (card agent-bo-95422839): locked or with its displays asleep, This Mac reads nothing,
/// as the Stats app does. macOS tells a lock and an unlock through distributed notifications and display sleep and wake
/// through NSWorkspace; the tests post to plain centers instead.
@MainActor
final class ScreenEvents {
    static let locked = Notification.Name("com.apple.screenIsLocked"), unlocked = Notification.Name("com.apple.screenIsUnlocked")
    static let shared = ScreenEvents()

    private let distributed: NotificationCenter, workspace: NotificationCenter
    private let lockedNow: () -> Bool
    private var locked = false, asleep = false, told: Bool?

    init(distributed: NotificationCenter = DistributedNotificationCenter.default(), workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         lockedNow: @escaping () -> Bool = ScreenEvents.isLocked) {
        self.distributed = distributed; self.workspace = workspace; self.lockedNow = lockedNow
    }

    /// Whether the screen is locked now, from the login session (the app window waits for an unlock with it too).
    nonisolated static func isLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Calls `changed` with whether the screen is in use (unlocked and awake), now and at each change.
    func start(_ changed: @escaping @MainActor (Bool) -> Void) {
        locked = lockedNow()
        for (center, name) in [(distributed, Self.locked), (distributed, Self.unlocked),
                               (workspace, NSWorkspace.screensDidSleepNotification), (workspace, NSWorkspace.screensDidWakeNotification)] {
            // Kept for Pilot's lifetime, so the tokens need no keeping.
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.handle(name, changed) }
            }
        }
        tell(changed)
    }

    /// Pauses `readers` while the screen is out of use and resumes them when it is back.
    func start(pausing readers: [any ScreenPausing]) {
        start { inUse in readers.forEach { inUse ? $0.resume() : $0.pause() } }
    }

    private func handle(_ name: Notification.Name, _ changed: @MainActor (Bool) -> Void) {
        switch name {
        case Self.locked: locked = true
        case Self.unlocked: locked = false
        case NSWorkspace.screensDidSleepNotification: asleep = true
        case NSWorkspace.screensDidWakeNotification: asleep = false
        default: return
        }
        tell(changed)
    }

    private func tell(_ changed: @MainActor (Bool) -> Void) {
        let inUse = !locked && !asleep
        guard inUse != told else { return }
        told = inUse
        changed(inUse)
    }
}
