import Foundation
import Observation
import PilotCore

/// Home's blocks, as the person picks and places them (story 167, Sven 2026-10-10: "each user should be able to customise
/// it and also we ship with a good default home page"): every block Pilot draws and every installed extension with a page,
/// each shown or hidden, each on its cells of Home's grid (P91, model A) with the class its Layout keeps. Edit Home changes
/// a draft, Done saves it; Reset puts the default back.
struct HomeLayout: Codable, Equatable, Sendable {
    /// A block: one of Pilot's own, an installed extension's page (`ext:<id>`), or a widget placed on Home
    /// (`widget:<placement>`).
    struct Row: Codable, Equatable, Sendable, Identifiable {
        let id: String
        var shown: Bool
        /// Its lane size, the one 1.0.2 and before read, kept so going back to one draws Home close to this: the size it
        /// had before the grid until its cells change, then the lane its cells sit in (HomeLayout.lane(of:)). The grid
        /// never draws by it, and isStandard ignores it.
        var size: Size? = nil
        /// Its cells on Home's grid; a hidden block keeps them, so showing it puts it back there. None: the grid's foot.
        var cell: HomeCell? = nil
        /// The class its Layout keeps; none is Auto, by its size.
        var layout: Widget.SizeClass? = nil
    }

    var rows: [Row]
    /// The grid's version, 1; none in a layout saved before 1.0.3, whose lanes convert to cells as it loads.
    var grid: Int?

    static let version = 1

    init(rows: [Row], grid: Int? = HomeLayout.version) {
        self.rows = rows
        self.grid = grid
    }

    /// Pilot's own blocks, in the order a new one joins the list.
    enum Block: String, CaseIterable, Sendable {
        case greeting, workspaces, keyboard, mostUsed, pilot, thisMac, clipboard, quickActions

        var title: String {
            switch self {
            case .greeting: "Today"
            case .workspaces: "Workspaces"
            case .keyboard: "Hyper keyboard"
            case .mostUsed: "Most used today"
            case .pilot: "Pilot"
            case .thisMac: "This Mac"
            case .clipboard: "Clipboard"
            case .quickActions: "Quick actions"
            }
        }

        var symbol: String {
            switch self {
            case .greeting: "sun.max"
            case .workspaces: "desktopcomputer"
            case .keyboard: "keyboard"
            case .mostUsed: "flame"
            case .pilot: "scope"
            case .thisMac: "cpu"
            case .clipboard: "doc.on.clipboard"
            case .quickActions: "bolt"
            }
        }

        /// Instrument and Toybox leave quick actions to the menu (their mockups have none on Home); Instrument's notices are
        /// its Pilot block.
        func drawn(in style: PilotStyle) -> Bool {
            switch self {
            case .quickActions: false
            case .pilot: style != .instrument
            default: true
            }
        }
    }

    /// The cells a block takes when it is shown with none of its own: the greeting two rows of the left five columns, the
    /// lists three, the keyboard and This Mac the board's eighteen, an extension's page half of it, a widget a card.
    static func size(of id: String) -> (w: Int, h: Int) {
        switch Block(rawValue: id) {
        case .greeting?: (5, 2)
        case .keyboard?: (18, 6)
        case .thisMac?: (18, 5)
        case .pilot?: (18, 3)
        case nil: widgetID(id) != nil ? (5, 3) : (9, 5)
        default: (5, 3)
        }
    }

    /// The default, direction 2 on the grid (Sven's pick, 2026-10-12, converted as any layout is): the greeting, Workspaces,
    /// Clipboard and Most used down the left, the Hyper keyboard and This Mac beside them. No timer: Pomodoro is an extension.
    static let shownByDefault: [Block] = [.greeting, .workspaces, .keyboard, .clipboard, .mostUsed, .thisMac]
    static let standard = HomeLayout(lanes: HomeLayout(rows: shownByDefault.filter { $0 != .greeting }.map { Row(id: $0.rawValue, shown: true) }
        + Block.allCases.filter { !shownByDefault.contains($0) }.map { Row(id: $0.rawValue, shown: false) }, grid: nil))

    static let extensionPrefix = "ext:"
    static func extensionRow(_ id: String) -> String { extensionPrefix + id }

