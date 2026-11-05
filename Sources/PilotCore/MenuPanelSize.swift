import CoreGraphics

/// The menu panel's size (card agent-bo-95422981, mockups A and B; Q130): 750 wide everywhere in Instrument, as Raycast's;
/// the shape sets how tall it may grow and its rows: short at the root and in Trigger and Capture, System taller for its
/// sections, a search and every other branch in between. Toybox keeps its own widths.
public enum MenuPanelSize {
    /// `points` one scale step up, as the menu's type and rows are (PilotStyle.scale, C3): every size here goes through it.
    public static func s(_ points: CGFloat) -> CGFloat { (points * PilotStyle.scale).rounded() }

    public enum Shape: Equatable, Sendable { case narrow, system, wide }

    private static let narrowBranches: Set<MenuBranch> = [.trigger, .capture]

    /// `only` is the kind Tab shows at the root: a list, so wide with nothing typed too (Sven 2026-10-12).
    public static func shape(branch: MenuBranch?, query: String, isList: Bool, only: MenuEntry.Kind? = nil) -> Shape {
        if isList { return .wide }
        guard let branch else { return query.isEmpty && only == nil ? .narrow : .wide }
        if branch.browsed == .system { return .system }
        return narrowBranches.contains(branch) ? .narrow : .wide
    }

    /// The menu's one width in every shape and both layouts: Raycast's 750 (Sven, Q130), as drawn.
    public static let width: CGFloat = 750

    /// Instrument's menu (mockup A's menu.html, card agent-bo-95423181): a 40 pt row in a narrow list, 44 pt in the others
    /// (a step taller than the mockup's 36 and 40 at the 750 width, Q130), 28 pt over a heading; a 58 pt search line, a
    /// 42 pt foot and the list's 6 pt insets round them.
    public static let instrumentRow: CGFloat = s(40), instrumentWideRow: CGFloat = s(44), instrumentHeading: CGFloat = s(28)

    /// As tall as its rows and headings, plus `extra` under them (the no-match line, Clean's wait) and a `bar` over them
    /// (Stickers and GIFs' GIFs | Stickers), so no list sits over
    /// an empty band: two rows at least when nothing shows under them (an empty list's line), and no more than the
    /// shape's tallest, which `full` takes (Cmd+K's actions). The top edge stays put as it changes (MenuSizer).
    public static func instrument(_ shape: Shape, rows: Int, headings: Int, extra: CGFloat = 0, bar: CGFloat = 0, full: Bool = false) -> CGSize {
        let (row, tallest): (CGFloat, CGFloat) = switch shape {
        case .narrow: (instrumentRow, s(560))
        case .system: (instrumentWideRow, s(600))
        case .wide: (instrumentWideRow, s(540))
        }
        let height = s(112) + CGFloat(extra > 0 ? rows : max(rows, 2)) * row + CGFloat(headings) * instrumentHeading + extra + bar
        return CGSize(width: width, height: full ? tallest : min(height, tallest))
    }

    // MARK: Rail (menu Rail and Classic, T6)

    /// What the Rail draws beside the list: nothing in a picker; at the empty root the whole rail, 170 pt, beside the
    /// recents; at a root search or a kind Tab shows, the whole rail, 182 pt, with each kind's count; inside a branch or
    /// on an answer a 52 pt strip of icons.
    public enum RailBand: Equatable, Sendable { case none, root, full, slim }

    /// The rail's widths, in points as drawn: the mockups' are already a step up, so they skip `s`.
    public static let railRootWidth: CGFloat = 170, railWidth: CGFloat = 182, railSlimWidth: CGFloat = 52
    /// A rail row is 30 pt, not the mockup's 32, so the root's 17 rows (6 kinds, 10 branches, Clipboard) and Go to fit
    /// in 650 (Q81); a slim strip's icon is 32 pt with 2 between.
    public static let railRow: CGFloat = 30, railHeading: CGFloat = 24, railSlimRow: CGFloat = 32, railInset: CGFloat = 6
    /// The whole rail reaches 650 pt, at the root (Q81) and beside a search, since Go to lists the root's branches and
    /// Clipboard: it never scrolls (coordinator, build mode).
    public static let railTallest: CGFloat = 650
    /// How tall a menu that lists Go to may grow: `room`, the face's height the screen holds (MenuModel.room), so every Go
    /// to row shows on Sven's screen and the menu still fits a small one (T36); 650 where no screen is known.
    public static func goToTallest(_ room: CGFloat?) -> CGFloat { room ?? railTallest }
    /// The search line and the foot round the rail.
    public static let railChrome: CGFloat = 58 + s(42)

    /// The rail's own height: `items` rows (kinds, branches, Clipboard) under one Go to heading, or a slim strip's icons.
    public static func railHeight(_ band: RailBand, items: Int) -> CGFloat {
        switch band {
        case .none: 0
        case .root, .full: CGFloat(items) * railRow + railHeading + 2 * railInset
        case .slim: CGFloat(items) * railSlimRow + CGFloat(max(items - 1, 0)) * 2 + 2 * railInset
        }
    }

