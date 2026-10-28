import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Tools › Captures (spec `capture.html` CP4): the folders read as `pilot get` does.
@MainActor
@Suite("Capture settings")
struct CaptureRoutingTests {
    @Test("The folders read as paths")
    func setting() async throws {
        let store = CaptureSettingsStore(defaults: UserDefaults(suiteName: testSuite())!)
        let schema = SettingsSchema()
        schema.registerCaptures(store)
        #expect(try schema.get("capture.folder") == .string(NSHomeDirectory() + "/Pictures/Pilot/"))
        #expect(try schema.get("capture.recordingsFolder") == .string(NSHomeDirectory() + "/Movies/Pilot/"))
    }
}