    /// The extension a row is the page of, if it is one.
    static func extensionID(_ row: String) -> String? {
        row.hasPrefix(extensionPrefix) ? String(row.dropFirst(extensionPrefix.count)) : nil
    }

    static let widgetPrefix = "widget:"
    static func widgetRow(_ placement: String) -> String { widgetPrefix + placement }

    /// The Home placement a row draws, if it is a widget's.
    static func widgetID(_ row: String) -> String? {
        row.hasPrefix(widgetPrefix) ? String(row.dropFirst(widgetPrefix.count)) : nil
    }

    /// A row beyond Pilot's own blocks, from what `extensions` lists: an extension's id is its page's row, a Home widget's
    /// row is itself (an extension's id holds no colon).
    private static func beyond(_ id: String) -> String { widgetID(id) != nil ? id : extensionRow(id) }

    /// What `extensions` takes: the installed extensions with a page by id, then Home's widgets by their placements' rows.
    static func beyond(pages: [String], widgets: [String]) -> [String] { pages + widgets.map(widgetRow) }

    /// The rows Edit Home lists and Home draws: the saved ones it can draw, in their order, then any block or extension
    /// page added since, hidden, and any widget put on Home since, shown (placing it there asked for it). `extensions`
    /// lists the installed extensions with a page by id and Home's widgets by their rows. A row of an extension no
    /// longer installed stays saved, so reinstalling it puts it back where it was, and is neither listed nor drawn.
    func resolved(extensions: [String]) -> [Row] {
        let known = Self.known(extensions: extensions)
        var rows = rows.filter { known.contains($0.id) }
        let have = Set(rows.map(\.id))
        rows += Block.allCases.map(\.rawValue).filter { !have.contains($0) }.map { Row(id: $0, shown: false) }
        rows += extensions.map(Self.beyond).filter { !have.contains($0) }.map { Row(id: $0, shown: Self.widgetID($0) != nil) }
        return rows
    }

    /// The rows Home can draw: Pilot's blocks, the installed extensions' pages and Home's widgets.
    static func known(extensions: [String]) -> Set<String> { Set(Block.allCases.map(\.rawValue)).union(extensions.map(beyond)) }

    /// The ids Home draws, in order.
    func shown(extensions: [String]) -> [String] { resolved(extensions: extensions).filter(\.shown).map(\.id) }

    /// Changes a block's row, taking it in hidden first when the layout has none.
    private mutating func change(_ id: String, _ body: (inout Row) -> Void) {
        if let i = rows.firstIndex(where: { $0.id == id }) { body(&rows[i]) } else { var row = Row(id: id, shown: false); body(&row); rows.append(row) }
    }

    /// Shows or hides a block; a hidden one keeps its cells and its Layout.
    mutating func set(_ id: String, shown: Bool) { change(id) { $0.shown = shown } }

    func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    /// A block's saved cells, if it has any.
    func cell(of id: String) -> HomeCell? { row(id)?.cell }

    /// The class a block's Layout keeps, nil for Auto.
    func layout(of id: String) -> Widget.SizeClass? { row(id)?.layout }

    /// Puts a block on `cell`; moved or resized, its lane size follows its new cells.
    mutating func set(_ id: String, cell: HomeCell?) {
        change(id) { row in
            guard row.cell != cell else { return }
            if row.cell != nil || row.size == nil { row.size = cell.map(Self.lane(of:)) }
            row.cell = cell
        }
    }

    /// Pins a block's class, or Auto with nil.
    mutating func set(_ id: String, layout: Widget.SizeClass?) { change(id) { $0.layout = layout } }

    /// The cells Home draws `ids` at, packed (HomeGrid.settle): each its saved cells, one with none at the grid's foot at
    /// its own size; `subject`, the block just moved (from `from`), resized or shown, wins its cells.
    func cells(_ ids: [String], subject: String? = nil, from: HomeCell? = nil) -> [String: HomeCell] {
        var cells: [String: HomeCell] = [:]
        for id in ids where cells[id] == nil {
            cells[id] = cell(of: id)?.clamped ?? HomeGrid.foot(Self.size(of: id), under: cells.values)
        }
        return HomeGrid.settle(cells, subject: subject, from: from, order: ids)
    }

