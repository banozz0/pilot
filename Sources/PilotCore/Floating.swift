import CoreGraphics

/// Floating windows (stories 65 and 66): the plans Pilot runs through its tiler and Accessibility.
public enum Floating {
    public struct WorkspacePlan: Equatable, Sendable {
        public let float: Bool
        public let ids: [Int]

        public var commands: [AeroCommand] { ids.map { .setFloating(id: $0, float) } }
    }

    /// Hyper+Ctrl+T: while any window on the workspace tiles, the tiled ones float; once none does, they all tile.
    public static func toggleWorkspace(_ windows: [AeroWindow]) -> WorkspacePlan {
        let tiled = windows.filter { !$0.isFloating }
        return tiled.isEmpty ? WorkspacePlan(float: false, ids: windows.map(\.id)) : WorkspacePlan(float: true, ids: tiled.map(\.id))
    }

    /// Frames for `count` floated windows, cascaded from the centre placement: the middle one centred, each next one a
    /// step down and right.
    public static func cascade(_ count: Int, in visible: CGRect, step: CGFloat = 30) -> [CGRect] {
        let centre = Placement.centre.frame(in: visible)
        return (0..<count).map { i in
            let offset = (CGFloat(i) - CGFloat(count - 1) / 2) * step
            return centre.offsetBy(dx: offset, dy: offset)
        }
    }
}
