import AppKit
import PilotCore

/// Watches one app by bundle id through NSWorkspace's runningApplications, which lists every app; its launch and
/// terminate notifications never arrive for menu-bar-only apps (AppLifecycle). Stops when released.
@MainActor
final class AppWatcher {
    private var observation: NSKeyValueObservation?

    init(_ bundleId: String, launched: @escaping @MainActor (NSRunningApplication) -> Void, ended: @escaping @MainActor () -> Void) {
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { _, kvo in
            let change = AppLifecycle.change(for: bundleId, added: kvo.newValue?.map(\.bundleIdentifier),
                                             removed: kvo.oldValue?.map(\.bundleIdentifier))
            guard change.ended || change.launched else { return }
            let app = kvo.newValue?.first { $0.bundleIdentifier == bundleId }
            Task { @MainActor in
                if change.ended { ended() }
                if let app { launched(app) }
            }
        }
    }
}
