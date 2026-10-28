import Foundation

/// Binds' whole keyboard (card agent-bo-95423003, Sven 2026-10-07: "no fn keys no arrows etc, it should match any
/// keyboard layout"): a tenkeyless board, the shape of Sven's Keychron V3 Max. Esc and F1 to F12 in groups of four, the
/// nav cluster (Insert, Home, Page Up; Forward Delete, End, Page Down) and the arrows beside the main block, every
/// modifier on both sides with fn by the right Ctrl as Keychron's Mac mode has it. ANSI or ISO as macOS reports the
/// board, each key's caption from the Mac's keyboard layout where it types a character. `compact` is the 75 % board a
/// narrow window draws: the nav keys one column down the right, the arrows tucked under it.
extension BindsKeyboard {
    public enum Shape: Sendable { case ansi, iso }
    public enum Modifier: Sendable {
        case shift, ctrl, alt, cmd, fn, caps

        /// Both sides of it as a bind's modifiers; none for fn and Caps Lock.
        public var both: Modifiers {
            switch self {
            case .shift: .shift
            case .ctrl: .ctrl
            case .alt: .alt
            case .cmd: .cmd
            case .fn, .caps: []
            }
        }
    }
    public enum Side: Sendable { case left, right }

    /// One key on the board: where it sits in key units (a row's `x` from the board's left edge), its caption, the key
    /// code a bind takes (nil for a modifier), and the modifier it is. ISO's Return spans its row and the next, narrower
    /// below (`isoReturn`).
    public struct Spot: Equatable, Sendable {
        public let legend: String
        public let code: Int64?
        public let row: Int
        public let x: Double
        public let width: Double
        public var modifier: Modifier?
        public var side: Side?
        public var isoReturn = false
    }

    public struct Board: Equatable, Sendable {
        /// The board's width in key units: 15 for the main block, a quarter's gap, the three nav columns (one when compact).
        public let width: Double
        public let spots: [Spot]
        /// Every key code a bind can take on the board.
        public let codes: Set<Int64>

        /// `legends` are the layout's characters by key code (lowercase is drawn as capitals); a key it does not name
        /// keeps its US name; with `capitals` off a letter keeps the case it types (an Option board: ⌥A types å). `pcSwap` is a PC layout on an ISO board (British-PC): the key left of 1 sends 50 and the
        /// key left of Z sends 10, where Apple's own ISO board has them the other way round.
        public init(_ shape: Shape, legends: [Int64: String] = [:], pcSwap: Bool = false, compact: Bool = false, capitals: Bool = true) {
            width = compact ? 16.25 : 18.25
            var spots: [Spot] = []
            var x = 0.0, row = 0
            func key(_ legend: String, _ code: Int64?, _ width: Double = 1, modifier: Modifier? = nil, side: Side? = nil) {
                let caption = code.flatMap { legends[$0] }.flatMap { Self.caption($0, capitals: capitals) } ?? legend
                spots.append(Spot(legend: caption, code: code, row: row, x: x, width: width, modifier: modifier, side: side))
                x += width
            }
            func typed(_ codes: [Int64]) { for code in codes { key(KeyNames.name(for: code), code) } }
            func next(at start: Double = 0) { row += 1; x = start }
            func nav(_ keys: [(String, Int64)], from column: Int = 0) {
                x = 15.25 + Double(column)
                for (legend, code) in keys { key(legend, code) }
            }

            // Esc, then F1 to F12 in groups of four, a key's gap after Esc and half one between the groups.
            key("Esc", 53)
            for (i, code) in ([122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] as [Int64]).enumerated() {
                x = 2 + Double(i) + Double(i / 4) * 0.5
                key("F\(i + 1)", code)
            }
            if compact { nav([("⌦", 117)]) }

            let iso = shape == .iso
            let section: Int64 = iso && !pcSwap ? 10 : 50, extra: Int64 = pcSwap ? 10 : 50
            next()
            typed([section, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24])
            key("Delete", 51, 2)
            nav(compact ? [("Home", 115)] : [("Ins", 114), ("Home", 115), ("PgUp", 116)])

            next()
            key("Tab", 48, 1.5)
            typed([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30])
            if iso {
                spots.append(Spot(legend: "Return", code: 36, row: row, x: x, width: 1.5, isoReturn: true))
            } else {
                key(KeyNames.name(for: 42), 42, 1.5)
            }
            nav(compact ? [("PgUp", 116)] : [("⌦", 117), ("End", 119), ("PgDn", 121)])

            next()
            key("Caps", nil, 1.75, modifier: .caps)
            typed([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39])
            if iso { typed([42]) } else { key("Return", 36, 2.25) }
            if compact { nav([("PgDn", 121)]) }

            next()
            key("Shift", nil, iso ? 1.25 : 2.25, modifier: .shift, side: .left)
            if iso { typed([extra]) }
            typed([6, 7, 8, 9, 11, 45, 46, 43, 47, 44])
            key("Shift", nil, compact ? 1.75 : 2.75, modifier: .shift, side: .right)
            if compact { x = 14.25; key("↑", 126); key("End", 119) } else { nav([("↑", 126)], from: 1) }

            next()
            key("Ctrl", nil, 1.25, modifier: .ctrl, side: .left)
            key("Opt", nil, 1.25, modifier: .alt, side: .left)
            key("Cmd", nil, 1.25, modifier: .cmd, side: .left)
            let right = compact ? 1.0 : 1.25
            key("Space", 49, compact ? 5.5 : 6.25)
            key("Cmd", nil, right, modifier: .cmd, side: .right)
            key("Opt", nil, right, modifier: .alt, side: .right)
            key("Fn", nil, right, modifier: .fn, side: .right)
            key("Ctrl", nil, right, modifier: .ctrl, side: .right)
            if compact { key("←", 123); key("↓", 125); key("→", 124) } else { nav([("←", 123), ("↓", 125), ("→", 124)]) }
            self.spots = spots
            codes = Set(spots.compactMap(\.code))
            halves = 1
        }

