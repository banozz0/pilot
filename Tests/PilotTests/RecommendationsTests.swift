import Foundation
import Testing
@testable import Pilot

@MainActor
@Suite("Recommend apps")
struct RecommendationsTests {
    @Test("Recommend apps is on by default and saved (card agent-bo-95423241)")
    func savedSwitch() throws {
        let name = testSuite()
        let saved = Recommendations(defaults: try #require(UserDefaults(suiteName: name)))
        #expect(saved.show)
        saved.show = false
        #expect(Recommendations(defaults: try #require(UserDefaults(suiteName: name))).show == false)
    }
}
