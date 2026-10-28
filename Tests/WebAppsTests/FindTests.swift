import Testing
@testable import WebApps

/// Find in page in a web app (card agent-bo-95422811): the count, the bar's label, its keys and the Edit menu items.
@Suite("Web app find in page")
struct FindTests {
    @Test("Matches are counted ignoring case, without overlaps; the label says how many")
    func countAndLabel() {
        #expect(FindInPage.count("ab", in: "Ab ab aB") == 3)
        #expect(FindInPage.count("aa", in: "aaaa") == 2)
        #expect(FindInPage.count("", in: "anything") == 0)
        #expect(FindInPage.label(query: "", count: 0) == "")
        #expect(FindInPage.label(query: "x", count: 0) == "no matches")
        #expect(FindInPage.label(query: "x", count: 1) == "1 match")
        #expect(FindInPage.label(query: "x", count: 3) == "3 matches")
    }

    @Test("Return and Cmd+G go forward, Shift+Return and Shift+Cmd+G back, Escape closes")
    func keys() {
        #expect(FindInPage.step(for: .return) == .next)
        #expect(FindInPage.step(for: .return, shift: true) == .previous)
        #expect(FindInPage.step(for: .escape) == .close)
        // Cmd+G and Shift+Cmd+G are the Edit menu's keys.
        let step = { (key: String, shift: Bool) in FindInPage.menuItems.first { $0.key == key && $0.shift == shift }?.step }
        #expect(step("g", false) == .next)
        #expect(step("g", true) == .previous)
        #expect(step("f", false) == .show)
    }

    @Test("The Edit menu gets Find… Cmd+F, Find Next Cmd+G and Find Previous Shift+Cmd+G")
    func menu() {
        #expect(FindInPage.menuItems.map(\.title) == ["Find…", "Find Next", "Find Previous"])
        #expect(FindInPage.menuItems.map(\.key) == ["f", "g", "g"])
        #expect(FindInPage.menuItems.map(\.shift) == [false, false, true])
    }
}
