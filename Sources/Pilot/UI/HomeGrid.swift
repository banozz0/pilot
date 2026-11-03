import PilotCore
import SwiftUI

// Home's grid (P91, model A, Sven Q746/Q747): 23 columns of cells 56 pt tall with 8 pt between them. A block takes whole
// cells; one moved or resized wins its cells, blocks in its way move down, and every block then floats up into free
// space, so nothing overlaps and no gap opens. The columns stretch or shrink with the window, so each block keeps its
// share of the width and draws the class its points pick (Widget.SizeClass).

/// A block's place on Home's grid, in cells: its left column, its top row, and how many columns and rows it spans.
struct HomeCell: Codable, Hashable, Sendable, CustomStringConvertible {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var maxX: Int { x + w }
    var maxY: Int { y + h }

    func overlaps(_ other: HomeCell) -> Bool { x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY }

    /// The most rows a block takes.
    static let tallest = 40

    /// Within the grid's columns, at least one cell each way.
    var fits: Bool { x >= 0 && y >= 0 && w >= 1 && h >= 1 && maxX <= HomeGrid.columns }

    /// The same cell kept inside the columns, `tallest` rows at most: its left edge moved in first, then its width cut to
    /// what is left.
    var clamped: HomeCell {
        let x = min(max(0, x), HomeGrid.columns - 1)
        return HomeCell(x: x, y: max(0, y), w: min(max(1, w), HomeGrid.columns - x), h: min(max(1, h), Self.tallest))
    }

    /// The sides a resize moves: a corner two, an edge one.
    struct Edges: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    /// The cell with `edges` moved `dx` columns and `dy` rows, the opposite sides kept: inside the columns, never under one
    /// cell nor over `tallest` rows (a handle's drag, Shift and an arrow).
    func resized(_ edges: Edges, dx: Int, dy: Int) -> HomeCell {
        var cell = self
        if edges.contains(.right) { cell.w = min(max(1, w + dx), HomeGrid.columns - x) }
        if edges.contains(.left) { cell.x = min(max(0, x + dx), maxX - 1); cell.w = maxX - cell.x }
        if edges.contains(.bottom) { cell.h = min(max(1, h + dy), Self.tallest) }
        if edges.contains(.top) { cell.y = min(max(0, maxY - Self.tallest, y + dy), maxY - 1); cell.h = maxY - cell.y }
        return cell
    }

    /// "5,0 18×6", as the CLI and the probe print it.
    var description: String { "\(x),\(y) \(w)×\(h)" }

    /// Reads "x,y,w,h" (the CLI's --cells).
    init?(words: String) {
        let parts = words.split(whereSeparator: { ", ×x".contains($0) }).compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        self.init(x: parts[0], y: parts[1], w: parts[2], h: parts[3])
    }

    init(x: Int, y: Int, w: Int, h: Int) {
        (self.x, self.y, self.w, self.h) = (x, y, w, h)
    }
}

/// The grid's measures and its packing.
enum HomeGrid {
    /// Always 23 columns, at every window width (the page's 1000 × 660 frame: cells 30 pt wide instead of 57).
    static let columns = 23
    /// A row's height and the room between cells, both ways.
    static let row: CGFloat = 56, gap: CGFloat = 8
    static var pitch: CGFloat { row + gap }

    /// A column's width on a page `inner` points wide.
    static func cellWidth(_ inner: CGFloat) -> CGFloat { max(1, (inner - CGFloat(columns - 1) * gap) / CGFloat(columns)) }

    /// Where a cell draws on a page `inner` wide, from the grid's top left.
    static func rect(_ cell: HomeCell, inner: CGFloat) -> CGRect {
        let width = cellWidth(inner)
        return CGRect(x: CGFloat(cell.x) * (width + gap), y: CGFloat(cell.y) * pitch,
                      width: CGFloat(cell.w) * width + CGFloat(cell.w - 1) * gap, height: CGFloat(cell.h) * pitch - gap)
    }

    /// The grid's height for its lowest block.
    static func height(_ cells: some Collection<HomeCell>) -> CGFloat {
        let rows = cells.map(\.maxY).max() ?? 0
        return rows == 0 ? 0 : CGFloat(rows) * pitch - gap
    }

    /// The cells nearest a frame on a page `inner` wide: its top left to the nearest cell, its size to whole cells.
    static func cell(nearest rect: CGRect, inner: CGFloat) -> HomeCell {
        let across = cellWidth(inner) + gap
        return HomeCell(x: Int((rect.minX / across).rounded()), y: Int((rect.minY / pitch).rounded()),
                        w: max(1, Int(((rect.width + gap) / across).rounded())), h: max(1, Int(((rect.height + gap) / pitch).rounded()))).clamped
    }

    /// The class a block draws: the one its Layout keeps, else by its points (Widget.SizeClass). One row is always a
    /// Strip. Cells change a whole cell at a time, so a drag needs no hold near a line.
    static func sizeClass(_ cell: HomeCell, inner: CGFloat, pin: Widget.SizeClass?) -> Widget.SizeClass {
        if let pin { return pin }
        if cell.h == 1 { return .strip }
        return Widget.SizeClass(rect(cell, inner: inner).size)
    }