        /// 1 for a whole board, 2 for a split one, its right half under its left, `rowsPerHalf` rows down.
        public let halves: Int
        public static let rowsPerHalf = 6

        private init(width: Double, spots: [Spot]) {
            self.width = width
            self.spots = spots
            codes = Set(spots.compactMap(\.code))
            halves = 2
        }

        /// The compact board in two halves, the right one under the left (card agent-bo-95423023), for a window too narrow
        /// to name every key whole: each half's keys twice as wide. Split as an Alice board is: Esc to F5, 6, T, G, B and
        /// Space on the left; F6 on, 7, Y, H, N, the nav column and the arrows on the right, rows 6 to 11. Each half keeps
        /// its outer edge in line and its inner edge ragged, as on a split board; Space ends under B and the right Cmd
        /// widens to the right half's inner edge, so neither half has a hole at its foot.
        public func split() -> Board {
            // Where each row's right half starts, in key units of the compact board; the right half moves left by `shift`.
            let starts: [Double] = [7.5, 7, 6.5, 6.75, 7.25, 9.25], shift = 6.5, spaceEnd = 7.25, rightCmd = 7.25
            let halved = spots.map { spot -> Spot in
                guard spot.x >= starts[spot.row] else {
                    return spot.code == 49 ? Spot(legend: spot.legend, code: spot.code, row: spot.row, x: spot.x, width: spaceEnd - spot.x) : spot
                }
                let x = spot.modifier == .cmd && spot.side == .right ? rightCmd : spot.x
                return Spot(legend: spot.legend, code: spot.code, row: spot.row + Self.rowsPerHalf, x: x - shift, width: spot.width + spot.x - x,
                            modifier: spot.modifier, side: spot.side, isoReturn: spot.isoReturn)
            }
            return Board(width: width - shift, spots: halved)
        }

        /// A layout's character as a cap shows it: a letter as its capital (ß stays ß); nil for one that prints nothing,
        /// which keeps the US name.
        static func caption(_ typed: String, capitals: Bool = true) -> String? {
            let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !trimmed.isEmpty else { return nil }
            guard capitals else { return trimmed }
            let capital = trimmed.uppercased()
            return capital.count == trimmed.count ? capital : trimmed
        }
    }
}
