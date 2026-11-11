import CoreGraphics

/// A bar drop: the terminal's or Ask AI's panel hung under the top bar (spec Bar drops, Q89). `BarDrop` itself is the
/// bar editor's drag target (BarEditing.swift), so the drops go by these names. The case order is the left-to-right order
/// when both are open: Terminal left, Ask AI right.
public enum BarDropKind: String, CaseIterable, Sendable {
    case terminal, askAI
    /// The pill's views (spec desktop-controls T5): hung under its own item by PillPlacement, alone: opening it closes
    /// the other drops, and the reverse (DropKeys).
    case pill

    /// The drops that sit side by side under the bar.
    public static let paired: [BarDropKind] = [.terminal, .askAI]
}

/// Where the open bar drops sit on the focused display (spec Bar drops T2, notes › Placement; P97). A drop hangs under its
/// own item on the bar, kept on screen; with no item to go by it is centred, and two sit side by side, never overlapping.
/// AppKit's screen coordinates, the origin bottom left.
public enum BarDropPlacement {
    /// The starting sizes, measured off the C frames; the designer tunes them in T8.
    public static let width: CGFloat = 760
    public static let height: CGFloat = 560
    /// The room kept to the screen's edges, both sides together, and the gap between two drops.
    public static let edges: CGFloat = 48
    public static let gap: CGFloat = 12
    /// The most of the visible height a drop takes.
    public static let heightShare: CGFloat = 0.6

    /// Each open drop's frame on a screen whose frame is `screen` and visible frame (under the menu bar, above the Dock)
    /// `visible`. A drop hangs from the bar's bottom edge, `bar` being the top bar's strip on this screen; with the bar
    /// off, from the visible frame's top. `items` is each drop's item's centre on this screen; a closed drop has no frame,
    /// so closing one of two puts the other back under its item.
    public static func frames(open: Set<BarDropKind>, screen: CGRect, visible: CGRect, bar: CGRect?, items: [BarDropKind: CGFloat] = [:]) -> [BarDropKind: CGRect] {
        let drops = BarDropKind.paired.filter(open.contains)
        guard !drops.isEmpty else { return [:] }
        let count = CGFloat(drops.count)
        let width = min(Self.width, ((screen.width - edges - gap * (count - 1)) / count).rounded(.down))
        let height = min(Self.height, (visible.height * heightShare).rounded(.down))
        let top = bar?.minY ?? visible.maxY
        let centred = (screen.midX - (width * count + gap * (count - 1)) / 2).rounded()
        // Left to right as their items sit; those with no item keep the case order, around the middle.
        let ordered = drops.sorted { (items[$0] ?? screen.midX, drops.firstIndex(of: $0)!) < (items[$1] ?? screen.midX, drops.firstIndex(of: $1)!) }
        var xs = ordered.enumerated().map { index, drop in
            items[drop].map { ($0 - width / 2).rounded() } ?? centred + CGFloat(index) * (width + gap)
        }
        // On screen, then apart: pushed right past the one before, then back in from the right edge.
        let least = screen.minX + edges / 2, most = screen.maxX - edges / 2 - width
        for index in xs.indices { xs[index] = max(index == 0 ? least : xs[index - 1] + width + gap, xs[index]) }
        for index in xs.indices.reversed() { xs[index] = min(index == xs.count - 1 ? most : xs[index + 1] - width - gap, xs[index]) }
        return Dictionary(uniqueKeysWithValues: zip(ordered, xs).map { drop, x in
            (drop, CGRect(x: x, y: top - height, width: width, height: height))
        })
    }
}
