import SwiftUI

/// Home's drop slots (spec home-edit, seam 2): from the lanes as the page drew them and the frames it measured, each place a
/// carried block can land, the size it takes there and the area the pointer finds it in; and the slot under a point. Built
/// at pick-up and kept until the drop, while the page holds its shape (HomeNowEdit.held), so a slot never moves under the
/// pointer. The carried block's own spot falls in the slot that leaves it where it is.
struct HomeSlots {
    typealias Place = HomeEditSession.Place

    /// Home's lanes: the column's row of icon tabs, its small cards, and the board.
    enum Lane: Hashable, Sendable { case icons, column, board }

    struct Slot: Equatable {
        let place: Place
        /// The size a block dropped here takes: the lane sets it (Place.size(carrying:)).
        let size: HomeLayout.Size
        /// Where the pointer finds it, in the page's space: one rect, or more where a row of tabs or cards wraps or a
        /// lone medium's empty half cuts a board row's band. The slots of a page never overlap.
        let area: [CGRect]
    }

    let slots: [Slot]

    /// The slot under a point in the page's space, nil off every lane (the block goes back where it was).
    func slot(at point: CGPoint) -> Slot? { slots.first { $0.area.contains { $0.contains(point) } } }

    /// The slots for carrying `carried`, from what `frames` measured last; none before the page has drawn in edit mode.
    @MainActor
    init(_ frames: HomeFrames, carrying carried: String, size: (String) -> HomeLayout.Size) {
        slots = frames.drawn.map { Self.slots(lanes: $0.lanes, shape: $0.shape, rects: frames.rects, carrying: carried, size: size) } ?? []
    }

    static func slots(lanes: HomeLayout.Lanes, shape: HomeNow.Shape, rects: [HomeFrames.Key: CGRect], carrying carried: String,
                      size: (String) -> HomeLayout.Size) -> [Slot] {
        let half = shape.gap / 2, carriedSize = size(carried)
        func frame(_ id: String) -> CGRect? { rects[.block(id)] }
        /// A lane's band across its container, from its first block or well to its last, half a gap out on every side so
        /// the gaps between lanes and blocks belong to a slot too.
        func region(_ ids: [String], well: HomeSlots.Lane, across container: HomeSlots.Lane) -> CGRect? {
            guard let box = (ids.isEmpty ? [rects[.well(well)]] : ids.map(frame)).compactMap({ $0 }).union,
                  let lane = rects[.lane(container)] else { return nil }
            return CGRect(x: lane.minX, y: box.minY, width: lane.width, height: box.height).insetBy(dx: -half, dy: -half)
        }
        var found: [(Place, [CGRect])] = []
        func add(_ place: Place, _ rect: CGRect) {
            guard rect.width > 0.5, rect.height > 0.5 else { return }
            if let i = found.firstIndex(where: { $0.0 == place }) { found[i].1.append(rect) } else { found.append((place, [rect])) }
        }

        // The icon tabs and, stacked, the small cards flow in rows; beside the board the cards are one column.
        if let area = region(lanes.icons, well: .icons, across: .column) {
            for (place, rect) in flow(lanes.icons.filter { $0 != carried }, frame: frame, in: area, place: Place.icons) { add(place, rect) }
        }
        if let area = region(lanes.column, well: .column, across: .column) {
            let cards = lanes.column.filter { $0 != carried }
            let rows = shape.wide ? stack(cards.compactMap { id in frame(id).map { (id, $0) } }, in: area, place: Place.column)
                : flow(cards, frame: frame, in: area, place: Place.column)
            for (place, rect) in rows { add(place, rect) }
        }
        // The board's rows, the carried block out of its own; a row left with one medium, while the board holds two, has
        // the empty half beside it, which cuts the rows' bands.
        if let area = region(lanes.board.flatMap { $0 }, well: .board, across: .board), let board = rects[.lane(.board)] {
            // Each row as drawn, the carried block out of it, and where it lies.
            let rows = lanes.board.compactMap { drawn -> (drawn: [String], ids: [String], rect: CGRect)? in
                let ids = drawn.filter { $0 != carried }
                return ids.compactMap(frame).union.map { (drawn, ids, $0) }
            }
            var beside: [(Place, CGRect)] = []
            if shape.across == 2 {
                let each = (board.width - shape.gap) / 2
                for row in rows where row.ids.count == 1 && size(row.ids[0]) == .medium {
                    // Its empty half is the left one only when its pair there was picked up.
                    let left = row.drawn.first == carried
                    beside.append((.beside(row.ids[0], trailing: !left),
                                   CGRect(x: left ? board.minX : board.maxX - each, y: row.rect.minY, width: each, height: row.rect.height)))
                }
            }
            for (place, rect) in stack(rows.map { ($0.ids[0], $0.rect) }, in: area, place: Place.board) {
                for piece in beside.reduce([rect], { pieces, well in pieces.flatMap { cut($0, well.1) } }) { add(place, piece) }
            }
            for (place, rect) in beside { add(place, rect) }
        }
        return found.map { Slot(place: $0.0, size: $0.0.size(carrying: carriedSize), area: $0.1) }
    }

