import CoreGraphics
import Foundation

/// The live gap while a piece is dragged along the dock or the top bar (spec drag-reorder; Sven, 2026-11-14: "move stuff
/// in dock by simply dragging them"). Nothing is saved until the drop: the others slide by the dragged piece's width
/// toward where it was, opening its new place, as the macOS Dock does. Pure, so the dock and the bar share it.
public enum DragGap {
    /// Where a dragged app lands: `dx` from its place `from` along places `slot` wide, held to `reach`.
    public static func place(from: Int, dx: Double, slot: Double, reach: ClosedRange<Int>) -> Int {
        guard slot > 0 else { return from }
        return min(max(from + Int((dx / slot).rounded()), reach.lowerBound), reach.upperBound)
    }

    /// The shift of the piece at `j` in a row (its place there, the dragged one counted) while the dragged piece leaves
    /// that row from `source` and enters it before the other now at `target`, each nil when it does neither. The row
    /// keeps its anchor: the left holds its left end (the dock's pill, a group, the bar's left side), the right its right
    /// end, the centre its middle.
    public static func shift(_ anchor: TopBarSide, j: Int, leaving source: Int?, entering target: Int?, width: Double) -> Double {
        var shift = 0.0
        if let source {
            switch anchor {
            case .left: if j > source { shift -= width }
            case .right: if j < source { shift += width }
            case .centre: shift += j < source ? width / 2 : -width / 2
            }
        }
        if let target {
            let k = source.map { j > $0 ? j - 1 : j } ?? j
            switch anchor {
            case .left: if k >= target { shift += width }
            case .right: if k < target { shift -= width }
            case .centre: shift += k < target ? -width / 2 : width / 2
            }
        }
        return shift
    }
}

extension BarDrop {
    /// The drop over a bar's `sides` as drawn: `frame` gives each slot's frame by its side and place, nil or off the row
    /// (no width, or wholly left of the bar, gone for room) counting as undrawn. The Menu bar page's strip and the bar's
    /// own drag (spec drag-reorder) both read it so, so a drop lands alike on both.
    public init(_ sides: [TopBarSide: [BarSlot]], size: CGSize, frame: (TopBarSide, Int) -> CGRect?) {
        let slots = TopBarSide.allCases.map { side in
            (side, (sides[side] ?? []).enumerated().map { i, slot in
                let rect = frame(side, i).flatMap { $0.width > 0 && $0.maxX > 0 ? $0 : nil } ?? .zero
                return Slot(item: slot.item, minX: rect.minX, maxX: rect.maxX)
            })
        }
        self.init(sides: Dictionary(uniqueKeysWithValues: slots), width: size.width, height: size.height)
    }
}
