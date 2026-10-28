// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/Workspace.swift
import AppKit

@MainActor private var workspaceNameToWorkspace: [String: Workspace] = [:]

@MainActor private var screenPointToPrevVisibleWorkspace: [CGPoint: String] = [:]
@MainActor private var screenPointToVisibleWorkspace: [CGPoint: Workspace] = [:]
@MainActor private var visibleWorkspaceToScreenPoint: [Workspace: CGPoint] = [:]

// The returned workspace must be invisible and it must belong to the requested monitor
@MainActor func getStubWorkspace(for monitor: MonitorInfo) -> Workspace {
    getStubWorkspace(forPoint: monitor.rect.topLeftCorner)
}

@MainActor
private func getStubWorkspace(forPoint point: CGPoint) -> Workspace {
    if let prev = screenPointToPrevVisibleWorkspace[point].map({ Workspace.get(byName: $0) }),
       !prev.isVisible && prev.workspaceMonitor.rect.topLeftCorner == point && prev.forceAssignedMonitor == nil
    {
        return prev
    }
    if let candidate = Workspace.all
        .first(where: { !$0.isVisible && $0.workspaceMonitor.rect.topLeftCorner == point })
    {
        return candidate
    }
    // Pilot: a loop over the names "1", "2", … instead of `first` over an endless range, which had to unwrap through a fault
    var number = 1
    while true {
        let workspace = Workspace.get(byName: String(number))
        if workspace.isEffectivelyEmpty && !workspace.isVisible && !config.persistentWorkspaces.contains(workspace.name) &&
            workspace.forceAssignedMonitor == nil
        {
            return workspace
        }
        number += 1
    }
}

final class Workspace: TreeNode, NonLeafTreeNodeObject, Hashable, Comparable {
    let name: String
    nonisolated private let nameLogicalSegments: StringLogicalSegments
    /// `assignedMonitorPoint` must be interpreted only when the workspace is invisible
    fileprivate var assignedMonitorPoint: CGPoint? = nil

    @MainActor
    private init(_ name: String) {
        self.name = name
        self.nameLogicalSegments = name.toLogicalSegments()
        super.init()
    }

    @MainActor static var all: [Workspace] {
        workspaceNameToWorkspace.values.sorted()
    }

    @MainActor static func existing(byName name: String) -> Workspace? { workspaceNameToWorkspace[name] } // Pilot

    @MainActor static func get(byName name: String) -> Workspace {
        if let existing = workspaceNameToWorkspace[name] {
            return existing
        } else {
            let workspace = Workspace(name)
            workspaceNameToWorkspace[name] = workspace
            return workspace
        }
    }

    nonisolated static func < (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.nameLogicalSegments < rhs.nameLogicalSegments
    }

    override func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        workspaceMonitor.visibleRectPaddedByOuterGaps.getDimension(targetOrientation)
    }

    override func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) throws {
        try raiseFault("It's not possible to change weight of Workspace")
    }

    @MainActor
    var description: String {
        let description = [
            ("name", name),
            ("isVisible", String(isVisible)),
            ("isEffectivelyEmpty", String(isEffectivelyEmpty)),
            ("doKeepAlive", String(config.persistentWorkspaces.contains(name))),
        ].map { "\($0.0): \(String(describing: $0.1).singleQuoted)" }.joined(separator: ", ")
        return "Workspace(\(description))"
    }

    @MainActor
    static func garbageCollectUnusedWorkspaces() {
        for name in config.persistentWorkspaces {
            _ = get(byName: name) // Make sure that all persistent workspaces are "cached"
        }
        workspaceNameToWorkspace = workspaceNameToWorkspace.filter { (_, workspace: Workspace) in
            config.persistentWorkspaces.contains(workspace.name) ||
                !workspace.isEffectivelyEmpty ||
                workspace.isVisible ||
                workspace.name == focus.workspace.name
        }
    }

    nonisolated static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        checkSoft((lhs === rhs) == (lhs.name == rhs.name), "lhs: \(lhs) rhs: \(rhs)")
        return lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

extension Workspace {
    @MainActor
    var isVisible: Bool { visibleWorkspaceToScreenPoint.keys.contains(self) }
    @MainActor
    var workspaceMonitor: MonitorInfo {
        forceAssignedMonitor
            ?? visibleWorkspaceToScreenPoint[self]?.monitorApproximation
            ?? assignedMonitorPoint?.monitorApproximation
            ?? mainMonitorInfo
    }
}

extension MonitorInfo {
    @MainActor
    var activeWorkspace: Workspace {
        if let existing = screenPointToVisibleWorkspace[rect.topLeftCorner] {
            return existing
        }
        // What if monitor configuration changed? (frame.origin is changed)
        rearrangeWorkspacesOnMonitors()
        // Pilot: AeroSpace recursed here, and died in rearrange when no stub fitted (#506); a miss is now a reported
        // fault and a stub that is not cached, and the next call rearranges again.
        if let existing = screenPointToVisibleWorkspace[rect.topLeftCorner] {
            return existing
        }
        checkSoft(false, "No visible workspace for the monitor at \(rect.topLeftCorner) after rearranging")
        return getStubWorkspace(for: self)
    }

    @MainActor
    func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        rect.topLeftCorner.setActiveWorkspace(workspace)
    }
}

/// Pilot (live bug 2026-10-15): a display that went took its workspace out of view and the focus with it, so a new window
/// registered on that hidden workspace; the focus moves to the workspace the nearest display now shows.
@MainActor
func gcMonitors() {
    if screenPointToVisibleWorkspace.count != monitorInfos.count {
        let gained = windowsGainedWhileTheirDisplayWasAway()
        rearrangeWorkspacesOnMonitors()
        keepOnMain(gained)
        if !focus.workspace.isVisible { _ = focus.workspace.workspaceMonitor.activeWorkspace.focusWorkspace() }
    }
}

