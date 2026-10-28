import Foundation
import Testing
@testable import PilotCore

/// The menu's headings (design round 4, card agent-bo-95422895): the rows keep their order and their keys; a heading
/// sits where the kind of row changes and the first match is the best one.
@Suite("Menu groups")
struct MenuGroupsTests {
    static let ghostty = MenuEntry(title: "Ghostty", target: .app("com.mitchellh.ghostty"))
    static let ghostex = MenuEntry(title: "Ghostex", target: .app("dev.ghostex"))
    static let window = MenuEntry(title: "pilot — Ghostty", target: .window(4))
    static let file = MenuEntry(title: "README.md", target: .file("/tmp/README.md"))
    static let lock = MenuEntry(title: "Lock screen", target: .action("system.lock"))
    static let apps = MenuEntry(title: "Apps", target: .branch(.apps)), learn = MenuEntry(title: "Learn", target: .branch(.learn))

    @Test("Searching: the first row is the best match, then a heading wherever the kind changes; windows and files share one")
    func searching() {
        let rows = [Self.ghostty, Self.ghostex, Self.window, Self.file, Self.lock, Self.apps]
        #expect(MenuGroups.headings(rows, searching: true) == [0: .bestMatch, 1: .apps, 2: .windowsAndFiles, 4: .actions, 5: .goTo])
    }

    @Test("A root search keeps the best match first and gathers the rest by group, each where its best row stood")
    func grouped() {
        let rows = [Self.ghostty, Self.lock, Self.window, Self.ghostex, Self.apps, Self.file]
        #expect(MenuGroups.grouped(rows).map(\.title) == ["Ghostty", "Lock screen", "pilot — Ghostty", "README.md", "Ghostex", "Apps"])
        let headings = MenuGroups.headings(MenuGroups.grouped(rows), searching: true)
        #expect(headings == [0: .bestMatch, 1: .actions, 2: .windowsAndFiles, 4: .apps, 5: .goTo], "each heading once")
    }

    @Test("The navigator's root search is grouped, so the arrow keys walk the rows in the order they are drawn")
    func navigatorGroups() {
        // Ranked alone these interleave: the actions and windows score between the apps.
        var nav = MenuNavigator(entries: [
            MenuEntry(title: "Notes", target: .app("com.apple.Notes"), home: .apps),
            MenuEntry(title: "Note — TextEdit", target: .window(7)),
            MenuEntry(title: "New note", target: .action("notes.new")),
            MenuEntry(title: "Notion", target: .app("notion.id"), home: .apps),
            MenuEntry(title: "notes.md", target: .file("/tmp/notes.md")),
            MenuEntry(title: "Nota", target: .action("x.nota")),
        ])
        nav.query = "no"
        // Ranked alone: Notes, Notion, Nota, Note — TextEdit, New note (the actions split by the window); the file waits
        // for the Files view (card agent-bo-95422968). Ask AI, Search the web and Search files follow the best match's
        // group (Sven Q174, Q182).
        #expect(nav.rows.map(\.title) == ["Notes", "Ask AI", "Search the web", "Search files for \"no\"", "Notion", "Nota", "New note",
                                          "Note — TextEdit"])
    }

    @Test("Answers (a sum, a reminder) head as the best match together, never as actions")
    func answers() {
        let sum = MenuEntry(title: "= 4", target: .copy("4"), isAnswer: true), remind = MenuEntry(title: "Remind", target: .copy("r"), isAnswer: true)
        #expect(MenuGroups.headings([sum, remind, Self.lock], searching: true) == [0: .bestMatch, 2: .actions])
    }

    @Test("The root before typing is one list with no heading (card agent-bo-95422981)")
    func root() {
        #expect(MenuGroups.headings([Self.apps, Self.learn], searching: false).isEmpty)
    }

    @Test("Inside a branch with no sections the rows carry no headings")
    func branch() {
        #expect(MenuGroups.headings([Self.ghostty, Self.ghostex], searching: false).isEmpty)
        #expect(MenuGroups.headings([Self.ghostty, Self.ghostex], searching: false, branch: .apps).isEmpty)
    }
}
