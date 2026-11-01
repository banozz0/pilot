import CoreGraphics
import Foundation

/// A workspace's layout preset (story 107, card agent-bo-95422736). Pilot's tiler arranges a workspace as one in its own
/// tree (WorkspaceArrangement); a workspace preset's apply builds it from tiler commands: flatten the workspace, set its
/// root, order the tiles by moving each to the far end in turn, group the ones that share a column, then equal sizes. A
/// column starts with join-with between two windows; a later window moves left into it, since a second join would nest
/// it and the tiler's normalization would turn the inner pair sideways. Scrolling is every window a column on one strip,
/// each at its own width, so it needs no groups and no equal sizes (spec Projects/Pilot/specs/scrolling-layout.html).
/// Stage tiles the focused window's group in the centre and shelves the rest at the left edge (ADR 0015).
public enum LayoutPreset: String, CaseIterable, Codable, Sendable {
    case mainStack, columns, rows, grid, scrolling, stage

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
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .scrolling: "Scrolling"
        case .stage: "Stage"
        }
    }

    /// The one key's cycle; a workspace with no preset starts at main + stack.
    public static func next(after preset: LayoutPreset?) -> LayoutPreset {
        guard let preset, let i = allCases.firstIndex(of: preset) else { return .mainStack }
        return allCases[(i + 1) % allCases.count]
    }

    /// The commands that build this preset from `windows`, the tiles in the order they should read; none for none.
    public func commands(workspace: String, windows: [Int]) -> [AeroCommand] {
        guard !windows.isEmpty else { return [] }
        let along: Direction = self == .rows ? .down : .right
        let order = windows.flatMap { id in Array(repeating: AeroCommand.move(id: id, along), count: windows.count - 1) }
        let group: [AeroCommand] = switch self {
        case .mainStack: windows.dropFirst(2).prefix(1).map { .joinWith(id: $0, .left) } + windows.dropFirst(3).map { .move(id: $0, .left) }
        case .grid: windows.indices.filter { $0 % 2 == 1 }.map { .joinWith(id: windows[$0], .left) }
        case .columns, .rows, .scrolling, .stage: []
        }
        let root = switch self { case .rows: "v_tiles"; case .scrolling: "h_scrolling"; case .stage: "h_stage"; default: "h_tiles" }
        return [.flatten(workspace: workspace), .setRootLayout(workspace: workspace, root)] + order + group
            + (self == .scrolling ? [] : [.balanceSizes(workspace: workspace)])
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
    /// draws its slots): grid's four, scrolling's columns drawn whole, the rest three. The layout pictures draw these.
    public static func spots(_ layout: LayoutPreset?) -> Int { layout == .grid ? 4 : layout == .scrolling ? shownColumns : 3 }

    /// The tiles this preset lays `n` windows into within `area`, in order, each with whether it shares its column.
    /// Scrolling's strip: a lone window is the whole area, more are columns a third of it wide, and each past the third
    /// peeks in at the right edge, 8 % of the width (all of them a quarter at most), as the strip keeps a sliver of a
    /// column past the screen.
    private func slots(_ n: Int, in area: CGRect) -> [(rect: CGRect, stacked: Bool)] {
        func split(_ r: CGRect, _ k: Int, stacked: Bool) -> [(rect: CGRect, stacked: Bool)] {
            (0..<k).map { i in
                let rect = stacked ? CGRect(x: r.minX, y: r.minY + r.height * CGFloat(i) / CGFloat(k), width: r.width, height: r.height / CGFloat(k))
                    : CGRect(x: r.minX + r.width * CGFloat(i) / CGFloat(k), y: r.minY, width: r.width / CGFloat(k), height: r.height)
                return (rect, stacked)
            }
        }
        guard n > 0 else { return [] }
        switch self {
        case .columns: return split(area, n, stacked: false)
        case .scrolling:
            guard n > 1 else { return [(area, false)] }
            let shown = Self.shownColumns, peek = area.width * min(0.08, 0.25 / CGFloat(max(1, n - shown)))
            let width = (area.width - CGFloat(max(0, n - shown)) * peek) / CGFloat(shown)
            return (0..<n).map { i in
                let x = area.minX + width * CGFloat(min(i, shown)) + peek * CGFloat(max(0, i - shown))
                return (CGRect(x: x, y: area.minY, width: i < shown ? width : peek, height: area.height), false)
            }
        case .rows: return split(area, n, stacked: true)
        case .stage:
            // The first on the stage right of the shelf's room, the rest shelved down that room, at most a quarter high each.
            let (shelf, stage) = area.divided(atDistance: area.width * Self.shelfShare, from: .minXEdge)
            guard n > 1 else { return [(stage, false)] }
            let height = min(shelf.height / CGFloat(n - 1), shelf.height / 4)
            return [(stage, false)] + (0..<(n - 1)).map { i in
                (CGRect(x: shelf.minX, y: shelf.minY + height * CGFloat(i), width: shelf.width, height: height), true)
            }
        case .mainStack:
            guard n > 1 else { return [(area, false)] }
            let (main, stack) = area.divided(atDistance: area.width / 2, from: .minXEdge)
            return [(main, false)] + split(stack, n - 1, stacked: true)
        case .grid:
            return split(area, (n + 1) / 2, stacked: false).enumerated().flatMap { c, column in
                n - 2 * c > 1 ? split(column.rect, 2, stacked: true) : [column]
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
