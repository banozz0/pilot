import AppKit

// Typed calls in place of AeroSpace's command layer (code review, 2026-10-07): each one is the body of the
// command it names in AeroSpace 74a1bf17 `Sources/AppBundle/command/impl/`, without the argv parse or text output.

extension Window {
    /// MoveNodeToWorkspaceCommand.swift `moveWindowToWorkspace`: false when the window is already there.
    @MainActor @discardableResult
    func moveToWorkspace(_ target: Workspace, focusFollowsWindow: Bool = false, index: Int = INDEX_BIND_LAST) throws -> Bool {
        if nodeWorkspace == target { return false }
        let container: NonLeafTreeNodeObject = try isFloating ? target.floatingWindowsContainer : target.rootTilingContainer
        try bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: index)
        return focusFollowsWindow ? try focusWindow() : true
    }

    enum FloatingLayout { case floating, tiling }

    /// LayoutCommand.swift's `floating` and `tiling` cases: false for a window macOS holds (minimized, fullscreen,
    /// hidden app) or one with no workspace.
    @MainActor @discardableResult
    func setLayout(_ layout: FloatingLayout) async throws -> Bool {
        switch (layout, try windowParentCases) {
            case (.floating, .floatingWindowsContainer), (.tiling, .tilingContainer):
                return true // LayoutCommand.swift: "Already in the requested mode", the window stays where it is
            case (.floating, .tilingContainer):
                guard let workspace = nodeWorkspace else { return false }
                try bindAsFloatingWindow(to: workspace)
                if let size = lastFloatingSize { setAxFrame(nil, size) }
                return true
            case (.tiling, .floatingWindowsContainer(let container)):
                await rememberFloatingSize()
                guard let workspace = container.nodeWorkspace else { return false }
                return (try? await relayoutWindow(on: workspace, .nonCancellable, forceTile: true)) != nil
            default:
                return false
        }
    }

    /// LayoutCommand.swift and EnableCommand.swift: the size to give the window back when it floats again; kept as it
    /// was when AX does not answer.
    @MainActor
    func rememberFloatingSize() async {
        lastFloatingSize = (try? await getAxSize(.nonCancellable)) ?? lastFloatingSize
    }
}

extension Window {
    /// FocusCommand.swift, `focus <direction>` with the default boundaries (workspace, stop) and the default
    /// floating-as-tiling: the workspace's floating windows join the tree by their centres for the lookup, then go back.
    /// False when nothing lies that way.
    @MainActor @discardableResult
    func focusNeighbor(_ direction: CardinalDirection) async throws -> Bool {
        guard let workspace = try visualWorkspace else { return false }
        let floatingWindows = try await makeFloatingWindowsSeenAsTiling(workspace: workspace)
        let result = Result { () throws -> Bool in
            guard let target = try neighborLeaf(direction) else { return false }
            return try target.focusWindow()
        }
        try restoreFloatingWindows(floatingWindows, workspace: workspace)
        return try result.get()
    }

    /// JoinWithCommand.swift: the window and its neighbour that way share a new container of the opposite orientation.
    @MainActor @discardableResult
    func join(with direction: CardinalDirection) throws -> Bool {
        guard let (parent, joinWithTarget) = try neighbor(direction) else { return false }
        let prevBinding = try joinWithTarget.unbindFromParent()
        let newParent = try TilingContainer(
            parent: parent,
            adaptiveWeight: prevBinding.adaptiveWeight,
            parent.orientation.opposite,
            .tiles,
            index: prevBinding.index,
        )
        newParent.columnWidth = joinWithTarget.columnWidth // Pilot: on a scrolling strip the stack keeps the column's width
        try unbindFromParent()
        try joinWithTarget.bind(to: newParent, adaptiveWeight: WEIGHT_AUTO, index: 0)
        try bind(to: newParent, adaptiveWeight: WEIGHT_AUTO, index: direction.isPositive ? 0 : INDEX_BIND_LAST)
        return true
    }

    /// SwapCommand.swift, `swap <direction>` without wrap-around: false when nothing lies that way.
    @MainActor @discardableResult
    func swap(_ direction: CardinalDirection) throws -> Bool {
        guard let target = try neighborLeaf(direction) else { return false }
        try swapWindows(mruDominant: self, target)
        return true
    }

    /// FocusCommand, JoinWithCommand and SwapCommand: the node beside the window that way, in the closest parent that
    /// has one, and that parent.
    @MainActor
    private func neighbor(_ direction: CardinalDirection) throws -> (parent: TilingContainer, node: TreeNode)? {
        guard let (parent, ownIndex) = try closestParent(hasChildrenInDirection: direction, withLayout: nil) else { return nil }
        return (parent, parent.children[ownIndex + direction.focusOffset])
    }

    /// The window a move or focus that way lands on: the neighbour's leaf nearest this window.
    @MainActor
    private func neighborLeaf(_ direction: CardinalDirection) throws -> Window? {
        guard let (_, node) = try neighbor(direction) else { return nil }
        return try node.findLeafWindowRecursive(snappedTo: direction.opposite)
    }

