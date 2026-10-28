import Testing
@testable import PilotCore

@Suite("Keys and registry")
struct RegistryTests {
    @Test("Key names round-trip and label like the sheet")
    func keyNames() {
        #expect(Key("k").keyCode == KeyCode.k)
        #expect(Key("K", shift: true).label == "Hyper+Shift+K")
        #expect(Key(keyCode: 123).label == "Hyper+←")
        #expect(Key("t", [.shift, .ctrl]).label == "Hyper+Shift+Ctrl+T")
        #expect(Key(keyCode: 4, modifiers: .leftAlt, hyper: false).label == "Left Alt+H")
        #expect(KeyNames.code(for: KeyNames.name(for: 999)) == 999)
        #expect(KeyNames.name(for: 999) == "key999")
    }

    @Test("Registering records the default key; a second action on the same default key or id is refused")
    func registerRefusesCollisions() throws {
        var registry = ActionRegistry()
        try registry.register(Action(id: "engine.sheet", label: "Cheat sheet", module: .engine, defaultKey: Key("k")) {})
        #expect(registry.defaults == ["engine.sheet": Key("k")])

        #expect(throws: ActionRegistry.RegistrationError.duplicateId("engine.sheet")) {
            try registry.register(Action(id: "engine.sheet", label: "Again", module: .engine) {})
        }
        #expect(throws: ActionRegistry.RegistrationError.keyTaken(Key("k"), by: "engine.sheet")) {
            try registry.register(Action(id: "apps.browser", label: "Browser", module: .apps, defaultKey: Key("k")) {})
        }
        #expect(registry.actions.count == 1)
    }
}
