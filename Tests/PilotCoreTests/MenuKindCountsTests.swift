import Foundation
import Testing
@testable import PilotCore

/// The Rail's counts (menu Rail and Classic, T2): how many hits each kind holds, read from the ranked rows. Pure, no GUI.
@Suite("Menu kind counts")
struct MenuKindCountsTests {
    static let entries = [
        MenuEntry(title: "Notes", target: .app("com.apple.Notes"), home: .apps),
        MenuEntry(title: "Notion", target: .app("notion.id"), home: .apps),
        MenuEntry(title: "Safari", target: .app("com.apple.Safari"), home: .apps),
        MenuEntry(title: "Hidden Notes", target: .app("hidden.notes"), home: .learn, inSearch: false),
        MenuEntry(title: "Notes: new note", target: .action("notes.new")),
        MenuEntry(title: "Toggle gaps", target: .action("workspaces.gaps")),
    ]

    static let windows = MenuEntries.windows(MenuEntries.byWorkspace([
        AeroWindow(id: 1, appName: "Notes", bundleId: "com.apple.Notes", pid: 1, workspace: "1", monitorId: 1, layout: "h_tiles",
                   title: "Groceries"),
        AeroWindow(id: 2, appName: "Safari", bundleId: "com.apple.Safari", pid: 2, workspace: "2", monitorId: 1, layout: "h_tiles",
                   title: "News"),
    ]), excluding: nil)

    static let files = [
        MenuEntry(title: "notes.txt", target: .file("/tmp/notes.txt")),
        MenuEntry(title: "notes-old.txt", target: .file("/tmp/notes-old.txt")),
    ]

    func navigator() -> MenuNavigator {
        var nav = MenuNavigator(entries: Self.entries)
        nav.provide(.window, Self.windows)
        return nav
    }

    func counts(_ nav: MenuNavigator) -> [Int?] { MenuEntry.Kind.tabOrder.compactMap(\.self).map(nav.count(of:)) }

    @Test("A search counts each kind's ranked rows; files stay blank under All")
    func searchCountsEachKind() {
        var nav = navigator()
        nav.query = "notes"
        // tabOrder: app, window, file, action, package
        #expect(counts(nav) == [1, 1, nil, 1, 0])
        #expect(nav.rows.contains { $0.target == .searchFiles }, "Search files is offered")
        #expect(nav.count(of: .branch) == nil, "only the tab kinds count")
    }

    @Test("A count is what Tab to its kind lists, and every kind keeps its count while one is shown")
    func countPredictsTheList() {
        var nav = navigator()
        nav.query = "no"
        let all = counts(nav)
        for _ in 0..<5 {
            _ = nav.handle(.tab)
            guard let kind = nav.only, kind != .file else { continue }
            #expect(nav.count(of: kind) == nav.rows.count, "\(kind)")
            #expect(counts(nav) == all, "the other kinds keep their counts")
        }
    }

    @Test("Offers never count: a search that finds nothing reads 0 for every kind")
    func offersNeverCount() {
        var nav = navigator()
        nav.query = "raycast"
        #expect(nav.rows.count == 4 && nav.rows.allSatisfy { $0.isOffer }, "Ask AI, Search the web, Search to install and Search files")
        #expect(counts(nav) == [0, 0, nil, 0, 0])
    }

    @Test("Files count only in the Files view, where the index's rows arrive")
    func filesCountInTheirView() {
        var nav = navigator()
        nav.query = "notes"
        nav.provide(.file, Self.files)
        #expect(nav.count(of: .file) == nil, "under All files wait for Search files")
        for _ in 0..<3 { _ = nav.handle(.tab) }
        #expect(nav.only == .file)
        #expect(nav.count(of: .file) == 2)
        #expect(nav.count(of: .app) == 1)
    }

    @Test("The empty root counts every app, window and action; files and packages stay blank")
    func emptyRootTotals() {
        var nav = MenuNavigator(entries: Self.entries)
        #expect(counts(nav) == [3, 0, nil, 2, nil], "an entry kept out of search is not counted")
        nav.provide(.window, Self.windows)
        #expect(nav.count(of: .window) == 2, "windows arriving after the menu opened count")
        _ = nav.handle(.tab)
        #expect(counts(nav) == [3, 2, nil, 2, nil], "a shown kind keeps the totals")
        nav.query = "notes"
        nav.query = ""
        #expect(counts(nav) == [3, 2, nil, 2, nil])
    }

    @Test("Inside a branch and in a picker nothing counts")
    func noCountsElsewhere() {
        var nav = MenuNavigator(entries: Self.entries, branch: .apps)
        nav.query = "notes"
        #expect(counts(nav).allSatisfy { $0 == nil })
        var picker = MenuNavigator(list: Self.entries)
        picker.query = "notes"
        #expect(counts(picker).allSatisfy { $0 == nil })
    }
}
