import AppKit

/// Show desktop (Sven, 2026-10-26): the focused workspace's windows wait in its monitor's hide corner, as an unseen
/// workspace's do, and come back on the next press. Nothing leaves the tree, so every tile, floating place and the focus
/// return as they were; a minimise or an app hide would rebind each window at a new tree index.
struct ShownDesktop {
    let workspace: Workspace
    /// The window focused at the press: focus on another window of the workspace brings them all back.
    let focusedAtPress: Window?
}

@MainActor var shownDesktop: ShownDesktop? = nil

/// On: the focused workspace hides. Off: it lays out again, the window focused at the press focused once more.
@MainActor
func toggleShownDesktop() throws {
    if let shown = shownDesktop {
        shownDesktop = nil
        // Back in front too: a click on the desktop left Finder there.
        if let window = shown.focusedAtPress, window.nodeWorkspace === shown.workspace {
            _ = try window.focusWindow()
            window.nativeFocus()
        }
    } else {
        shownDesktop = ShownDesktop(workspace: focus.workspace, focusedAtPress: focus.windowOrNil)
    }
}

/// The workspace whose windows wait in the corner this pass, nil once it ended: its monitor shows another workspace,
/// or another of its windows took focus (a new window, Cmd+Tab to another app). Focus on no window, a click on the
/// desktop, keeps it, and so does Cmd+Tab back to the app in front at the press; a Dock click on that app ends it
/// (`endShownDesktopOnDockClick`).
@MainActor
func workspaceShowingDesktop() -> Workspace? {
    guard let shown = shownDesktop else { return nil }
    let focused = focus.windowOrNil
    if !shown.workspace.isVisible || (focused != nil && focused !== shown.focusedAtPress && focused?.nodeWorkspace === shown.workspace) {
        shownDesktop = nil
        return nil
    }
    return shown.workspace
}

/// The workspace Show desktop holds out now, by name, nil when it is off or that workspace is no longer shown: Pilot's
/// widgets show over it (Q592). A read only; the tiler's own refresh ends a stale one.
@MainActor
public func showDesktopWorkspace() -> String? {
    guard let shown = shownDesktop, shown.workspace.isVisible else { return nil }
    return shown.workspace.name
}

/// Pilot's widgets hear Show desktop end on a path that sends no focus event (a Pilot window raised, a Dock click).
@MainActor public var showDesktopEnded: @MainActor () -> Void = {}

/// Show desktop ends with no focus change: the workspace lays out again. True when it was on.
@MainActor @discardableResult
func endShownDesktop() -> Bool {
    guard shownDesktop != nil else { return false }
    shownDesktop = nil
    refreshOnWindowEvent(kAXWindowCreatedNotification)
    showDesktopEnded()
    return true
}

/// A click at `point` (top-left origin, as AX) on the Dock icon of an app with a window Show desktop holds brings them
/// all back. The app in front at the press is active already, so its icon activates nothing and no focus event ends
/// it (Sven on 1.0.2: the Dock icon left him on the desktop); after a click on the desktop the icon brings back the
/// window focused at the press, which `workspaceShowingDesktop` keeps it for.
@MainActor
func endShownDesktopOnDockClick(at point: CGPoint) async {
    guard let shown = shownDesktop, !ownWindowAt(point),
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return }
    // Off the main thread: a hung Dock waits out the AX timeout there, not in the key tap.
    guard let clicked = await Task.detached(operation: { dockAppPath(at: point, dock: dock) }).value,
          shownDesktop?.workspace === shown.workspace else { return }
    let held = Set(shown.workspace.allLeafWindowsRecursive.map(\.app.pid))
    if held.contains(where: { NSRunningApplication(processIdentifier: $0)?.bundleURL?.standardizedFileURL.path == clicked }) {
        endShownDesktop()
    }
}

/// Whether one of Pilot's windows is in front at `point` (top-left origin, as AX): a click there was on Pilot (the
/// capture overlay, its toolbar), never on the Dock.
@MainActor
private func ownWindowAt(_ point: CGPoint) -> Bool {
    let top = NSWindow.windowNumber(at: point.withYAxisFlipped, belowWindowWithWindowNumber: 0)
    return NSApp?.windows.contains { $0.windowNumber == top } == true
}

/// The bundle path of the app whose Dock icon is at `point`, nil off one (a folder, the Trash, a minimised window).
/// Asks the Dock itself, never the system-wide element: that hit-tests whatever window is in front, and when it is
/// Pilot's own, AppKit answers in-process on this thread, holding Accessibility's lock while it waits for SwiftUI's,
/// which the main thread holds as it asks Accessibility: Pilot froze, and the key tap with it (T59, build 6).
nonisolated private func dockAppPath(at point: CGPoint, dock: pid_t) -> String? {
    var hit: AXUIElement?
    let app = AXUIElementCreateApplication(dock).withMessagingTimeout()
    guard unsafe AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
          let hit else { return nil }
    var subrole: CFTypeRef?, url: CFTypeRef?
    guard unsafe AXUIElementCopyAttributeValue(hit, kAXSubroleAttribute as CFString, &subrole) == .success,
          subrole as? String == kAXApplicationDockItemSubrole,
          unsafe AXUIElementCopyAttributeValue(hit, kAXURLAttribute as CFString, &url) == .success else { return nil }
    return (url as? URL)?.standardizedFileURL.path
}
