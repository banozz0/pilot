import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422770, Sven's call on card agent-bo-95422726: what ClipBook did, Pilot does before it goes.
@MainActor
@Suite("ClipBook carry-over")
struct ClipBookCarryTests {
    @Test("The clipboard panel opens on Option+V, ClipBook's key, beside Hyper+V in My binds")
    func optionV() {
        var registry = ActionRegistry()
        AppsModule.register(into: &registry)
        #expect(registry.defaults["apps.clipboard"] == Key("v"))
        #expect(registry.defaults["apps.clipboardOptionV"] == Key("v", .alt, hyper: false))
    }

    @Test("Launch at login is on by default, and the login item follows the setting through its seam, never the real one")
    func launchAtLogin() {
        #expect(PilotSettings.launchAtLoginDefault)
        var status = LaunchAtLogin.Status.notRegistered
        var calls: [String] = []
        let item = LoginItem(service: .init(status: { status }, register: { calls.append("register"); status = .enabled },
                                            unregister: { calls.append("unregister"); status = .notRegistered }))
        item.apply(true)
        item.apply(true)
        #expect(calls == ["register"] && item.status == .enabled)
        item.apply(false)
        #expect(calls == ["register", "unregister"] && item.status == .notRegistered)
    }

    /// Moody's REJECT http://localhost:8228/p/31GdKR91Yh4: the setting itself applies, at launch and on each change.
    @Test("The Launch at login setting registers at launch when on, and switching it off or on applies at once")
    func settingApplies() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        var status = LaunchAtLogin.Status.notRegistered
        var calls: [String] = []
        let item = LoginItem(service: .init(status: { status }, register: { calls.append("register"); status = .enabled },
                                            unregister: { calls.append("unregister"); status = .notRegistered }))
        let settings = PilotSettings(defaults: defaults, loginItem: item)
        #expect(settings.launchAtLogin && calls.isEmpty)
        settings.applyLaunchAtLogin()
        #expect(calls == ["register"])
        settings.launchAtLogin = false
        #expect(calls == ["register", "unregister"] && defaults.object(forKey: "launchAtLogin") as? Bool == false)
        settings.launchAtLogin = true
        #expect(calls == ["register", "unregister", "register"] && item.status == .enabled)
    }
}
