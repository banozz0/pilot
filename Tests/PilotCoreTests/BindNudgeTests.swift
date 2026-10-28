import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95422934: a hint naming the bind after a mouse open or a menu pick, rate-limited.
@Suite("BindNudge")
struct BindNudgeTests {
    @Test("Once an hour per bind, once every two minutes overall")
    func limits() {
        var n = BindNudges()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func allow(_ id: String, _ after: TimeInterval) -> Bool { n.allow(id, at: t0.addingTimeInterval(after)) }
        let first = allow("apps.telegram", 0), sameInHour = allow("apps.telegram", 3000), otherSoon = allow("apps.zen", 60)
        let otherLater = allow("apps.zen", 200), sameNextHour = allow("apps.telegram", 3700)
        #expect(first)
        #expect(!sameInHour, "the same bind inside the hour")
        #expect(!otherSoon, "another bind inside two minutes")
        #expect(otherLater)
        #expect(sameNextHour)
    }

    @Test("A click and then a menu pick of the same bind share the hour; a role's key is the same bind as the app's")
    func oneLimitPerKey() {
        var n = BindNudges()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let click = n.hint(for: "Telegram", key: "Hyper+T", at: t0)
        let pick = n.hint(for: "Telegram", key: "Hyper+T", at: t0.addingTimeInterval(300))
        let role = n.hint(for: "Terminal", key: "Hyper+Return", at: t0.addingTimeInterval(600))
        let roleAgain = n.hint(for: "Ghostty", key: "Hyper+Return", at: t0.addingTimeInterval(900))
        #expect(click == "Telegram is on Hyper+T")
        #expect(pick == nil, "the menu pick five minutes after the click is the same bind")
        #expect(role == "Terminal is on Hyper+Return")
        #expect(roleAgain == nil)
    }

    @Test("An activation is the mouse's only right after a click and with no Pilot bind just before")
    func byMouse() {
        #expect(BindNudges.byMouse(sinceMouseDown: 0.3, sinceBind: 10))
        #expect(BindNudges.byMouse(sinceMouseDown: 0.3, sinceBind: nil))
        #expect(!BindNudges.byMouse(sinceMouseDown: 2, sinceBind: 10), "a keyboard switch long after the last click")
        #expect(!BindNudges.byMouse(sinceMouseDown: 0.3, sinceBind: 0.5), "a bind ran: the key was used")
    }

    @Test("The hint names the app or action and its key")
    func text() {
        #expect(BindNudges.text(for: "Telegram", key: "Hyper+T") == "Telegram is on Hyper+T")
    }

    @Test("An app with no key is offered one under the same limits, keyed by the action its key would run")
    func offer() {
        var n = BindNudges()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let first = n.offer(for: "TextEdit", action: "apps.open:com.apple.TextEdit", at: t0)
        let soon = n.hint(for: "Telegram", key: "Hyper+T", at: t0.addingTimeInterval(60))
        let again = n.offer(for: "TextEdit", action: "apps.open:com.apple.TextEdit", at: t0.addingTimeInterval(600))
        #expect(first == "TextEdit has no key")
        #expect(soon == nil, "a hint inside two minutes of an offer")
        #expect(again == nil, "the same app inside the hour")
        #expect(BindNudges.capture(for: "TextEdit") == "Press a Hyper key for TextEdit · Esc stops")
        #expect(BindNudges.capture(for: "TextEdit", taken: ("Hyper+T", "Telegram")) == "Hyper+T runs Telegram · Press a Hyper key for TextEdit · Esc stops")
    }

    @Test("An app's key is its own bind, else the bind of the role it fills; none means no hint")
    func appKey() {
        let store = BindStore(defaults: ["apps.terminal": Key("return"), "apps.open:org.telegram": Key("t")])
        let roles = MenuEntries.roleKeys(store: store, roleApps: ["apps.terminal": "com.mitchellh.ghostty"])
        let open: (String) -> String = { "apps.open:\($0)" }
        #expect(MenuEntries.appKey("org.telegram", store: store, roleKeys: roles, openID: open) == Key("t"))
        #expect(MenuEntries.appKey("com.mitchellh.ghostty", store: store, roleKeys: roles, openID: open) == Key("return"))
        #expect(MenuEntries.appKey("com.apple.TextEdit", store: store, roleKeys: roles, openID: open) == nil)
    }
}
