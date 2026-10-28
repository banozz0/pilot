import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423046: the front app's menu items found by typing at the menu's root; a fake menu tree, never a real
/// app's menus.
@Suite("Menu item search")
struct MenuItemSearchTests {
    /// A fake Accessibility element: its attributes and the items inside it.
    struct Element: Sendable {
        let title: String?, enabled: Bool, char: String?, modifiers: Int?
        let children: [Element]
        init(_ title: String?, enabled: Bool = true, char: String? = nil, modifiers: Int? = nil, _ children: [Element] = []) {
            self.title = title; self.enabled = enabled; self.char = char; self.modifiers = modifiers; self.children = children
        }
    }

    static func read(_ e: Element) -> MenuItemSearch.Raw<Element>? {
        MenuItemSearch.Raw(title: e.title, enabled: e.enabled, char: e.char, modifiers: e.modifiers, children: e.children)
    }

    static let bar = [
        Element("Apple", [Element("About This Mac"), Element("System Settings…")]),
        Element("TextEdit", [Element("About TextEdit"), Element("Services", [Element("Make Sticky")]), Element("Quit TextEdit", char: "Q")]),
        Element("File", [
            Element("New", char: "N", modifiers: 0),
            Element("Open Recent", [Element("notes.txt"), Element("todo.rtf")]),
            Element(""),
            Element("Print…", enabled: false, char: "P"),
            Element("Export > PDF"),
            Element("Page Setup… "),
        ]),
    ]

    static func walk(_ bar: [Element], cap: Int = 1500, expired: @escaping () -> Bool = { false }) -> [MenuItemNode] {
        MenuItemSearch.walk(bar, read: read, cap: cap, expired: expired)
    }

    static func rows(_ bar: [Element] = bar) -> [MenuEntry] {
        MenuItemSearch.entries(walk(bar), bundle: "com.apple.TextEdit")
    }

    @Test("Every enabled item under its path; no Apple menu, Services, separator or disabled item")
    func items() {
        let rows = Self.rows()
        #expect(rows.map(\.title) == ["About TextEdit", "Quit TextEdit", "New", "notes.txt", "todo.rtf", "Page Setup…"])
        #expect(rows.map(\.subtitle) == ["TextEdit", "TextEdit", "File", "File › Open Recent", "File › Open Recent", "File"])
        #expect(rows.allSatisfy { $0.home == nil && $0.inSearch && $0.kind == .menuItem && $0.app == "com.apple.TextEdit" })
        let new = rows[2]
        #expect(new.detail == "⌘N" && new.detailIsKey)
        #expect(rows[3].detail == nil && !rows[3].detailIsKey)
        #expect(new.kindWord == "Menu item")
    }

    @Test("A row runs the drive route that presses its item by title path; a title holding the separator gives no row")
    func target() {
        let new = Self.rows()[2]
        #expect(new.target == .action("drive.menu:com.apple.TextEdit:File > New"))
        #expect(new.frecencyKey == "action:drive.menu:com.apple.TextEdit:File > New")
        #expect(DriveRoute(id: "drive.menu:com.apple.TextEdit:File > New") == .menu(bundle: "com.apple.TextEdit", path: ["File", "New"]))
        #expect(!Self.rows().contains { $0.title.contains("Export") })
        // The press matches the menu's own title, trailing space and all.
        #expect(Self.rows().last?.target == .action("drive.menu:com.apple.TextEdit:File > Page Setup… "))
        #expect(RowAction.list(for: new, favourite: false).prefix(3) == [.run, .setBind, .copyID])
    }

    @Test("A bound menu item already listed as an action is not listed twice")
    func notDoubled() {
        let rows = MenuItemSearch.entries(Self.walk(Self.bar), bundle: "com.apple.TextEdit",
                                          except: ["drive.menu:com.apple.TextEdit:File > New"])
        #expect(rows.map(\.title) == ["About TextEdit", "Quit TextEdit", "notes.txt", "todo.rtf", "Page Setup…"])
    }

    @Test("The walk stops at the item cap and when its time is up, keeping what it read")
    func bounded() {
        // TextEdit, About TextEdit and Services are the three asks; nothing after them is read.
        #expect(MenuItemSearch.entries(Self.walk(Self.bar, cap: 3), bundle: "b").map(\.title) == ["About TextEdit"])
        var asks = 0
        let nodes = Self.walk(Self.bar) { asks += 1; return asks > 2 }
        #expect(!nodes.isEmpty)
        #expect(MenuItemSearch.entries(nodes, bundle: "b").count < Self.rows().count)
    }

    @Test("Shortcut caps: Shift, Option, Control and no Command from the modifier mask; none for a key it cannot print")
    func shortcuts() {
        #expect(MenuItemSearch.key(char: "s", modifiers: 1) == "⇧⌘S")
        #expect(MenuItemSearch.key(char: "S", modifiers: 2) == "⌥⌘S")
        #expect(MenuItemSearch.key(char: "F", modifiers: 4) == "⌃⌘F")
        #expect(MenuItemSearch.key(char: "F", modifiers: 13) == "⌃⇧F")
        #expect(MenuItemSearch.key(char: "\u{8}", modifiers: 0) == nil)
        #expect(MenuItemSearch.key(char: nil, modifiers: 0) == nil)
        #expect(MenuItemSearch.key(char: "N", modifiers: nil) == "⌘N")
    }

    @Test("Typing at the root finds menu items beside the root's actions, and providing them never drops those actions")
    func search() {
        let entries = [MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps),
                       MenuEntry(title: "New", target: .action("windows.new"))]
        var nav = MenuNavigator(entries: entries)
        nav.provide(.menuItem, Self.rows())
        nav.query = "new"
        // An action that matches as well stays above the menu item.
        #expect(nav.matched.map(\.kind) == [.action, .menuItem])
        nav.query = "recent"
        #expect(Set(nav.matched.map(\.title)) == ["notes.txt", "todo.rtf"])
        var inside = MenuNavigator(entries: entries, branch: .apps)
        inside.provide(.menuItem, Self.rows())
        inside.query = "new"
        #expect(!inside.rows.contains { $0.kind == .menuItem })
    }
}
