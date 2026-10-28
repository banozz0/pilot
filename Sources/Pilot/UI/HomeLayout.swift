import Foundation
import Observation
import PilotCore

/// Home's blocks, as the person picks and orders them (story 167, Sven 2026-10-10: "each user should be able to customise
/// it and also we ship with a good default home page"): every block Pilot draws and every installed extension with a page,
/// each shown or hidden, in their order. Edit Home changes a draft, Done saves it; Reset puts the default back.
struct HomeLayout: Codable, Equatable, Sendable {
    /// A block: one of Pilot's own, or an installed extension's page (`ext:<id>`).
    struct Row: Codable, Equatable, Sendable, Identifiable {
        let id: String
        var shown: Bool
        /// Its size; nil is its default (Size.standard), and a layout saved before sizes reads as that.
        var size: Size? = nil
    }

    /// How big a block draws, on direction 2 "Now beside the board" (Sven's pick, 2026-10-12): a ~300 pt column of what is
    /// happening beside a board of two columns. The size picks the lane and the space, each step a whole slot more than
    /// the one under it (Sven, build 36: "small shouldn't be small … make them with some thought, not random sizes"):
    ///
    /// | Size   | Where                 | Workspaces     | Keyboard      | Most used, Clipboard | This Mac      | Extension            |
    /// |--------|-----------------------|----------------|---------------|----------------------|---------------|----------------------|
    /// | icon   | a tab in the column   | the one now    | keys bound    | presses, copies kept | CPU           | its bar text         |
    /// | small  | a card in the column  | rows, folded   | the board, small | rows, folded      | four readings | first figure, rows folded |
    /// | medium | one board column      | a strip        | the board, small | the style's card  | the style's card | figures and three rows |
    /// | large  | both board columns    | the map        | the board with names | the style's card | the style's card | the whole page |
    ///
    /// An icon's hover shows its small card. A medium with no medium after it to pair with takes both board columns and
    /// keeps its medium content.
    enum Size: String, Codable, CaseIterable, Sendable {
        case icon, small, medium, large

        var title: String { rawValue.capitalized }

        /// Where it goes and how much of it, as Edit Home's size menu says it.
        var place: String {
            switch self {
            case .icon: "a tab in the column"
            case .small: "a card in the column"
            case .medium: "half the board"
            case .large: "the whole board"
            }
        }

        /// The column beside the board, or the board.
        enum Lane: Equatable, Sendable { case column, board }
        var lane: Lane { self == .icon || self == .small ? .column : .board }

        /// A block's size until one is picked: what the column of now lists small (Workspaces as rows, Clipboard, Most
        /// used, the Pilot block), the keyboard and This Mac on the board; an extension's page medium.
        static func standard(_ id: String) -> Size {
            switch Block(rawValue: id) {
            case .keyboard?, .thisMac?: .large
            case nil: .medium
            default: .small
            }
        }

        /// An icon tab's side.
        static let tab: CGFloat = 52
    }

    /// Pilot's own blocks, in the order a new one joins the list.
    enum Block: String, CaseIterable, Sendable {
        case workspaces, keyboard, mostUsed, pilot, thisMac, clipboard, quickActions

        var title: String {
            switch self {
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

    var rows: [Row]

    /// The default, direction 2 (Sven's pick, 2026-10-12): Workspaces, Clipboard and Most used in the column, the Hyper
    /// keyboard and This Mac on the board. No timer: Pomodoro is an extension.
    static let shownByDefault: [Block] = [.workspaces, .keyboard, .clipboard, .mostUsed, .thisMac]
    static let standard = HomeLayout(rows: shownByDefault.map { Row(id: $0.rawValue, shown: true) }
        + Block.allCases.filter { !shownByDefault.contains($0) }.map { Row(id: $0.rawValue, shown: false) })

    static let extensionPrefix = "ext:"
    static func extensionRow(_ id: String) -> String { extensionPrefix + id }

    /// The extension a row is the page of, if it is one.
    static func extensionID(_ row: String) -> String? {
        row.hasPrefix(extensionPrefix) ? String(row.dropFirst(extensionPrefix.count)) : nil
    }

    /// The rows Edit Home lists and Home draws: the saved ones it can draw, in their order, then any block or extension
    /// page added since, hidden. A row of an extension no longer installed stays saved, so reinstalling it puts it back
    /// where it was, and is neither listed nor drawn.
    func resolved(extensions: [String]) -> [Row] {
        let known = Self.known(extensions: extensions)
        var rows = rows.filter { known.contains($0.id) }
        let have = Set(rows.map(\.id))
        rows += Block.allCases.map(\.rawValue).filter { !have.contains($0) }.map { Row(id: $0, shown: false) }
        rows += extensions.map(Self.extensionRow).filter { !have.contains($0) }.map { Row(id: $0, shown: false) }
        return rows
    }

    /// The rows Home can draw: Pilot's blocks and the installed extensions' pages.
    static func known(extensions: [String]) -> Set<String> { Set(Block.allCases.map(\.rawValue)).union(extensions.map(extensionRow)) }

    /// The ids Home draws, in order.
    func shown(extensions: [String]) -> [String] { resolved(extensions: extensions).filter(\.shown).map(\.id) }

    mutating func set(_ id: String, shown: Bool) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].shown = shown } else { rows.append(Row(id: id, shown: shown)) }
    }

