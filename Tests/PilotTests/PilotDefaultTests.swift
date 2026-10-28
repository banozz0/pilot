import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Pilot default (story 149): every bind in the preset a new install starts on runs an action, so a new user never meets
/// a dead key: a registered one, or an app, site or picker the engine builds from its id (Sven's layout since Q531).
@MainActor
@Suite("Pilot default")
struct PilotDefaultTests {
    @Test("Every Pilot default bind and a new file's every mouse button runs an action; the tab pair are Drive's next and previous tab")
    func registered() {
        let engine = Engine(), registry = engine.registry
        for id in PilotDefault.binds.keys { #expect(engine.action(id) != nil, "\(id)") }
        // A new file's mouse buttons each run an action here; Mouse 4 runs Sven's own Now Playing extension, which a
        // Mac without it lacks, so it is left free rather than taken to run nothing.
        let mouse = engine.binds.store.mouseBinds
        for b in mouse { #expect(engine.action(b.bind.action) != nil, "\(b.trigger.label)") }
        #expect(mouse.count == PilotDefault.mouse.count - 1)
        #expect(engine.binds.store.action(for: Key("Mouse 4", hyper: false)) == nil)
        #expect(registry.actions["drive.nextTab"]?.label == "Next tab" && registry.defaults["drive.nextTab"] == nil)
        #expect(PilotDefault.binds["terminal.drop"] == registry.defaults["terminal.drop"])
        #expect(PilotDefault.binds["ai.chat"] == registry.defaults["ai.chat"])
        #expect(BindStore(presets: [.pilot: PilotDefault.binds]).refused.isEmpty, "the drops' T and Q are free there")
    }
}
