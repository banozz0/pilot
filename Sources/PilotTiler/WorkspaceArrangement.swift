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
        let columns: [[Window]] = switch preset {
            case .columns, .rows, .scrolling, .stage: windows.map { [$0] }
            case .mainStack: windows.count > 2 ? [[windows[0]], Array(windows[1...])] : windows.map { [$0] }
            case .grid: stride(from: 0, to: windows.count, by: 2).map { Array(windows[$0..<min($0 + 2, windows.count)]) }
        }
        // A grid of one column is that column, as AeroSpace's flatten normalization would leave it.
        let single = columns.count == 1 && columns[0].count > 1
        root.layout = switch preset { case .scrolling: .scrolling; case .stage: .stage; default: .tiles }
        root.changeOrientation(preset == .rows || single ? .v : .h) // the root has no container above to flip
        for column in columns {
            if column.count == 1 || single {
                for window in column { try window.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
            } else {
                let stack = try TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                for window in column { try window.bind(to: stack, adaptiveWeight: 1, index: INDEX_BIND_LAST) }
            }
        }
    }
}

extension TilingContainer {
    /// Where one more tiled window goes on this root, arranged as `preset`: the slot `arrange` gives the last of its
    /// windows (main + stack: the foot of the stack), reshaping the tree around the windows already there, which keep
    /// their sizes. A tree changed by hand since is taken as it is.
    @MainActor
    func nextSlot(_ preset: LayoutPreset) throws -> BindingData {
        let parent: TilingContainer = switch preset {
            case .columns, .rows, .scrolling, .stage: self
            case .mainStack: children.count > 1 ? try children.last as? TilingContainer ?? stack([children[children.count - 1]]) : self
            case .grid: try nextGridColumn()
        }
        return BindingData(parent: parent, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    /// One window is a column of two to be; a column of two becomes the grid's first column; a lone last window gets
    /// its pair under it.
    @MainActor
    private func nextGridColumn() throws -> TilingContainer {
        if children.count == 1, children[0] is Window { changeOrientation(.v); return self }
        if orientation == .v, children.count > 1 { _ = try stack(children); changeOrientation(.h); return self }
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

/// Before layout: each auto workspace whose tiled windows changed is rebuilt, the windows it had in the order the tree
/// now reads (a swap since is kept), new ones after. A workspace whose window is being dragged waits for the release.
@MainActor
func arrangeAutoWorkspaces() throws {
    for (name, var kept) in arrangements where kept.auto {
        guard let workspace = Workspace.existing(byName: name) else { continue }
        let tiled = try workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)
        guard tiled.count != kept.order.count || Set(tiled) != Set(kept.order),
              currentlyManipulatedWithMouseWindowId.map(tiled.contains) != true else { continue }
        kept.order = tiled.filter(kept.order.contains) + tiled.filter { !kept.order.contains($0) }
        try workspace.arrange(kept)
    }
}
