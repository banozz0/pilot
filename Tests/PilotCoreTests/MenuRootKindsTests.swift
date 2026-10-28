import Foundation
import Testing
@testable import PilotCore

/// Tab at the empty root (menu Rail and Classic, T1; Sven 2026-10-12): the menu doubles as an app, window and action
/// switcher before anything is typed. Pure, no GUI and no tiler.
@Suite("Menu root kinds")
struct MenuRootKindsTests {
    static func window(_ id: Int, _ app: String, _ title: String, on workspace: String) -> AeroWindow {
        AeroWindow(id: id, appName: app, bundleId: "app.\(app.lowercased())", pid: 1, workspace: workspace, monitorId: 1,
                   layout: "h_tiles", title: title)
    }

    static let entries = [
        MenuEntry(title: "Zed", target: .app("dev.zed.Zed"), home: .apps),
        MenuEntry(title: "Arc", target: .app("company.thebrowser.Browser"), home: .apps),
        MenuEntry(title: "Terminal", target: .app("com.apple.Terminal"), home: .apps),
        MenuEntry(title: "Learn's Terminal", target: .app("com.apple.Terminal.learn"), home: .learn, inSearch: false),
        MenuEntry(title: "Toggle gaps", target: .action("workspaces.gaps")),
        MenuEntry(title: "Close window", target: .action("windows.close")),
    ]

    /// The tiler's windows, out of workspace order; the menu lists them by workspace, each workspace's in the tiler's order.
    static let windows = MenuEntries.windows(MenuEntries.byWorkspace([
        window(3, "Zed", "main.swift", on: "2"), window(1, "Arc", "Docs", on: "10"), window(2, "Terminal", "", on: "1"),
        window(4, "Arc", "Mail", on: "2"),
    ]), excluding: nil)

    func navigator() -> MenuNavigator {
        let picks = Frecency(picks: ["app:com.apple.Terminal": [Date(timeIntervalSince1970: 1_760_000_000)]])
        var nav = MenuNavigator(entries: Self.entries, frecency: picks, now: Date(timeIntervalSince1970: 1_760_000_100))
        nav.provide(.window, Self.windows)
        return nav
    }

    func titles(_ nav: MenuNavigator) -> [String] { nav.rows.map(\.title) }

    @Test("Tab at the empty root lists every app by frecency then name, then every window by workspace, then every action")
    func tabListsEachKind() {
        var nav = navigator()
        let root = titles(nav)
        #expect(nav.handle(.tab) == .handled)
        #expect(nav.only == .app)
        #expect(titles(nav) == ["Terminal", "Arc", "Zed"], "the picked app first, then by name; a branch's own copy stays out")
        #expect(nav.selection == 0)
        #expect(nav.handle(.tab) == .handled)
        #expect(titles(nav) == ["Terminal", "Zed — main.swift", "Arc — Mail", "Arc — Docs"])
        #expect(nav.rows.map(\.detail) == ["workspace 1", "workspace 2", "workspace 2", "workspace 10"])
        #expect(nav.handle(.tab) == .handled)
        #expect(nav.only == .file)
        #expect(nav.handle(.tab) == .handled)
        #expect(nav.only == .action)
        #expect(titles(nav) == ["Close window", "Toggle gaps"])
        #expect(nav.handle(.tab) == .handled)
        #expect(nav.handle(.tab) == .handled)
        #expect(nav.only == nil)
        #expect(titles(nav) == root, "Tab from Packages wraps home: the root's branches")
    }

    @Test("Files and Packages at the empty root list nothing and say what typing does")
    func filesAndPackagesWait() {
        var nav = navigator()
        #expect(nav.emptyLine == nil, "the root lists its branches")
        for _ in 0..<3 { _ = nav.handle(.tab) }
        #expect(nav.only == .file && nav.inFiles)
        #expect(nav.rows.isEmpty)
        #expect(nav.fileQuery == nil, "the file index is asked nothing")
        #expect(nav.emptyLine == "Type to search your files.")
        nav.stepFilter(.place)
        #expect(nav.emptyLine == "Type to search in \(nav.shownFileFilters.place!.title).", "a stepped place is named")
        for _ in 0..<2 { _ = nav.handle(.tab) }
        #expect(nav.only == .package)
        #expect(nav.rows.isEmpty)
        #expect(nav.emptyLine == "Type to search Homebrew and the catalogue.")
        nav.query = "zz"
        #expect(nav.emptyLine == nil, "once typed, the search says what it found")
    }

    @Test("Shift+Tab at the empty root steps back, wrapping from home to Packages and on round to home")
    func backTabWrapsHome() {
        var nav = navigator()
        let root = titles(nav)
        #expect(nav.handle(.backTab) == .handled)
        #expect(nav.only == .package)
        #expect(nav.handle(.backTab) == .handled)
        #expect(nav.only == .action)
        for _ in 0..<4 { #expect(nav.handle(.backTab) == .handled) }
        #expect(nav.only == nil)
        #expect(titles(nav) == root)
    }

    @Test("Typing filters the shown kind; clearing it lists the whole kind again")
    func typingFiltersTheKind() {
        var nav = navigator()
        _ = nav.handle(.tab)
        nav.query = "ar"
        #expect(titles(nav) == ["Arc"])
        nav.query = ""
        #expect(titles(nav) == ["Terminal", "Arc", "Zed"])
    }

    @Test("Escape keeps today's behaviour: on a shown kind with nothing typed it closes the menu")
    func escapeCloses() {
        var nav = navigator()
        _ = nav.handle(.tab)
        #expect(nav.handle(.escape) == .close)
    }

    @Test("Tab inside a branch and in an empty picker still does nothing")
    func tabElsewhere() {
        var inApps = MenuNavigator(entries: Self.entries, branch: .apps)
        #expect(inApps.handle(.tab) == .ignored)
        var picker = MenuNavigator(list: Self.entries)
        #expect(picker.handle(.tab) == .ignored)
        #expect(picker.only == nil)
    }

    @Test("A shown kind widens the shape: the root is narrow until Tab shows a kind")
    func shownKindWidens() {
        #expect(MenuPanelSize.shape(branch: nil, query: "", isList: false, only: nil) == .narrow)
        for kind in MenuEntry.Kind.tabOrder.compactMap(\.self) {
            #expect(MenuPanelSize.shape(branch: nil, query: "", isList: false, only: kind) == .wide, "\(kind)")
        }
        #expect(MenuPanelSize.shape(branch: .trigger, query: "", isList: false, only: .app) == .narrow, "a branch keeps its own")
    }
}
