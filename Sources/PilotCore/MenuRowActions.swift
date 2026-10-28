import Foundation

/// What Cmd+K offers on a menu row (card agent-bo-95422968), after Vicinae's action panel: each kind of row its own list.
public enum RowAction: String, Equatable, Sendable {
    case open, focus, run, install, showInFinder, copyPath, copyBundleID, copyTitle, copyID, quit, forceQuit, uninstall
    case openWith, convert, trash, searchInside
    /// An app command's app, brought forward (P38).
    case openApp
    case favourite, unfavourite, resetRanking, setBind, setAlias
    /// A root "tr …" translation's (P40, Q291): Translate opens with the text, its languages in its line.
    case changeLanguages

    public var title: String {
        switch self {
        case .open: "Open"
        case .focus: "Focus"
        case .run: "Run"
        case .install: "Install"
        case .showInFinder: "Show in Finder"
        case .copyPath: "Copy path"
        case .copyBundleID: "Copy bundle id"
        case .copyTitle: "Copy title"
        case .copyID: "Copy action id"
        case .quit: "Quit"
        case .forceQuit: "Force quit"
        case .uninstall: "Uninstall…"
        case .openWith: "Open With…"
        case .convert: "Convert to…"
        case .trash: "Move to Trash…"
        case .searchInside: "Search inside"
        case .openApp: "Open app"
        case .favourite: "Add to favourites"
        case .unfavourite: "Remove from favourites"
        case .resetRanking: "Reset ranking"
        case .setBind: "Set Hyper bind…"
        case .setAlias: "Set alias…"
        case .changeLanguages: "Change languages…"
        }
    }

    /// The row's actions, what Return does first; quitting only for an app that runs, favourites, ranking and an alias
    /// only for a row frecency keeps, and an alias only where the root search finds it. A row Return does not pick
    /// (Remove's, Update's, Search files) has none.
    public static func list(for row: MenuEntry, favourite: Bool) -> [RowAction] {
        let kept: [RowAction] = row.frecencyKey == nil ? [] : [favourite ? .unfavourite : .favourite, .resetRanking]
        let aliased = kept.isEmpty || !aliasable(row) ? kept : kept + [.setAlias]
        switch row.target {
        case .app:
            return [.open, .showInFinder, .copyPath, .copyBundleID] + (row.running ? [.quit, .forceQuit] : []) + [.uninstall] + aliased + [.setBind]
        case .window: return [.focus, .copyTitle]
        case .file(let path):
            // A folder's files are searched with Search inside (N5): Where becomes that folder.
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let folder = values?.isDirectory == true && values?.isPackage != true
            return [.open, .openWith, .convert, .showInFinder, .copyPath] + (folder ? [.searchInside] : []) + [.trash] + aliased
        case .action: return [.run] + (row.kind == .command ? [.openApp] : []) + [.setBind, .copyID] + aliased
        case .package: return [.install] + aliased
        case .branch: return [.open] + (row.extensionID == nil ? [] : [.uninstall]) + aliased
        // A quick note (notes round 2): Move to Trash on every note but Scratch, wherever its row is listed.
        case .note(.open(let id)): return [.open, .showInFinder] + (id == NoteStore.scratch ? [] : [.trash])
        case .copy where row.isAnswer && row.home == .translate: return [.changeLanguages]
        case .remove, .update, .clean, .copy, .emoji, .sticker, .snippet, .reminder, .note, .ask, .calendarEvent, .searchFiles, .searchInstall, .searchWeb, .allowFullDiskAccess, .openPage, .process: return []
        }
    }

    /// Whether the root search, where an alias is typed, lists the row as the menu opens (card agent-bo-95423037): not a
    /// file (only in the Files view), a Homebrew result (only in its search), a Remove or Update category (listed once
    /// its branch has looked; Moody aO8s82TATKI) or a menu item (only the app in front's, read after the menu opens).
    private static func aliasable(_ row: MenuEntry) -> Bool {
        guard row.inSearch, row.kind != .menuItem else { return false }
        switch row.target {
        case .file: return false
        case .branch(.category(_, let browsed)): return browsed == .install
        default: return true
        }
    }
}

/// The Cmd+K list over one row: a filter, ranked as the menu's search is, and the selected action.
public struct RowActionsMenu: Equatable, Sendable {
    /// One line of the list: one of Pilot's row actions, or one the row's source names itself, by its index there and
    /// its title (an extension row's, card agent-bo-95423244).
    public enum Choice: Hashable, Sendable {
        case row(RowAction), own(Int, String)

        public var title: String {
            switch self {
            case .row(let action): action.title
            case .own(_, let title): title
            }
        }
    }

    public let row: MenuEntry
    private let all: [Choice]
    public var query = "" {
        didSet {
            visible = FuzzyRanker.rank(all, query: query, title: \.title)
            selection = 0
        }
    }
    public private(set) var visible: [Choice]
    public private(set) var selection = 0

    public init(row: MenuEntry, _ actions: [Choice]) {
        self.row = row
        all = actions
        visible = actions
    }

    public var selected: Choice? { visible.indices.contains(selection) ? visible[selection] : nil }
    /// How many actions the row has, whatever the filter shows.
    public var total: Int { all.count }

    mutating func move(_ by: Int) { selection = min(max(selection + by, 0), max(visible.count - 1, 0)) }
    mutating func select(_ index: Int) { if visible.indices.contains(index) { selection = index } }
}
