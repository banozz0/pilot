import AppKit
import PilotCore

/// Finder's own desktop icons on or off (Sven, Q745): Finder's CreateDesktop preference, then Finder quit and opened
/// again once, which is when it reads it. Not the captures' switch (DesktopIcons, Q189), which leaves the icons out of
/// captures and never changes the desktop. Finder is asked to quit through NSRunningApplication and opened through
/// NSWorkspace: no AppleScript to Finder, no killall. A Finder that will not quit (a copy under way) is never forced:
/// the setting then shows at its next start, and a tip says so.
@MainActor
enum FinderDesktopIcons {
    private nonisolated static let key = "CreateDesktop", domain = DesktopIcons.finder

    /// Whether Finder draws the desktop's icons: CreateDesktop unset or true, read now (a call to cfprefsd).
    nonisolated static var shown: Bool { shown(CFPreferencesCopyAppValue(key as CFString, domain as CFString)) }

    /// CreateDesktop as `defaults write` leaves it: a boolean, a number, or the text "false" from a write without -bool.
    nonisolated static func shown(_ value: Any?) -> Bool {
        switch value {
        case let on as Bool: on
        case let text as String: !["false", "no", "0"].contains(text.lowercased())
        default: true
        }
    }

    /// Flips the icons: the preference written, then Finder started again so it draws them, or leaves them off.
    static func toggle() {
        let show = !shown
        CFPreferencesSetAppValue(key as CFString, show as CFBoolean, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
        slog.notice("desktop icons: CreateDesktop \(show ? "on" : "off", privacy: .public), restarting Finder")
        Task {
            let restarted = await restartFinder()
            HUD.tip(restarted ? (show ? "Desktop icons are back." : "Desktop icons are hidden.")
                              : "Finder did not quit, so the desktop icons change when it next starts.")
        }
    }

    /// Asks Finder to quit, waits up to 5 s for it, then opens it again in the background; false when it stayed.
    private static func restartFinder() async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: DesktopIcons.finder)
        for finder in running {
            finder.terminate()
            for _ in 0..<50 where !finder.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard running.allSatisfy(\.isTerminated) else {
            slog.notice("desktop icons: Finder did not quit within 5 s; left running")
            return false
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DesktopIcons.finder) else { return false }
        let start = NSWorkspace.OpenConfiguration()
        start.activates = false
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: start) } catch {
            slog.error("desktop icons: Finder not opened again: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
}