    /// ResizeCommand.swift, `resize width|height ±step`: false for a window with no tiles parent of that orientation
    /// (a floating one, say). Pilot: on a scrolling strip width is the column's own, `step` points of the usable width
    /// plus a gap (Strip's rule), kept between a tenth and full.
    @MainActor @discardableResult
    func resize(_ orientation: Orientation, by step: CGFloat) throws -> Bool {
        if orientation == .h, let (_, column) = scrollingColumn, let monitor = nodeWorkspace?.workspaceMonitor {
            let gap = CGFloat(ResolvedGaps(gaps: config.gaps, monitor: monitor).inner.horizontal)
            let width = column.columnWidth ?? config.scrollingNewWidth
            let next = (width + step / (monitor.visibleRectPaddedByOuterGaps.width + gap)).coerce(in: 0.1 ... 1)
            guard next != width else { return false }
            column.columnWidth = next
            return true
        }
        guard let node = parentsWithSelf.first(where: {
            ($0.parent as? TilingContainer).map { $0.layout == .tiles && $0.orientation == orientation } == true
        }), let parent = node.parent as? TilingContainer else { return false }
        guard let childDiff = step.div(parent.children.count - 1) else { return false }
        for sibling in parent.children where sibling != node {
            try sibling.setWeight(parent.orientation, sibling.getWeight(parent.orientation) - childDiff)
        }
        try node.setWeight(orientation, node.getWeight(orientation) + step)
        return true
    }

    /// LayoutCommand.swift, `layout horizontal vertical`: the window's tiling parent turns to the other orientation. A
    /// scrolling workspace's strip stays horizontal and its stacks vertical, so nothing there flips; a stage's row stays
    /// a row, its joined groups flip.
    @MainActor @discardableResult
    func flipSplit() throws -> Bool {
        guard case .tilingContainer(let parent) = try windowParentCases, try nodeWorkspace?.rootTilingContainer.layout != .scrolling,
              parent.layout != .stage else { return false }
        parent.changeOrientation(parent.orientation.opposite)
        return true
    }

    /// MoveCommand.swift, `move <direction> --boundaries-action stop`: a step within the tree; at the workspace's edge
    /// nothing moves (true, as AeroSpace's stop answers).
    @MainActor @discardableResult
    func move(_ direction: CardinalDirection) throws -> Bool {
        guard case .tilingContainer(let parent) = try windowParentCases else { return false }
        guard let indexOfCurrent = try ownIndex else { return false }
        let indexOfSiblingTarget = indexOfCurrent + direction.focusOffset
        if parent.orientation == direction.orientation && parent.children.indices.contains(indexOfSiblingTarget) {
            switch try parent.children[indexOfSiblingTarget].tilingTreeNodeCasesOrDie() {
                case .tilingContainer(let sibling):
                    switch try sibling.tilingTreeNodeCasesOrDie().findDeepMoveInTargetRecursive(direction.orientation) {
                        case .tilingContainer(let deepTarget):
                            try bind(to: deepTarget, adaptiveWeight: WEIGHT_AUTO, index: 0)
                        case .window(let deepTarget):
                            guard let deepParent = deepTarget.parent as? TilingContainer, let deepIndex = try deepTarget.ownIndex else { return false }
                            try bind(to: deepParent, adaptiveWeight: WEIGHT_AUTO, index: deepIndex + 1)
                    }
                case .window:
                    let prevBinding = try unbindFromParent()
                    try bind(to: parent, adaptiveWeight: prevBinding.adaptiveWeight, index: indexOfSiblingTarget)
            }
            return true
        }
        // moveOut: into the nearest ancestor of that orientation, or stop at the workspace
        let innerMost = try parents.first(where: {
            switch try $0.parent?.cases {
                case .tilingContainer(let parent): parent.orientation == direction.orientation
                default: true
            }
        }) as? TilingContainer
        guard let innerMost else { return false }
        switch try innerMost.tilingContainerParentCases {
            case .tilingContainer(let ancestor):
                guard let ownIndex = try innerMost.ownIndex else { return false }
                try bind(to: ancestor, adaptiveWeight: WEIGHT_AUTO, index: ownIndex + direction.insertionOffset)
                return true
            case .workspace, .unbound:
                return true
        }
    }

    /// MoveNodeToMonitorCommand.swift, `move-node-to-monitor --wrap-around <direction>`: onto the active workspace of
    /// the next monitor that way.
    @MainActor @discardableResult
    func moveToMonitor(_ direction: CardinalDirection, focusFollowsWindow: Bool = true) throws -> Bool {
        guard let currentMonitor = try nodeMonitor,
              let targetMonitor = currentMonitor.monitor(inDirection: direction) else { return false }
        let targetWorkspace = targetMonitor.activeWorkspace
        let index = try direction.isPositive && targetWorkspace.rootTilingContainer.orientation == direction.orientation ? 0 : INDEX_BIND_LAST
        return try moveToWorkspace(targetWorkspace, focusFollowsWindow: focusFollowsWindow, index: index)
    }
}

