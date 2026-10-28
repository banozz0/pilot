import Foundation
import Observation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422934: bind hints are on by default, observed, and kept across launches.
@MainActor
@Suite("BindNudge setting")
struct BindNudgeSettingTests {
    @Test("On by default; switching it off notifies observers and is read back at the next launch")
    func stored() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let item = LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {}))
        let settings = PilotSettings(defaults: defaults, loginItem: item)
        #expect(settings.bindNudges)
        nonisolated(unsafe) var fired = 0
        withObservationTracking { _ = settings.bindNudges } onChange: { fired += 1 }
        settings.bindNudges = false
        #expect(fired == 1)
        #expect(!PilotSettings(defaults: defaults, loginItem: item).bindNudges)
    }
}