    /// Packs the blocks `ids` names (the ones Home draws) and keeps their cells; the others' stay as they are.
    mutating func place(_ ids: [String], subject: String? = nil, from: HomeCell? = nil) {
        for (id, cell) in cells(ids, subject: subject, from: from) { set(id, cell: cell) }
    }

    /// A block shown on `cell` (its saved cells, or the grid's foot, when nil), winning them from the blocks Home draws in
    /// `style` with `extensions` installed: those in its way move down. Moved, `from` is where it was drawn, so it passes a
    /// block once past its middle. Edit mode and `pilot add home-blocks` both put a block this way.
    mutating func put(_ id: String, on cell: HomeCell? = nil, style: PilotStyle?, extensions: [String], from: HomeCell? = nil) {
        set(id, shown: true)
        if let cell { set(id, cell: cell.clamped) }
        place(drawn(style, extensions: extensions), subject: id, from: from)
    }

    /// A block hidden, its cells and Layout kept; the blocks under it float up.
    mutating func hide(_ id: String, style: PilotStyle?, extensions: [String]) {
        set(id, shown: false)
        place(drawn(style, extensions: extensions))
    }

    /// The blocks Home draws in `style` (every shown one with none), in order: the ones a change packs.
    func drawn(_ style: PilotStyle?, extensions: [String]) -> [String] { shown(extensions: extensions).filter { Self.draws($0, in: style) } }

    /// Whether a style draws a block: Pilot's own as their style says, every page and widget.
    static func draws(_ id: String, in style: PilotStyle?) -> Bool { style.map { Block(rawValue: id)?.drawn(in: $0) ?? true } ?? true }

    /// The blocks in reading order: by their cells' rows, then columns.
    static func reading(_ cells: [String: HomeCell]) -> [String] {
        cells.keys.sorted { a, b in
            let (p, q) = (cells[a]!, cells[b]!)
            return (p.y, p.x, a) < (q.y, q.x, b)
        }
    }

    /// Moves `id` in front of `target` in the list (the tray's order, and the CLI's), or to the end when nil.
    mutating func move(_ id: String, before target: String?, listed: [String]) {
        guard id != target else { return }
        for missing in listed where !rows.contains(where: { $0.id == missing }) { rows.append(Row(id: missing, shown: false)) }
        guard let from = rows.firstIndex(where: { $0.id == id }) else { return }
        let row = rows.remove(at: from)
        let to = target.flatMap { t in rows.firstIndex { $0.id == t } } ?? rows.endIndex
        rows.insert(row, at: to)
    }

    /// Whether Home draws this as it draws the default, with nothing else kept: the rows the default resolves to, in its
    /// order, the shown ones at its cells, and no saved row of an extension no longer installed (saving nothing would lose
    /// its place).
    func isStandard(extensions: [String]) -> Bool {
        let known = Self.known(extensions: extensions)
        // A hidden block's cells are where it last was, not something it draws, and the lane size is only 1.0.2's.
        let drawn = { (layout: HomeLayout) in
            layout.resolved(extensions: extensions).map { Row(id: $0.id, shown: $0.shown, cell: $0.shown ? $0.cell : nil, layout: $0.layout) }
        }
        return rows.allSatisfy { known.contains($0.id) } && drawn(self) == drawn(Self.standard)
    }

    /// Every shown block inside the columns and none on another: a layout Home can draw as saved.
    var isValid: Bool {
        grid == Self.version && Set(rows.map(\.id)).count == rows.count && HomeGrid.valid(rows.filter(\.shown).compactMap(\.cell))
    }
}

extension HomeLayout {
    /// The blocks a style draws, in order: the shown ones it can draw. While something needs you Toybox draws the Pilot
    /// block too, at the top of the board, where it says so (Instrument's notices always do).
    static func drawn(_ shown: [String], style: PilotStyle, needsYou: Bool) -> [String] {
        var ids = shown.filter { draws($0, in: style) }
        let pilot = Block.pilot.rawValue
        if needsYou && style == .toybox && !ids.contains(pilot) { ids.insert(pilot, at: 0) }
        return ids
    }
}

