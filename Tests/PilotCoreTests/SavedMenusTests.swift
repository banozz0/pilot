import Foundation
import Testing
@testable import PilotCore

/// Saved menu bars (T41, Sven Q830): only what an app always shows is kept, never what it holds, nothing that acts unseen,
/// and the store keeps each app's copy to its owner.
struct SavedMenusTests {
    /// A menu item as a fake Accessibility element: its title, its submenu and its shortcut's character.
    struct Item { var title: String; var kids: [Item] = []; var key: String? = nil }

    /// The paths a saved read keeps of `bar` (the Apple menu first, as a menu bar has it), and every title the walk read.
    func saved(_ bar: [Item], windows: [String] = [], app: String = "Google Chrome") -> (kept: [String], read: [String]) {
        var read: [String] = []
        let nodes = MenuItemSearch.walk([Item(title: "Apple")] + bar, read: { item in
            read.append(item.title)
            return .init(title: item.title, enabled: false, char: item.key, modifiers: 0, children: item.kids)
        }, skip: SavedMenu.skip(windowTitles: windows, app: app), expired: { false })
        func paths(_ n: [MenuItemNode], _ p: String = "") -> [String] {
            n.flatMap { $0.children.isEmpty ? [p + $0.title] : paths($0.children, p + $0.title + " > ") }
        }
        return (paths(SavedMenu.kept(nodes)), read)
    }

    @Test("Menus that name what the app holds are skipped unread; app commands stay")
    func holdings() {
        let (kept, read) = saved([
            Item(title: "Chrome", kids: [Item(title: "Settings…", key: ","), Item(title: "Services", kids: [Item(title: "X")])]),
            Item(title: "File", kids: [Item(title: "New Tab", key: "T"), Item(title: "Open Recent", kids: [Item(title: "secret.pdf")]),
                                      Item(title: "Close “Bank statement”"), Item(title: ""), Item(title: "Save Page As…", key: "S")]),
            Item(title: "Edit", kids: [Item(title: "Undo Typing", key: "Z"), Item(title: "Copy", key: "C"), Item(title: "Zoom 1.5×")]),
            Item(title: "Profiles", kids: [Item(title: "sven@example.com")]),
            Item(title: "History", kids: [Item(title: "Online banking")]),
            Item(title: "Bookmarks", kids: [Item(title: "My bank")]),
            Item(title: "Tab", kids: [Item(title: "Inbox (3) – svenmail"), Item(title: "Search Tabs…", key: "A")]),
            Item(title: "Window", kids: [Item(title: "Inbox (3) – svenmail")]),
            Item(title: "Help", kids: [Item(title: "Chrome Help")]),
        ], windows: ["Inbox (3) – svenmail — Google Chrome", "New Tab - Google Chrome"])
        #expect(kept == ["Chrome > Settings…", "File > New Tab", "File > Save Page As…", "Edit > Copy", "Edit > Zoom 1.5×", "Tab > Search Tabs…"])
        #expect(!read.contains("Online banking") && !read.contains("My bank") && !read.contains("secret.pdf"))
    }

    @Test("Lists inside a submenu, accounts and the Account menu are never saved (review round 1)")
    func lists() {
        let (kept, read) = saved([
            Item(title: "Mailbox", kids: [Item(title: "Erase Deleted Items", kids: [Item(title: "sven@icloud.com"), Item(title: "Work Exchange")]),
                                         Item(title: "Get All New Mail", key: "N")]),
            Item(title: "Song", kids: [Item(title: "Add to Playlist", kids: [Item(title: "Gym 2026")])]),
            Item(title: "Account", kids: [Item(title: "Sven Medina")]),
            Item(title: "View", kids: [Item(title: "Sort By", kids: [Item(title: "Name", key: "1")])]),
        ], app: "Mail")
        #expect(kept == ["Mailbox > Get All New Mail", "View > Sort By > Name"])
        #expect(!read.contains("Sven Medina"))
    }

    @Test("Site and file names anywhere in a title are never saved, a trailing ellipsis aside (review round 1)")
    func names() {
        let (kept, _) = saved([Item(title: "Safari", kids: [Item(title: "Settings for x.com…"), Item(title: "Settings…", key: ",")]),
                               Item(title: "File", kids: [Item(title: "Export report.pdf as PDF…"), Item(title: "Export as PDF…"),
                                                         Item(title: "Node.js Console"), Item(title: "Version 2.0"),
                                                         Item(title: "Export Résumé.pdf as PDF…")]),
                               Item(title: "Develop", kids: [Item(title: "Settings for acme.network…")])], app: "Safari")
        #expect(kept == ["Safari > Settings…", "File > Export as PDF…", "File > Version 2.0"])
    }

