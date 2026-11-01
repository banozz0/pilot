import Foundation
import Testing
@testable import PilotCore

/// Vicinae's root search and Cmd+K actions in the menu (card agent-bo-95422968): the app the query names first, then its
/// actions and the rest, Search files beside Ask AI and Search the web after the best match (Q182); the file index only once that row is picked; pure, no GUI and no index.
@Suite("Menu search order and row actions")
struct MenuActionsTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let bitwarden = MenuEntry(title: "Bitwarden", target: .app("com.bitwarden.desktop"), home: .apps, running: true)
    static let search = MenuEntry(title: "Bitwarden: search vault", target: .action("apps.bitwardenSearch"))
    static let lock = MenuEntry(title: "Bitwarden: lock all vaults", target: .action("apps.bitwardenLock"))
    static let generator = MenuEntry(title: "Bitwarden: password generator", target: .action("apps.bitwardenGenerator"))
    static let cask = MenuEntry(title: "Bitwarden", target: .package("cask:bitwarden"), detail: "cask · installed")
    static let window = MenuEntry(title: "Bitwarden — Vault", target: .window(3), detail: "workspace 2")
    static let textEdit = MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps)
    static let file = MenuEntry(title: "bitwarden.py", target: .file("/Users/ada/code/bitwarden.py"))
    static let entries = [textEdit, cask, search, window, lock, bitwarden, generator]

    /// Search vault picked far more than the app, as Sven's frecency had it in the before screenshot.
    static func navigator(favourites: Set<String> = []) -> MenuNavigator {
        var picks = Frecency()
        for day in 0..<8 { picks.record("action:apps.bitwardenSearch", at: now.addingTimeInterval(Double(-day) * 3600)) }
        return MenuNavigator(entries: entries, frecency: picks, favourites: favourites, now: now)
    }

    static func type(_ text: String, into nav: inout MenuNavigator) -> [String?] {
        text.map { letter in
            nav.query += String(letter)
            return nav.fileQuery
        }
    }

    @Test("Typing bitwa asks no file index, lists the Bitwarden app first, then Ask AI, Search the web and Search files, then its actions")
    func vicinaeOrder() {
        var nav = Self.navigator()
        let asked = Self.type("bitwa", into: &nav)
        #expect(asked.allSatisfy { $0 == nil })
        #expect(nav.rows.first == Self.bitwarden)
        #expect(nav.matched[1...3].map(\.title).allSatisfy { $0.hasPrefix("Bitwarden: ") })
        #expect(nav.matched[1] == Self.search)
        // Ask AI, Search the web and Search files after the best match's group (Sven Q174, Q182).
        #expect(nav.rows[1...3].map(\.target) == [.ask("bitwa"), .searchWeb("bitwa"), .searchFiles])
        #expect(nav.rows[3].title == "Search files for \"bitwa\"")
        #expect(nav.rows.contains(Self.window) && nav.rows.contains(Self.cask))
    }

    @Test("A search nothing matches offers Search to install as well as Search files, install first for an app's name (Sven 2026-10-12)")
    func noMatchOffersInstall() {
        var nav = Self.navigator()
        nav.query = "raycast"
        // Ask AI and Search the web lead (Sven 2026-10-16), then the install offer.
        #expect(nav.rows.map(\.target) == [.ask("raycast"), .searchWeb("raycast"), .searchInstall("raycast"), .searchFiles])
        #expect(nav.rows[2].title == "Search to install \"raycast\"" && nav.rows[2].returnLabel == "Open")
        // Return on it opens Search packages searching the text.
        _ = nav.handle(.down); _ = nav.handle(.down)
        #expect(nav.handle(.return) == .handled)
        #expect(nav.branch == .homebrew && nav.query == "raycast")
        // A file's name puts Search files first.
        nav = Self.navigator()
        nav.query = "budget.xlsx"
        #expect(nav.rows.map(\.target) == [.ask("budget.xlsx"), .searchWeb("budget.xlsx"), .searchFiles, .searchInstall("budget.xlsx")])
        // Something matched but no app: an app's name is still offered to install, after Search files (Sven, 1.0.1,
        // "videorc"); an app on this Mac leading, a narrowed kind or one letter: no install row.
        nav.query = "vault"
        #expect(nav.rows.firstIndex { $0.target == .searchFiles }.map { nav.rows[$0 + 1].target } == .searchInstall("vault"))
        nav.query = "bitwa"
        #expect(!nav.rows.contains { $0.target == .searchInstall("bitwa") })
        nav.query = "raycast"
        _ = nav.handle(.tab)
        #expect(!nav.rows.contains { $0.isOffer })
        // One letter: no install or files offer, but Ask AI and Search the web, as for anything typed.
        nav = Self.navigator()
        nav.query = "q"
        #expect(!nav.rows.contains { $0.target == .searchFiles || $0.target == .searchInstall("q") })
        #expect(nav.rows.contains { $0.target == .ask("q") } && nav.rows.contains { $0.target == .searchWeb("q") })
        #expect(MenuNavigator.looksLikeApp("visual studio code") && !MenuNavigator.looksLikeApp("~/notes"))
    }

    @Test("A file row a provider left behind is never listed under All; one letter has no Search files row")
    func noFilesUnderAll() {
        var nav = Self.navigator()
        nav.query = "bitwa"
        nav.provide(.file, [Self.file])
        #expect(!nav.rows.contains(Self.file))
        nav.query = "b"
        #expect(nav.rows.last?.target != .searchFiles)
    }

    @Test("Picking Search files opens the Files view: the index is asked once with the query, only file rows list")
    func pickSearchFiles() {
        var nav = Self.navigator()
        _ = Self.type("bitwa", into: &nav)
        while nav.selected?.target != .searchFiles { #expect(nav.handle(.down) == .handled) }
        #expect(nav.handle(.return) == .handled)
        #expect(nav.only == .file)
        #expect(nav.fileQuery == "bitwa")
        nav.provide(.file, [Self.file])
        #expect(nav.rows == [Self.file])
        // Escape leaves the Files view: nothing more is asked of the index.
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.fileQuery == nil)
    }

    @Test("Tab to Files searches files too, as the Files tab did")
    func tabToFiles() {
        var nav = Self.navigator()
        nav.query = "bitwa"
        while nav.only != .file { #expect(nav.handle(.tab) == .handled) }
        #expect(nav.fileQuery == "bitwa")
        #expect(!nav.rows.contains { $0.target == .searchFiles })
        #expect(nav.handle(.tab) == .handled)
        #expect(nav.fileQuery == nil)
    }

    @Test("Each kind of row has its own actions; an app's are Vicinae's, quitting only one that runs")
    func lists() {
        #expect(RowAction.list(for: Self.bitwarden, favourite: false)
                == [.open, .showInFinder, .copyPath, .copyBundleID, .quit, .forceQuit, .uninstall, .favourite, .resetRanking, .setAlias, .setBind])
        #expect(RowAction.list(for: Self.textEdit, favourite: true)
                == [.open, .showInFinder, .copyPath, .copyBundleID, .uninstall, .unfavourite, .resetRanking, .setAlias, .setBind])
        #expect(RowAction.list(for: Self.window, favourite: false) == [.focus, .copyTitle])
        #expect(RowAction.list(for: Self.file, favourite: false) == [.open, .openWith, .convert, .showInFinder, .copyPath, .trash, .favourite, .resetRanking])
        #expect(RowAction.list(for: Self.search, favourite: false) == [.run, .setBind, .copyID, .favourite, .resetRanking, .setAlias])
        #expect(RowAction.list(for: Self.cask, favourite: false) == [.install, .favourite, .resetRanking, .setAlias])
        #expect(RowAction.list(for: MenuEntry(title: "x", target: .searchFiles), favourite: false).isEmpty)
        #expect(RowAction.list(for: Self.bitwarden, favourite: false).map(\.title)
                == ["Open", "Show in Finder", "Copy path", "Copy bundle id", "Quit", "Force quit", "Uninstall…", "Add to favourites",
                    "Reset ranking", "Set alias…", "Set Hyper bind…"])
    }

    @Test("Cmd+K opens the selected row's actions: typing filters, arrows move, Return runs one, Escape closes only them")
    func popover() {
        var nav = Self.navigator()
        nav.query = "bitwa"
        #expect(nav.handle(.commandK) == .handled)
        #expect(nav.actions?.row == Self.bitwarden)
        #expect(nav.actions?.visible.first == .row(.open))
        nav.actionQuery = "quit"
        #expect(nav.actions?.visible == [.row(.quit), .row(.forceQuit)])
        #expect(nav.handle(.down) == .handled)
        #expect(nav.handle(.return) == .act(.forceQuit, Self.bitwarden))
        #expect(nav.actions == nil)
        #expect(nav.handle(.commandK) == .handled)
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.actions == nil)
        #expect(nav.query == "bitwa")
        // Open is Return on the row; a row with no actions opens nothing.
        #expect(nav.handle(.commandK) == .handled)
        #expect(nav.handle(.return) == .run(Self.bitwarden))
        while nav.selected?.target != .searchFiles { _ = nav.handle(.down) }
        #expect(nav.handle(.commandK) == .handled)
        #expect(nav.actions == nil)
    }

    @Test("Uninstall opens Remove searching for the app, so Remove's own confirm asks before anything runs")
    func uninstall() {
        var nav = Self.navigator()
        nav.query = "bitwa"
        _ = nav.handle(.commandK)
        nav.actionQuery = "uninst"
        #expect(nav.handle(.return) == .handled)
        #expect(nav.branch == .remove)
        #expect(nav.query == "Bitwarden")
        #expect(nav.actions == nil)
    }

    @Test("A favourite lifts a row above an equal match, kept on disk; Reset ranking forgets a row's picks")
    func favouriteAndReset() throws {
        let one = MenuEntry(title: "Alpha One", target: .app("a.one"), home: .apps)
        let two = MenuEntry(title: "Alpha Two", target: .app("a.two"), home: .apps)
        var nav = MenuNavigator(entries: [one, two], now: Self.now)
        nav.query = "alpha"
        #expect(nav.matched.prefix(2) == [one, two])
        // Ask AI and Search the web follow the best match (Q174): down to Alpha Two.
        while nav.selected != two { _ = nav.handle(.down) }
        _ = nav.handle(.commandK)
        nav.actionQuery = "favourite"
        #expect(nav.handle(.return) == .act(.favourite, two))
        #expect(nav.favourites == ["app:a.two"])
        #expect(nav.matched.prefix(2) == [two, one])

        let url = FileManager.default.temporaryDirectory.appending(path: "pilot-favourites-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FavouritesStore(url: url)
        #expect(try store.load().isEmpty)
        try store.save(nav.favourites)
        var reopened = MenuNavigator(entries: [one, two], favourites: try store.load(), now: Self.now)
        reopened.query = "alpha"
        #expect(reopened.matched.prefix(2) == [two, one])

        // A favourite never picked still beats the most picked equal match (Moody, o8q5FSbLr3o).
        var heavy = Frecency()
        for hour in 0..<10 { heavy.record("app:a.one", at: Self.now.addingTimeInterval(Double(-hour) * 3600)) }
        var favoured = MenuNavigator(entries: [one, two], frecency: heavy, favourites: ["app:a.two"], now: Self.now)
        favoured.query = "alpha"
        #expect(favoured.matched.prefix(2) == [two, one])

        var picks = Frecency()
        picks.record("app:a.two", at: Self.now)
        var ranked = MenuNavigator(entries: [one, two], frecency: picks, now: Self.now)
        ranked.query = "alpha"
        #expect(ranked.matched.prefix(2) == [two, one])
        _ = ranked.handle(.commandK)
        ranked.actionQuery = "reset"
        #expect(ranked.handle(.return) == .act(.resetRanking, two))
        #expect(ranked.matched.prefix(2) == [one, two])
        picks.forget("app:a.two")
        #expect(picks.score("app:a.two", now: Self.now) == 0)
    }
}

extension MenuNavigator {
    /// The rows a root search matched, without its Search files row.
    var matched: [MenuEntry] { rows.filter { !$0.isOffer } }

    /// Picks the Search files row: the Files view.
    mutating func openFiles() {
        while selected?.target != .searchFiles, selection < rows.count - 1 { _ = handle(.down) }
        _ = handle(.return)
    }
}
