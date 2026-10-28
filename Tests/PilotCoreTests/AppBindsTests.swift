import Foundation
import Testing
@testable import PilotCore

/// Per-app binds (story 143, card agent-bo-95423311): binds.json version 2 adds an apps list; the front app's bind wins
/// over the normal one, a null action is off there, and a version 1 file reads unchanged.
@Suite("App binds")
struct AppBindsTests {
    static let defaults: [String: Key] = ["windows.close": Key("w"), "apps.terminal": Key("return")]
    static let ghostty = "com.mitchellh.ghostty", finder = "com.apple.finder"

    /// Sven's binds.json as Pilot wrote it on 2026-10-08 (version 1, 181 rows, 23 his own), its apps and links made up, with
    /// the defaults and actions it was written against read back out of its own rows.
    static let svenFile = try! Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/binds-v1.json"))
    static func svenStore() throws -> (store: BindStore, file: [String: Any]) {
        let file = try #require(try JSONSerialization.jsonObject(with: svenFile) as? [String: Any])
        let rows = try #require(file["binds"] as? [[String: Any]])
        var defaults: [String: Key] = [:]
        for row in rows where row["custom"] as? Bool == false {
            guard let t = row["trigger"] as? [String: Any] else { continue }
            defaults[row["action"] as! String] = Key(keyCode: KeyNames.code(for: t["key"] as! String)!,
                                                     modifiers: Modifiers(names: t["modifiers"] as! [String])!, hyper: t["hyper"] as! Bool)
        }
        let store = try BindStore(json: svenFile, defaults: defaults, actions: rows.map { $0["action"] as! String })
        return (store, file)
    }

    @Test("The user's version 1 file loads with every row, preset and bind intact, and reads back byte for byte as version 1")
    func svenV1() throws {
        let (store, file) = try Self.svenStore()
        #expect(store.fileVersion == 1)
        #expect(store.refused.isEmpty)
        #expect(store.preset == .myBinds)
        #expect(store.appBinds.isEmpty)
        #expect(store.actions.count == (file["binds"] as? [Any])?.count)
        #expect(store.isCustom("windows.focusLeft") && store.action(for: Key("left")) == "windows.focusLeft")
        #expect(store.json(version: 1) == Self.svenFile)
        let v2 = try #require(try JSONSerialization.jsonObject(with: store.json(version: 2)) as? [String: Any])
        #expect(v2["version"] as? Int == 2 && v2["presets"] == nil)
        #expect((v2["apps"] as? [Any])?.isEmpty == true)
        #expect(v2["binds"] as? NSArray == file["binds"] as? NSArray)
    }

