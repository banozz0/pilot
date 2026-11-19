import AppKit
import Foundation
import OSLog
import PilotCore

let looklog = Logger(subsystem: "dev.banozz.pilot", category: "look")

/// The Ghostty bridge (card agent-bo-95422790): Pilot's colours reach Ghostty through Pilot's own include and
/// one marked block in Ghostty's config (PilotCore's GhosttyFiles), and Ghostty reloads through its app menu's Reload
/// Configuration, pressed through Accessibility like any drive menu route; never its reload key (ADR 0001).
@MainActor
enum GhosttyBridge {
    static let bundle = "com.mitchellh.ghostty"
    static let reloadItem = ["Ghostty", "Reload Configuration"]

    /// Omarchy's palettes from the bundle.
    static let themes = BundledJSON.load("themes", log: looklog, empty: [OmarchyTheme]()) { try OmarchyThemes.parse($0) }

    /// Every running Ghostty reloads through its menu; a stopped one reads the config at launch.
    static func reload() { DriveModule.pressMenu(bundle, reloadItem, quietWhenNotRunning: true, every: true) }

    /// A theme's Apply and Restore: Ghostty › Reload Configuration pressed now in every running Ghostty (a second one
    /// from `open -na` too), through its menu (ADR 0001, never its key), off the main thread. True when any pressed;
    /// nil when none is running, since it reads its config at launch.
    static func reloadNow() async -> Bool? {
        let pids = running()
        guard !pids.isEmpty else { return nil }
        let item = reloadItem
        let pressed = await Task.detached(priority: .userInitiated) { pids.filter { AXMenu.press(pid: $0, path: item) }.count }.value
        looklog.notice("theme: Ghostty reload pressed in \(pressed, privacy: .public) of \(pids.count, privacy: .public)")
        return pressed > 0
    }
    /// Every running Ghostty's pid, each instance its own process.
    static func running() -> [pid_t] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundle }.map(\.processIdentifier)
    }

    /// Look's Ghostty write on a theme pick: the standard files, then a reload when they changed; errors go to the caller.
    struct Writer: GhosttyWriting {
        func apply(_ look: GhosttyLook) throws -> Bool {
            guard ThemeCoordinator.legacyAllowed() else { throw ThemeFailure("Restore the active theme pack before changing legacy Ghostty appearance") }
            let changed = try GhosttyFiles.standard.apply(look)
            if changed { reload() }
            return changed
        }
        var isApplied: Bool { GhosttyFiles.standard.isApplied }
    }
}
