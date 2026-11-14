import AppKit
import ApplicationServices
import PilotCore

/// Where Pilot reads other apps' notifications from. The app's is Notification Center's Accessibility tree; the sandbox's
/// is a fake, so no agent run ever observes or moves anything on Sven's Mac.
protocol NotificationSource: AnyObject, Sendable {
    /// Notification Center's pid now, 0 when it isn't running.
    func currentPID() -> pid_t
    /// `pid` is still that process, cheaply: the slow timer's first question.
    func stillRunning(_ pid: pid_t) -> Bool
    /// Starts delivering layout changes to `changed`; false when there is nothing to attach to yet.
    @MainActor func attach(changed: @escaping @MainActor () -> Void) -> Bool
    @MainActor func detach()
    /// The application element, read afresh; off the main thread, as a hung Notification Center must never hold the tap.
    func root() -> (any NotificationElement)?
    /// Control Center's application element, read afresh: it draws some of macOS's own banners (a screen-capture privacy
    /// hint) in a window of its own. Nil when it isn't running or the screen is locked.
    func systemRoot() -> (any NotificationElement)?
    /// Every language's action names, read once when the setting goes on.
    func vocabulary() -> NotificationVocabulary
}

/// Notification Center through Accessibility. The observer's callback only asks for a sweep: every read runs off the main
/// thread, each element answering within 1 s.
final class LiveNotificationSource: NotificationSource, @unchecked Sendable {
    static let bundle = "com.apple.notificationcenterui"
    /// A banner is a view in one host window. On macOS 27.2 that window exists only while a banner is up (measured
    /// 2026-11-10: no windows while idle), so the first banner may come as the window's creation, the rest as layout changes.
    private static let watched = [kAXLayoutChangedNotification, kAXWindowCreatedNotification, kAXUIElementDestroyedNotification]
    /// Control Center draws macOS's privacy hints in a window it makes for each banner (measured 2026-11-14: no windows while
    /// idle). Only a window's creation is watched: it also hosts the menu extras, whose layout changes all the time. The
    /// watcher looks again on a short timer while such a banner is up, to see it go.
    static let systemBundle = "com.apple.controlcenter"
    private static let systemWatched = [kAXWindowCreatedNotification]

    @MainActor private var observer: AXObserver?
    @MainActor private var systemObserver: AXObserver?
    @MainActor private var systemPID: pid_t = 0
    @MainActor private var changed: (@MainActor () -> Void)?

    nonisolated init() {}

    func currentPID() -> pid_t { Self.pid(of: Self.bundle) }

    func stillRunning(_ pid: pid_t) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        // Control Center came back under a new pid: re-attaching watches the new one too.
        let system = MainActor.assumeIsolated { systemPID }
        return system == 0 || kill(system, 0) == 0
    }

    private static func pid(of bundle: String) -> pid_t {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier ?? 0
    }

    @MainActor func attach(changed: @escaping @MainActor () -> Void) -> Bool {
        detach()
        let pid = currentPID()
        guard pid > 0, AXIsProcessTrusted(), let made = observe(pid, Self.watched) else { return false }
        observer = made
        self.changed = changed
        attachSystem()
        return true
    }

    /// Control Center's window creations; Notification Center's watch works without it.
    @MainActor private func attachSystem() {
        let pid = Self.pid(of: Self.systemBundle)
        guard pid > 0, let made = observe(pid, Self.systemWatched) else { return }
        systemObserver = made
        systemPID = pid
    }

    /// An observer of `names` on `pid`'s application element, on the main run loop; nil when none of them could be added.
    @MainActor private func observe(_ pid: pid_t, _ names: [String]) -> AXObserver? {
        var made: AXObserver?
        guard AXObserverCreate(pid, notificationSourceCallback, &made) == .success, let made else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let me = Unmanaged.passUnretained(self).toOpaque()
        var added = 0
        for name in names where AXObserverAddNotification(made, app, name as CFString, me) == .success { added += 1 }
        guard added > 0 else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
        return made
    }

    @MainActor func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        if let systemObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(systemObserver), .defaultMode) }
        observer = nil
        systemObserver = nil
        systemPID = 0
        changed = nil
    }

    @MainActor fileprivate func deliver() { changed?() }

    /// Nil while the screen is locked: it lists no windows then, which would read as every banner gone.
    func root() -> (any NotificationElement)? {
        let pid = currentPID()
        guard pid > 0, !Self.screenLocked else { return nil }
        return AXNotificationElement(AXUIElementCreateApplication(pid))
    }

    func systemRoot() -> (any NotificationElement)? {
        let pid = Self.pid(of: Self.systemBundle)
        guard pid > 0, !Self.screenLocked else { return nil }
        return AXNotificationElement(AXUIElementCreateApplication(pid))
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    func vocabulary() -> NotificationVocabulary {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundle)
            ?? URL(fileURLWithPath: "/System/Library/CoreServices/NotificationCenter.app")
        let table = app.appending(path: "Contents/Resources/Localizable.loctable")
        guard let data = try? Data(contentsOf: table),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return .english }
        return .from(loctable: plist)
    }
}

private func notificationSourceCallback(observer: AXObserver, element: AXUIElement, name: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let source = Unmanaged<LiveNotificationSource>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { source.deliver() }
}
