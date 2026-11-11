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

    /// Takes Pilot's block and include out of Ghostty's config, then reloads.
    static func remove(files: GhosttyFiles = .standard) {
        change("Pilot's look taken out") {
            guard ThemeCoordinator.legacyAllowed() else { throw ThemeFailure("Restore the active theme pack before changing legacy Ghostty appearance") }
            return try files.remove()
        }
    }

    /// One write, logged; a change reloads Ghostty.
    private static func change(_ what: String, _ write: () throws -> Bool) {
        do {
            guard try write() else { return looklog.notice("ghostty: \(what, privacy: .public), nothing to change") }
            looklog.notice("ghostty: \(what, privacy: .public) written")
            reload()
        } catch {
            looklog.error("ghostty: \(String(describing: error), privacy: .public)")
            HUD.tip("Ghostty's config was not changed: \(error)")
        }
    }

    /// A running Ghostty reloads through its menu; a stopped one reads the config at launch.
    static func reload() { DriveModule.pressMenu(bundle, reloadItem, quietWhenNotRunning: true) }

    /// A theme's Apply and Restore: Ghostty › Reload Configuration pressed now, through its menu (ADR 0001, never its
    /// key), off the main thread. Nil when Ghostty isn't running, since it reads its config at launch.
    static func reloadNow() async -> Bool? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else { return nil }
        let pid = app.processIdentifier, item = reloadItem
        let pressed = await Task.detached(priority: .userInitiated) { AXMenu.press(pid: pid, path: item) }.value
        looklog.notice("theme: Ghostty reload \(pressed ? "pressed" : "not found", privacy: .public)")
        return pressed
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

    /// Two keyless actions, in the menu's search and pilot://run: Pilot's look in Ghostty (the picked theme's Omarchy
    /// palette), and taking it out.
    /// They write files, so they run after the tap callback.
    static func register(into registry: inout ActionRegistry) {
        let actions: [(String, String, @MainActor () -> Void)] = [
            ("look.ghosttyApply", "Ghostty: use Pilot's look", {
                Look.shared.restyleGhostty()
            }),
            ("look.ghosttyRemove", "Ghostty: take Pilot's look out", { remove() }),
        ]
        for (id, label, run) in actions {
            do { try registry.register(Action(id: id, label: label, module: .system) { DispatchQueue.main.async { run() } }) }
            catch { looklog.error("\(id, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
    }
}
