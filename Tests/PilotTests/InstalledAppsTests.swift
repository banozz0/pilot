import Foundation
import Testing
@testable import Pilot

/// The app list the menu, the Binds screen and the workspace rules read (card agent-bo-95422766): Finder lives in
/// CoreServices, outside the application folders, yet is an app Sven opens by name.
@MainActor
@Suite("Installed apps")
struct InstalledAppsTests {
    @Test("Finder is listed once, by its name")
    func finder() {
        let finder = AppsModule.installedApps().filter { $0.bundle == "com.apple.finder" }
        #expect(finder.map(\.name) == ["Finder"])
    }

    @Test("Add app offers only apps a person launches: no dot-named, agent, background-only or nested helper")
    func pickable() {
        func app(_ path: String, _ info: [String: Any] = [:]) -> Bool { AppsModule.isPickable(URL(filePath: path), info: info) }
        #expect(app("/Applications/Safari.app"))
        #expect(!app("/Applications/.Karabiner-VirtualHIDDevice-Manager.app"))
        #expect(!app("/Applications/Bartender.app", ["LSUIElement": true]))
        #expect(!app("/Applications/Helper.app", ["LSUIElement": "1"]))
        #expect(!app("/Applications/Agent.app", ["LSBackgroundOnly": true]))
        #expect(!app("/Applications/Xcode.app/Contents/Applications/Instruments.app"))
        #expect(app("/Applications/Plain.app", ["LSUIElement": false]))
    }
}
