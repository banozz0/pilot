import Foundation
import Testing
@testable import PilotCore

/// Settings by name (Q131, spec settings-search): Hyper+Space's root search and the window's search find Pilot's pages and
/// parts and macOS's System Settings panes.
@Suite("Settings search")
struct SettingsSearchTests {
    /// The root as it ranks for Sven: his apps and actions (SearchRankingTests) with the settings rows provided, as MenuPanel does.
    func top(_ query: String) -> [MenuEntry] {
        var nav = MenuNavigator(entries: SearchRankingTests.entries)
        nav.query = query
        nav.provideSettings(query)
        return nav.matched
    }

    func target(_ pane: String, in parent: String? = nil) -> MenuEntry.Target? {
        SettingsSearch.panes.first { $0.title == pane && $0.parent == parent }.map { .action(SettingsSearch.actionID($0)) }
    }

    @Test("The user's words put the row they mean first at the root")
    func rootRanks() {
        let privacy = target("Privacy & Security")
        #expect(top("privacy and security").first?.target == privacy, "\(top("privacy and security").prefix(3).map(\.title))")
        #expect(top("privacy").first?.target == privacy, "\(top("privacy").prefix(3).map(\.title))")
        // Pilot's own Screen recording and Gaps on or off actions stay first; the setting is right under each.
        #expect(top("screen recording").prefix(2).last?.target == target("Screen & System Audio Recording", in: "Privacy & Security"))
        #expect(top("gaps").prefix(2).map(\.target) == [.action("action.Gaps on or off"), .action(SettingsSearch.actionID(AppPlace(.tiling)))],
                "\(top("gaps").prefix(3).map(\.title))")
        #expect(top("caps lock").first?.target == .action(SettingsSearch.actionID(AppPlace(.general))))
    }

    @Test("wifi keeps Pilot's own Wi-Fi rows first, the Wi-Fi pane right under them")
    func wifi() {
        let rows = top("wifi").prefix(3)
        #expect(rows.prefix(2).allSatisfy { $0.ownKind != .setting }, "\(rows.map(\.title))")
        #expect(rows.last?.target == target("Wi-Fi"), "\(rows.map(\.title))")
    }

    @Test("The user's own queries still rank as before with the settings rows added")
    func rankingKept() {
        for c in SearchRankingTests.cases {
            let rows = top(c.query).map(\.title), rank = rows.firstIndex(of: c.want).map { $0 + 1 }
            #expect(rank != nil && rank! <= c.within, "\(c.query): \(c.want) ranked \(rank.map(String.init) ?? "nowhere") in \(rows.prefix(3))")
        }
    }

    @Test("The window's search: panes by name first, then by a word they are searched by")
    func panes() {
        #expect(SettingsSearch.panes("privacy and security").first?.title == "Privacy & Security")
        #expect(SettingsSearch.panes("privacy").first?.title == "Privacy & Security")
        #expect(SettingsSearch.panes("wifi").first?.title == "Wi-Fi")
        #expect(SettingsSearch.panes("dark mode").first?.title == "Appearance")
        #expect(SettingsSearch.panes("control centre").first?.title == "Menu Bar")
        #expect(SettingsSearch.panes("  ").isEmpty && SettingsSearch.panes("zzzq").isEmpty)
        // Pilot's places stay first in the window: its own Wi-Fi switch sits on System.
        #expect(AppPlace.search("wifi").first == AppPlace(.system) && AppPlace.search("gaps") == [AppPlace(.tiling)])
    }

    @Test("A row's action id opens what it names")
    func actionIDs() {
        let pane = SettingsSearch.panes.first { $0.title == "Privacy & Security" }!
        #expect(SettingsSearch.pane(inAction: SettingsSearch.actionID(pane)) == "com.apple.settings.PrivacySecurity.extension")
        #expect(pane.url.absoluteString == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        #expect(SettingsSearch.pane(inAction: "system.pane:") == nil && SettingsSearch.pane(inAction: "system.wifi") == nil)
        for place in AppPage.allCases.map({ AppPlace($0) }) + AppSection.allCases.map({ AppPlace($0) }) {
            #expect(SettingsSearch.place(inAction: SettingsSearch.actionID(place)) == place, "\(place.path)")
        }
        #expect(SettingsSearch.place(inAction: "window.page:nowhere") == nil)
        var nav = MenuNavigator(entries: [], branch: .system)
        nav.provideSettings("privacy")
        #expect(nav.matched.isEmpty, "no settings inside a branch")
        #expect(Set(SettingsSearch.panes.map(\.id)).count == SettingsSearch.panes.count, "each pane once")
    }
}
