import AppKit
import PilotTiler

/// Settings and Finish setup open from the menu bar. macOS 26 hands a menu-bar click to its own menu-bar host, so
/// Pilot gets no user event and a cooperative NSApp.activate() is refused: the window opened behind the app Sven was
/// in. Pilot takes the front from that app instead, and gives the front back when the window closes, or macOS hands
/// it to whichever app it picks (ClipBook, seen 2026-10-04).
@MainActor
enum WindowFocus {
    /// The last app Sven was in: set on open, and again each time he switches to another app while the window is open.
    private static var previousApp: NSRunningApplication?
    private static var switchObserver: NSObjectProtocol?
    private static var closeObserver: NSObjectProtocol?

    /// Call right after opening the window (openSettings, openWindow): SwiftUI creates it on the next turn.
    static func bringForward() {
        // A window Show desktop holds would come forward out of sight: the desktop's widgets hide as it ends.
        if TilerOwnWindows.broughtForward() { WidgetDesk.shared.showDesktopChanged() }
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front != .current { previousApp = front }
        NSRunningApplication.current.activate(from: front ?? .current, options: [])
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.last(where: { $0.isVisible && $0.level == .normal }) else {
                return log.error("window focus: no window to raise, the front is not handed back on close")
            }
            window.makeKeyAndOrderFront(nil)
            watch(window)
        }
    }

    private static func watch(_ window: NSWindow) {
        stopWatching()
        switchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current else { return }
            MainActor.assumeIsolated { previousApp = app }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                stopWatching()
                // Only while Pilot has the front: otherwise closing the window moves no focus and Sven is elsewhere.
                if NSApp.isActive { previousApp?.activate(from: .current, options: []) }
                previousApp = nil
            }
        }
    }

    private static func stopWatching() {
        if let switchObserver { NSWorkspace.shared.notificationCenter.removeObserver(switchObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        switchObserver = nil
        closeObserver = nil
    }
}
