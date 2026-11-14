import CoreGraphics
import Foundation

/// A workspace's layout preset (story 107, card agent-bo-95422736). Pilot's tiler arranges a workspace as one in its own
/// tree (WorkspaceArrangement); a workspace preset's apply builds it from tiler commands: flatten the workspace, set its
/// root, order the tiles by moving each to the far end in turn, group the ones that share a column, then equal sizes. A
/// column starts with join-with between two windows; a later window moves left into it, since a second join would nest
/// it and the tiler's normalization would turn the inner pair sideways. Scrolling is every window a column on one strip,
/// each at its own width, so it needs no groups and no equal sizes (spec Projects/Pilot/specs/scrolling-layout.html).
/// Stage tiles the focused window's group in the centre and shelves the rest at the left edge (ADR 0015).
/// Layouts round 1 (spec Projects/Pilot/specs/layouts-round1.html): Main + stack is Sven's split, Dwindle and Centred main
/// join, and every tiled layout but scrolling and stage is a TileTree, built in the tiler's tree in one command.
public enum LayoutPreset: String, CaseIterable, Codable, Sendable {
    case mainStack, dwindle, centred, columns, rows, grid, scrolling, stage

    /// Scrolling replaced accordion (2026-10-12): a stored accordion reads as scrolling, since one value that fails to
    /// decode drops every workspace's layout (WorkspaceLayout.load) and preset.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let preset = LayoutPreset(rawValue: raw == "accordion" ? "scrolling" : raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no layout preset \(raw)"))
        }
        self = preset
    }

    public var label: String {
        switch self {
        case .mainStack: "Main + stack"
        case .dwindle: "Dwindle"
        case .centred: "Centred main"
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .scrolling: "Scrolling"
        case .stage: "Stage"
        }
    }

    /// The one key's and the bar's cycle (Sven's Q235, 2026-11-14): Rows and Columns are out of it and stay in the
    /// workspace editor. A workspace with no preset, or one of those two, starts at main + stack.
    public static let cycle: [LayoutPreset] = [.mainStack, .dwindle, .centred, .grid, .scrolling, .stage]

    public static func next(after preset: LayoutPreset?) -> LayoutPreset {
        guard let preset, let i = cycle.firstIndex(of: preset) else { return .mainStack }
        return cycle[(i + 1) % cycle.count]
    }

    /// The commands that build this preset from `windows`, the tiles in the order they should read; none for none. The
    /// layouts whose tree nests are one `arrange`, the engine's own build, at the shares no move or join can give.
    public func commands(workspace: String, windows: [Int]) -> [AeroCommand] {
        guard !windows.isEmpty else { return [] }
        switch self {
        case .mainStack, .dwindle, .centred, .grid: return [.arrange(workspace: workspace, self, windows: windows)]
        case .columns, .rows, .scrolling, .stage: break
        }
        let along: Direction = self == .rows ? .down : .right
        let order = windows.flatMap { id in Array(repeating: AeroCommand.move(id: id, along), count: windows.count - 1) }
        let root = switch self { case .rows: "v_tiles"; case .scrolling: "h_scrolling"; case .stage: "h_stage"; default: "h_tiles" }
        return [.flatten(workspace: workspace), .setRootLayout(workspace: workspace, root)] + order
            + (self == .scrolling ? [] : [.balanceSizes(workspace: workspace)])
    }

    /// This preset's tree for `n` windows on a screen of `size`; nil for none, and for scrolling and stage, whose root
    /// lays its own columns. Main + stack is Sven's split (Q231): 1 whole, 2 halves, 3 the right half top and bottom, 4
    /// the bottom right halved sideways, 5 the top right too, so the right half is 2x2; from 6 each new window halves the
    /// newest tile (Q232, option B). Dwindle is Hyprland's: each new window halves the newest tile. Both cut a tile
    /// along its longer side, sideways when it is wider than tall (a square too, so a picture's square starts side by
    /// side), as Hyprland's dwindle does. Centred main: the first in
    /// the middle half from 3 windows, the rest in quarter columns either side, right first. Grid: 2 side by side (Sven,
    /// 2026-11-14), then columns of two, the last alone when the count is odd.
    public func tree(_ n: Int, in size: CGSize) -> TileTree? {
        guard n > 0 else { return nil }
        let windows = (0..<n).map(TileTree.window)
        switch self {
        case .scrolling, .stage: return nil
        case .columns: return .even(sideways: true, windows)
        case .rows: return .even(sideways: false, windows)
        case .grid:
            guard n > 2 else { return .even(sideways: true, windows) }
            return .even(sideways: true, stride(from: 0, to: n, by: 2).map { .even(sideways: false, Array(windows[$0..<min($0 + 2, n)])) })
        case .centred:
            guard n > 2 else { return .even(sideways: true, windows) }
            let right = windows.indices.filter { $0 > 0 && $0 % 2 == 1 }, left = windows.indices.filter { $0 > 0 && $0 % 2 == 0 }
            return .split(sideways: true, [.init(0.25, .even(sideways: false, left.map(TileTree.window))), .init(0.5, .window(0)),
                                           .init(0.25, .even(sideways: false, right.map(TileTree.window)))])
        case .mainStack, .dwindle:
            var tree = TileTree.window(0)
            for k in 1..<n {
                let (target, sideways) = growth(k, of: tree, in: size)
                tree = tree.splitting(target, sideways: sideways, with: k)
            }
            return tree
        }
    }

    /// Which tile window `k` halves on `tree`, the first `k` windows' tree, and which way: Sven's split names its first
    /// five, the rest (and dwindle's) halve the newest tile along its longer side.
    private func growth(_ k: Int, of tree: TileTree, in size: CGSize) -> (target: Int, sideways: Bool) {
        if self == .mainStack, let named = [1: (0, true), 2: (1, false), 3: (2, true), 4: (1, true)][k] { return named }
        let tile = tree.slots(in: CGRect(origin: .zero, size: size))[k - 1].rect
        return (k - 1, tile.width >= tile.height)
    }

    /// For the tiler's new window on a main + stack or dwindle workspace of `n` windows: the place in open order of the
    /// window whose tile it halves, and which way; nil for every other preset.
    public func growth(adding n: Int, in size: CGSize) -> (target: Int, sideways: Bool)? {
        guard self == .mainStack || self == .dwindle, n > 0, let tree = tree(n, in: size) else { return nil }
        return growth(n, of: tree, in: size)
    }

    /// `order`, a workspace's windows in open order as last built, followed through `reading`, its windows as the tree
    /// reads them now: a closed one drops out, a swap since swaps their places, a new one goes last. Sven's split and
    /// Centred main read in another order than they open (5 reads 1, 2, 5, 3, 4), so the tree's reading alone would
    /// reshuffle them on every rebuild.
    public func openOrder<ID: Hashable>(_ order: [ID], reading: [ID], in size: CGSize) -> [ID] {
        let kept = Set(order), now = reading.filter(kept.contains), still = Set(now)
        let built = (tree(order.count, in: size)?.reading ?? Array(order.indices)).map { order[$0] }.filter(still.contains)
        let moved = Dictionary(zip(built, now), uniquingKeysWith: { first, _ in first })
        return order.filter(still.contains).map { moved[$0] ?? $0 } + reading.filter { !kept.contains($0) }
    }

    /// `others`, in this preset's order, with `dropped` put where `point` falls (card agent-bo-95422861): in the tile this
    /// preset gives each of them in `area`, before that tile or after it along the way its column or row runs. A tile
    /// alone in its column splits left and right, one sharing it splits above and below.
    public func dropOrder(_ others: [Int], inserting dropped: Int, at point: CGPoint, in area: CGRect) -> [Int] {
        Self.dropOrder(others, inserting: dropped, at: point, slots: slots(others.count, in: area))
    }

    /// The same rule over `slots` the caller has, one per window in `others`: a nil slot (a column off the screen) is
    /// never the one dropped beside; with no slot at all the dropped window goes last.
    public static func dropOrder(_ others: [Int], inserting dropped: Int, at point: CGPoint, slots: [(rect: CGRect, stacked: Bool)?]) -> [Int] {
        let shown = slots.indices.compactMap { i in slots[i].map { (i, $0) } }
        guard let (nearest, slot) = shown.min(by: { distance($0.1.rect, point) < distance($1.1.rect, point) }) else { return others + [dropped] }
        let after = slot.stacked ? point.y >= slot.rect.midY : point.x >= slot.rect.midX
        var order = others
        order.insert(dropped, at: after ? nearest + 1 : nearest)
        return order
    }

    /// The tiles this preset lays `n` windows into within `area`, in order: the workspace editor's preview draws them.
    public func tiles(_ n: Int, in area: CGRect) -> [CGRect] { slots(n, in: area).map(\.rect) }

    /// How much of the width the editor's Stage picture gives the shelf: its room on a 1440 pt wide screen.
    static let shelfShare = CGFloat(PilotBlock.shelfWidth) / 1440

    /// How many of scrolling's columns the editor draws whole: a new window's third of the screen each.
    public static let shownColumns = 3

    /// How many spots a layout shows before it is full, `layout` nil for own sizes (Sven 2026-10-30: a picked layout
    /// draws its slots): grid's and dwindle's four, scrolling's columns drawn whole, the rest three. The layout pictures draw these.
    public static func spots(_ layout: LayoutPreset?) -> Int { layout == .grid || layout == .dwindle ? 4 : layout == .scrolling ? shownColumns : 3 }

    /// The tiles this preset lays `n` windows into within `area`, in open order, each with whether it shares its column:
    /// a tree's tiles, or scrolling's or stage's. Scrolling's strip: a lone window is the whole area, more are columns a third of it wide, and each past the third
    /// peeks in at the right edge, 8 % of the width (all of them a quarter at most), as the strip keeps a sliver of a
    /// column past the screen.
    private func slots(_ n: Int, in area: CGRect) -> [(rect: CGRect, stacked: Bool)] {
        guard n > 0 else { return [] }
        if let tree = tree(n, in: area.size) { return tree.slots(in: area) }
        switch self {
        case .columns, .rows, .mainStack, .dwindle, .centred, .grid: return []
        case .scrolling:
            guard n > 1 else { return [(area, false)] }
            let shown = Self.shownColumns, peek = area.width * min(0.08, 0.25 / CGFloat(max(1, n - shown)))
            let width = (area.width - CGFloat(max(0, n - shown)) * peek) / CGFloat(shown)
            return (0..<n).map { i in
                let x = area.minX + width * CGFloat(min(i, shown)) + peek * CGFloat(max(0, i - shown))
                return (CGRect(x: x, y: area.minY, width: i < shown ? width : peek, height: area.height), false)
            }
        case .stage:
            // The first on the stage right of the shelf's room, the rest shelved down that room, at most a quarter high each.
            let (shelf, stage) = area.divided(atDistance: area.width * Self.shelfShare, from: .minXEdge)
            guard n > 1 else { return [(stage, false)] }
            let height = min(shelf.height / CGFloat(n - 1), shelf.height / 4)
            return [(stage, false)] + (0..<(n - 1)).map { i in
                (CGRect(x: shelf.minX, y: shelf.minY + height * CGFloat(i), width: shelf.width, height: height), true)
            }
        }
    }

    /// Zero inside `rect`, else how far `point` is from it.
    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }
}

/// One workspace's preset and its auto switch, kept in UserDefaults as one JSON object by workspace name.
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public var preset: LayoutPreset?
    /// Re-apply the preset whenever a window opens or closes on the workspace.
    public var auto: Bool

    public init(preset: LayoutPreset?, auto: Bool) { self.preset = preset; self.auto = auto }

    /// Keep this layout is on unless a workspace turned it off (Sven's Q229, 2026-10-17): a saved row keeps the switch it
    /// was saved with, so an off Sven chose stays off; a row without one reads on.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(LayoutPreset.self, forKey: .preset)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? true
    }

    /// A workspace whose layout was never set: no ready layout, Keep this layout on (Q229).
    public static let unset = WorkspaceLayout(preset: nil, auto: true)

    public static let key = "workspaces.layouts"

    public static func load(_ defaults: UserDefaults) -> [String: WorkspaceLayout] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: WorkspaceLayout].self, from: $0) } ?? [:]
    }

    public static func save(_ layouts: [String: WorkspaceLayout], to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(layouts), forKey: key)
    }
}
