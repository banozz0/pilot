import CoreGraphics

/// A tiled layout's tree for some windows (layouts round 1, spec Projects/Pilot/specs/layouts-round1.html): a split is a row
/// (sideways) or a column of parts at their shares of it, a leaf is a window by its place in open order. A split never
/// holds a split of its own direction: two cuts the same way are one split at unequal shares, since the tiler's
/// normalization turns a nested container of its parent's direction the other way. The tiler builds it, and the editor's
/// pictures, the drop slots, the bar's glyph and `pilot layout tiles` read it.
public indirect enum TileTree: Equatable, Sendable {
    case window(Int)
    case split(sideways: Bool, [Part])

    public struct Part: Equatable, Sendable {
        public var share: CGFloat
        public var node: TileTree
        public init(_ share: CGFloat, _ node: TileTree) { self.share = share; self.node = node }
    }

    /// `nodes` side by side (or stacked) at equal shares; one node is itself.
    static func even(sideways: Bool, _ nodes: [TileTree]) -> TileTree {
        nodes.count == 1 ? nodes[0] : .split(sideways: sideways, nodes.map { Part(1 / CGFloat(nodes.count), $0) })
    }

    /// The windows as the tree reads them, depth first: the tiler's tree reads its windows in this order.
    public var reading: [Int] {
        switch self {
        case .window(let index): [index]
        case .split(_, let parts): parts.flatMap(\.node.reading)
        }
    }

    /// Each window's tile in `area`, by its place in open order, with whether its split stacks it.
    public func slots(in area: CGRect) -> [(rect: CGRect, stacked: Bool)] {
        var found = Array(repeating: (rect: CGRect.zero, stacked: false), count: reading.count)
        func walk(_ node: TileTree, _ rect: CGRect, stacked: Bool) {
            switch node {
            case .window(let index): found[index] = (rect, stacked)
            case .split(let sideways, let parts):
                var start: CGFloat = 0
                for part in parts {
                    let tile = sideways
                        ? CGRect(x: rect.minX + rect.width * start, y: rect.minY, width: rect.width * part.share, height: rect.height)
                        : CGRect(x: rect.minX, y: rect.minY + rect.height * start, width: rect.width, height: rect.height * part.share)
                    start += part.share
                    walk(part.node, tile, stacked: !sideways)
                }
            }
        }
        walk(self, area, stacked: false)
        return found
    }

    /// This tree with window `target`'s tile halved, `sideways` or top and bottom, window `new` taking the second half.
    func splitting(_ target: Int, sideways: Bool, with new: Int) -> TileTree {
        switch self {
        case .window(let index):
            guard index == target else { return self }
            return .split(sideways: sideways, [Part(0.5, self), Part(0.5, .window(new))])
        case .split(let direction, let parts):
            return .split(sideways: direction, parts.flatMap { part -> [Part] in
                // A cut the split's own way shares out the part's room instead of nesting.
                if part.node == .window(target), direction == sideways {
                    return [Part(part.share / 2, part.node), Part(part.share / 2, .window(new))]
                }
                return [Part(part.share, part.node.splitting(target, sideways: sideways, with: new))]
            })
        }
    }
}