    /// One block over the next: the band from the last one's middle to this one's goes in front of it, the rest of the
    /// lane past the last one's middle to its end.
    static func stack(_ units: [(String, CGRect)], in area: CGRect, place: (String?) -> Place) -> [(Place, CGRect)] {
        var top = area.minY, out: [(Place, CGRect)] = []
        for (id, rect) in units {
            out.append((place(id), CGRect(x: area.minX, y: top, width: area.width, height: rect.midY - top)))
            top = rect.midY
        }
        out.append((place(nil), CGRect(x: area.minX, y: top, width: area.width, height: area.maxY - top)))
        return out
    }

    /// Rows of blocks side by side, wrapping: in a row, from the last one's middle to this one's goes in front of it; past
    /// a row's last middle goes in front of the next row's first, or to the lane's end.
    static func flow(_ ids: [String], frame: (String) -> CGRect?, in area: CGRect, place: (String?) -> Place) -> [(Place, CGRect)] {
        let items = ids.compactMap { id in frame(id).map { (id, $0) } }
        var rows: [[(String, CGRect)]] = []
        for item in items {
            // A block right of the last one and level with it is in its row.
            if let last = rows.last?.last, item.1.minY < last.1.maxY - 0.5, item.1.minX > last.1.minX {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        guard !rows.isEmpty else { return [(place(nil), area)] }
        let boxes = rows.map { $0.map(\.1).union! }
        var out: [(Place, CGRect)] = [], next = 0
        for (k, row) in rows.enumerated() {
            let top = k == 0 ? area.minY : (boxes[k - 1].maxY + boxes[k].minY) / 2
            let bottom = k == rows.count - 1 ? area.maxY : (boxes[k].maxY + boxes[k + 1].minY) / 2
            var x = area.minX
            for (id, rect) in row {
                out.append((place(id), CGRect(x: x, y: top, width: rect.midX - x, height: bottom - top)))
                x = rect.midX
            }
            next += row.count
            out.append((place(next < items.count ? items[next].0 : nil), CGRect(x: x, y: top, width: area.maxX - x, height: bottom - top)))
        }
        return out
    }

    /// `rect` less `hole`: what is above, below, left and right of it.
    static func cut(_ rect: CGRect, _ hole: CGRect) -> [CGRect] {
        let i = rect.intersection(hole)
        guard !i.isNull, i.width > 0.5, i.height > 0.5 else { return [rect] }
        return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: i.minY - rect.minY),
                CGRect(x: rect.minX, y: i.maxY, width: rect.width, height: rect.maxY - i.maxY),
                CGRect(x: rect.minX, y: i.minY, width: i.minX - rect.minX, height: i.height),
                CGRect(x: i.maxX, y: i.minY, width: rect.maxX - i.maxX, height: i.height)].filter { $0.width > 0.5 && $0.height > 0.5 }
    }
}

/// Where Home's page measures itself in edit mode: each block's frame, each lane's (the column, the board) and each empty
/// lane's well, in the page's space, and the lanes and shape it drew. Plain storage: a frame written never draws again.
@MainActor
final class HomeFrames {
    static let space = "home.page"

    enum Key: Hashable { case block(String), lane(HomeSlots.Lane), well(HomeSlots.Lane) }

    struct Drawn: Equatable {
        let shape: HomeNow.Shape
        let lanes: HomeLayout.Lanes
    }

    var rects: [Key: CGRect] = [:]
    var drawn: Drawn?
    /// Where the page, the window's Home and the edit bar lie on screen (global space), for a carried block (T5): the
    /// pointer is global, the slots are in the page's space, and the page moves under a still pointer as it scrolls.
    var origin: CGPoint?
    var window: CGRect?
    var bar: CGRect?
    /// How far Home's page has scrolled and how far it can, for auto-scroll.
    var scroll: ScrollGeometry?

    /// The block drawn under a point in the page's space, if any.
    func block(at point: CGPoint) -> String? {
        guard let lanes = drawn?.lanes else { return nil }
        return (lanes.icons + lanes.column + lanes.board.flatMap { $0 }).first { rects[.block($0)]?.contains(point) == true }
    }
}

/// Home in edit mode, as its page is told (spec home-edit): an empty lane draws as a well, the page measures itself into
/// `frames`, and `held`, the shape taken at pick-up, keeps the column beside the board or over it until the drop.
struct HomeNowEdit {
    let frames: HomeFrames
    var held: HomeNow.Shape?
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

private extension Array where Element == CGRect {
    var union: CGRect? { first.map { dropFirst().reduce($0) { $0.union($1) } } }
}
