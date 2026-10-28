import AppKit

// The list-windows and list-workspaces answers Pilot reads today (AeroWindow, AeroWorkspace in PilotCore), as values
// instead of `--format` JSON.

/// One window, with what `AeroWindow.format` asks for.
public struct TilerWindow: Equatable, Sendable {
    public let id: UInt32
    public let appName: String
    public let bundleId: String
    public let pid: Int32
    public let workspace: String
    public let monitorId: Int
    /// format.swift `toLayoutResult`: h_tiles, h_scrolling, floating, macos_native_fullscreen and so on.
    public let layout: String
    public let title: String
    /// A pinned pop-out (spec omarchy-ideas T1).
    public var pinned = false
}

/// A workspace with its monitor and root layout.
public struct TilerWorkspace: Equatable, Sendable {
    public let name: String
    public let monitorId: Int
    public let monitorName: String
    public let rootLayout: TilerLayout
    public var displayUUID: String? = nil
}

public enum TilerWindowScope: Equatable, Sendable {
    case all, focused, workspace(String)
}

/// ListWindowsCommand.swift.
@MainActor
func listWindows(_ scope: TilerWindowScope) async throws -> [TilerWindow] {
    let windows: [Window] = switch scope {
        case .all: Workspace.all.flatMap(\.allLeafWindowsRecursive)
        case .focused: focus.windowOrNil.asList()
        case .workspace(let name): Workspace.get(byName: name).allLeafWindowsRecursive
    }
    var monitorIds: [Workspace: Int] = [:] // the monitor sort runs once per workspace, not per window
    func monitorId(of workspace: Workspace?) -> Int {
        guard let workspace else { return 0 }
        if let id = monitorIds[workspace] { return id }
        let id = workspace.workspaceMonitor.monitorId_oneBased ?? 0
        monitorIds[workspace] = id
        return id
    }
    var result: [TilerWindow] = []
    for window in windows {
        let workspace = window.nodeWorkspace
        result.append(TilerWindow(
            id: window.windowId,
            appName: window.app.name ?? "",
            bundleId: window.app.rawAppBundleId ?? "",
            pid: window.app.pid,
            workspace: workspace?.name ?? "",
            monitorId: monitorId(of: workspace),
            layout: try layoutDescription(of: window),
            title: try await window.getTitle(.cancellable),
            pinned: window.isPinned,
        ))
    }
    return result
}

/// ListWorkspacesCommand.swift, `--monitor all --visible`.
@MainActor
func visibleWorkspaces() throws -> [TilerWorkspace] {
    try sortedMonitorInfos.map { try $0.activeWorkspace.info() }
}

/// `list-workspaces --focused`.
@MainActor
func focusedWorkspace() throws -> TilerWorkspace {
    try focus.workspace.info()
}

/// `list-workspaces --monitor mouse --visible`: where a dragged window was released.
@MainActor
func mouseWorkspace() throws -> TilerWorkspace {
    try mouseLocation.monitorApproximation.activeWorkspace.info()
}

extension Workspace {
    @MainActor fileprivate func info() throws -> TilerWorkspace {
        let monitor = workspaceMonitor
        // The snapshot's native screen index is distinct from the tiler's sorted monitor number. Refuse stale
        // snapshots rather than borrowing a same-named monitor's UUID; never cache identity by the numeric handle.
        let screen = NSScreen.screens.enumerated().first {
            $0.offset + 1 == monitor.monitorAppKitNsScreenScreensId && $0.element.localizedName == monitor.name
                && $0.element.frame.monitorFrameNormalized() == monitor.rect
        }?.element
        let uuid = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
        return TilerWorkspace(
            name: name,
            monitorId: monitor.monitorId_oneBased ?? 0,
            monitorName: monitor.name,
            rootLayout: try TilerLayout(rootTilingContainer),
            displayUUID: uuid,
        )
    }
}

@MainActor
private func layoutDescription(of window: Window) throws -> String {
    guard let parent = window.parent else { return "NULL-PARENT" }
    return switch try getChildParentRelation(child: window, parent: parent) {
        case .tiling(let container): TilerLayout(container).rawValue
        case .floatingWindow: "floating"
        case .macosNativeFullscreenWindow: "macos_native_fullscreen"
        case .macosNativeHiddenAppWindow: "macos_native_window_of_hidden_app"
        case .macosNativeMinimizedWindow: "macos_native_minimized"
        case .macosPopupWindow: "NULL-WINDOW-LAYOUT"
        case .rootTilingContainer, .shimContainerRelation: try raiseFaultT("A window as \(parent)'s container")
    }
}
