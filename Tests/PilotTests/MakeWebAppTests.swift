import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Install's Make a web app row (card agent-bo-95422994, G13): the action the menu lists opens Install › Web apps, the
/// page's own flow. The window is a fake; nothing opens.
@MainActor
@Suite("Make a web app")
struct MakeWebAppTests {
    @Test("Apps registers Make a web app, unbound, and running it opens Install › Web apps")
    func opensWebApps() throws {
        @MainActor final class Opened { var places: [AppPlace] = [] }
        let opened = Opened()
        var registry = ActionRegistry()
        AppsModule.register(into: &registry, show: { opened.places.append($0) })
        let action = try #require(registry.actions["apps.webApp"])
        #expect(action.label == "Make a web app")
        #expect(registry.defaults["apps.webApp"] == nil)
        action.run()
        #expect(opened.places == [AppPlace(.webApps)])
        #expect(opened.places.first?.page == .install)
    }
}