// MARK: - Layouts saved before 1.0.3

extension HomeLayout {
    /// How big a block drew before the grid, on direction 2 "Now beside the board": an icon tab or a small card in the
    /// ~300 pt column, a medium half the board or a large across it. Kept only to read a layout saved then.
    enum Size: String, Codable, CaseIterable, Sendable {
        case icon, small, medium, large

        /// A block's size until one was picked: the column's lists small, the keyboard and This Mac large, an extension's
        /// page medium.
        static func standard(_ id: String) -> Size {
            switch Block(rawValue: id) {
            case .keyboard?, .thisMac?: .large
            case nil: .medium
            default: .small
            }
        }

        var onBoard: Bool { self == .medium || self == .large }
    }

    /// The lane 1.0.2 would draw a block of these cells in: one row an icon tab, within the left five columns a small
    /// card, fourteen columns or more across the board, the rest half of it.
    static func lane(of cell: HomeCell) -> Size {
        if cell.h == 1 { return .icon }
        if cell.maxX <= 5 { return .small }
        return cell.w >= 14 ? .large : .medium
    }

    /// A layout saved before the grid, converted to the same look in cells (P91): where each block drew in the column and
    /// on the board, snapped to the cells nearest its frame. The column is the left 5 cells (320 pt at Sven's window) and
    /// the board the other 18: the greeting 5 × 2 at the top, then each icon tab as a one-row Strip, then each small card
    /// 5 × 3; beside them the board's rows from the top, the keyboard 18 × 6, any other large 18 × 5, two mediums 9 × 5
    /// side by side and a lone one across the board, as it drew. With nothing in the column the greeting and the board
    /// take the whole width; with nothing on the board the cards go four to a row. Hidden blocks keep no cells, Layout is
    /// Auto, and a layout already in cells comes back as it is.
    init(lanes old: HomeLayout) {
        guard old.grid == nil else { self = old; return }
        let size = { (id: String) in old.row(id)?.size ?? Size.standard(id) }
        let greeting = Block.greeting.rawValue
        let ids = old.rows.filter { $0.shown && $0.id != Block.quickActions.rawValue && $0.id != greeting }.map(\.id)
        let icons = ids.filter { size($0) == .icon }, cards = ids.filter { size($0) == .small }
        let board = Self.boardRows(ids.filter { size($0).onBoard }, size: size)
        var cells: [String: HomeCell] = [:]
        if board.isEmpty || (icons.isEmpty && cards.isEmpty) {
            // One lane only: the greeting across, then the blocks four to a row or the board across the page.
            cells[greeting] = HomeCell(x: 0, y: 0, w: HomeGrid.columns, h: 2)
            var y = 2
            for (items, h) in [(icons, 1), (cards, 3)] {
                for start in stride(from: 0, to: items.count, by: 4) {
                    var x = 0
                    for (k, id) in items[start..<min(start + 4, items.count)].enumerated() {
                        let w = k < 3 ? 6 : 5
                        cells[id] = HomeCell(x: x, y: y, w: w, h: h)
                        x += w
                    }
                    y += h
                }
            }
            Self.lay(board, x: 0, width: HomeGrid.columns, from: y, into: &cells)
        } else {
            cells[greeting] = HomeCell(x: 0, y: 0, w: 5, h: 2)
            var y = 2
            for id in icons { cells[id] = HomeCell(x: 0, y: y, w: 5, h: 1); y += 1 }
            for id in cards { cells[id] = HomeCell(x: 0, y: y, w: 5, h: 3); y += 3 }
            Self.lay(board, x: 5, width: HomeGrid.columns - 5, from: 0, into: &cells)
        }
        // Each keeps the lane size it had, so 1.0.2 still draws it so.
        var rows = old.rows.map { Row(id: $0.id, shown: $0.shown, size: $0.size, cell: cells[$0.id], layout: $0.layout) }
        if let i = rows.firstIndex(where: { $0.id == greeting }) { rows[i].shown = true; rows[i].cell = cells[greeting] }
        else { rows.insert(Row(id: greeting, shown: true, cell: cells[greeting]), at: 0) }
        self.init(rows: rows)
    }

