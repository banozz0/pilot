import Foundation
import Testing
@testable import PilotCore

/// The bind store (stories 29 and 50): one versioned JSON file, the registry's defaults plus Sven's own binds.
@Suite("Bind store")
struct BindStoreTests {
    static let defaults: [String: Key] = [
        "windows.close": Key("w"),
        "windows.minimise": Key("down"),
        "windows.toggleFloatWorkspace": Key("t", .ctrl),
    ]

    @Test("A fresh store is the defaults, written out in full so a reader outside Pilot sees every bind")
    func seed() throws {
        let store = BindStore(defaults: Self.defaults)
        #expect(store.action(for: Key("t", .ctrl)) == "windows.toggleFloatWorkspace")
        #expect(String(decoding: store.json(), as: UTF8.self) == """
            {
              "apps" : [

              ],
              "binds" : [
                {
                  "action" : "windows.close",
                  "custom" : false,
                  "trigger" : {
                    "hyper" : true,
                    "key" : "W",
                    "modifiers" : [

                    ]
                  }
                },
                {
                  "action" : "windows.minimise",
                  "custom" : false,
                  "trigger" : {
                    "hyper" : true,
                    "key" : "↓",
                    "modifiers" : [

                    ]
                  }
                },
                {
                  "action" : "windows.toggleFloatWorkspace",
                  "custom" : false,
                  "trigger" : {
                    "hyper" : true,
                    "key" : "T",
                    "modifiers" : [
                      "ctrl"
                    ]
                  }
                }
              ],
              "preset" : "myBinds",
              "presets" : [
                {
                  "base" : "myBinds",
                  "binds" : [

                  ],
                  "id" : "myBinds",
                  "name" : "My binds"
                }
              ],
              "version" : 3
            }
            """)
    }

    @Test("A default whose key another action holds is refused, and the store says which and by whom")
    func refusal() throws {
        // Sven's own key first, then a newer default on that key (Build 56: Ask AI about selected text on Sound settings' key).
        var store = BindStore(defaults: Self.defaults)
        try store.set("system.soundSettings", to: Key("a", .ctrl))
        #expect(store.refusal(for: "ai.selection") == nil)
        let newer = Self.defaults.merging(["ai.selection": Key("a", .ctrl)]) { a, _ in a }
        let back = try BindStore(json: store.json(), defaults: newer)
        #expect(back.refusal(for: "ai.selection") == BindStore.Refusal(action: "ai.selection", trigger: Key("a", .ctrl), takenBy: "system.soundSettings"))
        #expect(back.trigger(for: "ai.selection") == nil && back.refusal(for: "windows.close") == nil)
    }

    @Test("Sublayer, plain-combo and unbound binds round-trip through the file")
    func roundTrip() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("windows.close", to: Key("x", [.shift, .ctrl]))
        try store.set("windows.minimise", to: nil)
        let leftAltH = Key(keyCode: 4, modifiers: .leftAlt, hyper: false)
        try store.set("apps.open:com.apple.Notes", to: leftAltH)

        let back = try BindStore(json: store.json(), defaults: Self.defaults)
        #expect(back == store)
        #expect(back.action(for: Key("x", [.shift, .ctrl])) == "windows.close")
        #expect(back.action(for: Key("w")) == nil)
        #expect(back.trigger(for: "windows.minimise") == nil)
        #expect(back.action(for: leftAltH) == "apps.open:com.apple.Notes")
        #expect(back.action(for: Key(keyCode: 4, modifiers: .rightAlt, hyper: false)) == nil)
        #expect(back.isCustom("windows.close") && !back.isCustom("windows.toggleFloatWorkspace"))
    }

    @Test("A renamed action keeps its bind and its switched-off state; a name already bound is left alone")
    func rename() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("focus.session:Focus", to: Key("1", .alt))
        store.rename("focus.session:Focus", to: "focus.session:Deep work")
        #expect(store.action(for: Key("1", .alt)) == "focus.session:Deep work")
        #expect(!store.isCustom("focus.session:Focus"))
        try store.set("focus.session:Other", to: Key("2", .alt))
        store.rename("focus.session:Deep work", to: "focus.session:Other")
        #expect(store.action(for: Key("1", .alt)) == "focus.session:Deep work")
        #expect(store.action(for: Key("2", .alt)) == "focus.session:Other")
    }

    @Test("A removed action's bind leaves the file and frees its key")
    func remove() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("focus.session:Deep work", to: Key("1", .alt))
        store.remove("focus.session:Deep work")
        #expect(store.action(for: Key("1", .alt)) == nil)
        #expect(!store.isCustom("focus.session:Deep work"))
        #expect(!store.actions.contains("focus.session:Deep work"))
    }

    @Test("A file naming removed actions (Pilot Focus, parked) loads: their default rows go, a key set on one stays its own")
    func removedActions() throws {
        let file = """
            {"version": \(BindStore.version), "apps": [], "binds": [
              {"action": "system.focusToggle", "custom": false, "trigger": {"hyper": true, "key": "F6", "modifiers": []}},
              {"action": "system.focus:com.apple.focus.work", "custom": true, "trigger": {"hyper": true, "key": "F7", "modifiers": []}},
              {"action": "windows.close", "custom": true, "trigger": {"hyper": true, "key": "X", "modifiers": []}}]}
            """
        let store = try BindStore(json: Data(file.utf8), defaults: Self.defaults, actions: Array(Self.defaults.keys))
        #expect(store.trigger(for: "windows.close") == Key("x") && store.refused.isEmpty)
        #expect(store.action(for: Key("F6")) == nil, "the parked default no longer holds its key")
        #expect(!store.actions.contains("system.focusToggle"))
        #expect(store.action(for: Key("F7")) == "system.focus:com.apple.focus.work", "a key set by hand is never dropped")
    }

    @Test("The user's own binds survive a change of defaults; the rest follow the new defaults")
    func defaultsChange() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("windows.close", to: Key("x", .shift))
        var moved = Self.defaults
        moved["windows.minimise"] = Key("m")
        let back = try BindStore(json: store.json(), defaults: moved)
        #expect(back.trigger(for: "windows.close") == Key("x", .shift))
        #expect(back.trigger(for: "windows.minimise") == Key("m"))
    }

    @Test("A v0 file (no version, keyCode and shift) migrates and is written back as the current version")
    func migrateV0() throws {
        let v0 = """
            {"binds": {"windows.close": {"keyCode": 7, "shift": true}, "windows.minimise": null}}
            """
        let store = try BindStore(json: Data(v0.utf8), defaults: Self.defaults)
        #expect(store.trigger(for: "windows.close") == Key("x", .shift))
        #expect(store.isCustom("windows.close"))
        #expect(store.trigger(for: "windows.minimise") == nil)
        #expect(store.isCustom("windows.minimise"))
        #expect(store.trigger(for: "windows.toggleFloatWorkspace") == Key("t", .ctrl))
        let written = try JSONSerialization.jsonObject(with: store.json()) as? [String: Any]
        #expect(written?["version"] as? Int == BindStore.version)
    }

    @Test("A file from a newer Pilot is refused, never rewritten")
    func newerVersionRefused() {
        #expect(throws: BindStore.LoadError.newerVersion(4)) {
            try BindStore(json: Data(#"{"version": 4, "binds": []}"#.utf8), defaults: Self.defaults)
        }
    }

    @Test("A trigger already in use is refused and the store is unchanged")
    func collisionRefused() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("windows.close", to: Key("x", .shift))
        let before = store
        #expect(throws: BindStore.BindError.triggerTaken(Key("x", .shift), by: "windows.close")) {
            try store.set("windows.minimise", to: Key("x", .shift))
        }
        #expect(throws: BindStore.BindError.triggerTaken(Key("t", .ctrl), by: "windows.toggleFloatWorkspace")) {
            try store.set("windows.close", to: Key("t", .ctrl))
        }
        #expect(store == before)
        // Setting an action to the trigger it already has is no clash.
        try store.set("windows.close", to: Key("x", .shift))
    }

    @Test("A hand-edited file with two binds on one trigger keeps the first and names the refused one")
    func duplicateInFileRefused() throws {
        let file = """
            {"version": 1, "binds": [
              {"action": "windows.close", "custom": true, "trigger": {"hyper": true, "key": "X", "modifiers": ["shift"]}},
              {"action": "windows.minimise", "custom": true, "trigger": {"hyper": true, "key": "X", "modifiers": ["shift"]}}
            ]}
            """
        let store = try BindStore(json: Data(file.utf8), defaults: Self.defaults)
        #expect(store.action(for: Key("x", .shift)) == "windows.close")
        #expect(store.trigger(for: "windows.minimise") == Key("down"))
        #expect(store.refused == [.init(action: "windows.minimise", trigger: Key("x", .shift), takenBy: "windows.close")])
    }

    @Test("The user's bind wins over a default that lands on its trigger, and the default is named as refused")
    func customBeatsDefault() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("windows.close", to: Key("m"))
        var moved = Self.defaults
        moved["windows.minimise"] = Key("m")
        let back = try BindStore(json: store.json(), defaults: moved)
        #expect(back.action(for: Key("m")) == "windows.close")
        #expect(back.trigger(for: "windows.minimise") == nil)
        #expect(back.refused == [.init(action: "windows.minimise", trigger: Key("m"), takenBy: "windows.close")])
    }

    @Test("Reset puts one bind back on its default; reset all drops every custom bind")
    func reset() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("windows.close", to: Key("x", .shift))
        try store.set("windows.minimise", to: nil)
        try store.reset("windows.close")
        #expect(store.trigger(for: "windows.close") == Key("w"))
        #expect(!store.isCustom("windows.close"))
        store.resetAll()
        #expect(store == BindStore(defaults: Self.defaults))
    }

    @Test("Reset is refused while another bind holds the default's trigger")
    func resetRefused() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("windows.close", to: Key("x"))
        try store.set("windows.minimise", to: Key("w"))
        let before = store
        #expect(throws: BindStore.BindError.triggerTaken(Key("w"), by: "windows.minimise")) { try store.reset("windows.close") }
        #expect(store == before)
    }

    @Test("Every registered action keeps its row: one with no default and no key reads trigger null, also after a reset")
    func everyActionListed() throws {
        var store = BindStore(defaults: Self.defaults, actions: ["windows.minimise", "windows.centre"])
        func row(_ id: String) throws -> [String: Any]? {
            let rows = try #require(try JSONSerialization.jsonObject(with: store.json()) as? [String: Any])["binds"] as? [[String: Any]]
            return rows?.first { $0["action"] as? String == id }
        }
        #expect(try row("windows.centre")?["trigger"] is NSNull)
        try store.set("windows.centre", to: Key("c", .shift))
        try store.reset("windows.centre")
        let centre = try #require(try row("windows.centre"))
        #expect(centre["trigger"] is NSNull)
        #expect(centre["custom"] as? Bool == false)
    }

    @Test("Editing a bind's action moves its key: the new action runs it, the old one is left with no key, both read back from the file")
    func moveToAnotherAction() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set("windows.minimise", to: Key("w"), from: "windows.close")
        #expect(store.action(for: Key("w")) == "windows.minimise")
        #expect(store.trigger(for: "windows.close") == nil)
        #expect(store.action(for: Key("down")) == nil)
        try store.set("apps.open:com.apple.TextEdit", to: Key("w"), from: "windows.minimise")
        let back = try BindStore(json: store.json(), defaults: Self.defaults)
        #expect(back == store)
        #expect(back.action(for: Key("w")) == "apps.open:com.apple.TextEdit")
        #expect(back.isCustom("apps.open:com.apple.TextEdit"))
        #expect(back.trigger(for: "windows.minimise") == nil)
    }

    @Test("Moving a bind onto a key a third action holds is refused and the store is unchanged")
    func moveRefused() throws {
        var store = BindStore(defaults: Self.defaults)
        let before = store
        #expect(throws: BindStore.BindError.triggerTaken(Key("down"), by: "windows.minimise")) {
            try store.set("apps.open:com.apple.TextEdit", to: Key("down"), from: "windows.close")
        }
        #expect(store == before)
    }

    /// Sven's binds.json as Pilot wrote it before Bar drops T7: My binds active, Telegram's extra on Hyper+T and ai.chat
    /// keyless as default rows, `custom` the preset's own rows.
    static func dropsFile(custom: String) -> Data {
        Data("""
            {"version": 3, "preset": "myBinds", "apps": [], "binds": [
              {"action": "apps.open:com.tdesktop.Telegram", "custom": false, "trigger": {"hyper": true, "key": "T", "modifiers": []}},
              {"action": "ai.chat", "custom": false, "trigger": null}],
             "presets": [{"id": "myBinds", "name": "My binds", "base": "myBinds", "binds": [
              {"action": "apps.notes", "custom": true, "trigger": {"hyper": true, "key": "N", "modifiers": []}}\(custom)]}]}
            """.utf8)
    }

    static let dropsPresets: [BindStore.Base: [String: Key]] = [.myBinds: MyBinds.preset(registry: MyBindsTests.drops)]

    @Test("A file with Telegram on Hyper+T, not custom, loads it on Hyper+Alt+T: the terminal and Ask AI take T and Q, no clash")
    func dropsMigrate() throws {
        let store = try BindStore(json: Self.dropsFile(custom: ""), presets: Self.dropsPresets)
        #expect(store.action(for: Key("t")) == "terminal.drop")
        #expect(store.action(for: Key("q")) == "ai.chat")
        #expect(store.trigger(for: "apps.open:com.tdesktop.Telegram") == Key("t", .alt))
        #expect(store.action(for: Key("n")) == "apps.notes", "his own binds stay")
        #expect(store.refused.isEmpty)
    }

    @Test("A key the user set on Hyper+T or Hyper+Q stays theirs; the drop's default is refused, so the load logs it")
    func dropsKeepHisKeys() throws {
        let his = """
            ,
              {"action": "apps.open:com.apple.Terminal", "custom": true, "trigger": {"hyper": true, "key": "T", "modifiers": []}},
              {"action": "apps.open:com.apple.QuickTime", "custom": true, "trigger": {"hyper": true, "key": "Q", "modifiers": []}}
            """
        let store = try BindStore(json: Self.dropsFile(custom: his), presets: Self.dropsPresets)
        #expect(store.action(for: Key("t")) == "apps.open:com.apple.Terminal")
        #expect(store.action(for: Key("q")) == "apps.open:com.apple.QuickTime")
        #expect(store.trigger(for: "apps.open:com.tdesktop.Telegram") == Key("t", .alt))
        #expect(store.refused == [BindStore.Refusal(action: "ai.chat", trigger: Key("q"), takenBy: "apps.open:com.apple.QuickTime"),
                                  BindStore.Refusal(action: "terminal.drop", trigger: Key("t"), takenBy: "apps.open:com.apple.Terminal")])
        #expect(store.trigger(for: "terminal.drop") == nil && store.trigger(for: "ai.chat") == nil)
    }

    /// The menu's live check (card agent-bo-95422711) marks apps.launcher custom on its own default, Space, so the tap
    /// runs it instead of handing Hyper+Space to Hammerspoon; pilot://bind cannot, it drops a bind equal to the default.
    @Test("A row hand-set custom on its default key stays custom through a load and a write")
    func customOnDefault() throws {
        let file = #"{"version": 1, "binds": [{"action": "apps.launcher", "custom": true, "trigger": {"hyper": true, "key": "Space", "modifiers": []}}]}"#
        let defaults = ["apps.launcher": Key("space")]
        let store = try BindStore(json: Data(file.utf8), defaults: defaults)
        #expect(store.isCustom("apps.launcher"))
        #expect(store.action(for: Key("space")) == "apps.launcher")
        #expect(try BindStore(json: store.json(), defaults: defaults).isCustom("apps.launcher"))
        var viaBind = BindStore(defaults: defaults)
        try viaBind.set("apps.launcher", to: Key("space"))
        #expect(!viaBind.isCustom("apps.launcher"))
    }
}

