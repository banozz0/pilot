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

    /// Each window's frame as the tiler lays this tree in `area` (layoutTiles): `gap` between neighbours, half of it each
    /// side's, and each window at least its `minimums` size where the room allows, the parts beside it giving way (TileFit).
    public func frames(in area: CGRect, gap: CGFloat = 0, minimums: [Int: CGSize] = [:]) -> [CGRect] {
        var found = Array(repeating: CGRect.zero, count: reading.count)
        func least(_ node: TileTree, sideways: Bool) -> CGFloat {
            switch node {
            case .window(let index): minimums[index].map { sideways ? $0.width : $0.height } ?? 0
            case .split(let along, let parts): TileFit.least(parts.map { least($0.node, sideways: sideways) }, along: along == sideways, gap: gap)
            }
        }
        func walk(_ node: TileTree, _ rect: CGRect) {
            guard case .split(let sideways, let parts) = node else {
                if case .window(let index) = node { found[index] = rect }
                return
            }
            let extent = sideways ? rect.width : rect.height
            let spans = TileFit.spans(parts.map { $0.share * extent }, gap: gap, minimums: parts.map { least($0.node, sideways: sideways) })
            let origin = sideways ? rect.minX : rect.minY
            for (i, (part, span)) in zip(parts, spans).enumerated() {
                let own = TileFit.gapShare(i, of: parts.count, gap: gap), lead = i == 0 ? 0 : gap / 2, start = origin + span.start
                walk(part.node, sideways
                    ? CGRect(x: start + lead, y: rect.minY, width: span.size - own, height: rect.height)
                    : CGRect(x: rect.minX, y: start + lead, width: rect.width, height: span.size - own))
            }
        }
        walk(self, area)
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

/// Room for a window that cannot shrink to its tile (live bug 2026-11-16: Vesktop, 940 points at the least, ran 460
/// points under X from a 430-point column). One split's parts along its direction, which the tiler lays and
/// `TileTree.frames` previews alike.
public enum TileFit {
    /// The part of the inner gap part `i` of `count` gives up: half on each side that has a neighbour.
    public static func gapShare(_ i: Int, of count: Int, gap: CGFloat) -> CGFloat {
        gap - (i == 0 ? gap / 2 : 0) - (i == count - 1 ? gap / 2 : 0)
    }

    /// The least room a split's parts take, `leasts` each: one after another with `gap` between when they run `along`
    /// the way asked, else the largest.
    public static func least(_ leasts: [CGFloat], along: Bool, gap: CGFloat) -> CGFloat {
        along ? leasts.reduce(0, +) + gap * CGFloat(max(0, leasts.count - 1)) : leasts.max() ?? 0
    }

    /// Where each part starts along the split and the room it takes (its gap share in it), from `sizes` (the preset's,
    /// adding up to the split's), with every part at least its window's `minimums` along the split plus its gap share: a
    /// part short of it gets it, and the rest give way in proportion to their sizes, each down to its own least.
    ///
    /// When the leasts outgrow the room (bug 10, 2026-11-18: two Ghostex windows, 600 points tall at the least, stacked
    /// in a 1080-point column), each part with a least takes it and the others their preset size, and the parts overlap
    /// by the room they lack, shared evenly between neighbours: the first starts where the split does and the last ends
    /// where it ends, so no window runs past the room's edge and its bottom lines up with its neighbours'. Some window
    /// overlaps whatever is done; the preset's sizes left the last one running past the screen.
    public static func spans(_ sizes: [CGFloat], gap: CGFloat, minimums: [CGFloat]) -> [(start: CGFloat, size: CGFloat)] {
        let needs = minimums.indices.map { minimums[$0] > 0 ? minimums[$0] + gapShare($0, of: minimums.count, gap: gap) : 0 }
        let total = sizes.reduce(0, +)
        var fitted = sizes, overlap: CGFloat = 0
        if needs.count == sizes.count, sizes.count > 1, needs.reduce(0, +) > total + 0.5 {
            fitted = sizes.indices.map { needs[$0] > 0 ? needs[$0] : sizes[$0] }
            overlap = (fitted.reduce(0, +) - total) / CGFloat(sizes.count - 1)
        } else if needs.count == sizes.count {
            fitted = fit(sizes, needs: needs, total: total)
        }
        var start: CGFloat = 0
        return fitted.map { size in
            defer { start += size - overlap }
            return (start, size)
        }
    }

    /// `sizes` with every part at least its `needs`, the rest giving way in proportion; the leasts fit in `total`.
    private static func fit(_ sizes: [CGFloat], needs: [CGFloat], total: CGFloat) -> [CGFloat] {
        guard zip(sizes, needs).contains(where: { $0 < $1 - 0.5 }) else { return sizes }
        var held = Set(sizes.indices.filter { sizes[$0] < needs[$0] - 0.5 }), fitted = sizes
        while true {
            let free = sizes.indices.filter { !held.contains($0) }
            if free.isEmpty { // every part at its least: what is left over goes round as the sizes did
                let extra = total - needs.reduce(0, +)
                return sizes.indices.map { needs[$0] + (total > 0 ? extra * sizes[$0] / total : 0) }
            }
            let room = total - held.map { needs[$0] }.reduce(0, +), weight = free.map { sizes[$0] }.reduce(0, +)
            for i in held { fitted[i] = needs[i] }
            for i in free { fitted[i] = weight > 0 ? room * sizes[i] / weight : room / CGFloat(free.count) }
            let short = free.filter { fitted[$0] < needs[$0] - 0.5 }
            if short.isEmpty { return fitted }
            held.formUnion(short)
        }
    }
}
