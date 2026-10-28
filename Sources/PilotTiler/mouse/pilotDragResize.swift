import AppKit
import PilotCore

// Pilot's modifier right-drag of a tiled window (story 119; Sven on build 19, 2026-10-10: "showing cool box of the resize
// but resizing isnt happening as the blue box but just width change"). The outline Pilot draws may move only the edges
// the tree can move, and only as far: an edge moves when tiles lie beyond it, and those tiles give or take the
// difference, as AeroSpace's resizeWithMouse shares it, down to WindowGeometry.minimumSize each. The release lands
// exactly that frame.

extension TilerDrag {
    /// Where tiled window `id`'s edges can go, from its last layout (no AX); nil when the tiler does not tile it, so
    /// Pilot resizes it as a floating window.
    @MainActor public static func reach(_ id: UInt32) -> EdgeReach? {
        guard let window = tiledWindow(id) else { return nil }
        return (try? window.edgeReach()) ?? EdgeReach()
    }

    /// The release: the tiles beyond each moved edge give or take what it moved, kept inside the reach, then laid out.
    @MainActor public static func resize(_ id: UInt32, to frame: CGRect) async throws {
        guard isTilerEnabled else { throw TilerNotRunning() }
        try await runLightSession(.pilotCall("drag-resize"), .forceRun) { try tiledWindow(id)?.dragResize(to: frame) }
    }
}

/// Window `id` while the tiler runs and tiles it.
@MainActor
func tiledWindow(_ id: UInt32) -> Window? {
    guard isTilerEnabled, let window = Window.get(byId: id), window.parent is TilingContainer else { return nil }
    return window
}

extension Window {
    /// Each edge with tiles beyond it moves inward until this window reaches the minimum size, outward until the smallest
    /// of those tiles does (they shrink alike).
    @MainActor
    func edgeReach() throws -> EdgeReach {
        guard let frame = lastAppliedLayoutPhysicalRect else { return EdgeReach() }
        let minimum = WindowGeometry.minimumSize
        var reach = EdgeReach()
        for direction in CardinalDirection.allCases {
            guard let (parent, own) = try closestParent(hasChildrenInDirection: direction, withLayout: .tiles) else { continue }
            let beyond = direction.isPositive ? parent.children[(own + 1)...] : parent.children[..<own]
            let orientation = direction.orientation
            let least = orientation == .h ? minimum.width : minimum.height
            guard let smallest = try beyond.map({ try $0.getWeight(orientation) }).min() else { continue }
            let grow = max(0, smallest - least) * CGFloat(beyond.count)
            switch direction {
                case .left: reach.left = (frame.minX - grow)...max(frame.minX - grow, frame.maxX - least)
                case .right: reach.right = min(frame.minX + least, frame.maxX + grow)...(frame.maxX + grow)
                case .up: reach.top = (frame.minY - grow)...max(frame.minY - grow, frame.maxY - least)
                case .down: reach.bottom = min(frame.minY + least, frame.maxY + grow)...(frame.maxY + grow)
            }
        }
        return reach
    }

    /// Weights for `target`, kept inside the reach should the tree have changed since the press: resizeWithMouse's sharing
    /// from the current weights.
    @MainActor
    func dragResize(to target: CGRect) throws {
        guard let frame = lastAppliedLayoutPhysicalRect else { return }
        let to = try edgeReach().clamp(target, from: frame.cgRect)
        try shareEdgeMoves(from: frame, to: Rect(topLeftX: to.minX, topLeftY: to.minY, width: to.width, height: to.height),
                           past: 0.5) { try $0.getWeight($1) }
    }
}
