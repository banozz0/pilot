// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/frozen/closedWindowsCache.swift
import AppKit

/// First line of defence against lock screen
///
/// When you lock the screen, all accessibility API becomes unobservable (all attributes become empty, window id
/// becomes nil, etc.) which tricks AeroSpace into thinking that all windows were closed.
/// That's why every time a window dies AeroSpace caches the "entire world" (unless window is already presented in the cache)
/// so that once the screen is unlocked, AeroSpace could restore windows to where they were
@MainActor private var closedWindowsCache = FrozenWorld(workspaces: [], monitors: [], windowIds: [])

struct FrozenMonitor: Sendable {
    let topLeftCorner: CGPoint
    let visibleWorkspace: String

    @MainActor init(_ monitor: MonitorInfo) {
        topLeftCorner = monitor.rect.topLeftCorner
        visibleWorkspace = monitor.activeWorkspace.name
    }
}

struct FrozenWorkspace: Sendable {
    let name: String
    let monitor: FrozenMonitor // todo drop this property, once monitor to workspace assignment migrates to TreeNode
    let rootTilingNode: FrozenContainer
    let floatingWindows: [FrozenWindow]
    let macosUnconventionalWindows: [FrozenWindow]

    @MainActor init(_ workspace: Workspace) throws {
        name = workspace.name
        monitor = FrozenMonitor(workspace.workspaceMonitor)
        rootTilingNode = try FrozenContainer(try workspace.rootTilingContainer)
        floatingWindows = try workspace.floatingWindows.map(FrozenWindow.init)
        macosUnconventionalWindows =
            try (workspace.macOsNativeHiddenAppsWindowsContainer.children + workspace.macOsNativeFullscreenWindowsContainer.children)
                .map { try FrozenWindow(($0 as? Window).orFault("\($0) in a window container")) }
    }
}

@MainActor func clearClosedWindowsCache() {
    closedWindowsCache = FrozenWorld(workspaces: [], monitors: [], windowIds: [])
}

@MainActor func cacheClosedWindowIfNeeded() throws {
    let allWs = Workspace.all
    let allWindowIds = allWs.flatMap { collectAllWindowIdsRecursive($0) }.toSet()
    if allWindowIds.isSubset(of: closedWindowsCache.windowIds) {
        return // already cached
    }
    closedWindowsCache = FrozenWorld(
        workspaces: try allWs.map { try FrozenWorkspace($0) },
        monitors: monitorInfos.map(FrozenMonitor.init),
        windowIds: allWindowIds,
    )
}

@MainActor func restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: Window) async throws -> Bool {
    if !closedWindowsCache.windowIds.contains(newlyDetectedWindow.windowId) {
        return false
    }
    let monitors = monitorInfos
    let topLeftCornerToMonitor = monitors.grouped { $0.rect.topLeftCorner }

    for frozenWorkspace in closedWindowsCache.workspaces {
        let workspace = Workspace.get(byName: frozenWorkspace.name)
        _ = topLeftCornerToMonitor[frozenWorkspace.monitor.topLeftCorner]?
            .singleOrNil()?
            .setActiveWorkspace(workspace)
        for frozenWindow in frozenWorkspace.floatingWindows {
            try MacWindow.get(byId: frozenWindow.id)?.bindAsFloatingWindow(to: workspace)
        }
        for frozenWindow in frozenWorkspace.macosUnconventionalWindows { // Will get fixed by normalizations
            try MacWindow.get(byId: frozenWindow.id)?.bindAsFloatingWindow(to: workspace)
        }
        let prevRoot = try workspace.rootTilingContainer // Save prevRoot into a variable to avoid it being garbage collected earlier than needed
        let potentialOrphans = prevRoot.allLeafWindowsRecursive
        try prevRoot.unbindFromParent()
        try restoreTreeRecursive(frozenContainer: frozenWorkspace.rootTilingNode, parent: workspace, index: INDEX_BIND_LAST)
        for window in try (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
            try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
        }
    }

    for monitor in closedWindowsCache.monitors {
        _ = topLeftCornerToMonitor[monitor.topLeftCorner]?
            .singleOrNil()?
            .setActiveWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }
    return true
}

@discardableResult
@MainActor
private func restoreTreeRecursive(frozenContainer: FrozenContainer, parent: NonLeafTreeNodeObject, index: Int) throws -> Bool {
    let container = try TilingContainer(
        parent: parent,
        adaptiveWeight: frozenContainer.weight,
        frozenContainer.orientation,
        frozenContainer.layout,
        index: index,
    )

    for (index, child) in frozenContainer.children.enumerated() {
        switch child {
            case .window(let w):
                // Stop the loop if can't find the window, because otherwise all the subsequent windows will have incorrect index
                guard let window = MacWindow.get(byId: w.id) else { return false }
                try window.bind(to: container, adaptiveWeight: w.weight, index: index)
            case .container(let c):
                // There is no reason to continue
                if try !restoreTreeRecursive(frozenContainer: c, parent: container, index: index) { return false }
        }
    }
    return true
}

// Consider the following case:
// 1. Close window
// 2. The previous step lead to caching the whole world
// 3. Change something in the layout
// 4. Lock the screen
// 5. The cache won't be updated because all alive windows are already cached
// 6. Unlock the screen
// 7. The wrong cache is used
//
// That's why we have to reset the cache every time layout changes. The layout can only be changed by running commands
// and with mouse manipulations
@MainActor func resetClosedWindowsCache() {
    closedWindowsCache = FrozenWorld(workspaces: [], monitors: [], windowIds: [])
}
