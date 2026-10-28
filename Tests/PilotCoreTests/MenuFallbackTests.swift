import Foundation
import Testing
@testable import PilotCore

/// Sven 2026-10-16: whatever is typed at the root, Hyper+Space offers Ask AI with it and Search the web for it, under the
/// best match's group when others match (Sven Q174) and first when nothing does; rows like any other (the arrows, Return, ⌘ numbers reach
/// them). They replace the Ask Quick AI row that only followed answers. Pure, no GUI.
@Suite("Menu Ask AI and Search the web")
struct MenuFallbackTests {
    static let entries = [
        MenuEntry(title: "Notes", target: .app("com.apple.Notes"), home: .apps),
        MenuEntry(title: "Notion", target: .app("notion.id"), home: .apps),
        MenuEntry(title: "Quick notes", target: .action("notes.toggle")),
        MenuEntry(title: "Notes folder", target: .action("notes.folder")),
        MenuEntry(title: "New note", target: .action("notes.new")),
    ]

    func targets(_ nav: MenuNavigator) -> [MenuEntry.Target] { nav.rows.map(\.target) }
    func at(_ nav: MenuNavigator, _ target: MenuEntry.Target) -> Int? { nav.rows.firstIndex { $0.target == target } }

    @Test("With hits, Ask AI, Search the web and Search files come right after the best match's group, then the other hits")
    func afterTheBestMatch() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "no"
        let ask = at(nav, .ask("no")), web = at(nav, .searchWeb("no"))
        #expect(ask == 1 && web == 2, "\(nav.rows.map(\.title))")
        #expect(!nav.rows[0].isOffer && MenuNavigator.bestMatchEnd(nav.rows.filter { !$0.isOffer }) == 1)
        #expect(nav.rows[3].target == .searchFiles, "Search files joins them (Q182)")
        #expect(!nav.rows.dropFirst(4).contains { $0.isOffer })
        // Offers, so no kind counts them and the line's count leaves them out.
        #expect(nav.rows[ask!].isOffer && nav.rows[web!].isOffer)
        #expect(nav.count(of: .action) == 3 && nav.count(of: .app) == 2)
    }

    @Test("With one hit, they follow it")
    func oneHit() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "notion"
        #expect(targets(nav).prefix(3) == [.app("notion.id"), .ask("notion"), .searchWeb("notion")], "\(nav.rows.map(\.title))")
    }

    @Test("Answers that head together as the Best match keep that group whole: the rows follow the last answer")
    func answersTogether() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "no"
        let first = MenuEntry(title: "1", target: .copy("1"), isAnswer: true), second = MenuEntry(title: "2", target: .copy("2"), isAnswer: true)
        nav.provide(.answer, [first, second])
        #expect(Array(targets(nav).prefix(4)) == [.copy("1"), .copy("2"), .ask("no"), .searchWeb("no")], "\(nav.rows.map(\.title))")
    }

    @Test("With nothing matching they are the first two rows, Search to install and Search files after them")
    func noMatch() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "zzqxv"
        #expect(Array(targets(nav).prefix(2)) == [.ask("zzqxv"), .searchWeb("zzqxv")])
        #expect(nav.rows.allSatisfy { $0.isOffer })
        #expect(targets(nav).contains(.searchInstall("zzqxv")))
    }

    @Test("An answer keeps the lead with them under it; `ask …` keeps its own Ask row and gets only Search the web")
    func answers() {
        var sum = MenuNavigator(entries: Self.entries)
        sum.query = "22 km to mi"
        sum.provide(.answer, RootAnswers.entries(for: sum.query, now: .now))
        #expect(sum.rows.first?.isAnswer == true)
        #expect(Array(targets(sum)[1...2]) == [.ask("22 km to mi"), .searchWeb("22 km to mi")])
        var ask = MenuNavigator(entries: Self.entries)
        ask.query = "ask why is the sky blue"
        ask.provide(.answer, RootAnswers.entries(for: ask.query, now: .now))
        #expect(nav(ask, count: { if case .ask = $0 { true } else { false } }) == 1, "\(ask.rows.map(\.title))")
        #expect(targets(ask).contains(.searchWeb("ask why is the sky blue")))
    }

    func nav(_ nav: MenuNavigator, count: (MenuEntry.Target) -> Bool) -> Int { nav.rows.count { count($0.target) } }

    @Test("Return on Search the web runs it; ⌘n reaches them as any row; nothing typed, a kind Tab shows or a branch: none")
    func reachAndScope() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "zzqxv"
        var web = nav
        #expect(web.handle(.number(2)) == .run(nav.rows[1]))
        var ret = nav
        _ = ret.handle(.down)
        #expect(ret.handle(.return) == .run(nav.rows[1]))
        var empty = MenuNavigator(entries: Self.entries)
        empty.query = "   "
        #expect(!empty.rows.contains { $0.target == .searchWeb("") })
        var apps = MenuNavigator(entries: Self.entries)
        apps.query = "no"
        while apps.only != .app { _ = apps.handle(.tab) }
        #expect(!apps.rows.contains { $0.isOffer })
        var branch = MenuNavigator(entries: Self.entries, branch: .apps)
        branch.query = "no"
        #expect(!branch.rows.contains { $0.isOffer })
    }

    @Test("The rows head as Ask or search; the web row names the engine and browser once read")
    func headingAndVia() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "no"
        let headings = MenuGroups.headings(nav.rows, searching: true)
        #expect(headings[1] == .askOrSearch)
        #expect(headings[2] == nil && headings[3] == nil, "Search files heads with them")
        #expect(headings[4] != nil, "the hits after them head as their own group")
        // No heading repeats (Q174).
        let titles = headings.values.map { "\($0)" }
        #expect(Set(titles).count == titles.count, "\(headings)")
        #expect(nav.rows.first { $0.target == .searchWeb("no") }?.detail == "Return searches the web")
        nav.webVia = "Google in Chrome"
        #expect(nav.rows.first { $0.target == .searchWeb("no") }?.detail == "Return searches Google in Chrome")
        var none = MenuNavigator(entries: Self.entries)
        none.query = "zzqxv"
        #expect(MenuGroups.headings(none.rows, searching: true)[0] == .askOrSearch, "not Best match")
    }
}
