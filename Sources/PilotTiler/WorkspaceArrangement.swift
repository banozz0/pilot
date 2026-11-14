import AppKit
import PilotCore

/// One workspace's arrangement as the engine keeps it (card agent-bo-95422997, AC3): Pilot's preset, built straight into
/// the tree where driving AeroSpace needed flatten, moves and joins, whether a window coming or going rebuilds it, and the order
/// its tiled windows read in.
public struct WorkspaceArrangement: Equatable, Sendable {
    var preset: LayoutPreset
    var auto: Bool
    var order: [UInt32]

    init(_ preset: LayoutPreset, auto: Bool, order: [UInt32]) {
        self.preset = preset
        self.auto = auto
        self.order = order
    }
}

/// Each workspace's arrangement by name; a workspace without one keeps whatever tree its commands made.
@MainActor var arrangements: [String: WorkspaceArrangement] = [:]

extension Workspace {
    /// Rebuilds the tiled windows as `preset`, in `order` (a window not in it follows in tree order), with equal sizes.
    /// Floating windows stay where they are.
    /// Keeps `kept` as this workspace's arrangement and builds it.
    @MainActor
    func arrange(_ kept: WorkspaceArrangement) throws {
        arrangements[name] = kept
        try arrange(kept.preset, order: kept.order)
    }

    @MainActor
    func arrange(_ preset: LayoutPreset, order: [UInt32]) throws {
        let root = try rootTilingContainer
        // A stage keeps its joined groups and the one in use (ADR 0015): a window that comes is already a group of its
        // own (the new-window path, or a drop's bind), one that goes is already unbound; only a tiles root is rebuilt.
        if preset == .stage, root.layout == .stage { return }
        let tiled = root.allLeafWindowsRecursive
        let windows = order.compactMap { id in tiled.first { $0.windowId == id } } + tiled.filter { !order.contains($0.windowId) }
        for window in windows { try window.unbindFromParent() }
        for child in root.children { try child.unbindFromParent() }
        root.layout = switch preset { case .scrolling: .scrolling; case .stage: .stage; default: .tiles }
        // The root has no container above to flip. A strip or a stage is a column per window, as is a lone window.
        guard let tree = preset.tree(windows.count, in: areaSize), case .split(let sideways, let parts) = tree else {
            root.changeOrientation(preset == .rows ? .v : .h)
            for window in windows { try window.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
            return
        }
        root.changeOrientation(sideways ? .h : .v)
        try root.bind(parts, sideways: sideways, extent: areaSize, windows)
    }

    /// The room the workspace's tiles share, which its trees cut by its shape and weigh their tiles in.
    @MainActor
    var areaSize: CGSize {
        let area = workspaceMonitor.visibleRectPaddedByOuterGaps
        return CGSize(width: area.width, height: area.height)
    }
}

extension TilingContainer {
    /// `parts` of a tree as this container's children, each at its share of `extent` along the split, so layout keeps
    /// the shares: it adds the same to every weight until they fill the container, so weights of 2, 1 and 1 would come
    /// out nearly even. A split part is a container of the other direction, normalization's own shape.
    @MainActor
    fileprivate func bind(_ parts: [TileTree.Part], sideways: Bool, extent: CGSize, _ windows: [Window]) throws {
        for part in parts {
            let weight = part.share * (sideways ? extent.width : extent.height)
            switch part.node {
                case .window(let index): try windows[index].bind(to: self, adaptiveWeight: weight, index: INDEX_BIND_LAST)
                case .split(let inner, let children):
                    let container = try TilingContainer(parent: self, adaptiveWeight: weight, inner ? .h : .v, .tiles, index: INDEX_BIND_LAST)
                    try container.bind(children, sideways: inner,
                                       extent: sideways ? CGSize(width: weight, height: extent.height) : CGSize(width: extent.width, height: weight), windows)
            }
        }
    }