    /// A block's size: the one picked, else its default.
    func size(of id: String) -> Size { rows.first { $0.id == id }?.size ?? .standard(id) }

    /// Picks a block's size; its default is kept as none, so a layout of defaults still reads as the default.
    mutating func set(_ id: String, size: Size) {
        let size = size == .standard(id) ? nil : size
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].size = size } else { rows.append(Row(id: id, shown: false, size: size)) }
    }

    /// Moves `id` one place up (`by` -1) or down (1) among the rows Edit Home lists, which `listed` names in order; the
    /// saved rows of uninstalled extensions keep their places.
    mutating func move(_ id: String, by step: Int, listed: [String]) {
        guard let at = listed.firstIndex(of: id), listed.indices.contains(at + step) else { return }
        move(id, before: step < 0 ? listed[at + step] : listed.indices.contains(at + 2) ? listed[at + 2] : nil, listed: listed)
    }

    /// Moves `id` in front of `target` (a drop on it), or to the end when nil.
    mutating func move(_ id: String, before target: String?, listed: [String]) {
        guard id != target else { return }
        takeIn(listed)
        guard let from = rows.firstIndex(where: { $0.id == id }) else { return }
        let row = rows.remove(at: from)
        let to = target.flatMap { t in rows.firstIndex { $0.id == t } } ?? rows.endIndex
        rows.insert(row, at: to)
    }

    /// Moves `id` right behind `target` (a drop on a lone medium's right half): in front of the row after it.
    mutating func move(_ id: String, after target: String, listed: [String]) {
        guard id != target else { return }
        takeIn(listed)
        let others = rows.map(\.id).filter { $0 != id }
        guard let at = others.firstIndex(of: target) else { return }
        move(id, before: others.indices.contains(at + 1) ? others[at + 1] : nil, listed: listed)
    }

    /// The saved rows take in every listed one first, hidden, so a moved row lands among them all.
    private mutating func takeIn(_ listed: [String]) {
        for missing in listed where !rows.contains(where: { $0.id == missing }) { rows.append(Row(id: missing, shown: false)) }
    }

    /// Whether Home draws this as it draws the default, with nothing else kept: the rows the default resolves to, in its
    /// order, and no saved row of an extension no longer installed (saving nothing would lose its place).
    func isStandard(extensions: [String]) -> Bool {
        let known = Self.known(extensions: extensions)
        return rows.allSatisfy { known.contains($0.id) } && resolved(extensions: extensions) == Self.standard.resolved(extensions: extensions)
    }
}

extension HomeLayout {
    /// The blocks a style draws, in order: the shown ones it can draw. While something needs you Toybox draws the Pilot
    /// block first, where it says so (Instrument's notices always do).
    static func drawn(_ shown: [String], style: PilotStyle, needsYou: Bool) -> [String] {
        var ids = shown.filter { Block(rawValue: $0)?.drawn(in: style) ?? true }
        let pilot = Block.pilot.rawValue
        if needsYou && style == .toybox && !ids.contains(pilot) { ids.insert(pilot, at: 0) }
        return ids
    }

    /// Home's blocks by lane, each in its order: the icon tabs and the small cards of the column, and the board's rows.
    struct Lanes: Equatable {
        var icons: [String] = []
        var column: [String] = []
        var board: [[String]] = []
    }

    /// Splits the drawn blocks by their sizes' lanes; on the board a large block takes a row, and a medium one shares its
    /// row with the medium right after it when the board is `across` 2, else takes the row (blocks are never reordered).
    static func lanes(_ ids: [String], size: (String) -> Size, across: Int) -> Lanes {
        var lanes = Lanes(), i = 0
        while i < ids.count {
            let id = ids[i], kind = size(id)
            i += 1
            switch kind {
            case .icon: lanes.icons.append(id)
            case .small: lanes.column.append(id)
            case .large: lanes.board.append([id])
            case .medium:
                var row = [id]
                // The next board block, skipping the column's: a medium pairs with it.
                if across > 1, let next = ids[i...].firstIndex(where: { size($0).lane == .board }), size(ids[next]) == .medium {
                    row.append(ids[next])
                    for j in i..<next { size(ids[j]) == .icon ? lanes.icons.append(ids[j]) : lanes.column.append(ids[j]) }
                    i = next + 1
                }
                lanes.board.append(row)
            }
        }
        return lanes
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

    /// Rows each list shows when Home is one column under the board's width: five, the mockup's.
    static let stacked = 5
}

/// Where Home's layout is kept: Pilot's defaults, as JSON under `home.blocks`; none saved reads as the default.
@Observable @MainActor
final class HomeLayoutStore {
    static let shared = HomeLayoutStore()

    private(set) var layout: HomeLayout
    @ObservationIgnored private let defaults: UserDefaults
    static let key = "home.blocks"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        layout = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(HomeLayout.self, from: $0) } ?? .standard
    }

    func save(_ layout: HomeLayout) {
        self.layout = layout
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: Self.key) }
    }

    /// Back to the default; nothing saved, so a later default is the one read.
    func reset() {
        layout = .standard
        defaults.removeObject(forKey: Self.key)
    }
}
