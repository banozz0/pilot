import Foundation
import Testing
@testable import PilotCore

/// Bind presets (story 149, Sven 2026-10-09): Pilot default ships and is on for a new user, My binds stays Sven's,
/// Start from scratch and copies make his own, each keeps the keys set in it, and binds.json version 3 lists them all.
@Suite("Bind presets")
struct BindPresetTests {
    static let tables: [BindStore.Base: [String: Key]] = [
        .pilot: ["apps.launcher": Key("space"), "windows.close": Key("w"), "apps.browser": Key("b")],
        .myBinds: ["apps.launcher": Key("space"), "windows.close": Key("w"), "apps.browser": Key("b", .shift), "windows.flipSplit": Key("/"),
                   "apps.open:md.obsidian": Key("o", .shift)],
        .empty: ["apps.launcher": Key("space")],
    ]
    static let actions = ["apps.launcher", "windows.close", "apps.browser", "windows.flipSplit"]

    @Test("A new store is on Pilot default; My binds is listed beside it; switching changes every key and switches back")
    func builtIns() {
        var store = BindStore(presets: Self.tables, actions: Self.actions)
        #expect(store.preset == .pilot)
        #expect(store.presets == [.pilot, .myBinds])
        #expect(store.action(for: Key("b")) == "apps.browser")
        store.use(.myBinds)
        #expect(store.action(for: Key("b", .shift)) == "apps.browser")
        #expect(store.action(for: Key("b")) == nil)
        #expect(store.action(for: Key("o", .shift)) == "apps.open:md.obsidian")
        store.use(.pilot)
        #expect(store == BindStore(presets: Self.tables, actions: Self.actions))
    }

    @Test("The keys set in a preset stay with it: another preset never sees them, and coming back brings them")
    func editsStayWithTheirPreset() throws {
        var store = BindStore(presets: Self.tables)
        try store.set("windows.close", to: Key("q"))
        store.use(.myBinds)
        #expect(store.trigger(for: "windows.close") == Key("w"))
        #expect(!store.isCustom("windows.close"))
        store.use(.pilot)
        #expect(store.trigger(for: "windows.close") == Key("q"))
        store.resetAll()
        #expect(store.trigger(for: "windows.close") == Key("w"))
    }

    @Test("No shipped preset binds a shell command: Hyper+Shift+Ctrl+1 say hi was a live check's leftover row (card agent-bo-95422993, G11)")
    func noShellBindShips() {
        for id in Set(MyBinds.preset(registry: [:]).keys).union(PilotDefault.binds.keys) {
            #expect(DriveRoute(id: id).map { if case .shell = $0 { false } else { true } } ?? true, "\(id)")
        }
    }

    @Test("Pilot default is Sven's layout (Q531): the menu, the browser, workspaces 1 to 9 and moving to them, focus and move by arrows, tabs on Alt+arrows, close and the drops; one action per key")
    func pilotDefault() {
        let b = PilotDefault.binds
        #expect(b["apps.launcher"] == Key("space") && b["apps.browser"] == Key("b"))
        #expect(b["workspaces.go:1"] == Key("1") && b["workspaces.move:9"] == Key("9", .shift))
        #expect(b["windows.focusLeft"] == Key("left") && b["windows.swapRight"] == Key("right", .shift))
        #expect(b["windows.vimFocusDown"] == nil && b["windows.minimise"] == Key("h"))
        #expect(b["drive.previousTab"] == Key("left", .alt) && b["drive.nextTab"] == Key("right", .alt))
        #expect(b["windows.close"] == Key("w") && b["engine.sheet"] == nil)
        #expect(b["terminal.drop"] == Key("t") && b["ai.chat"] == Key("q"))
        #expect(b["system.pill"] == Key("u"))
        #expect(b.count == 114)
        #expect(Set(b.values).count == b.count)
        #expect(BindStore(presets: [.pilot: b]).refused.isEmpty)
        #expect(PilotDefault.mouse.count == 8 && PilotDefault.mouse[Key("Mouse Scroll Up")] == "media.volumeUp")
        #expect(PilotDefault.scratch == ["apps.launcher": Key("space")])
    }

    @Test("Start from scratch: only Hyper+Space, the menu, and the preset is on; a copy carries the keys set in the one it copies")
    func newPresets() throws {
        var store = BindStore(presets: Self.tables, actions: Self.actions)
        try store.set("windows.flipSplit", to: Key("j"))
        let scratch = store.addPreset(named: "Clean slate", copying: false)
        #expect(scratch == BindStore.Preset(id: "clean-slate", name: "Clean slate", base: .empty))
        #expect(store.preset == scratch && !scratch.isBuiltIn)
        #expect(store.binds == [Key("space"): "apps.launcher"])
        store.use(.pilot)
        let copy = store.addPreset(named: "  ", copying: true)
        #expect(copy.name == "Untitled" && copy.base == .pilot)
        #expect(store.trigger(for: "windows.flipSplit") == Key("j"))
        let second = store.addPreset(named: "clean slate", copying: false)
        #expect(second.name == "clean slate 2")
        #expect(store.presets.map(\.id) == ["pilot", "myBinds", "clean-slate", "untitled", "clean-slate-2"])
    }