    /// Where one more tiled window goes on this root, arranged as `kept`: the slot `arrange` gives the last of its
    /// windows, reshaping the tree around the windows already there, which keep their sizes. Main + stack and dwindle
    /// halve the tile their tree names; centred main stacks it on its side; grid on its last column. A tree changed by
    /// hand since is taken as it is.
    @MainActor
    func nextSlot(_ kept: WorkspaceArrangement) throws -> BindingData {
        let last = BindingData(parent: self, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        switch kept.preset {
            case .columns, .rows, .scrolling, .stage: return last
            case .grid: return BindingData(parent: try nextGridColumn(), adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            case .centred: return try nextCentredSlot() ?? last
            case .mainStack, .dwindle:
                let windows = allLeafWindowsRecursive, size = nodeWorkspace?.areaSize ?? .zero
                guard let (target, sideways) = kept.preset.growth(adding: windows.count, in: size) else { return last }
                let order = kept.preset.openOrder(kept.order, reading: windows.map(\.windowId), in: size)
                guard order.indices.contains(target), let window = windows.first(where: { $0.windowId == order[target] }),
                      let parent = window.parent as? TilingContainer else { return last }
                return try parent.halving(window, sideways ? .h : .v)
        }
    }

    /// The slot that halves `window`, a child of this container, along `orientation`: beside it at half its weight when
    /// this container runs that way, else in a new pair in its place. A lone window's root just turns.
    @MainActor
    private func halving(_ window: Window, _ orientation: Orientation) throws -> BindingData {
        if isRootContainer, children.count == 1 { changeOrientation(orientation) }
        if self.orientation == orientation {
            let half = try window.getWeight(orientation) / 2
            try window.setWeight(orientation, half)
            return BindingData(parent: self, adaptiveWeight: half, index: try window.ownIndex.orFault() + 1)
        }
        let place = try window.unbindFromParent()
        let pair = try TilingContainer(parent: self, adaptiveWeight: place.adaptiveWeight, orientation, .tiles, index: place.index)
        try window.bind(to: pair, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        return BindingData(parent: pair, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }

    /// Centred main's next window: the third a column of its own on the left; then the right and the left in turn, each
    /// at the foot of its side.
    @MainActor
    private func nextCentredSlot() throws -> BindingData? {
        let n = allLeafWindowsRecursive.count
        guard n > 1 else { changeOrientation(.h); return nil }
        if n == 2 { return BindingData(parent: self, adaptiveWeight: WEIGHT_AUTO, index: 0) }
        guard let side = n % 2 == 1 ? children.last : children.first else { return nil }
        let column = try side as? TilingContainer ?? stack([side])
        return BindingData(parent: column, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    /// One window gets its pair beside it; two side by side become the grid's first column; a lone last window gets its
    /// pair under it.
    @MainActor
    private func nextGridColumn() throws -> TilingContainer {
        if children.count == 1, children[0] is Window { changeOrientation(.h); return self }
        if children.count == 2, children.allSatisfy({ $0 is Window }) { _ = try stack(children); changeOrientation(.h); return self }
        guard let foot = children.last as? Window else { return self }
        return try stack([foot])
    }

    /// `nodes`, children of this container, moved into a new vertical stack in the first one's place and at its weight;
    /// each keeps its height when this container already stacked them.
    @MainActor
    private func stack(_ nodes: [TreeNode]) throws -> TilingContainer {
        let heights = try nodes.map { orientation == .v ? try $0.getWeight(.v) : 1 }
        let place = try nodes[0].unbindFromParent()
        let stack = try TilingContainer.newVTiles(parent: self, adaptiveWeight: place.adaptiveWeight, index: place.index)
        for (node, height) in zip(nodes, heights) { try node.bind(to: stack, adaptiveWeight: height, index: INDEX_BIND_LAST) }
        return stack
    }
}

/// Before layout: each auto workspace whose tiled windows changed is rebuilt, the windows it had in their open order as
/// the tree now holds them (a swap since is kept; LayoutPreset.openOrder), new ones after. A workspace whose window is being dragged waits for the release.
@MainActor
func arrangeAutoWorkspaces() throws {
    for (name, var kept) in arrangements where kept.auto {
        guard let workspace = Workspace.existing(byName: name) else { continue }
        let tiled = try workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)
        guard tiled.count != kept.order.count || Set(tiled) != Set(kept.order),
              currentlyManipulatedWithMouseWindowId.map(tiled.contains) != true else { continue }
        kept.order = kept.preset.openOrder(kept.order, reading: tiled, in: workspace.areaSize)
        try workspace.arrange(kept)
    }
}
