import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Settings search in the app (Q131): the window search's Return and the settings rows' actions.
@Suite("Settings search in the app") @MainActor
struct SettingsSearchWindowTests {
    @Test("Return opens Pilot's place first, else the System Settings pane, and empties the search")
    func returnPicks() throws {
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        var opened: [String] = []
        model.openPane = { opened.append($0.title) }
        model.query = "privacy and security"
        model.goToFirstResult()
        #expect(opened == ["Privacy & Security"] && model.query.isEmpty)
        model.query = "gaps"
        model.goToFirstResult()
        #expect(model.page == .tiling && opened.count == 1 && model.query.isEmpty)
        model.query = "zzzq"
        model.goToFirstResult()
        #expect(model.query == "zzzq" && opened.count == 1)
    }

    @Test("A settings row's id builds its action, named for the binds")
    func actions() {
        let pane = SettingsSearch.panes.first { $0.title == "Privacy & Security" }!
        #expect(SettingsActions.dynamic(SettingsSearch.actionID(pane))?.label == "Privacy & Security in System Settings")
        #expect(SettingsActions.dynamic(SettingsSearch.actionID(AppPlace(.reports)))?.label == "Activity › Reports in Pilot")
        #expect(SettingsActions.dynamic("system.wifi") == nil && SettingsActions.dynamic("window.page:nowhere") == nil)
    }
}
