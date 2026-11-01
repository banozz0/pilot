// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/TilingContainer.swift
import AppKit

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    var orientation: Orientation { _orientation }
    var layout: Layout
    /// Pilot (scrolling layout): how far a scrolling root's strip is scrolled, in points from its first column.
    var stripOffset: CGFloat = 0
    /// Pilot (scrolling layout T8): how many columns the strip's widths were last fitted to (fitColumnWidths).
    var fittedColumns = 0

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, _ orientation: Orientation, _ layout: Layout, index: Int) throws {
        self._orientation = orientation
        self.layout = layout
        try super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) throws -> TilingContainer {
        try TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .h, .tiles, index: index)
    }

    @MainActor
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) throws -> TilingContainer {
        try TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .v, .tiles, index: index)
    }
}

extension TilingContainer {
    var isRootContainer: Bool { parent is Workspace }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        if orientation == targetOrientation {
            return
        }
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            var orientation = targetOrientation
            parentsWithSelf
                .filterIsInstance(of: TilingContainer.self)
                .forEach {
                    $0._orientation = orientation
                    orientation = orientation.opposite
                }
        } else {
            _orientation = targetOrientation
        }
    }

    func normalizeOppositeOrientationForNestedContainers() {
        if orientation == (parent as? TilingContainer)?.orientation {
            _orientation = orientation.opposite
        }
        for child in children {
            (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

enum Layout: String {
    case tiles
    /// Pilot: each child a column on one horizontal strip that scrolls (layout/scrolling.swift); replaced accordion.
    case scrolling
    /// Pilot: one group tiled in the centre, the rest shelved in the hide corner (layout/stage.swift, ADR 0015).
    case stage

    /// Pilot: the root is one row of groups (a strip's columns, a stage's groups): it is never flattened, stays
    /// horizontal, keeps its frames within the displays beside it, takes a new window as a group of its own, and has no
    /// gaps to drag between its groups.
    var isRow: Bool { self != .tiles }
}