    /// The Rail's panel: the menu's 750 width; as tall as Instrument's list would be
    /// or as the rail, whichever is taller, up to `room` (goToTallest) wherever the whole rail shows and the shape's tallest
    /// beside the slim strip. The top edge stays put as it changes (MenuSizer).
    public static func rail(_ shape: Shape, band: RailBand, railItems: Int, rows: Int, headings: Int, extra: CGFloat = 0, bar: CGFloat = 0,
                            full: Bool = false, room: CGFloat? = nil) -> CGSize {
        let list = instrument(shape, rows: rows, headings: headings, extra: extra, bar: bar, full: full)
        guard band != .none else { return list }
        let tallest = band == .slim ? instrument(shape, rows: 0, headings: 0, full: true).height : goToTallest(room)
        let rail = railHeight(band, items: railItems) + railChrome
        return CGSize(width: list.width, height: full ? tallest : min(max(list.height, rail), tallest))
    }

    // MARK: Classic (menu Rail and Classic, T8)

    /// Classic's rows (Classic Shell, Q139), in points as drawn: 38 at the root and in a narrow list, so the ten branches
    /// fit 650 under their rule heading (26); 42 in a wide one; the status line at the foot, 32,
    /// which holds the kinds and the keys.
    public static let classicRow: CGFloat = 38, classicWideRow: CGFloat = 42, classicStatus: CGFloat = 32, classicRootHeading: CGFloat = 26
    /// Classic's chrome: the 58 pt prompt line, the list's 6 pt insets and the status line.
    public static let classicChrome: CGFloat = 58 + 12 + classicStatus
    /// The root reaches 650 pt (Sven, Q56), so all ten branches show unscrolled.
    public static let classicTallest: CGFloat = 650

    /// Classic's panel: the menu's 750 width, Classic's chrome and rows, the root's rows under their rule heading
    /// (`root`), and `card` more where an answer's card stands in for its row. The root reaches `room` (goToTallest),
    /// narrow 650, wide 582 as Instrument's; `full` takes the shape's tallest (Cmd+K, a detail).
    public static func classic(_ shape: Shape, rows: Int, headings: Int, root: Bool = false, card: CGFloat = 0,
                               extra: CGFloat = 0, bar: CGFloat = 0, full: Bool = false, room: CGFloat? = nil) -> CGSize {
        let today = instrument(shape, rows: 0, headings: 0, full: true)
        let tallest = root && !full ? goToTallest(room) : shape == .narrow ? classicTallest : today.height
        let row = shape == .wide ? classicWideRow : classicRow
        let listed = CGFloat(extra > 0 || root ? rows : max(rows, 2)) * row + CGFloat(headings) * instrumentHeading
        let height = classicChrome + listed + (root ? classicRootHeading : 0) + card + extra + bar
        return CGSize(width: today.width, height: full ? tallest : min(height, tallest))
    }

    // MARK: Line (menu-morph T1)

    /// Line's sizes, in points as drawn (the round-2 mockups): its root is Classic's at Omarchy's 431 width; a search, a
    /// branch or a list is the menu's 750. A 60 pt search line in JetBrains Mono 20, 36 pt rows, the 6 pt list insets and
    /// Instrument's foot; a heading is Instrument's, as the list it draws is MenuBody's.
    public static let lineRootWidth: CGFloat = 431, lineSearch: CGFloat = 60, lineRow: CGFloat = 36
    public static let lineHeading: CGFloat = instrumentHeading
    /// The chrome round Line's list: its search line, two hairlines, the list's insets and the foot (s(42), InstrumentFoot).
    public static let lineChrome: CGFloat = lineSearch + 2 + 12 + s(42)

    /// Line's root: Classic's root (its rows under their rule heading, no recents since Sven 2026-10-20) at Line's 36 pt
    /// rows, up to `room` (goToTallest), so every Go to row shows (T36).
    public static func lineRoot(rows: Int, room: CGFloat? = nil) -> CGSize {
        let listed = CGFloat(rows) * lineRow + classicRootHeading
        return CGSize(width: lineRootWidth, height: min(lineChrome + listed, goToTallest(room)))
    }

    /// Line's list: 750 wide, as tall as its rows and headings plus `card` more where an answer's card stands in for its
    /// row, `extra` under them and a `bar` over them; at most 650 narrow, 582 otherwise; `full` takes that (Cmd+K, a detail).
    public static func line(_ shape: Shape, rows: Int, headings: Int, card: CGFloat = 0, extra: CGFloat = 0, bar: CGFloat = 0,
                            full: Bool = false) -> CGSize {
        let tallest = shape == .narrow ? classicTallest : instrument(shape, rows: 0, headings: 0, full: true).height
        let listed = CGFloat(extra > 0 ? rows : max(rows, 2)) * lineRow + CGFloat(headings) * lineHeading
        let height = lineChrome + listed + card + extra + bar
        return CGSize(width: width, height: full ? tallest : min(height, tallest))
    }

    /// Toybox's row and the gap under it (card agent-bo-95423182, mockup B's `.item`: 50 pt, none between).
    public static let toyboxRowPitch: CGFloat = s(50)

    /// Toybox's panel, for its bigger type, its 50 pt rows and its search line with the Pilot mark: around a narrow one's
    /// rows its pop block's outline and edge, the search line, the rule, the list's insets and the foot's caps, as the
    /// renders measure them.
    public static func toybox(_ shape: Shape, rows: Int) -> CGSize {
        switch shape {
        case .narrow: CGSize(width: s(440), height: s(157) + CGFloat(min(max(rows, 2), MenuBranch.top.count)) * toyboxRowPitch)
        case .system: CGSize(width: s(480), height: s(640))
        case .wide: CGSize(width: s(720), height: s(560))
        }
    }
}
