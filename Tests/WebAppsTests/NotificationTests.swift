import Foundation
import Testing
@testable import WebApps

/// Notifications in a web app (card agent-bo-95422812): the site's Notification API mapped to macOS notifications,
/// asked once per web app. Never asks macOS for real: both asks are fakes.
@Suite("Web app notifications")
struct NotificationTests {
    let suite = testSuite()

    final class Asks {
        var user = 0, macOS = 0
    }

    func gate(user: Bool, macOS: Bool, _ asks: Asks, _ decisions: NotificationDecisions) -> NotificationGate {
        NotificationGate(decisions: decisions,
                         askUser: { asks.user += 1; return user },
                         askMacOS: { asks.macOS += 1; return macOS })
    }

    @Test("No decision: the web app asks; Allow and macOS yes is granted and kept; a second request asks only macOS again")
    func allow() async throws {
        let decisions = NotificationDecisions(defaults: try #require(UserDefaults(suiteName: suite)))
        let asks = Asks()
        #expect(await gate(user: true, macOS: true, asks, decisions).request() == .init(permission: .granted, message: nil))
        #expect(decisions.decision == .allowed)
        #expect(await gate(user: false, macOS: true, asks, decisions).request().permission == .granted)
        #expect(asks.user == 1)
        #expect(asks.macOS == 2)
    }

    @Test("Don't Allow is denied and kept, so a second request asks nobody")
    func deny() async throws {
        let decisions = NotificationDecisions(defaults: try #require(UserDefaults(suiteName: suite)))
        let asks = Asks()
        #expect(await gate(user: false, macOS: true, asks, decisions).request().permission == .denied)
        #expect(decisions.decision == .denied)
        #expect(await gate(user: true, macOS: true, asks, decisions).request().permission == .denied)
        #expect(asks.user == 1 && asks.macOS == 0)
    }

    @Test("Allow but macOS says no: denied, with the plain message once")
    func macOSDenies() async throws {
        let decisions = NotificationDecisions(defaults: try #require(UserDefaults(suiteName: suite)))
        let asks = Asks()
        let first = await gate(user: true, macOS: false, asks, decisions).request()
        #expect(first.permission == .denied)
        #expect(first.message == "Notifications are off for this web app in System Settings › Notifications.")
        #expect(await gate(user: true, macOS: false, asks, decisions).request().message == nil)
    }

    @Test("What the page sees at load: granted only when allowed here and by macOS; default before anyone asked")
    func initial() throws {
        let decisions = NotificationDecisions(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(decisions.pagePermission(macOSAllows: true) == .default)
        decisions.decision = .allowed
        #expect(decisions.pagePermission(macOSAllows: true) == .granted)
        #expect(decisions.pagePermission(macOSAllows: false) == .denied)
        decisions.decision = .denied
        #expect(decisions.pagePermission(macOSAllows: true) == .denied)
    }

    @Test("A show message parses into a notification; a malformed one is dropped")
    func parse() {
        let shown = WebNotificationMessage(["type": "show", "id": 7, "title": "Hi", "body": "There", "tag": "chat"])
        #expect(shown == .show(id: 7, title: "Hi", body: "There", tag: "chat"))
        #expect(WebNotificationMessage(["type": "show", "id": 7, "title": "Hi"]) == .show(id: 7, title: "Hi", body: "", tag: ""))
        #expect(WebNotificationMessage(["type": "request", "id": 3]) == .request(id: 3))
        #expect(WebNotificationMessage(["type": "close", "id": 7, "tag": ""]) == .close(id: 7, tag: ""))
        #expect(WebNotificationMessage(["type": "show", "id": 7]) == nil)
        #expect(WebNotificationMessage(["type": "nope"]) == nil)
        #expect(WebNotificationMessage("not a dictionary") == nil)
        // A tag replaces the earlier notification with the same tag, as browsers do.
        #expect(WebNotificationMessage.identifier(id: 7, tag: "chat") == "tag-chat")
        #expect(WebNotificationMessage.identifier(id: 7, tag: "") == "id-7")
    }

    @Test("The limits no longer say No notifications; they say a web app must be running")
    func limits() {
        #expect(!WebAppSpec.limits.contains("No notifications"))
        #expect(WebAppSpec.limits.contains("Notifications only while the web app is running"))
        // Card agent-bo-95422994, G17: Bitwarden's fill login types into a Pilot web app, so no limit warns about it.
        #expect(!WebAppSpec.limits.contains { $0.localizedCaseInsensitiveContains("bitwarden") || $0.localizedCaseInsensitiveContains("autofill") })
    }
}