    @Test("Nothing that quits, hides or destroys without asking is saved; one that asks stays (review round 1)")
    func unseen() {
        let (kept, _) = saved([
            Item(title: "Notes", kids: [Item(title: "Quit Notes", key: "Q"), Item(title: "Hide Notes", key: "H"), Item(title: "Hide Others", key: "H"),
                                       Item(title: "Show All"), Item(title: "Settings…", key: ",")]),
            Item(title: "Edit", kids: [Item(title: "Delete", key: "⌫"), Item(title: "Clear All"), Item(title: "Empty Recently Deleted…"),
                                      Item(title: "Hide Sidebar", key: "S")]),
        ], app: "Notes")
        #expect(kept == ["Notes > Settings…", "Edit > Empty Recently Deleted…", "Edit > Hide Sidebar"])
    }

    @Test("A menu bar in another language is not kept: the skips read English (review round 1)")
    func language() {
        #expect(SavedMenu.english(menus: ["Apple", "Safari", "File", "Window", "Help"]))
        #expect(!SavedMenu.english(menus: ["Apple", "Safari", "Ablage", "Verlauf", "Lesezeichen", "Fenster", "Hilfe"]))
        #expect(!SavedMenu.english(menus: ["Apple", "Safari", "Archief", "Wijzig", "Geschiedenis", "Bladwijzers", "Venster", "Help"]))
    }

    @Test("The store keeps each app's copy readable by its owner alone, refuses a bundle id that names a path, drops gone apps")
    func store() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "saved-menus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SavedMenuStore(folder: folder)
        let menu = SavedMenu(bundle: "com.google.Chrome", version: "142.0 7444", read: .now,
                             items: [MenuItemNode(title: "File", enabled: true, children: [MenuItemNode(title: "New Tab", enabled: true)])])
        try store.save(menu)
        try store.save(menu)
        let mode = { (path: String) in try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int }
        #expect(try mode(folder.appending(path: "com.google.Chrome.json").path) == 0o600)
        #expect(try mode(folder.path) == 0o700)
        #expect(store.load("com.google.Chrome")?.items == menu.items)
        #expect(store.file("../evil") == nil && store.file("a/b") == nil)
        #expect(throws: (any Error).self) { try store.save(SavedMenu(bundle: "../x", version: "1", read: .now, items: [])) }
        #expect(store.prune { $0 != "com.google.Chrome" }.gone == ["com.google.Chrome"] && store.bundles().isEmpty)
    }

    @Test("An app is read again at another version or a day on, never sooner")
    func due() {
        let now = Date.now, day: TimeInterval = 24 * 3600
        #expect(SavedMenu.due(saved: nil, version: "1"))
        #expect(!SavedMenu.due(saved: ("1", now - day + 60), version: "1", now: now))
        #expect(SavedMenu.due(saved: ("1", now - day), version: "1", now: now))
        #expect(SavedMenu.due(saved: ("1", now), version: "2", now: now))
    }

    @Test("Typing an app's name lists all its actions right under it, above Ask AI: Pilot's own, its menu items (Q831)")
    func underTheApp() {
        let actions = [BindsPage.ActionInfo(id: "apps.generatePassword", label: "Generate a password", module: "apps"),
                       BindsPage.ActionInfo(id: "system.newEvent", label: "New calendar event", module: "system")]
        let entries = MenuEntries.build(apps: [(name: "Bitwarden", bundle: "com.bitwarden.desktop"), (name: "Calendar", bundle: "com.apple.iCal")],
                                        actions: actions, store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                        openID: { "apps.open:\($0)" }, running: [])
        let saved = MenuItemSearch.entries([MenuItemNode(title: "File", enabled: true, children: [MenuItemNode(title: "New Item", enabled: true)])],
                                           bundle: "com.bitwarden.desktop", app: "Bitwarden")
        var nav = MenuNavigator(entries: entries)
        nav.provide(.menuItem, saved)
        nav.query = "bitwarden"
        #expect(Array(nav.rows.map(\.title).prefix(4)) == ["Bitwarden", "Generate a password", "New Item", "Ask AI"])
        #expect(MenuGroups.headings(nav.rows, searching: true)[1] == .section("Bitwarden commands"))
        nav.query = "calendar"
        #expect(Array(nav.rows.map(\.title).prefix(3)) == ["Calendar", "New calendar event", "Ask AI"])
    }
}
