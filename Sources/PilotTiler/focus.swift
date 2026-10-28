// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/focus.swift
import AppKit

/// This object should be only passed around but never memorized
/// Alternative name: ResolvedFocus
struct LiveFocus: AeroAny, Equatable {
    let windowOrNil: Window?
    var workspace: Workspace

    @MainActor fileprivate var frozen: FrozenFocus {
        return FrozenFocus(
            windowId: windowOrNil?.windowId,
            workspaceName: workspace.name,
            monitorId_oneBased: workspace.workspaceMonitor.monitorId_oneBased ?? 0,
        )
    }
}

/// "old", "captured", "frozen in time" Focus
/// It's safe to keep a hard reference to this object.
/// Unlike in LiveFocus, information inside FrozenFocus isn't guaranteed to be self-consistent.
/// window - workspace - monitor relation could change since the moment object was created
private struct FrozenFocus: AeroAny, Equatable, Sendable {
    let windowId: UInt32?
    let workspaceName: String
    // monitorId is not part of the focus. We keep it here only for 'on-focused-monitor-changed' to work
    let monitorId_oneBased: Int

    @MainActor var live: LiveFocus { // Important: don't access focus.monitorId here. monitorId is not part of the focus. Always prefer workspace
        let window: Window? = windowId.flatMap { Window.get(byId: $0) }
        let workspace = Workspace.get(byName: workspaceName)

        let workspaceFocus = workspace.toLiveFocus()
        // Pilot: a fault resolving the window's workspace (already reported) falls back to the workspace's focus
        let windowFocus = window.flatMap { try? $0.toLiveFocusOrNil() } ?? workspaceFocus

        return workspaceFocus.workspace != windowFocus.workspace
            ? workspaceFocus // If window and workspace become separated prefer workspace
            : windowFocus
    }
}

@MainActor private var _focus: FrozenFocus = {
    let monitor = mainMonitorInfo
    return FrozenFocus(windowId: nil, workspaceName: monitor.activeWorkspace.name, monitorId_oneBased: monitor.monitorId_oneBased ?? 0)
}()

/// Global focus.
/// Commands must be cautious about accessing this property directly. There are legitimate cases.
/// But, in general, commands must firstly check --window-id, --workspace, AEROSPACE_WINDOW_ID env and
/// AEROSPACE_WORKSPACE env before accessing the global focus.
@MainActor var focus: LiveFocus { _focus.live }

@MainActor func setFocus(to newFocus: LiveFocus) -> Bool {
    if _focus == newFocus.frozen { return true }
    let oldFocus = focus
    // Normalize mruWindow when focus away from a workspace
    if oldFocus.workspace != newFocus.workspace {
        oldFocus.windowOrNil?.markAsMostRecentChild()
    }

    _focus = newFocus.frozen
    let status = newFocus.workspace.workspaceMonitor.setActiveWorkspace(newFocus.workspace)

    newFocus.windowOrNil?.markAsMostRecentChild()
    return status
}
extension Window {
    @MainActor func focusWindow() throws -> Bool {
        if let focus = try toLiveFocusOrNil() {
            return setFocus(to: focus)
        } else {
            // todo We should also exit-native-hidden/unminimize[/exit-native-fullscreen?] window if we want to fix ID-B6E178F2
            //      and retry to focus the window. Otherwise, it's not possible to focus minimized/hidden windows
            return false
        }
    }

    @MainActor func toLiveFocusOrNil() throws -> LiveFocus? {
        guard let workspace = try visualWorkspace else { return nil }
        return LiveFocus(windowOrNil: self, workspace: workspace)
    }
}
extension Workspace {
    @MainActor func focusWorkspace() -> Bool { setFocus(to: toLiveFocus()) }

    func toLiveFocus() -> LiveFocus {
        // todo unfortunately mostRecentWindowRecursive may recursively reach empty rootTilingContainer
        //      while floating or macos unconventional windows might be presented
        if let wd = mostRecentWindowRecursive ?? anyLeafWindowRecursive {
            LiveFocus(windowOrNil: wd, workspace: self)
        } else {
            LiveFocus(windowOrNil: nil, workspace: self) // emptyWorkspace
        }
    }
}

@MainActor private var _lastKnownFocus: FrozenFocus = _focus

// Used by workspace-back-and-forth
@MainActor var _prevFocusedWorkspaceName: String? = nil {
    didSet {
        prevFocusedWorkspaceDate = .now
    }
}
@MainActor var prevFocusedWorkspaceDate: Date = .distantPast
@MainActor var prevFocusedWorkspace: Workspace? { _prevFocusedWorkspaceName.map { Workspace.get(byName: $0) } }

// Used by focus-back-and-forth
@MainActor private var _prevFocus: FrozenFocus? = nil
@MainActor var prevFocus: LiveFocus? { _prevFocus?.live.takeIf { $0 != focus } }

@MainActor private var onFocusChangedRecursionGuard = false
// Should be called in refreshSession
@MainActor func checkOnFocusChangedCallbacks_nonCancellable() async {
    if refreshSessionEvent?.isStartup == true {
        return
    }
    let focus = focus
    let frozenFocus = focus.frozen
    var hasFocusChanged = false
    var hasFocusedWorkspaceChanged = false
    var hasFocusedMonitorChanged = false
    if frozenFocus != _lastKnownFocus {
        _prevFocus = _lastKnownFocus
        hasFocusChanged = true
    }
    if frozenFocus.workspaceName != _lastKnownFocus.workspaceName {
        _prevFocusedWorkspaceName = _lastKnownFocus.workspaceName
        hasFocusedWorkspaceChanged = true
    }
    if frozenFocus.monitorId_oneBased != _lastKnownFocus.monitorId_oneBased {
        hasFocusedMonitorChanged = true
    }
    _lastKnownFocus = frozenFocus

    if onFocusChangedRecursionGuard { return }
    onFocusChangedRecursionGuard = true
    defer { onFocusChangedRecursionGuard = false }
    if hasFocusChanged {
        onFocusChanged(focus)
    }
    if let _prevFocusedWorkspaceName, hasFocusedWorkspaceChanged {
        onWorkspaceChanged(_prevFocusedWorkspaceName, frozenFocus.workspaceName)
    }
    if hasFocusedMonitorChanged {
        onFocusedMonitorChanged(focus)
    }
}

// Pilot: AeroSpace also ran the config's on-focus callbacks here; Pilot listens to the event stream instead.
@MainActor func onFocusedMonitorChanged(_ focus: LiveFocus) {
    broadcastEvent(.focusedMonitorChanged(
        workspace: focus.workspace.name,
        monitorId: focus.workspace.workspaceMonitor.monitorId_oneBased ?? 0,
    ))
}

@MainActor func onFocusChanged(_ focus: LiveFocus) {
    broadcastEvent(.focusChanged(
        windowId: focus.windowOrNil?.windowId,
        workspace: focus.workspace.name,
    ))
}

@MainActor private func onWorkspaceChanged(_ oldWorkspace: String, _ newWorkspace: String) {
    broadcastEvent(.workspaceChanged(
        workspace: newWorkspace,
        prevWorkspace: oldWorkspace,
    ))
}