    @Test("The front app's bind wins, then the normal bind; another app or none in front gets the normal bind")
    func resolution() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set(Key("w"), in: Self.ghostty, to: "apps.terminal")
        #expect(store.action(for: Key("w"), app: Self.ghostty) == "apps.terminal")
        #expect(store.action(for: Key("w"), app: Self.finder) == "windows.close")
        #expect(store.action(for: Key("w"), app: nil) == "windows.close")
        #expect(store.action(for: Key("w")) == "windows.close")
        // A key the app does not bind falls through to the normal bind.
        #expect(store.action(for: Key("return"), app: Self.ghostty) == "apps.terminal")
        #expect(store.trigger(for: "windows.close", app: Self.ghostty) == nil)
        #expect(store.trigger(for: "windows.close", app: Self.finder) == Key("w"))
        #expect(store.trigger(for: "apps.terminal", app: Self.ghostty) == Key("w"))
    }

    @Test("Off here leaves the key unbound in that app, so a plain combo passes to the app; elsewhere the bind runs")
    func offHere() throws {
        let altV = Key("v", .alt, hyper: false)
        var store = BindStore(defaults: Self.defaults.merging(["clipboard.paste": altV]) { a, _ in a })
        try store.set(altV, in: Self.ghostty, to: nil)
        #expect(store.action(for: altV, app: Self.ghostty) == nil)
        #expect(store.action(for: altV, app: Self.finder) == "clipboard.paste")
        #expect(store.appBind(altV, in: Self.ghostty) == BindStore.AppBind(app: Self.ghostty, trigger: altV, action: nil))
        let event = KeyEvent(kind: .keyDown, keyCode: KeyNames.code(for: "V")!, flags: KeyEvent.altMask | 0x20)
        #expect(event.plainCombos.first { store.action(for: $0, app: Self.ghostty) != nil } == nil)
        #expect(event.plainCombos.first { store.action(for: $0, app: Self.finder) != nil } == altV)
    }

    @Test("Two binds on one key in one app clash, store unchanged; Replace takes the key; an app bind over a normal key is no clash")
    func clash() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set(Key("w"), in: Self.ghostty, to: "apps.terminal")
        let before = store
        #expect(throws: BindStore.BindError.triggerTaken(Key("w"), by: "apps.terminal")) {
            try store.set(Key("w"), in: Self.ghostty, to: "windows.close")
        }
        #expect(store == before)
        // The same key in another app, or the bind moved from its own key, is free.
        try store.set(Key("w"), in: Self.finder, to: nil)
        try store.set(Key("e"), in: Self.ghostty, to: "apps.terminal", from: Key("w"))
        #expect(store.appBinds(in: Self.ghostty).map(\.trigger) == [Key("e")])
        let displaced = store.replace(Key("e"), in: Self.ghostty, with: "windows.close")
        #expect(displaced?.action == "apps.terminal")
        #expect(store.action(for: Key("e"), app: Self.ghostty) == "windows.close")
        let removed = store.remove(Key("e"), in: Self.ghostty), again = store.remove(Key("e"), in: Self.ghostty)
        #expect(removed && !again)
        #expect(store.appBinds(in: Self.ghostty).isEmpty)
    }

    @Test("App binds round-trip through the file, stay across presets and a reset, and a v2 file reads back as v2")
    func persisted() throws {
        var store = BindStore(presets: [.myBinds: Self.defaults, .pilot: [:]])
        try store.set(Key("w"), in: Self.ghostty, to: "apps.terminal")
        try store.set(Key("w"), in: "com.example.not-installed", to: nil)
        store.use(.myBinds)
        store.resetAll()
        #expect(store.appBinds.count == 2)
        let back = try BindStore(json: store.json(version: 2), presets: [.myBinds: Self.defaults, .pilot: [:]])
        #expect(back.fileVersion == 2)
        #expect(back.appBinds == store.appBinds)
        #expect(back.action(for: Key("w"), app: "com.example.not-installed") == nil)
    }

    @Test("A renamed action's app binds follow it; a removed action's app binds go with it")
    func renameRemove() throws {
        var store = BindStore(defaults: Self.defaults)
        try store.set(Key("f"), in: Self.ghostty, to: "focus.session:Deep")
        let renamed = store.rename("focus.session:Deep", to: "focus.session:Deeper")
        #expect(renamed)
        #expect(store.action(for: Key("f"), app: Self.ghostty) == "focus.session:Deeper")
        let removed = store.remove("focus.session:Deeper")
        #expect(removed)
        #expect(store.appBinds.isEmpty)
    }

    @Test("Import brings app binds, a shell one switched off with its key held; the user's own app bind on that key stays")
    func importing() throws {
        let shell = "drive.shell:echo hi"
        var a = BindStore(defaults: Self.defaults)
        try a.set(Key("w"), in: Self.ghostty, to: "apps.terminal")
        try a.set(Key("e"), in: Self.ghostty, to: shell)
        try a.set(Key("r"), in: Self.finder, to: "windows.close")
        var b = BindStore(defaults: Self.defaults)
        try b.set(Key("r"), in: Self.finder, to: nil)
        let plan = try b.plan(importing: a.json())
        #expect(plan.apps.map(\.trigger) == [Key("e"), Key("w")])
        #expect(plan.appClashes.map(\.trigger) == [Key("r")])
        #expect(plan.appsSwitchedOff.map(\.action) == [shell])
        #expect(plan.summary(name: "x.json") == "x.json: 0 new binds, 0 changed, 0 clashes. 2 app binds, 1 kept as they are here."
            + " 1 shell, URL or Shortcuts bind stays switched off until you turn it on.")
        b.apply(plan)
        #expect(b.action(for: Key("e"), app: Self.ghostty) == shell)
        #expect(b.bind(for: Key("e"), app: Self.ghostty)?.disabled == true)
        #expect(b.bind(for: Key("w"), app: Self.ghostty)?.disabled == false)
        #expect(b.action(for: Key("r"), app: Self.finder) == nil)
        let reread = try BindStore(json: b.json(), defaults: Self.defaults)
        #expect(reread.bind(for: Key("e"), app: Self.ghostty)?.disabled == true)
        b.enable(Key("e"), in: Self.ghostty)
        #expect(b.bind(for: Key("e"), app: Self.ghostty)?.disabled == false)
    }
}
