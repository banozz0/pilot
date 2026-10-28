import Testing
@testable import PilotCore

/// The app watcher (card agent-bo-95422739): one running-apps watcher for Hammerspoon and the like, menu-bar-only apps
/// whose NSWorkspace launch and terminate notifications never arrive.
@Suite("App lifecycle")
struct AppLifecycleTests {
    @Test("A change to the running apps launches or ends the watched app only when its bundle id is among those added or removed")
    func events() {
        let id = "org.hammerspoon.Hammerspoon"
        #expect(AppLifecycle.change(for: id, added: ["com.apple.finder", id], removed: nil) == (false, true))
        #expect(AppLifecycle.change(for: id, added: nil, removed: [nil, id]) == (true, false))
        #expect(AppLifecycle.change(for: id, added: ["com.apple.finder"], removed: ["com.apple.TextEdit"]) == (false, false))
        #expect(AppLifecycle.change(for: id, added: [id], removed: [id]) == (true, true))
    }
}
