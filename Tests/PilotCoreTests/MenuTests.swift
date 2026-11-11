import Foundation
import Testing
@testable import PilotCore

/// The menu's fuzzy ranking (story 74; SPEC.md, Testing Decisions): pure, no GUI.
@Suite("Fuzzy ranker")
struct FuzzyRankerTests {
    func ranked(_ query: String, _ titles: [String]) -> [String] { FuzzyRanker.rank(titles, query: query) { $0 } }

    @Test("A title matches when the query's letters appear in it in order, in any case and without accents")
    func matches() {
        #expect(FuzzyRanker.score("txed", in: "TextEdit") != nil)
        #expect(FuzzyRanker.score("TEXTEDIT", in: "TextEdit") != nil)
        #expect(FuzzyRanker.score("cafe", in: "Café") != nil)
        #expect(FuzzyRanker.score("tdx", in: "TextEdit") == nil)
        // One letter too many is a typo, found at three quarters of the score (card agent-bo-95422766).
        #expect(FuzzyRanker.score("notes", in: "Note") == 75)
        #expect(FuzzyRanker.score("notez", in: "Calendar") == nil)
    }

    @Test("A prefix beats the same letters inside a word, word starts beat letters inside words, shorter wins a tie; two letters inside a word list nothing")
    func order() {
        #expect(ranked("tex", ["Context", "TextEdit"]) == ["TextEdit", "Context"])
        #expect(ranked("set", ["Reset", "System Settings"]) == ["System Settings", "Reset"])
        #expect(ranked("term", ["Thermometer", "Terminal"]) == ["Terminal", "Thermometer"])
        #expect(ranked("te", ["TextEdit Helper", "TextEdit"]) == ["TextEdit", "TextEdit Helper"])
        #expect(ranked("ap", ["Maps", "App Store", "Photos"]) == ["App Store"])
    }

    @Test("An empty query keeps every item in its order")
    func empty() {
        #expect(ranked("", ["Zen", "Arc", "Mail"]) == ["Zen", "Arc", "Mail"])
    }
}

