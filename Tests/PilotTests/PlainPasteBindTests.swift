import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Paste as plain text from any app (card agent-bo-95423072): its action, and a key nothing else holds.
@MainActor
@Suite("Plain paste bind")
struct PlainPasteBindTests {
    @Test("apps.pastePlain is on Hyper+Alt+V, and in My binds that key is its alone")
    func freeKey() throws {
        var registry = ActionRegistry()
        AppsModule.register(into: &registry)
        let key = Key("v", .alt)
        #expect(registry.defaults["apps.pastePlain"] == key)
        #expect(registry.actions["apps.pastePlain"]?.label == "Paste as plain text")
        #expect(registry.actions["apps.pastePlain"]?.tier == .v1)
        let myBinds = MyBinds.preset(registry: registry.defaults)
        #expect(myBinds.filter { $0.value == key }.map(\.key) == ["apps.pastePlain"])
    }
}