    @Test("Rename and Delete work on a preset made by hand, never a built-in; deleting the active one falls back to Pilot default")
    func renameDelete() throws {
        var store = BindStore(presets: Self.tables)
        let mine = store.addPreset(named: "Mine", copying: false)
        let renamed = store.renamePreset(mine, to: "Laptop"), builtInRenamed = store.renamePreset(.pilot, to: "Mine")
        #expect(renamed && !builtInRenamed)
        #expect(store.preset.name == "Laptop" && store.preset(id: mine.id)?.name == "Laptop")
        let builtInDeleted = store.deletePreset(.myBinds), deleted = store.deletePreset(mine)
        #expect(!builtInDeleted && deleted)
        #expect(store.preset == .pilot && store.presets == [.pilot, .myBinds])
    }

    @Test("The file lists every preset with its own keys and names the active one; it reads back the same")
    func fileRoundTrip() throws {
        var store = BindStore(presets: Self.tables, actions: Self.actions)
        try store.set("windows.close", to: Key("q"))
        store.addPreset(named: "Clean slate", copying: false)
        try store.set("apps.browser", to: Key("b"))
        let file = try #require(try JSONSerialization.jsonObject(with: store.json()) as? [String: Any])
        #expect(file["version"] as? Int == 3 && file["preset"] as? String == "clean-slate")
        let presets = try #require(file["presets"] as? [[String: Any]])
        #expect(presets.map { $0["id"] as? String } == ["pilot", "myBinds", "clean-slate"])
        #expect(presets.map { $0["base"] as? String } == ["pilot", "myBinds", "empty"])
        #expect((presets[0]["binds"] as? [Any])?.count == 1 && (presets[1]["binds"] as? [Any])?.isEmpty == true)
        let back = try BindStore(json: store.json(), presets: Self.tables, actions: Self.actions)
        #expect(back == store)
        #expect(back.fileVersion == 3)
        #expect(throws: BindStore.LoadError.unreadable("preset hyprland")) {
            try BindStore(json: Data(#"{"version": 3, "preset": "hyprland", "presets": [], "binds": []}"#.utf8), presets: Self.tables)
        }
    }

    @Test("An older file's keys land on the preset it names, My binds without one; Omarchy's on My binds, with a notice")
    func migration() throws {
        let v1 = #"{"version": 1, "binds": [{"action": "windows.close", "custom": true, "trigger": {"hyper": true, "key": "Q", "modifiers": []}}]}"#
        var store = try BindStore(json: Data(v1.utf8), presets: Self.tables)
        #expect(store.preset == .myBinds && store.fileVersion == 1 && store.notice == nil)
        #expect(store.trigger(for: "windows.close") == Key("q"))
        store.use(.pilot)
        #expect(store.trigger(for: "windows.close") == Key("w"))
        let v2 = #"{"version": 2, "preset": "omarchy", "binds": [{"action": "windows.close", "custom": true, "trigger": {"hyper": true, "key": "Q", "modifiers": []}}], "apps": []}"#
        let omarchy = try BindStore(json: Data(v2.utf8), presets: Self.tables)
        #expect(omarchy.preset == .myBinds && omarchy.trigger(for: "windows.close") == Key("q"))
        #expect(omarchy.notice?.contains("Omarchy") == true)
        #expect(throws: BindStore.LoadError.unreadable("preset hyprland")) {
            try BindStore(json: Data(#"{"version": 1, "preset": "hyprland", "binds": []}"#.utf8), presets: Self.tables)
        }
    }

    @Test("Add as preset: a version 3 file's active preset arrives under its own name and is on; an older file's under the file's name")
    func importPreset() throws {
        var pack = BindStore(presets: Self.tables)
        pack.addPreset(named: "Omarchy", copying: false)
        try pack.set("windows.close", to: Key("x"))
        var store = BindStore(presets: Self.tables)
        let imported = try store.importPreset(pack.json(), name: "pilot-omarchy")
        #expect(imported.name == "Omarchy" && imported.base == .empty && store.preset == imported)
        #expect(store.trigger(for: "windows.close") == Key("x"))
        let v1 = #"{"version": 1, "binds": [{"action": "windows.close", "custom": true, "trigger": {"hyper": true, "key": "Z", "modifiers": []}}]}"#
        let old = try store.importPreset(Data(v1.utf8), name: "laptop")
        #expect(old.name == "laptop" && old.base == .myBinds && store.trigger(for: "windows.close") == Key("z"))
    }

    @Test("The Binds screen lists a preset's app links, which the registry does not know")
    func presetAppsListed() {
        var store = BindStore(presets: Self.tables)
        store.use(.myBinds)
        let registered = [BindsPage.ActionInfo(id: "windows.close", label: "Close window", module: "windows")]
        let actions = BindsPage.actions(registered: registered, store: store) {
            $0.hasPrefix("apps.") ? .init(id: $0, label: $0, module: "apps") : nil
        }
        #expect(actions.map(\.id).contains("apps.open:md.obsidian"))
    }
}
