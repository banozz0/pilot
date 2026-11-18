import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Pilot default (story 149): every bind in the preset a new install starts on runs an action, so a new user never meets
/// a dead key: a registered one, or an app, site or picker the engine builds from its id (Sven's layout since Q531).
@MainActor
@Suite("Pilot default")
struct PilotDefaultTests {
    @Test("Every Pilot default bind runs an action and a new file has no mouse binds; the tab pair are Drive's next and previous tab")
    func registered() {
        let engine = Engine(), registry = engine.registry
        for id in PilotDefault.binds.keys { #expect(engine.action(id) != nil, "\(id)") }
        // A new install's mouse buttons stay the apps' own until bound (Sven, Q251; a middle click once opened Ghostty).
        #expect(engine.binds.store.mouseBinds.isEmpty)
        #expect(registry.actions["drive.nextTab"]?.label == "Next tab" && registry.defaults["drive.nextTab"] == nil)
        #expect(PilotDefault.binds["terminal.drop"] == registry.defaults["terminal.drop"])
        #expect(PilotDefault.binds["ai.chat"] == registry.defaults["ai.chat"])
        #expect(BindStore(presets: [.pilot: PilotDefault.binds]).refused.isEmpty, "the drops' T and Q are free there")
    }
}
