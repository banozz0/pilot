import AppKit

// Typed calls in place of AeroSpace's command layer, continued (see WindowCalls.swift): the workspace, monitor and
// focus-wide commands Pilot sends today, each the body of its AeroSpace 74a1bf17 `command/impl/` file.

/// LayoutCmdArgs.LayoutDescription, the tiling part: what `layout --root` and Pilot's snapshots name. Scrolling is one
/// horizontal strip and a stage one row (ADR 0015), so neither has a `v_` form.
public enum TilerLayout: String, CaseIterable, Sendable {
    case tiles, scrolling, stage, horizontal, vertical
    case h_tiles, v_tiles, h_scrolling, h_stage

    /// The layout and orientation this description names; nil for the part it leaves out. Scrolling and stage are always `.h`.
    private var parts: (layout: Layout?, orientation: Orientation?) {
        switch self {
            case .tiles: (.tiles, nil)
            case .scrolling, .h_scrolling: (.scrolling, .h)
            case .stage, .h_stage: (.stage, .h)
            case .horizontal: (nil, .h)
            case .vertical: (nil, .v)
            case .h_tiles: (.tiles, .h)
            case .v_tiles: (.tiles, .v)
        }
    }

    @MainActor fileprivate func matches(_ container: TilingContainer) -> Bool {
        let (layout, orientation) = parts
        return (layout ?? container.layout) == container.layout && (orientation ?? container.orientation) == container.orientation
    }

    /// LayoutCommand.swift `changeTilingLayout`: the parts this description leaves out stay as they are. A scrolling
    /// strip and a stage stay horizontal: an orientation alone leaves them be.
    @MainActor fileprivate func apply(to container: TilingContainer) {
        let (layout, orientation) = parts
        container.layout = layout ?? container.layout
        container.changeOrientation(container.layout.isRow ? .h : orientation ?? container.orientation)
    }

    /// format.swift `toLayoutString`.
    @MainActor init(_ container: TilingContainer) {
        self = switch (container.layout, container.orientation) {
            case (.tiles, .h): .h_tiles
            case (.tiles, .v): .v_tiles
            case (.scrolling, _): .h_scrolling
            case (.stage, _): .h_stage
        }
    }
}

extension Workspace {
    /// LayoutCommand.swift, `layout --root <first> <second> …`: the first description the root does not match yet,
    /// so `[.tiles, .scrolling]` toggles between them; false when every one already matches.
    @MainActor @discardableResult
    func setRootLayout(toggling layouts: [TilerLayout]) throws -> Bool {
        let root = try rootTilingContainer
        guard let target = layouts.first(where: { !$0.matches(root) }) else { return false }
        target.apply(to: root)
        return true
    }

    /// BalanceSizesCommand.swift: every tile under the root back to equal weight.
    @MainActor
    func balanceSizes() throws {
        try balance(rootTilingContainer)
    }

