import Foundation
import Testing
@testable import PilotCore

/// Bind export and import (stories 41 and 58, card agent-bo-95422725): the bind store's own JSON is the file; a
/// shell, URL, Shortcuts or picker bind arrives switched off and keeps its key until it is turned on.
@Suite("Bind export and import")
struct BindExportTests {
    let defaults: [String: Key] = ["windows.close": Key("w"), "apps.terminal": Key("return")]
    let shell = "drive.shell:echo hi"

    func source() throws -> BindStore {
        var a = BindStore(defaults: defaults)
        try a.set("apps.terminal", to: Key("t", .shift))
        try a.set(shell, to: Key("e", .shift))
        try a.set("windows.close", to: nil)
        return a
    }

    @Test("Export then import gives the other Mac the same binds; the shell bind arrives switched off with its key")
    func roundTrip() throws {
        let a = try source()
        var b = BindStore(defaults: defaults)
        let plan = try b.plan(importing: a.json())
        #expect(plan.added.map(\.action) == ["apps.terminal", shell, "windows.close"])
        #expect(plan.changed.isEmpty && plan.clashes.isEmpty)
        #expect(plan.switchedOff == [shell])
        b.apply(plan)
        #expect(b.binds == a.binds)
        #expect(b.isDisabled(shell) && !a.isDisabled(shell))
        #expect(b.action(for: Key("e", .shift)) == shell)
        #expect(!b.isDisabled("apps.terminal"))
    }

    @Test("Switched off is kept in the file until it is turned on, and only then leaves it")
    func persisted() throws {
        var b = BindStore(defaults: defaults)
        b.apply(try b.plan(importing: source().json()))
        var reread = try BindStore(json: b.json(), defaults: defaults)
        #expect(reread.isDisabled(shell))
        #expect(reread.switchedOff == [shell])
        reread.enable(shell)
        #expect(!reread.isDisabled(shell))
        #expect(!String(decoding: reread.json(), as: UTF8.self).contains("disabled"))
        #expect(!String(decoding: BindStore(defaults: defaults).json(), as: UTF8.self).contains("disabled"))
    }

    @Test("A trigger this Mac already uses is a clash and keeps this Mac's bind; a different key is a change, on or off as before")
    func clashAndChange() throws {
        var b = BindStore(defaults: defaults)
        try b.set("apps.notes", to: Key("t", .shift))
        try b.set(shell, to: Key("x", .shift))
        let plan = try b.plan(importing: source().json())
        #expect(plan.clashes == [BindStore.Refusal(action: "apps.terminal", trigger: Key("t", .shift), takenBy: "apps.notes")])
        #expect(plan.changed.map(\.action) == [shell])
        #expect(plan.added.map(\.action) == ["windows.close"])
        b.apply(plan)
        #expect(b.action(for: Key("t", .shift)) == "apps.notes")
        // The same command on a new key: this Mac already runs it, so it stays on.
        #expect(b.trigger(for: shell) == Key("e", .shift) && !b.isDisabled(shell))
        #expect(plan.summary(name: "pilot-export.json") == "pilot-export.json: 1 new bind, 1 changed, 1 clash (Hyper+Shift+T).")
        var c = BindStore(defaults: defaults)
        #expect(try c.plan(importing: source().json()).summary(name: "x.json")
                == "x.json: 3 new binds, 0 changed, 0 clashes. 1 shell, URL or Shortcuts bind stays switched off until you turn it on.")
        c.apply(try c.plan(importing: source().json()))
        #expect(c.isDisabled(shell))
    }

    @Test("Shell, URL, Shortcuts and picker binds arrive off; keystrokes, menu items and Pilot's own actions do not")
    func whichArriveOff() {
        let pick = DriveRoute.picker(title: nil, list: "ls", run: "open $1").id
        // A link to a page in the browser is a web page; any other scheme can reach a command (pilot://run, shortcuts://).
        for id in [shell, "drive.url:shottr://grab/area", "drive.shortcut:Morning", pick,
                   "apps.web:pilot://run?action=drive.shell%3Atouch%20/tmp/x", "apps.url:app.zen-browser.zen:shortcuts://run-shortcut?name=x"] {
            #expect(BindStore.arrivesOff(id), "\(id)")
        }
        for id in ["drive.key:cmd+T", "drive.menu:com.apple.finder:File > New Finder Window", "windows.close", "apps.open:com.apple.Notes",
                   "apps.web:https://x.com", "apps.url:app.zen-browser.zen:https://claude.ai"] {
            #expect(!BindStore.arrivesOff(id), "\(id)")
        }
    }

    @Test("A pilot://import link carries the file itself and reads back to the same bytes")
    func link() throws {
        let json = try source().json()
        let url = BindStore.link(for: json)
        #expect(url.absoluteString.hasPrefix("pilot://import?pack="))
        #expect(BindStore.pack(in: url) == json)
        #expect(BindStore.pack(in: URL(string: "pilot://import?pack=not-base64!")!) == nil)
    }

    /// The file lane 1's live check imports: one shell bind on Hyper+Shift+Ctrl+9.
    static let liveFixture = """
    {"version": 1, "binds": [{"action": "drive.shell:touch /tmp/pilot-import-probe", "custom": true,
      "trigger": {"hyper": true, "key": "9", "modifiers": ["shift", "ctrl"]}}]}
    """

    @Test("The live check's fixture reads as one new shell bind on Hyper+Shift+Ctrl+9 that arrives switched off")
    func fixture() throws {
        let plan = try BindStore(defaults: defaults).plan(importing: Data(Self.liveFixture.utf8))
        #expect(plan.added == [.init(action: "drive.shell:touch /tmp/pilot-import-probe", trigger: Key("9", [.shift, .ctrl]))])
        #expect(plan.switchedOff == ["drive.shell:touch /tmp/pilot-import-probe"])
    }
}