    /// The blocks packed: each in turn rises as far as it can and drops below whatever it lands on, so a block in the way
    /// moves down, a block under freed space floats up, and none overlap. `subject` (the one moved, resized or shown) wins
    /// the cells it is put on: it goes before every block in its columns but those whose middle is above its top, and, moved
    /// down from `from`, those it was over whose middle its bottom has passed. The others go in reading order; `order`
    /// breaks ties the same way each time.
    static func settle(_ cells: [String: HomeCell], subject: String? = nil, from: HomeCell? = nil, order: [String] = []) -> [String: HomeCell] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var ids = cells.keys.filter { $0 != subject }.sorted { a, b in
            let (p, q) = (cells[a]!, cells[b]!)
            return (p.y, p.x, rank[a] ?? .max, a) < (q.y, q.x, rank[b] ?? .max, b)
        }
        if let subject, let target = cells[subject] {
            let above = { (o: HomeCell) -> Bool in
                guard o.x < target.maxX && target.x < o.maxX else { return o.y < target.y }
                if 2 * o.y + o.h <= 2 * target.y { return true }
                guard let from, target.y > from.y, o.x < from.maxX && from.x < o.maxX else { return false }
                return o.y >= from.y && 2 * o.y + o.h < 2 * target.maxY
            }
            ids = ids.filter { above(cells[$0]!) } + [subject] + ids.filter { !above(cells[$0]!) }
        }
        var placed: [(String, HomeCell)] = []
        for id in ids {
            var cell = cells[id]!.clamped
            while cell.y > 0, !placed.contains(where: { $0.1.overlaps(HomeCell(x: cell.x, y: cell.y - 1, w: cell.w, h: cell.h)) }) { cell.y -= 1 }
            while let below = placed.filter({ $0.1.overlaps(cell) }).map(\.1.maxY).max() { cell.y = below }
            placed.append((id, cell))
        }
        return Dictionary(uniqueKeysWithValues: placed)
    }

    /// The cell a block takes when shown with no place of its own: its size at the grid's foot, at the left.
    static func foot(_ size: (w: Int, h: Int), under cells: some Collection<HomeCell>) -> HomeCell {
        HomeCell(x: 0, y: cells.map(\.maxY).max() ?? 0, w: size.w, h: size.h).clamped
    }

    /// Whether `cells` is a layout Home can draw: every block inside the columns, none on another.
    static func valid(_ cells: [HomeCell]) -> Bool {
        cells.allSatisfy(\.fits) && !cells.indices.contains { i in cells[(i + 1)...].contains { $0.overlaps(cells[i]) } }
    }
}

/// Where Home's page measures itself in edit mode: each block's frame and the grid's, in the page's space; where the
/// page, the window's Home and the edit bar lie on screen; and how far the page has scrolled. Plain storage: a frame
/// written never draws again.
@MainActor
final class HomeFrames {
    static let space = "home.page"

    enum Key: Hashable { case block(String), grid }

    var rects: [Key: CGRect] = [:]
    /// The cells the page drew, by block.
    var cells: [String: HomeCell] = [:]
    var origin: CGPoint?
    var window: CGRect?
    var bar: CGRect?
    var scroll: ScrollGeometry?

    /// The grid's width, as the page drew it.
    var inner: CGFloat? { rects[.grid]?.width }

    /// Where a block's cells lie in the page's space, from the grid as measured: exact while the page animates, unlike
    /// the block's own measured frame.
    func frame(of id: String) -> CGRect? {
        guard let grid = rects[.grid], let cell = cells[id] else { return rects[.block(id)] }
        return HomeGrid.rect(cell, inner: grid.width).offsetBy(dx: grid.minX, dy: grid.minY)
    }

    /// The block whose cells lie under a point in the page's space, if any.
    func block(at point: CGPoint) -> String? {
        cells.keys.sorted().first { frame(of: $0)?.contains(point) == true }
    }

    /// The cell nearest a frame given in the page's space.
    func cell(nearest rect: CGRect) -> HomeCell? {
        guard let grid = rects[.grid] else { return nil }
        return HomeGrid.cell(nearest: rect.offsetBy(dx: -grid.minX, dy: -grid.minY), inner: grid.width)
    }
}

/// Home in edit mode, as its page is told: the page measures itself into `frames`.
struct HomeNowEdit {
    let frames: HomeFrames
}

extension EnvironmentValues {
    @Entry var homeEdit: HomeNowEdit? = nil
}

extension View {
    /// Reports this view's frame on Home's page while it is in edit mode.
    func homeFrame(_ key: HomeFrames.Key, _ edit: HomeNowEdit?) -> some View {
        onGeometryChange(for: CGRect?.self) { edit == nil ? nil : $0.frame(in: .named(HomeFrames.space)) } action: { rect in
            if let rect { edit?.frames.rects[key] = rect }
        }
    }
}

/// Home's blocks on the grid: each placed at its cell's frame on a page as wide as it is offered, the grid as tall as its
/// lowest block.
struct HomeGridLayout: Layout {
    static func inner(_ proposal: ProposedViewSize) -> CGFloat { proposal.width ?? 1000 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: Self.inner(proposal), height: HomeGrid.height(subviews.compactMap { $0[HomeCellKey.self] }))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            guard let cell = view[HomeCellKey.self] else { continue }
            let rect = HomeGrid.rect(cell, inner: bounds.width)
            view.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY), proposal: ProposedViewSize(rect.size))
        }
    }
}

private struct HomeCellKey: LayoutValueKey {
    static let defaultValue: HomeCell? = nil
}

extension View {
    /// Where this block sits in HomeGridLayout.
    func homeCell(_ cell: HomeCell) -> some View { layoutValue(key: HomeCellKey.self, value: cell) }
}
