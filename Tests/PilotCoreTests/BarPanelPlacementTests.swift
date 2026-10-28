import CoreGraphics
import PilotCore
import Testing

/// Where an item's popover or the dropdown hangs (card agent-bo-95422914, design round 4's Popover): its arrow over the
/// item's middle, kept on the item's screen.
@Suite("Bar panel placement")
struct BarPanelPlacementTests {
    static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let item = CGRect(x: 1000, y: 870, width: 40, height: 30)
    static let size = CGSize(width: 300, height: 200)

    @Test("The panel puts its arrow over the item's middle, under the item")
    func underTheItem() {
        let origin = BarPanelPlacement.frame(item: Self.item, size: Self.size, screen: Self.screen).origin
        #expect(origin.x + PopoverMetrics.arrowPoint == Self.item.midX && origin.y == 670)
    }

    /// KitPopover, BarPanel's clip and this placement read one set of numbers (card agent-bo-95422899), so the panel
    /// cannot drift from the popover it holds.
    @Test("The arrow point is the popover's arrow, 16 by 8 at 26 from its left edge; the corner is 14")
    func popoverMetrics() {
        #expect(PopoverMetrics.arrowSize == CGSize(width: 16, height: 8) && PopoverMetrics.arrowX == 26 && PopoverMetrics.inset == 12)
        #expect(PopoverMetrics.arrowHeight == 8 && PopoverMetrics.cornerRadius == 14)
    }

    @Test("A panel's room runs from under its item to the visible frame's foot, above the Dock, less the margin; 200 at least")
    func room() {
        let visible = CGRect(x: 0, y: 80, width: 1440, height: 790)
        #expect(BarPanelPlacement.room(item: Self.item, visible: visible) == 870 - 80 - BarPanelPlacement.margin)
        // An item lower than the menu bar (the top bar's), and a screen with almost no room.
        #expect(BarPanelPlacement.room(item: CGRect(x: 0, y: 840, width: 40, height: 30), visible: visible) == 840 - 80 - BarPanelPlacement.margin)
        #expect(BarPanelPlacement.room(item: Self.item, visible: CGRect(x: 0, y: 760, width: 1440, height: 110)) == 200)
    }

    @Test("Near a screen's left or right edge the panel stays on the screen, as far as the edge allows")
    func onScreen() {
        let right = CGRect(x: 1420, y: 870, width: 20, height: 30)
        #expect(BarPanelPlacement.frame(item: right, size: Self.size, screen: Self.screen).minX == 1440 - 300 - BarPanelPlacement.margin)
        let left = CGRect(x: -1080, y: 1890, width: 20, height: 30)
        let portrait = CGRect(x: -1080, y: 0, width: 1080, height: 1920)
        #expect(BarPanelPlacement.frame(item: left, size: Self.size, screen: portrait).minX == -1080 + BarPanelPlacement.margin)
    }

    /// Lane 1's live check of card agent-bo-95422899 (2026-10-07): the CPU popover's process rows arrive after the first
    /// sample, the panel kept its first height and clipped its top row and its arrow under the menu bar; it now refits
    /// through this frame (card agent-bo-95422983). Whatever height the content takes, the top stays under the item.
    @Test("Every height, a grown one or one taller than the screen, keeps the panel's top at the item's bottom")
    func topStaysUnderTheItem() {
        for height in [120.0, 200, 480, 860, 1000] {
            let frame = BarPanelPlacement.frame(item: Self.item, size: CGSize(width: 300, height: height), screen: Self.screen)
            #expect(frame.maxY == Self.item.minY, "height \(height)")
            #expect(frame.size == CGSize(width: 300, height: height))
        }
    }

    @Test("A click closes the panel unless it lands on the panel or on its own item; elsewhere on the same bar it closes")
    func clicks() {
        #expect(!BarPanelPlacement.clickCloses(at: CGPoint(x: 1010, y: 880), onPanel: false, item: Self.item))
        // The screen's top row reads as the item's maxY, and its right edge as maxX: still the item, so it toggles.
        #expect(!BarPanelPlacement.clickCloses(at: CGPoint(x: 1010, y: Self.item.maxY), onPanel: false, item: Self.item))
        #expect(!BarPanelPlacement.clickCloses(at: CGPoint(x: Self.item.maxX, y: 880), onPanel: false, item: Self.item))
        #expect(!BarPanelPlacement.clickCloses(at: CGPoint(x: 1100, y: 700), onPanel: true, item: Self.item))
        // Another item or a workspace number on the same top bar, and the desktop.
        #expect(BarPanelPlacement.clickCloses(at: CGPoint(x: 1200, y: 880), onPanel: false, item: Self.item))
        #expect(BarPanelPlacement.clickCloses(at: CGPoint(x: 300, y: 400), onPanel: false, item: Self.item))
    }
}