extension TreeNode {
    /// FocusCommand.swift: the leaf a move or focus arriving from `direction`'s opposite side lands on.
    @MainActor
    func findLeafWindowRecursive(snappedTo direction: CardinalDirection) throws -> Window? {
        switch try nodeCases {
            case .workspace(let workspace):
                return try workspace.rootTilingContainer.findLeafWindowRecursive(snappedTo: direction)
            case .window(let window):
                return window
            case .tilingContainer(let container):
                if direction.orientation == container.orientation {
                    return try (direction.isPositive ? container.children.last : container.children.first)?
                        .findLeafWindowRecursive(snappedTo: direction)
                } else {
                    return try mostRecentChild?.findLeafWindowRecursive(snappedTo: direction)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer,
                 .floatingWindowsContainer:
                try raiseFault("Impossible")
        }
    }
}

extension TilingTreeNodeCases {
    /// MoveCommand.swift: where a window moving into a sibling container lands.
    @MainActor fileprivate func findDeepMoveInTargetRecursive(_ orientation: Orientation) throws -> TilingTreeNodeCases {
        switch self {
            case .window:
                self
            case .tilingContainer(let container) where container.orientation == orientation:
                .tilingContainer(container)
            case .tilingContainer(let container):
                try container.mostRecentChild.orFault("Empty containers must be detached during normalization")
                    .tilingTreeNodeCasesOrDie()
                    .findDeepMoveInTargetRecursive(orientation)
        }
    }
}

/// moveWithMouse.swift: the two windows trade places, weights and all.
@MainActor
func swapWindows(mruDominant window1: Window, _ window2: Window) throws {
    if window1 == window2 { return }
    let binding2 = try window2.unbindFromParent()
    let binding1 = try window1.unbindFromParent()
    try window2.bind(to: binding1.parent, adaptiveWeight: binding1.adaptiveWeight, index: binding1.index)
    try window1.bind(to: binding2.parent, adaptiveWeight: binding2.adaptiveWeight, index: binding2.index)
}

private struct FloatingWindowData {
    let window: Window
    let center: CGPoint
    let tilingParent: TilingContainer
    let adaptiveWeight: CGFloat
    let index: Int
}

/// FocusCommand.swift: each floating window is bound into the tiling tree beside the tile under its centre.
@MainActor
private func makeFloatingWindowsSeenAsTiling(workspace: Workspace) async throws -> [FloatingWindowData] {
    let mruBefore = workspace.mostRecentWindowRecursive
    defer { mruBefore?.markAsMostRecentChild() }
    var unsorted: [FloatingWindowData] = []
    for window in try workspace.floatingWindows {
        guard let center = try? await window.getCenter(.nonCancellable) else { continue }
        let tilingParent: TilingContainer
        let index: Int
        if let target = try center.coerce(in: workspace.workspaceMonitor.visibleRectPaddedByOuterGaps)?
            .findWindowRecursively(in: workspace.rootTilingContainer)
        {
            guard let targetCenter = try? await target.getCenter(.nonCancellable) else { continue }
            guard let parent = target.parent as? TilingContainer else { continue }
            tilingParent = parent
            let isAfter = center.getProjection(parent.orientation) >= targetCenter.getProjection(parent.orientation)
            let targetIndex = try target.ownIndex.orFault()
            index = isAfter ? targetIndex + 1 : targetIndex
        } else {
            index = 0
            tilingParent = try workspace.rootTilingContainer
        }
        let data = try window.unbindFromParent()
        unsorted.append(FloatingWindowData(
            window: window,
            center: center,
            tilingParent: tilingParent,
            adaptiveWeight: data.adaptiveWeight,
            index: index,
        ))
    }
    let floatingWindows: [FloatingWindowData] = unsorted.sortedBy { $0.center.getProjection($0.tilingParent.orientation) }.reversed()
    for floating in floatingWindows {
        try floating.window.bind(to: floating.tilingParent, adaptiveWeight: 1, index: floating.index)
    }
    return floatingWindows
}

@MainActor
private func restoreFloatingWindows(_ floatingWindows: [FloatingWindowData], workspace: Workspace) throws {
    let mruBefore = workspace.mostRecentWindowRecursive
    defer { mruBefore?.markAsMostRecentChild() }
    for floating in floatingWindows {
        try floating.window.bind(to: workspace.floatingWindowsContainer, adaptiveWeight: floating.adaptiveWeight, index: INDEX_BIND_LAST)
    }
}

extension CGPoint {
    /// moveWithMouse.swift `findWindowRecursively` with fullscreenCoversAll false: virtual rects for FocusCommand,
    /// physical ones for a drop. A hidden scrolling column was not laid out, so nothing finds it.
    @MainActor
    func findWindowRecursively(in tree: TilingContainer, virtual: Bool = true) throws -> Window? {
        let target = tree.children.first(where: { (virtual ? $0.lastAppliedLayoutVirtualRect : $0.lastAppliedLayoutPhysicalRect)?.contains(self) == true })
        guard let target else { return nil }
        return switch try target.tilingTreeNodeCasesOrDie() {
            case .window(let window): window
            case .tilingContainer(let container): try findWindowRecursively(in: container, virtual: virtual)
        }
    }
}
