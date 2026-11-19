import CoreGraphics

/// The menu panel's size (card agent-bo-95422981, mockups A and B; Q130): 750 wide everywhere in Instrument, as Raycast's;
/// the shape sets how tall it may grow and its rows: short at the root and in Trigger and Capture, System taller for its
/// sections, a search and every other branch in between.
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

    /// How tall a menu that lists Go to may grow: `room`, the face's height the screen holds (MenuModel.room), so every Go
    /// to row shows on Sven's screen and the menu still fits a small one (T36); 650 where no screen is known.
    public static func goToTallest(_ room: CGFloat?) -> CGFloat { room ?? 650 }

    // MARK: Classic (menu Rail and Classic, T8)

    /// Classic's root rows (Classic Shell, Q139), which Line's root draws: 38 pt each under their rule heading (26).
    public static let classicRow: CGFloat = 38, classicRootHeading: CGFloat = 26
    /// The root reaches 650 pt (Sven, Q56), so all ten branches show unscrolled.
    public static let classicTallest: CGFloat = 650

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
}
