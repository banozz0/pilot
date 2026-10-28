import Foundation
@testable import PilotCore
import Testing
@testable import Pilot

/// The info HUD (story 188): its key, and the lines it shows from what the press reads.
@MainActor
@Suite("Info HUD")
struct InfoHUDTests {
    @Test("Hyper+Ctrl+Alt+T shows it, a v1.1 action on a key no other default, My binds or Pilot default holds")
    func key() throws {
        let registry = Engine().registry
        let key = Key("t", [.ctrl, .alt])
        #expect(registry.defaults["system.infoHUD"] == key)
        #expect(registry.actions["system.infoHUD"]?.tier == .v1_1)
        let others = MyBinds.preset(registry: registry.defaults).filter { $0.key != "system.infoHUD" && $0.value == key }
        #expect(others.isEmpty, "\(others.keys.sorted())")
        #expect(PilotDefault.binds.filter { $0.value == key }.keys.sorted() == ["system.infoHUD"])
    }

    @Test("The battery reads its percentage, charging or plugged in, then the time to full or left, as Stats says it")
    func battery() {
        #expect(SystemStats.Battery(percent: 82, charging: true, pluggedIn: true, minutesLeft: 80).phrase == "82 % · charging · 1 h 20 min to full")
        #expect(SystemStats.Battery(percent: 54, charging: false, minutesLeft: 190).phrase == "54 % · 3 h 10 min left")
        #expect(SystemStats.Battery(percent: 100, charging: false, pluggedIn: true, minutesLeft: nil).phrase == "100 % · plugged in")
    }

    @Test("A reading this Mac lacks leaves no line: a Mac mini with no weather item shows the time and date alone")
    func rows() {
        let full = InfoModel(time: "14:32", date: "Friday, 16 October 2026", battery: .init(percent: 54, charging: false, minutesLeft: 190),
                             weather: "☀️ 24°", wifi: "Home")
        #expect(full.rows.map(\.name) == ["Battery", "Weather", "Wi-Fi"])
        #expect(full.label == "14:32, Friday, 16 October 2026, Battery 54 % · 3 h 10 min left, Weather ☀️ 24°, Wi-Fi Home")
        let mini = InfoModel(time: "14:32", date: "Friday, 16 October 2026")
        #expect(mini.rows.isEmpty)
    }
}