/// Pilot (live bug, Sven 2026-10-19): a workspace pinned to a display that went stands in on main (TilerSettings.monitors),
/// and the windows it gains there are main's. Its windows as its display went, by workspace, until the display returns.
@MainActor private var windowsAsTheirDisplayWent: [String: Set<UInt32>] = [:]

/// The windows each pinned workspace gained since its display went, for the ones whose display is back; only the
/// windows it took away go back with it.
@MainActor
private func windowsGainedWhileTheirDisplayWasAway() -> [Window] {
    let monitors = sortedMonitorInfos
    var gained: [Window] = []
    for name in Set(Workspace.all.map(\.name)).union(windowsAsTheirDisplayWent.keys) {
        guard let display = config.workspaceToMonitorForceAssignment[name]?.first, display != .main else {
            windowsAsTheirDisplayWent[name] = nil
            continue
        }
        let windows = Workspace.existing(byName: name)?.allLeafWindowsRecursive ?? []
        if display.resolveMonitor(sortedMonitors: monitors) == nil {
            if windowsAsTheirDisplayWent[name] == nil { windowsAsTheirDisplayWent[name] = Set(windows.map(\.windowId)) }
        } else if let took = windowsAsTheirDisplayWent.removeValue(forKey: name) {
            gained += windows.filter { !took.contains($0.windowId) && ($0.parent is TilingContainer || $0.parent is FloatingWindowsContainer) }
        }
    }
    return gained
}

/// The windows gained on main join the workspace main shows now; the focus stays with the one it was on.
@MainActor
private func keepOnMain(_ windows: [Window]) {
    if windows.isEmpty { return }
    let main = mainMonitorInfo.activeWorkspace
    let focused = focus.windowOrNil
    do {
        for window in windows { try window.moveToWorkspace(main) }
        if let focused, windows.contains(focused) { _ = try focused.focusWindow() }
        tilerLog.notice("display back: windows \(windows.map { String($0.windowId) }.joined(separator: ", "), privacy: .public) stay on main, workspace \(main.name, privacy: .public)")
    } catch {
        checkSoft(false, "Keeping the windows gained on main there: \(error)")
    }
}

extension CGPoint {
    @MainActor
    fileprivate func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        if !isValidAssignment(workspace: workspace, screen: self) {
            return false
        }
        if let prevMonitorPoint = visibleWorkspaceToScreenPoint[workspace] {
            visibleWorkspaceToScreenPoint.removeValue(forKey: workspace)
            screenPointToPrevVisibleWorkspace[prevMonitorPoint] =
                screenPointToVisibleWorkspace.removeValue(forKey: prevMonitorPoint)?.name
        }
        if let prevWorkspace = screenPointToVisibleWorkspace[self] {
            screenPointToPrevVisibleWorkspace[self] =
                screenPointToVisibleWorkspace.removeValue(forKey: self)?.name
            visibleWorkspaceToScreenPoint.removeValue(forKey: prevWorkspace)
        }
        visibleWorkspaceToScreenPoint[workspace] = self
        screenPointToVisibleWorkspace[self] = workspace
        workspace.assignedMonitorPoint = self
        return true
    }
}

@MainActor
private func rearrangeWorkspacesOnMonitors() {
    let newScreens = monitorInfos.map(\.rect.topLeftCorner)
    var newScreenToOldScreenMapping: [CGPoint: CGPoint] = [:]
    for (oldScreen, _) in screenPointToVisibleWorkspace {
        guard let newScreen = newScreens.minBy({ ($0 - oldScreen).vectorLength }) else { continue }
        if let prevOldScreen = newScreenToOldScreenMapping[newScreen] {
            if (prevOldScreen - newScreen).vectorLength <= (oldScreen - newScreen).vectorLength {
                // newScreen has already been assigned to a closer oldScreen.
                continue
            }
        }
        newScreenToOldScreenMapping[newScreen] = oldScreen
    }

    let oldScreenPointToVisibleWorkspace = screenPointToVisibleWorkspace
    screenPointToVisibleWorkspace = [:]
    visibleWorkspaceToScreenPoint = [:]

    for newScreen in newScreens {
        if let existingVisibleWorkspace = newScreenToOldScreenMapping[newScreen].flatMap({ oldScreenPointToVisibleWorkspace[$0] }),
           newScreen.setActiveWorkspace(existingVisibleWorkspace)
        {
            continue
        }
        let stubWorkspace = getStubWorkspace(forPoint: newScreen)
        checkSoft(newScreen.setActiveWorkspace(stubWorkspace),
              "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(newScreen)")
    }
}

/// Pilot: the pins changed (N7). A shown workspace pinned to another monitor moves there, and the monitor it leaves
/// shows another, as after a display change.
@MainActor
func showPinnedWorkspacesOnTheirMonitors() {
    let moved = visibleWorkspaceToScreenPoint.filter { !isValidAssignment(workspace: $0.key, screen: $0.value) }.keys
    if moved.isEmpty { return }
    for workspace in moved.sorted() { _ = workspace.workspaceMonitor.setActiveWorkspace(workspace) }
    rearrangeWorkspacesOnMonitors()
}

@MainActor
private func isValidAssignment(workspace: Workspace, screen: CGPoint) -> Bool {
    switch workspace.forceAssignedMonitor {
        case let forceAssigned? where forceAssigned.rect.topLeftCorner != screen: false
        default: true
    }
}
