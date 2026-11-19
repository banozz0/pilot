import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Classic (story 149; Pilot default until 1.3, T11): every bind in the table an upgraded install keeps runs an action, so
/// its user never meets a dead key: a registered one, or an app, site or picker the engine builds from its id (Sven's
/// layout since Q531).
@MainActor
@Suite("Classic")
struct PilotDefaultTests {
    @Test("Every Classic bind runs an action and a new file has no mouse binds; the tab pair are Drive's next and previous tab")
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
