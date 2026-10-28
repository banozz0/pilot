import CoreGraphics

/// KitPopover's shape (design round 4's Popover, card agent-bo-95422899), here so the menu bar's panel, which
/// BarPanelPlacement hangs and BarPanel clips, reads the same numbers as the popover it holds.
public enum PopoverMetrics {
    /// The content's inset from the popover's edge.
    public static let inset: CGFloat = 12
    /// The arrow, and how far its left edge sits from the popover's left edge.
    public static let arrowSize = CGSize(width: 16, height: 8)
    public static let arrowX: CGFloat = 26
    /// Where the arrow's point sits from the popover's left edge.
    public static var arrowPoint: CGFloat { arrowX + arrowSize.width / 2 }

    /// The popover's corner.
    public static let cornerRadius: CGFloat = 14

    /// The room above the popover's body: the arrow.
    public static var arrowHeight: CGFloat { arrowSize.height }
}
