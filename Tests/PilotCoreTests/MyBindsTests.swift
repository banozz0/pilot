import Foundation
import Testing
@testable import PilotCore

/// My binds (card agent-bo-95422700, Interim layout): every Hammerspoon bind on its key today, so Hammerspoon can stay
/// quit. The registry's defaults hold the registered actions; MyBinds adds the app, page and private-window binds.
@Suite("My binds")
struct MyBindsTests {
    @Test("Hammerspoon's app and site binds keep their keys, opening in Zen where Hammerspoon did")
    func appBinds() {
        let b = MyBinds.extras
        #expect(b["apps.open:com.madda.ghostex.gpui"] == Key("g"))
        #expect(b["apps.open:app.zen-browser.zen"] == Key("b"))
        #expect(b["apps.url:app.zen-browser.zen:https://claude.ai"] == Key("i"))
        #expect(b["apps.private:app.zen-browser.zen"] == Key("b", .shift))
        #expect(b["apps.url:app.zen-browser.zen:https://x.com"] == Key("x", .shift))
        #expect(b["apps.open:net.whatsapp.WhatsApp"] == Key("w", .shift))
        #expect(Set(b.values).count == b.count)
    }

    @Test("The preset is the registry's defaults plus these; a registry default on one of their keys shows as refused")
    func preset() {
        let p = MyBinds.preset(registry: ["windows.close": Key("w")])
        #expect(p["windows.close"] == Key("w"))
        #expect(p["apps.open:app.zen-browser.zen"] == Key("b"))
        #expect(BindStore(presets: [.myBinds: p]).refused.isEmpty)
        let clash = BindStore(presets: [.myBinds: MyBinds.preset(registry: ["apps.browser": Key("b")])])
        #expect(clash.refused.map(\.action) == ["apps.open:app.zen-browser.zen"])
    }

    /// The registry's two drop keys typed here, as TerminalDrop and AIChatPanel register them; AIChatPanelTests pins
    /// ai.chat's own.
    static let drops: [String: Key] = ["terminal.drop": Key("t"), "ai.chat": Key("q")]

    @Test("Hyper+T drops the terminal, Hyper+Q Ask AI, Telegram moves to Hyper+Alt+T, and nothing clashes (Q105, Q92)")
    func drops() {
        #expect(MyBinds.extras["apps.open:com.tdesktop.Telegram"] == Key("t", .alt))
        #expect(!MyBinds.extras.values.contains(Key("t")) && !MyBinds.extras.values.contains(Key("q")))
        let store = BindStore(presets: [.myBinds: MyBinds.preset(registry: Self.drops)])
        #expect(store.action(for: Key("t")) == "terminal.drop")
        #expect(store.action(for: Key("q")) == "ai.chat")
        #expect(store.action(for: Key("t", .alt)) == "apps.open:com.tdesktop.Telegram")
        #expect(store.refused.isEmpty)
    }
}

/// The app picker's action ids (stories 17 and 19): an app, a page in the default browser, a page in one app, and a
/// private window of a browser.
@Suite("App links")
struct AppLinkTests {
    @Test("Each id reads back to what it opens, and writes the same id")
    func roundTrip() {
        let cases: [(String, AppLink)] = [
            ("apps.open:com.apple.TextEdit", .open(bundle: "com.apple.TextEdit")),
            ("apps.web:https://x.com", .web(url: "https://x.com")),
            ("apps.url:app.zen-browser.zen:https://claude.ai", .url(bundle: "app.zen-browser.zen", url: "https://claude.ai")),
            ("apps.private:app.zen-browser.zen", .privateWindow(bundle: "app.zen-browser.zen")),
        ]
        for (id, link) in cases {
            #expect(AppLink(id: id) == link)
            #expect(link.id == id)
        }
        #expect(AppLink(id: "windows.close") == nil)
        #expect(AppLink(id: "apps.url:app.zen-browser.zen") == nil)
    }

    @Test("A private window is the browser family's own flag; another app has none")
    func privateFlag() {
        #expect(AppLink.privateFlag(bundle: "app.zen-browser.zen") == "--private-window")
        #expect(AppLink.privateFlag(bundle: "org.mozilla.firefox") == "--private-window")
        #expect(AppLink.privateFlag(bundle: "com.google.Chrome") == "--incognito")
        #expect(AppLink.privateFlag(bundle: "com.apple.TextEdit") == nil)
    }
}
