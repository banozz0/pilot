import CoreGraphics

/// Tiles along one axis as the tiler sizes them: the slots frames fill, and the resizes that move every slot to a
/// target. Snapshot restore and workspace presets share it.
public enum TileResize {
    /// Layout order: left to right, or top to bottom along a vertical axis.
    public static func before(_ a: CGRect, _ b: CGRect, vertical: Bool) -> Bool {
        vertical ? (a.minY, a.minX) < (b.minY, b.minX) : (a.minX, a.minY) < (b.minX, b.minY)
    }

    /// The slots tiles in layout order fill: the tiler takes the inner gap out of each slot, half of it at an outer edge,
    /// so a slot ends halfway across the gap between windows.
    public static func slots(_ frames: [CGRect], vertical: Bool) -> [CGFloat] {
        let lo = { (r: CGRect) in vertical ? r.minY : r.minX }, hi = { (r: CGRect) in vertical ? r.maxY : r.maxX }
        guard let first = frames.first, let last = frames.last else { return [] }
        let edges = [lo(first)] + zip(frames, frames.dropFirst()).map { (hi($0) + lo($1)) / 2 } + [hi(last)]
        return zip(edges, edges.dropFirst()).map { $1 - $0 }
    }

    /// Resizes that take tiles `order`, at slots `start`, to slots `target` (same total). A `resize` changes one slot
    /// and spreads the change evenly over the other tiles (the tiler's ResizeCommand), so the changes are solved so that
    /// every tile lands on its target. They go as relative +N and -N: an absolute size can come out negative partway, and
    /// the tiler reads a leading minus as subtract.
    public static func commands(order: [Int], start: [CGFloat], target: [CGFloat], axis: AeroCommand.Axis) -> [AeroCommand] {
        let n = order.count
        guard n > 1 else { return [] }
        // Changing tile k by d_k leaves it at w_k + d_k * n/(n-1) - D/(n-1), D the sum of every change; the last tile
        // is never changed, which fixes D, and each d follows.
        let spread = CGFloat(n - 1)
        let sum = spread * (start[n - 1] - target[n - 1])
        return (0..<(n - 1)).compactMap { k in
            let d = Int(((target[k] - start[k] + sum / spread) * spread / CGFloat(n)).rounded())
            return d == 0 ? nil : .resize(id: order[k], axis, by: d)
        }
    }
}
