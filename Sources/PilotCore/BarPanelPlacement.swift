import CoreGraphics

/// Where a bar item's popover, or Pilot's dropdown, hangs under the item (card agent-bo-95422914, design round 4's
/// Popover): its arrow over the item's middle; kept on the item's screen. AppKit's screen coordinates, the origin bottom left.
public enum BarPanelPlacement {
    /// The least room kept to a screen's edge.
    public static let margin: CGFloat = 4

    /// The panel's frame for content of `size`. Its top stays at the item's bottom whatever the height, below the menu
    /// bar: a panel taller than the room runs off the screen's bottom, never up under the bar (card agent-bo-95422983).
    public static func frame(item: CGRect, size: CGSize, screen: CGRect) -> CGRect {
        let x = item.midX - PopoverMetrics.arrowPoint
        return CGRect(x: min(max(x, screen.minX + margin), screen.maxX - size.width - margin), y: item.minY - size.height,
                      width: size.width, height: size.height)
    }

    /// The most height a panel hung under `item` may take on a screen whose visible frame (under the menu bar, above the
    /// Dock) is `visible`: down to its foot, less the margin; never under 200, so a short screen still shows something.
    public static func room(item: CGRect, visible: CGRect) -> CGFloat {
        max(min(item.minY, visible.maxY) - visible.minY - margin, 200)
    }

    /// Whether a click at `point` (screen coordinates) closes the panel: anywhere but the panel and its own item, whose
    /// button toggles it. Another item on the same bar closes it, and its own button then opens its panel. The item's
    /// edges count as the item: NSEvent.mouseLocation reads the screen's top row as its maxY (CGRect.contains leaves that out).
    public static func clickCloses(at point: CGPoint, onPanel: Bool, item: CGRect) -> Bool {
        !onPanel && !((item.minX...item.maxX).contains(point.x) && (item.minY...item.maxY).contains(point.y))
    }
}
