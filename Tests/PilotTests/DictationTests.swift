import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Dictation (Q144, Q452): the two binds drive Pilot's own dictation.
@MainActor
@Suite("Dictation")
struct DictationTests {
    @Test("The two actions register in the Dictation module with no default key")
    func actions() {
        var registry = ActionRegistry()
        DictationModule.register(into: &registry, dictation: PilotDictationTests.Rig().pilot)
        let actions = registry.sorted.filter { $0.module == .dictation }
        #expect(actions.map(\.id) == ["dictation.hold", "dictation.toggle"])
        #expect(actions.allSatisfy { $0.defaultKey == nil } && actions[0].hold != nil)
    }
}
