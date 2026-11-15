import Foundation

extension Widget {
    /// The desktop's widget grid (Sven, 2026-11-15: "lock grid so they're very well aligned"): while Snap to grid is on, a
    /// move, a resize and a new placement land on whole cells of one size with one gap between them, for every widget, so
    /// edges and gaps line up. The grid fills a screen's room (its frame less the top bar and the dock), its columns and
    /// rows centred there, so the margins match on either side. Top-left coordinates throughout.
    public struct Grid: Equatable, Sendable {
        /// One cell's side and the room between two cells: a widget's side is n cells and the n − 1 gaps between them.
        public static let cell = 40.0, gap = 16.0
        public static var pitch: Double { cell + gap }

        /// The room it fills, its first cell's top left, and how many cells fit each way.
        public let area: CGRect, origin: CGPoint, columns: Int, rows: Int

        /// A cell's place and size, in cells.
        public struct Cell: Equatable, Sendable {
            public var x: Int, y: Int, w: Int, h: Int
            public init(x: Int, y: Int, w: Int, h: Int) { (self.x, self.y, self.w, self.h) = (x, y, w, h) }
            public func overlaps(_ o: Cell) -> Bool { x < o.x + o.w && o.x < x + w && y < o.y + o.h && o.y < y + h }
            /// `col,row wxh`, as `pilot status --part widgets` gives it.
            public var line: String { "\(x),\(y) \(w)x\(h)" }
        }

        /// The grid in `area`, at least one cell each way, centred with the room left over.
        public init(area: CGRect) {
            self.area = area
            let fit = { (side: Double) in max(1, Int(((side - Self.gap) / Self.pitch).rounded(.down))) }
            columns = fit(area.width); rows = fit(area.height)
            let used = { (n: Int) in Double(n) * Self.pitch - Self.gap }
            origin = CGPoint(x: area.minX + max(0, (area.width - used(columns)) / 2), y: area.minY + max(0, (area.height - used(rows)) / 2))
        }

        /// The points `n` cells span.
        public static func length(_ n: Int) -> Double { Double(n) * pitch - gap }

        /// The fewest cells a side may span: a widget's smallest side (Widget.Size.range) fits in them.
        public static var fewest: Int { Int(((Size.range.lowerBound + gap) / pitch).rounded(.up)) }

        /// The cells nearest a side, at least `fewest` and no more than `most`.
        public static func span(_ side: Double, most: Int) -> Int {
            min(max(fewest, Int(((side + gap) / pitch).rounded())), max(fewest, most))
        }

        /// Where a cell draws.
        public func rect(_ cell: Cell) -> CGRect {
            CGRect(x: origin.x + Double(cell.x) * Self.pitch, y: origin.y + Double(cell.y) * Self.pitch,
                   width: Self.length(cell.w), height: Self.length(cell.h))
        }

        /// The cells nearest a frame: its size to whole cells, its top left to the nearest cell, kept on the grid.
        public func cell(nearest frame: CGRect) -> Cell {
            let w = Self.span(frame.width, most: columns), h = Self.span(frame.height, most: rows)
            let x = Int(((frame.minX - origin.x) / Self.pitch).rounded()), y = Int(((frame.minY - origin.y) / Self.pitch).rounded())
            return Cell(x: x.clamped(0, columns - w), y: y.clamped(0, rows - h), w: w, h: h)
        }

        /// The cells a resize lands on: each pulled edge to the nearest cell's edge, the edges it does not pull kept
        /// where they are (on the grid already, while it snaps), at least `fewest` cells each way.
        public func cell(pulled frame: CGRect, left: Bool, top: Bool) -> Cell {
            func axis(_ low: Double, _ high: Double, _ start: Double, _ count: Int, pullsLow: Bool) -> (Int, Int) {
                let first = Int(((low - start) / Self.pitch).rounded()), past = Int(((high - start + Self.gap) / Self.pitch).rounded())
                let n = min(max(Self.fewest, past - first), max(1, count))
                return pullsLow ? (min(max(past, n), count) - n, n) : (max(0, min(first, count - n)), n)
            }
            let (x, w) = axis(frame.minX, frame.maxX, origin.x, columns, pullsLow: left)
            let (y, h) = axis(frame.minY, frame.maxY, origin.y, rows, pullsLow: top)
            return Cell(x: x, y: y, w: w, h: h)
        }

        /// Whether a frame is exactly its nearest cells, within half a point.
        public func holds(_ frame: CGRect) -> Bool {
            let rect = rect(cell(nearest: frame))
            return abs(rect.minX - frame.minX) < 0.5 && abs(rect.minY - frame.minY) < 0.5 && abs(rect.width - frame.width) < 0.5
                && abs(rect.height - frame.height) < 0.5
        }

        /// The free place nearest `cell`, its size kept, clear of every one in `taken`; the cell itself when none is free
        /// (a full screen overlaps rather than leaving one off). Ties go in reading order.
        public func free(_ cell: Cell, avoiding taken: [Cell]) -> Cell {
            guard taken.contains(where: cell.overlaps) else { return cell }
            var best: (Cell, Int)?
            for y in 0...max(0, rows - cell.h) {
                for x in 0...max(0, columns - cell.w) {
                    let spot = Cell(x: x, y: y, w: cell.w, h: cell.h)
                    guard !taken.contains(where: spot.overlaps) else { continue }
                    let d = (x - cell.x) * (x - cell.x) + (y - cell.y) * (y - cell.y)
                    if best.map({ d < $0.1 }) ?? true { best = (spot, d) }
                }
            }
            return best?.0 ?? cell
        }

        /// Frames put on the grid together: each takes its nearest cells, or the nearest free ones when one before it holds
        /// them, so none overlap while there is room. The ones already on the grid go first, so a new one never moves
        /// them; then the rest, in reading order (top to bottom, then left to right).
        public func pack(_ frames: [CGRect]) -> [Cell] {
            let order = frames.indices.sorted {
                (holds(frames[$0]) ? 0 : 1, frames[$0].minY, frames[$0].minX, $0) < (holds(frames[$1]) ? 0 : 1, frames[$1].minY, frames[$1].minX, $1)
            }
            var cells = [Cell?](repeating: nil, count: frames.count)
            var taken: [Cell] = []
            for i in order {
                let cell = free(cell(nearest: frames[i]), avoiding: taken)
                cells[i] = cell
                taken.append(cell)
            }
            return cells.map { $0! }
        }
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), Swift.max(low, high)) }
}
