import CoreGraphics

/// A bar drop: the terminal's or Ask AI's panel hung under the top bar (spec Bar drops, Q89). `BarDrop` itself is the
/// bar editor's drag target (BarEditing.swift), so the drops go by these names. The case order is the left-to-right order
/// when both are open: Terminal left, Ask AI right.
public enum BarDropKind: String, CaseIterable, Sendable {
    case terminal, askAI
}

/// Where the open bar drops sit on the focused display (spec Bar drops T2, notes › Placement). One open drop is centred
/// under the bar; both sit side by side, the pair centred. AppKit's screen coordinates, the origin bottom left.
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
    /// off, from the visible frame's top. A closed drop has no frame, so closing one of two puts the other back centre.
    public static func frames(open: Set<BarDropKind>, screen: CGRect, visible: CGRect, bar: CGRect?) -> [BarDropKind: CGRect] {
        let drops = BarDropKind.allCases.filter(open.contains)
        guard !drops.isEmpty else { return [:] }
        let count = CGFloat(drops.count)
        let width = min(Self.width, ((screen.width - edges - gap * (count - 1)) / count).rounded(.down))
        let height = min(Self.height, (visible.height * heightShare).rounded(.down))
        let top = bar?.minY ?? visible.maxY
        let left = (screen.midX - (width * count + gap * (count - 1)) / 2).rounded()
        return Dictionary(uniqueKeysWithValues: drops.enumerated().map { index, drop in
            (drop, CGRect(x: left + CGFloat(index) * (width + gap), y: top - height, width: width, height: height))
        })
    }
}