/// The menu's tree (story 74, wireframe wo-nZ-ZEKkY sections 1, 2 and 5): the root lists the branches, typing at the
/// root searches every branch, inside a branch only that branch; Return or → goes in, Escape or ← goes up.
@Suite("Menu navigator")
struct MenuNavigatorTests {
    static let textEdit = MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps)
    static let terminal = MenuEntry(title: "Terminal", target: .app("com.apple.Terminal"), home: .apps)
    static let close = MenuEntry(title: "Close window", target: .action("windows.close"), detail: "Hyper+W")
    static let entries = [textEdit, terminal, close]

    func titles(_ nav: MenuNavigator) -> [String] { nav.matched.map(\.title) }

    @Test("Omarchy's apps menu (Hyper+Alt+Space) opens the menu inside Apps; Escape goes up to the root")
    func opensInBranch() {
        var nav = MenuNavigator(entries: Self.entries, branch: .apps)
        #expect(nav.branch == .apps)
        #expect(nav.rows.allSatisfy { $0.home == .apps })
        #expect(!nav.rows.isEmpty)
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.branch == nil)
    }

    @Test("A picker lists its own rows at the root, ranked by what is typed; Escape closes it")
    func picker() {
        let rows = [MenuEntry(title: "pilot", target: .action("/Users/ada/code/pilot"), detail: "~/code/pilot"),
                    MenuEntry(title: "dotfiles", target: .action("/Users/ada/code/dotfiles"))]
        var nav = MenuNavigator(list: rows)
        #expect(nav.rows.map(\.title) == ["pilot", "dotfiles"])
        nav.query = "dot"
        #expect(nav.rows.map(\.title) == ["dotfiles"])
        #expect(nav.handle(.return) == .run(rows[1]))
        #expect(nav.handle(.escape) == .close)
    }

    @Test("The root lists the ten branches and nothing else, Clean after Update (card agent-bo-95422881), System last (card agent-bo-95422981), About above it (Q446), Extensions above that (story 158); Config is an extra")
    func root() {
        let nav = MenuNavigator(entries: Self.entries)
        #expect(titles(nav) == ["Apps", "Learn", "Actions", "Install", "Remove", "Update", "Clean", "Extensions", "About", "System"])
        #expect(nav.rows.first?.target == .branch(.apps))
        #expect(nav.branch == nil)
    }

    @Test("Typing at the root searches every branch, the actions and the branch names")
    func rootSearch() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "text"
        #expect(titles(nav) == ["TextEdit"])
        nav.query = "close"
        #expect(titles(nav) == ["Close window"])
        nav.query = "sys"
        #expect(titles(nav) == ["System"])
    }

    @Test("Return on a branch goes in with an empty search; inside, typing searches that branch only")
    func enter() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "apps"
        #expect(nav.handle(.return) == .handled)
        #expect(nav.branch == .apps)
        #expect(nav.query == "")
        #expect(titles(nav) == ["TextEdit", "Terminal"])
        nav.query = "close"
        #expect(titles(nav) == [])
        nav.query = "term"
        #expect(titles(nav) == ["Terminal"])
    }

    @Test("Escape at the root clears a typed search first, then closes the menu (card agent-bo-95422762)")
    func escapeClears() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "calc"
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.query == "")
        #expect(nav.handle(.escape) == .close)
    }

    @Test("Escape inside a branch goes up one level; at the root it closes the menu")
    func escape() {
        var nav = MenuNavigator(entries: Self.entries)
        #expect(nav.handle(.return) == .handled)
        nav.query = "te"
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.branch == nil)
        #expect(nav.query == "")
        #expect(nav.handle(.escape) == .close)
    }

    @Test("Escape from Search to install goes straight back to the root search with the text kept, as Search files does (Sven 2026-10-12)")
    func escapeFromInstallSearch() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "raycast"
        // Ask AI and Search the web lead a search nothing matches (Sven 2026-10-16); Search to install follows.
        while nav.selected?.target != .searchInstall("raycast") { _ = nav.handle(.down) }
        #expect(nav.handle(.return) == .handled)
        #expect(nav.branch == .homebrew && nav.query == "raycast")
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.branch == nil && nav.query == "raycast")
        #expect(nav.selected?.target == .searchInstall("raycast"))
        // Back at the root search Escape clears and closes as before.
        nav.query = ""
        #expect(nav.handle(.escape) == .close)
    }

    @Test("Return on an app or an action runs it; ⌘Return on an app shows it in Finder")
    func run() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "text"
        #expect(nav.handle(.return) == .run(Self.textEdit))
        #expect(nav.handle(.commandReturn) == .reveal(Self.textEdit))
        nav.query = "close"
        #expect(nav.handle(.return) == .run(Self.close))
        #expect(nav.handle(.commandReturn) == .ignored)
    }

    @Test("Arrows move within the rows; → goes into a branch, ← goes up only while the search is empty")
    func arrows() {
        var nav = MenuNavigator(entries: Self.entries)
        #expect(nav.handle(.up) == .handled)
        #expect(nav.selected?.title == "Apps")
        for _ in 0..<10 { _ = nav.handle(.down) }
        #expect(nav.selected?.title == "System")
        nav.query = "text"
        #expect(nav.handle(.right) == .ignored, "a root search's → moves the caret (Sven 2026-10-12)")
        #expect(nav.only == nil)
        nav.query = ""
        #expect(nav.handle(.up) == .handled)
        #expect(nav.handle(.right) == .handled)
        #expect(nav.branch == .apps)
        nav.query = "t"
        #expect(nav.handle(.left) == .ignored)
        nav.query = ""
        #expect(nav.handle(.left) == .handled)
        #expect(nav.branch == nil)
        #expect(nav.selected?.title == "Apps")
        #expect(nav.handle(.left) == .ignored)
    }

    @Test("Tab narrows the root search to apps, then windows, files, actions and packages, then every kind again")
    func tab() {
        let gaps = MenuEntry(title: "Toggle gaps", target: .action("workspaces.gaps"))
        var nav = MenuNavigator(entries: Self.entries + [gaps])
        nav.query = "t"
        #expect(Set(nav.rows.map(\.kind)) == [.app, .action, .branch])
        #expect(nav.handle(.tab) == .handled)
        #expect(titles(nav) == ["TextEdit", "Terminal"])
        for _ in 0..<3 { #expect(nav.handle(.tab) == .handled) }
        #expect(titles(nav) == ["Toggle gaps"])
        for _ in 0..<2 { #expect(nav.handle(.tab) == .handled) }
        #expect(nav.only == nil)
    }

    @Test("A branch a later ticket fills opens empty and says so; Apps shows its count")
    func emptyBranch() {
        var nav = MenuNavigator(entries: Self.entries)
        #expect(nav.rows.first?.detail == "2 installed")
        _ = nav.handle(.down)
        #expect(nav.handle(.return) == .handled)
        #expect(nav.branch == .learn)
        #expect(nav.rows.isEmpty)
        #expect(nav.handle(.return) == .handled)
    }
}

/// What the menu lists (wireframe section 2): every installed app with its bind, then every action the Binds screen
/// lists but the menu's own and the per-app opens, which the app rows already are.
@Suite("Menu entries")
struct MenuEntriesTests {
    @Test("An app shows its own bind, else the bind of the role it fills; search skips the menu and the app opens")
    func build() throws {
        var store = BindStore(defaults: ["apps.terminal": Key("return"), "apps.launcher": Key("space"), "windows.close": Key("w")])
        try store.set("apps.open:com.apple.TextEdit", to: Key("t", .shift))
        try store.set("apps.web:https://x.com", to: Key("x", .shift))
        let entries = MenuEntries.build(
            apps: [("Ghostty", "com.mitchellh.ghostty"), ("TextEdit", "com.apple.TextEdit"), ("Notes", "com.apple.Notes")],
            actions: [.init(id: "apps.launcher", label: "Pilot menu", module: "apps"),
                      .init(id: "apps.terminal", label: "Terminal", module: "apps"),
                      .init(id: "windows.close", label: "Close window", module: "windows"),
                      .init(id: "apps.open:com.apple.TextEdit", label: "TextEdit", module: "apps"),
                      .init(id: "apps.web:https://x.com", label: "x.com", module: "apps")],
            store: store, roleApps: ["apps.terminal": "com.mitchellh.ghostty"], menu: "apps.launcher",
            openID: { "apps.open:\($0)" }, running: [])
        // Learn's, Trigger's and Install's fixed rows (MenuBranchesTests, HomebrewSearchTests) aside.
        let searched = entries.filter { $0.inSearch && ![.learn, .trigger, .install].contains($0.home) }
        #expect(searched.map(\.title) == ["Ghostty", "TextEdit", "Notes", "Terminal", "Close window", "x.com"])
        #expect(searched.map(\.detail) == ["Hyper+Return", "Hyper+Shift+T", nil, "Hyper+Return", "Hyper+W", "Hyper+Shift+X"])
        #expect(searched[0] == MenuEntry(title: "Ghostty", target: .app("com.mitchellh.ghostty"), home: .apps, detail: "Hyper+Return",
                                         detailIsKey: true))
        // A bind's trigger draws as a key cap (card agent-bo-95422727); the root's count of installed apps does not.
        #expect(searched.filter { $0.detail != nil }.allSatisfy { $0.detailIsKey })
        let apps = try #require(MenuNavigator(entries: entries).rows.first { $0.target == .branch(.apps) })
        #expect(apps.detail == "3 installed" && !apps.detailIsKey)
        #expect(searched[5].target == .action("apps.web:https://x.com"))
    }

    @Test("Keybindings lists every bind (story 27, the cheat sheet): a bound action lives there, an unbound one only in search")
    func learn() {
        var store = BindStore(defaults: ["windows.close": Key("w")])
        try? store.set("apps.web:https://x.com", to: Key("x", .shift))
        let entries = MenuEntries.build(
            apps: [], actions: [.init(id: "windows.close", label: "Close window", module: "windows"),
                                .init(id: "windows.minimise", label: "Minimise", module: "windows"),
                                .init(id: "apps.web:https://x.com", label: "x.com", module: "apps")],
            store: store, roleApps: [:], menu: "apps.launcher", openID: { "apps.open:\($0)" }, running: [])
        #expect(entries.filter { $0.kind == .action && $0.home != .learn }.map(\.home) == [.keybindings, nil, .keybindings])
        let nav = MenuNavigator(entries: entries, branch: .keybindings)
        #expect(nav.rows.map(\.title) == ["Close window", "x.com"])
    }

    @Test("Keybindings also lists the binds that open an app and the menu's own key; search finds each app once")
    func learnApps() {
        var store = BindStore(defaults: ["apps.launcher": Key("space")])
        try? store.set("apps.open:com.madda.ghostex.gpui", to: Key("g"))
        let entries = MenuEntries.build(
            apps: [("Ghostex", "com.madda.ghostex.gpui"), ("Notes", "com.apple.Notes")],
            actions: [.init(id: "apps.launcher", label: "Pilot menu", module: "apps"),
                      .init(id: "apps.open:com.madda.ghostex.gpui", label: "Ghostex", module: "apps")],
            store: store, roleApps: [:], menu: "apps.launcher", openID: { "apps.open:\($0)" }, running: [])
        let learn = MenuNavigator(entries: entries, branch: .keybindings)
        #expect(learn.rows.map(\.title) == ["Pilot menu", "Ghostex"])
        #expect(learn.rows.map(\.detail) == ["Hyper+Space", "Hyper+G"])
        var root = MenuNavigator(entries: entries)
        root.query = "ghostex"
        #expect(root.rows.filter { $0.title == "Ghostex" }.count == 1)
    }

    @Test("An app row carries whether the app runs, from the running bundle ids; actions never do")
    func running() {
        let entries = MenuEntries.build(
            apps: [("TextEdit", "com.apple.TextEdit"), ("Notes", "com.apple.Notes")],
            actions: [.init(id: "windows.close", label: "Close window", module: "windows")],
            store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher", openID: { "apps.open:\($0)" },
            running: ["com.apple.TextEdit", "com.apple.finder"])
        #expect(entries.filter { ![.learn, .trigger, .install].contains($0.home) }.map(\.running) == [true, false, false])
    }
}

