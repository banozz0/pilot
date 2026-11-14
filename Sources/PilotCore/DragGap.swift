import Foundation

/// The live gap while a piece is dragged along the dock or the top bar (spec drag-reorder; Sven, 2026-11-14: "move stuff
/// in dock by simply dragging them"). Nothing is saved until the drop: the others slide by the dragged piece's width
/// toward where it was, opening its new place, as the macOS Dock does. Pure, so the dock and the bar share it.
public enum DragGap {
    /// A press moves this far, in points, before it is a drag; less, and it stays a click.
    public static let threshold = 4.0

    /// The shift of the piece at `k` among the others (the row without the dragged one) as the dragged one leaves its
    /// place `from` and goes before the other now at `to`: the ones between slide by `width` toward its old place.
    public static func shift(_ k: Int, from: Int, to: Int, width: Double) -> Double {
        if to < from, k >= to, k < from { return width }
        if to > from, k >= from, k < to { return -width }
        return 0
    }

    /// Where a dragged app lands: `dx` from its place `from` along places `slot` wide, held to `reach`.
    public static func place(from: Int, dx: Double, slot: Double, reach: ClosedRange<Int>) -> Int {
        guard slot > 0 else { return from }
        return min(max(from + Int((dx / slot).rounded()), reach.lowerBound), reach.upperBound)
    }

    /// The shift of the slot at `j` on a top bar side (its place there, the dragged one counted) while the dragged piece
    /// leaves that side from `source` and enters it before the other now at `target`, each nil when it does neither.
    /// Each side keeps its anchor: the left holds its left end, the right its right end, the centre its middle.
    public static func barShift(_ side: TopBarSide, j: Int, leaving source: Int?, entering target: Int?, width: Double) -> Double {
        var shift = 0.0
        if let source {
            switch side {
            case .left: if j > source { shift -= width }
            case .right: if j < source { shift += width }
            case .centre: shift += j < source ? width / 2 : -width / 2
            }
        }
        if let target {
            let k = source.map { j > $0 ? j - 1 : j } ?? j
            switch side {
            case .left: if k >= target { shift += width }
            case .right: if k < target { shift -= width }
            case .centre: shift += k < target ? -width / 2 : width / 2
            }
        }
        return shift
    }
}
