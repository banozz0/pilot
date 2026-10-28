import Foundation
import Testing
@testable import PilotCore

/// Aliases on menu rows (card agent-bo-95423037, audit gap 10, after Raycast's): typed exactly at the Hyper+Space root, an
/// alias puts its row first; a query that only starts with one ranks as before. Pure, no GUI; the store in a temp file.
@Suite("Command aliases")
struct AliasTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let picker = MenuEntry(title: "Web app picker", target: .action("apps.webAppPicker"))
    static let wordpad = MenuEntry(title: "WP Notes", target: .app("com.example.wpnotes"), home: .apps)
    static let wrap = MenuEntry(title: "Wrap text", target: .action("text.wrap"))
    static let safari = MenuEntry(title: "Safari", target: .app("com.apple.Safari"), home: .apps)
    static let window = MenuEntry(title: "Safari — Start", target: .window(4))
    static let entries = [wordpad, wrap, picker, safari, window]

    static func navigator(_ aliases: Aliases = Aliases()) -> MenuNavigator {
        MenuNavigator(entries: entries, aliases: aliases, now: now)
    }

    static func aliases(_ pairs: [(MenuEntry, String)]) -> Aliases {
        var aliases = Aliases()
        for (row, alias) in pairs { #expect(aliases.set(alias, for: row.frecencyKey!, title: row.title) == nil) }
        return aliases
    }

    @Test("Typing an alias exactly, any case, lists its row first, before a better match and an answer")
    func exactAliasFirst() {
        var nav = Self.navigator(Self.aliases([(Self.picker, "wp")]))
        nav.query = "wp"
        #expect(nav.rows.first == Self.picker)
        nav.query = "WP"
        #expect(nav.rows.first == Self.picker)
        let answer = MenuEntry(title: "wp = 42", target: .copy("42"), isAnswer: true)
        nav.provide(.answer, [answer])
        #expect(nav.rows.prefix(2) == [Self.picker, answer])
        #expect(nav.alias(of: Self.picker) == "wp")
        #expect(nav.alias(of: Self.safari) == nil)
    }

    @Test("An alias finds its row even when the row's name does not match it")
    func aliasOutsideTheName() {
        var nav = Self.navigator(Self.aliases([(Self.safari, "zz")]))
        nav.query = "zz"
        #expect(nav.rows.first == Self.safari)
        #expect(nav.handle(.return) == .run(Self.safari))
    }

    @Test("A query that only starts with an alias, or an alias inside a branch, ranks as without aliases")
    func prefixRanksAsBefore() {
        var plain = Self.navigator(), aliased = Self.navigator(Self.aliases([(Self.picker, "wp")]))
        for query in ["wpn", "w", "wp n"] {
            plain.query = query
            aliased.query = query
            #expect(aliased.rows == plain.rows, "\(query)")
        }
        var apps = MenuNavigator(entries: Self.entries, branch: .apps, aliases: Self.aliases([(Self.safari, "wp")]), now: Self.now)
        apps.query = "wp"
        #expect(apps.rows.first == Self.wordpad)
    }

    @Test("Under a kind tab the alias's row leads only when it is that kind")
    func kindTab() {
        var nav = Self.navigator(Self.aliases([(Self.picker, "wp")]))
        nav.query = "wp"
        _ = nav.handle(.tab)
        #expect(nav.only == .app)
        #expect(nav.rows.first != Self.picker)
        _ = nav.handle(.tab)
        _ = nav.handle(.tab)
        _ = nav.handle(.tab)
        #expect(nav.only == .action)
        #expect(nav.rows.first == Self.picker)
    }

    @Test("Cmd+K offers Set alias on a row frecency keeps, not on a window, and hands it to the panel")
    func setAliasAction() {
        var nav = Self.navigator()
        nav.query = "web app picker"
        #expect(nav.selectedActions.contains(.row(.setAlias)))
        #expect(RowAction.setAlias.title == "Set alias…")
        _ = nav.handle(.commandK)
        nav.actionQuery = "alias"
        #expect(nav.handle(.return) == .act(.setAlias, Self.picker))
        #expect(!RowAction.list(for: Self.window, favourite: false).contains(.setAlias))
    }

    @Test("No Set alias on a row the root search never lists: a Homebrew result, a Remove or Update category (Moody aO8s82TATKI)")
    func setAliasOnlyWhereFound() {
        let brew = MenuEntry(title: "zed", target: .package("cask:zed"), home: .homebrew, inSearch: false)
        #expect(!RowAction.list(for: brew, favourite: false).contains(.setAlias))
        #expect(RowAction.list(for: brew, favourite: false).contains(.favourite))
        for browsed in [MenuBranch.remove, .update] {
            let category = MenuEntry(title: "Casks", target: .branch(.category("Casks", in: browsed)), home: browsed)
            #expect(!RowAction.list(for: category, favourite: false).contains(.setAlias))
        }
        let window = MenuItemNode(title: "New Window", enabled: true)
        let item = MenuItemSearch.entries([MenuItemNode(title: "File", enabled: true, children: [window])], bundle: "com.apple.TextEdit")
        #expect(item.count == 1 && !item.contains { RowAction.list(for: $0, favourite: false).contains(.setAlias) })
        let install = MenuEntry(title: "Fonts", target: .branch(.category("Fonts")), home: .install)
        #expect(RowAction.list(for: install, favourite: false).contains(.setAlias))
    }

    @Test("An alias is lowercase letters and digits, one per row and unique; an empty one removes it")
    func rules() {
        var aliases = Aliases()
        let picker = Self.picker.frecencyKey!, safari = Self.safari.frecencyKey!
        #expect(aliases.set(" wp ", for: picker, title: "Web app picker") == nil)
        #expect(aliases.alias(for: picker) == "wp")
        #expect(aliases.set("Wp", for: safari, title: "Safari") != nil)
        #expect(aliases.set("w p", for: safari, title: "Safari") != nil)
        #expect(aliases.set("wp", for: safari, title: "Safari") == "wp is Web app picker's alias; pick another.")
        #expect(aliases.set("web2", for: picker, title: "Web app picker") == nil)
        #expect(aliases.all.map(\.alias) == ["web2"])
        #expect(aliases.key(for: "wp") == nil)
        #expect(aliases.key(for: "WEB2") == picker)
        #expect(aliases.set("", for: picker, title: "Web app picker") == nil)
        #expect(aliases.all.isEmpty)
    }

    @Test("Aliases survive a relaunch in aliases.json; none before the first, and a file that does not decode throws")
    func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pilot-aliases-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AliasesStore(url: url)
        #expect(try store.load().all.isEmpty)
        let aliases = Self.aliases([(Self.picker, "wp"), (Self.safari, "s")])
        try store.save(aliases)
        #expect(try store.load() == aliases)
        var reopened = MenuNavigator(entries: Self.entries, aliases: try store.load(), now: Self.now)
        reopened.query = "wp"
        #expect(reopened.rows.first == Self.picker)
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test("The starter aliases (Sven 2026-10-10) are saved once, to a user with no aliases file; one with a file, even empty, keeps it")
    func starters() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pilot-aliases-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AliasesStore(url: url)
        let seeded = try store.load(starters: Alias.starters)
        #expect(seeded.all == Alias.starters && FileManager.default.fileExists(atPath: url.path))
        #expect(seeded.key(for: "cb") == "action:apps.clipboard" && seeded.key(for: "sys") == "branch:system")
        // Each starter is a valid alias, none shared, none a starter quicklink's keyword.
        var check = Aliases()
        for alias in Alias.starters { #expect(check.set(alias.alias, for: alias.key, title: alias.title) == nil, "\(alias.alias)") }
        #expect(Set(Alias.starters.map(\.alias)).isDisjoint(with: Quicklink.shipped.map(\.keyword)))
        // Removed, it stays removed: an emptied file is never seeded again.
        try store.save(Aliases())
        #expect(try store.load(starters: Alias.starters).isEmpty)
    }
}
