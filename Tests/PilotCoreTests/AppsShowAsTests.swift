import Testing
@testable import PilotCore

/// Story 154: one setting says how every list shows an app, and the menu knows which of its rows list one.
@Suite("Apps show as")
struct AppsShowAsTests {
    @Test("Each mode shows the icon, the title or both; Icon only leaves a window's own title")
    func shows() {
        #expect(AppsShowAs.standard == .both)
        #expect(AppsShowAs.allCases.map(\.label) == ["Icon only", "Title only", "Icon and title"])
        #expect(AppsShowAs.both.shows() == (true, true))
        #expect(AppsShowAs.icon.shows() == (true, false))
        #expect(AppsShowAs.title.shows() == (false, true))
        #expect(AppsShowAs.icon.shows(.owner) == (true, true), "a window keeps its title under Icon only")
        #expect(AppsShowAs.title.shows(.owner) == (false, true))
        #expect(AppsShowAs.icon.shows(nil) == (true, true) && AppsShowAs.title.shows(nil) == (true, true), "a row that lists no app shows both")
    }

    @Test("An app, a window and a row wearing an app's picture list an app; an action, a file and a tool do not")
    func roles() {
        func entry(_ target: MenuEntry.Target, icon: MenuIcon? = nil) -> MenuEntry {
            var e = MenuEntry(title: "x", target: target)
            e.icon = icon
            return e
        }
        #expect(entry(.app("com.apple.finder")).appRole == .app)
        #expect(entry(.window(7)).appRole == .owner)
        #expect(entry(.package("cask:zed"), icon: MenuIcon.cask.app(path: "/Applications/Zed.app")).appRole == .app)
        #expect(entry(.package("formula:ripgrep"), icon: .formula).appRole == nil, "a command-line tool is not an app")
        var found = MenuIcon.appStore
        found.remote = "https://example.com/art.png"
        #expect(entry(.package("mas:1"), icon: found).appRole == .app, "a found picture says it is an app")
        #expect(entry(.action("system.lock")).appRole == nil)
        #expect(entry(.file("/tmp/a.txt")).appRole == nil)
    }
}