    /// FlattenWorkspaceTreeCommand.swift: every tiled window straight under the root, in tree order.
    @MainActor
    func flatten() throws {
        let root = try rootTilingContainer
        for window in root.allLeafWindowsRecursive {
            try window.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
    }

    /// FocusCommand.swift, `focus dfs-next|dfs-prev --boundaries-action wrap-around-the-workspace`: the tiled window
    /// after (or before) `current` in tree order, wrapping; false on a workspace without it.
    @MainActor @discardableResult
    func focusRing(from current: Window?, next: Bool) throws -> Bool {
        let windows = try rootTilingContainer.allLeafWindowsRecursive
        guard let currentIndex = windows.firstIndex(where: { $0 == current }) else { return false }
        let targetIndex = ((currentIndex + (next ? 1 : -1)) + windows.count) % windows.count
        return try windows[targetIndex].focusWindow()
    }

    /// CloseAllWindowsButCurrentCommand.swift: every other window of the workspace closes.
    @MainActor
    func closeAll(but kept: Window) throws {
        for window in allLeafWindowsRecursive where window != kept {
            try window.closeAxWindow()
        }
    }
}

@MainActor
private func balance(_ parent: TilingContainer) throws {
    for child in parent.children {
        if parent.layout == .tiles { try child.setWeight(parent.orientation, 1) }
        if let child = child as? TilingContainer { try balance(child) }
    }
}

/// WorkspaceCommand.swift, `workspace <name>`: false when it is already focused.
@MainActor @discardableResult
func focusWorkspace(named name: String) -> Bool {
    if focus.workspace.name == name { return false }
    return Workspace.get(byName: name).focusWorkspace()
}

/// WorkspaceCommand.swift `getNextPrevWorkspace`, `workspace --wrap-around next|prev`: the next workspace on the
/// focused workspace's monitor, in name order.
@MainActor @discardableResult
func focusNextWorkspace(_ next: Bool) -> Bool {
    let current = focus.workspace
    let monitorCorner = current.workspaceMonitor.rect.topLeftCorner
    // Workspace.all is sorted and holds the focused workspace already
    let workspaces = Workspace.all.filter { $0 == current || $0.workspaceMonitor.rect.topLeftCorner == monitorCorner }
    let index = workspaces.firstIndex(of: current).map { next ? $0 + 1 : $0 - 1 } ?? 0
    guard let target = workspaces.get(wrappingIndex: index), target != current else { return false }
    return target.focusWorkspace()
}

/// WorkspaceBackAndForthCommand.swift.
@MainActor @discardableResult
func focusPreviousWorkspace() -> Bool {
    prevFocusedWorkspace?.focusWorkspace() ?? false
}

/// FocusMonitorCommand.swift, `focus-monitor --wrap-around <direction>`.
@MainActor @discardableResult
func focusMonitor(_ direction: CardinalDirection) -> Bool {
    guard let target = focus.workspace.workspaceMonitor.monitor(inDirection: direction) else { return false }
    return target.activeWorkspace.focusWorkspace()
}

extension Window {
    /// Pilot's pop-out pin (spec omarchy-ideas T1): on floats the window and pins it; off unpins it and tiles it on the
    /// workspace it is on, the one you are looking at. False when the window cannot float or tile (setLayout's refusals).
    @MainActor
    func setPinned(_ on: Bool) async throws -> Bool {
        if on {
            guard try await setLayout(.floating) else { return false }
            isPinned = true
            return true
        }
        isPinned = false
        return try await setLayout(.tiling)
    }
}

/// Each pinned window on a workspace its monitor no longer shows goes to the one it shows now, into its floating layer:
/// the layout pass runs this before it parks hidden workspaces, so a pinned window is never parked. A pinned window
/// found tiled (put back in the tiles by another key) loses its pin; one macOS holds (minimized, fullscreen,
/// hidden app) keeps it and waits. A bind marks the window most recent, so the target's own most recent window is
/// marked again after it: closing a tile focuses the next tile, never the pinned window. The windows carried, which
/// layout raises.
@MainActor
func carryPinnedWindows() throws -> [Window] {
    var carried: [Window] = []
    for workspace in Workspace.all {
        for window in workspace.allLeafWindowsRecursive where window.isPinned {
            switch try window.windowParentCases {
                case .floatingWindowsContainer:
                    if workspace.isVisible { continue }
                    let target = workspace.workspaceMonitor.activeWorkspace
                    let mostRecent = target.mostRecentWindowRecursive
                    try window.bindAsFloatingWindow(to: target)
                    if let mostRecent, mostRecent != window { mostRecent.markAsMostRecentChild() }
                    carried.append(window)
                case .tilingContainer: window.isPinned = false
                case .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosMinimizedWindowsContainer,
                     .macosPopupWindowsContainer, .unbound: break
            }
        }
    }
    return carried
}

/// EnableCommand.swift: on, floating windows keep their size for later; off, the engine leaves every window alone and
/// the next refresh unhides every parked one (refresh.swift `layoutWorkspaces`).
@MainActor
func setTilerEnabled(_ on: Bool) async {
    if on == isTilerEnabled { return }
    if on {
        for workspace in Workspace.all {
            for window in workspace.allLeafWindowsRecursive where (try? window.isFloating) == true {
                await window.rememberFloatingSize()
            }
        }
    }
    isTilerEnabled = on
    if !on { gapDrag = nil } // Pilot: a gap held as tiling stops is let go (card agent-bo-95423035)
}

extension MonitorInfo {
    /// FocusMonitorCommand.swift `MonitorTarget.resolve` for a direction, with `--wrap-around` (all Pilot sends).
    @MainActor
    func monitor(inDirection direction: CardinalDirection) -> MonitorInfo? {
        let monitors = sortedMonitorInfos.filter {
            rect.topLeftCorner == $0.rect.topLeftCorner || $0.relation(to: self) == direction.orientation
        }
        guard let current = monitors.firstIndex(where: { $0.rect.topLeftCorner == rect.topLeftCorner }) else { return nil }
        let index = current + direction.focusOffset
        return monitors.get(wrappingIndex: index)
    }

    /// FocusMonitorCommand.swift: monitors side by side share some height.
    func relation(to monitor: MonitorInfo) -> Orientation {
        guard let otherYRange = monitor.rect.minY.until(excl: monitor.rect.maxY) else { return .h }
        guard let myYRange = rect.minY.until(excl: rect.maxY) else { return .h }
        return myYRange.overlaps(otherYRange) ? .h : .v
    }
}