    /// The board's rows as they drew: a large across, a medium with the next board block when that is medium, else across.
    private static func boardRows(_ ids: [String], size: (String) -> Size) -> [[String]] {
        var rows: [[String]] = [], i = 0
        while i < ids.count {
            if size(ids[i]) == .medium, i + 1 < ids.count, size(ids[i + 1]) == .medium { rows.append([ids[i], ids[i + 1]]); i += 2 }
            else { rows.append([ids[i]]); i += 1 }
        }
        return rows
    }

    /// The board's rows from row `y` down, in `width` columns from `x`: the keyboard six rows, the rest five; a pair splits
    /// the width.
    private static func lay(_ board: [[String]], x: Int, width: Int, from y: Int, into cells: inout [String: HomeCell]) {
        var y = y
        for row in board {
            let h = row.contains(Block.keyboard.rawValue) && row.count == 1 ? 6 : 5
            if row.count == 2 {
                cells[row[0]] = HomeCell(x: x, y: y, w: width / 2, h: h)
                cells[row[1]] = HomeCell(x: x + width / 2, y: y, w: width - width / 2, h: h)
            } else {
                cells[row[0]] = HomeCell(x: x, y: y, w: width, h: h)
            }
            y += h
        }
    }
}

/// How a list folds into its block (mockup "How long lists fold", Sven's pick 2026-10-12): it shows as many rows as the
/// block holds; when there are more, the last row that fits says "N more" and opens the list's page. Never "1 more": a
/// single row left over just shows.
enum HomeFold {
    /// Of `total` rows in room for `fits`: how many show, and the count on the "N more" row (0 for none).
    static func rows(total: Int, fits: Int) -> (shown: Int, more: Int) {
        let fits = max(1, fits)
        guard total > fits else { return (max(0, total), 0) }
        return (fits - 1, total - (fits - 1))
    }

    /// The rows a height holds at `row` each, never under `least`.
    static func fits(height: CGFloat, row: CGFloat, least: Int = 3) -> Int {
        max(least, row > 0 ? Int((height + 0.5) / row) : least)
    }
}

/// Where Home's layout is kept: Pilot's defaults, as JSON under `home.blocks`; none saved reads as the default. A layout
/// saved before the grid converts to cells the first time it loads (HomeLayout(lanes:)); its bytes are kept under
/// `home.blocks.lanes` first, never written again, and a conversion that fails leaves them where they were and draws the
/// default, as a layout with two rows of one block does. Each row keeps a lane size 1.0.2 reads (Row.size), so going
/// back draws Home close to how the grid had it.
@Observable @MainActor
final class HomeLayoutStore {
    static let shared = HomeLayoutStore()

    private(set) var layout: HomeLayout
    @ObservationIgnored private let defaults: UserDefaults
    static let key = "home.blocks"
    /// The layout as saved before 1.0.3, kept as it was the first time it converted.
    static let lanesKey = "home.blocks.lanes"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.key)
        guard let data, let saved = try? JSONDecoder().decode(HomeLayout.self, from: data) else { layout = .standard; return }
        guard saved.grid == nil else { layout = saved; return }
        if defaults.data(forKey: Self.lanesKey) == nil { defaults.set(data, forKey: Self.lanesKey) }
        let converted = HomeLayout(lanes: saved)
        guard converted.isValid else { layout = .standard; return }
        layout = converted
        if converted.isStandard(extensions: []) { defaults.removeObject(forKey: Self.key) } else { save(converted) }
    }

    func save(_ layout: HomeLayout) {
        self.layout = layout
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: Self.key) }
    }

    /// Drops the saved rows `gone` names (a widget taken off Home, whose placement's id never comes back); a layout left
    /// as the default saves as nothing, as Done's does.
    func forget(where gone: (String) -> Bool) {
        guard layout.rows.contains(where: { gone($0.id) }) else { return }
        var next = layout
        next.rows.removeAll { gone($0.id) }
        if next.isStandard(extensions: []) { reset() } else { save(next) }
    }

    /// Back to the default; nothing saved, so a later default is the one read.
    func reset() {
        layout = .standard
        defaults.removeObject(forKey: Self.key)
    }
}
