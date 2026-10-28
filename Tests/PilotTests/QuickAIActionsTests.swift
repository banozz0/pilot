import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Quick AI's actions (card agent-bo-95423050): Ask AI and Fix selected text registered, and a failure's words. The
/// chat's flow is AIChatPanelTests, the fix bind's QuickFixTests.
@Suite("Quick AI actions")
@MainActor
struct QuickAIActionsTests {
    @Test("Ask AI and Fix selected text are registered, the fix on Hyper+Ctrl+F, a key no preset or extra holds")
    func binds() {
        var registry = ActionRegistry()
        QuickAIActions.register(into: &registry)
        #expect(registry.actions["ai.ask"]?.label == "Ask AI" && registry.defaults["ai.ask"] == nil)
        #expect(registry.actions["ai.fix"]?.label == "Fix selected text" && registry.actions["ai.fix"]?.tier == .v1)
        let key = Key("f", .ctrl)
        #expect(registry.defaults["ai.fix"] == key)
        #expect(!PilotDefault.binds.values.contains(key))
        #expect(!MyBinds.extras.values.contains(key))
    }

    @Test("A failure says what went wrong and what to do")
    func failures() {
        #expect(QuickAI.Failure.missing.title == "Claude Code is not installed" && QuickAI.Failure.signedOut.hint?.contains("claude auth login") == true)
        #expect(QuickAI.Failure.failed("API Error: 529").hint == "API Error: 529")
    }
}
