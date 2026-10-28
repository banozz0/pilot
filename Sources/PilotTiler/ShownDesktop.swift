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
/// desktop, keeps it, and so does Cmd+Tab back to the app in front at the press.
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
