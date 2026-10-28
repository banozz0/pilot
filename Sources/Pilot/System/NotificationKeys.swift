import AppKit
import ApplicationServices
import PilotCore

/// The notification keys (card agent-bo-95422949) on Notification Center's real Accessibility tree. Only what it shows
/// is reachable: banners still on screen, alerts, and everything while its panel is open. The walk runs off the main
/// thread, so a hung Notification Center never holds the tap.
@MainActor
enum NotificationKeys {
    static func clearLatest() { run("clear latest") { Notifications.clearLatest($0()) ? 1 : 0 } }
    static func openLatest() { run("open latest") { Notifications.openLatest($0()) ? 1 : 0 } }
    static func clearAll() { run("clear all") { Notifications.clearAll($0) } }

    /// A walk in flight: a second tap while it runs is dropped, so two walks never press the same notification.
    private static var walking = false

    /// `press` gets the tree's root, read afresh on each call; it returns the presses made.
    private static func run(_ what: String, _ press: @escaping @Sendable (() -> (any NotificationElement)?) -> Int) {
        guard !walking else { return }
        walking = true
        Task.detached {
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
            let presses = press { pid.map { AXNotificationElement(AXUIElementCreateApplication($0)) } }
            await MainActor.run {
                walking = false
                slog.notice("notifications \(what, privacy: .public): \(presses) presses")
                if presses == 0 { HUD.tip(Notifications.noneTip, seconds: 2) }
            }
        }
    }
}

/// An AXUIElement read as a NotificationElement, its action names read once and only when the walk reaches it; every
/// element answers within 1 s, as AXMenu's apps do, since the timeout is per element.
final class AXNotificationElement: NotificationElement {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, 1)
        self.element = element
    }

    lazy var actionNames: [String] = {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success ? names as? [String] ?? [] : []
    }()

    var children: [any NotificationElement] {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement] ?? []).map { AXNotificationElement($0) }
    }

    func perform(_ action: String) -> Bool { AXUIElementPerformAction(element, action as CFString) == .success }
}
