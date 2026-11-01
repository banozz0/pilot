import Foundation
import PilotCore
import Testing
@testable import Pilot

/// `pilot actions|run|press|bind|unbind|open|import` (AI helper T6), asked through the registry the socket answers from,
/// on a test engine whose binds file is the test run's own. A gated request is only ever denied when it would run
/// something; Allow is given only to binds and an import, which write the test's binds file and nothing else. No window
/// opens, no app comes forward and no key is pressed.
@MainActor
// One at a time: a gated bind awaits its Allow, and with CFFIXED_USER_HOME every rig shares one binds file, so a rig
// made while another test waits would start on that test's keys (CLI W5).
@Suite("Control actions", .serialized)
struct ControlActionsTests {
    /// What the tests' gate, window and front app saw.
    @MainActor final class Log {
        var asked: [String] = []
        var fronted: [String] = []
        var opened: [AppPlace] = []
    }

    @MainActor final class Rig {
        let engine = Engine()
        let app = ControlActions()
        let verbs = ControlVerbs()
        let log = Log()
        var allow: Bool

        init(allow: Bool = false) {
            self.allow = allow
            let log = log, engine = engine
            app.engine = { engine }
            app.gate = ControlGate { [unowned self] ask, _ in
                log.asked.append(ask.text)
                return self.allow
            }
            app.offered = {
                [.init(kind: "app", info: .init(id: "apps.open:com.example.Test", label: "Test", module: "apps")),
                 .init(kind: "script", info: .init(id: "scripts.run:hello.sh", label: "Hello", module: "drive"))]
            }
            app.extensions = { [] }
            app.front = { log.fronted.append($0) }
            app.open = { place, _ in log.opened.append(place) }
            // No HUD here: the readback test covers the tips.
            app.readback = RunReadback(wait: .zero, tip: { nil })
            verbs.registerActions(app)
        }

        func ask(_ verb: String, _ args: String..., cwd: String? = nil) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args, cwd: cwd), peer: nil)
        }

        /// The binds file as the test engine wrote it.
        func onDisk() throws -> BindStore {
            try BindStore(json: Data(contentsOf: engine.binds.fileURL), presets: [.pilot: PilotDefault.binds, .myBinds: MyBinds.preset(registry: engine.registry.defaults),
                                                                       .empty: PilotDefault.scratch], actions: Array(engine.registry.actions.keys))
        }
    }

    static func field(_ answer: ControlAnswer, _ name: String) -> JSONValue? {
        if case .object(let o)? = answer.result { o[name] } else { nil }
    }

    @Test("actions --json lists every registered action and the ids the menu offers, each with its kind and key")
    func actionsList() async throws {
        let rig = Rig()
        let answer = await rig.ask("actions", "--json")
        guard case .array(let rows)? = answer.result else { Issue.record("not rows: \(answer)"); return }
        let byID = Dictionary(rows.compactMap { row -> (String, [String: JSONValue])? in
            guard case .object(let o) = row, case .string(let id)? = o["id"] else { return nil }
            return (id, o)
        }) { first, _ in first }
        #expect(byID.count == rows.count, "each id once")
        #expect(Set(rig.engine.registry.actions.keys).isSubset(of: byID.keys))
        #expect(rig.engine.registry.actions.count > 150, "the registry, 180 or so today: \(rig.engine.registry.actions.count)")
        #expect(byID["apps.open:com.example.Test"]?["kind"] == .string("app"))
        #expect(byID["scripts.run:hello.sh"]?["kind"] == .string("script"))
        #expect(byID["windows.snapLeft"]?["kind"] == .string("action"))
        #expect(byID["windows.snapLeft"]?["key"] == rig.engine.binds.store.trigger(for: "windows.snapLeft").map { .string($0.label) })

        guard case .string(let windows)? = await rig.ask("actions", "--module", "windows").result else { Issue.record("no text"); return }
        #expect(windows.contains("windows.snapLeft"))
        #expect(!windows.contains("apps.open:"))
        #expect(await rig.ask("actions", "--module", "nosuch").error?.code == .unknownModule)
        #expect(await rig.ask("actions", "--modul", "windows").error?.code == .unknownFlag)
    }

    static func rows(_ answer: ControlAnswer) -> [String: [String: JSONValue]] {
        guard case .array(let rows)? = answer.result else { return [:] }
        return Dictionary(rows.compactMap { row -> (String, [String: JSONValue])? in
            guard case .object(let o) = row, case .string(let id)? = o["id"] else { return nil }
            return (id, o)
        }) { first, _ in first }
    }

    @Test("actions --json marks each row: the Allow question, what it leaves on screen, a switch's state, an ability not added")
    func marks() async throws {
        let rig = Rig()
        rig.app.switches = { ["system.darkMode": true, "system.wifi": false] }
        let byID = Self.rows(await rig.ask("actions", "--json"))
        #expect(byID["scripts.run:hello.sh"]?["asks"] == .string("Run script: hello.sh"))
        #expect(byID["system.shutDown"]?["asks"] == .string("Shut down the Mac: system.shutDown"))
        #expect(byID["windows.snapLeft"]?["asks"] == nil)
        #expect(byID["system.killProcess"]?["opens"] == .string("picker"))
        #expect(byID["apps.clipboard"]?["opens"] == .string("panel"))
        #expect(byID["captures.area"]?["opens"] == .string("capture"))
        #expect(byID["captures.fullscreen"]?["opens"] == nil, "a full-screen capture finishes on its own")
        #expect(byID["windows.snapLeft"]?["opens"] == nil)
        #expect(byID["system.darkMode"]?["on"] == .bool(true))
        #expect(byID["system.wifi"]?["on"] == .bool(false))
        #expect(byID["windows.snapLeft"]?["on"] == nil)
        for (id, row) in byID {
            #expect((row["notAdded"] == .bool(true)) == !rig.engine.isListed(id), "\(id)")
            if Abilities.optional[id] == nil { #expect(row["notAdded"] == nil, "\(id) is not optional") }
        }
        // The list names registered ids only, so a renamed action cannot leave it marking nothing.
        #expect(Set(ControlActions.onScreen.keys).subtracting(rig.engine.registry.actions.keys).isEmpty)
        #expect(ControlActions.opens("drive.pick:{}", extensions: []) == .picker)
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-marks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "ports"), withIntermediateDirectories: true)
        try Data(#"{"id": "ports", "title": "Ports", "version": "1.0.0", "commands": [{"name": "list", "title": "Open ports", "mode": "list", "run": "run"}, {"name": "tick", "title": "Tick", "mode": "no-view", "run": "run"}]}"#.utf8)
            .write(to: folder.appending(path: "ports/\(Extension.manifestName)"))
        try Data("#!/bin/sh\n".utf8).write(to: folder.appending(path: "ports/run"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "ports/run").path)
        let extensions = Extension.find(in: folder).extensions
        #expect(ControlActions.opens("ext.ports.list", extensions: extensions) == .panel, "a list command's view opens in the menu")
        #expect(ControlActions.opens("ext.ports.tick", extensions: extensions) == nil)

        let detail = try rig.verbs.verb("run").detail?("system.killProcess")
        #expect(detail?.contains("opens a picker") == true)
        #expect(try rig.verbs.verb("run").detail?("no.such.action") == nil)
    }

    @Test("bind writes the binds file and answers the bind as stored; a taken key names its holder; unbind and --reset")
    func binding() async throws {
        let rig = Rig()
        let original = rig.engine.binds.store.trigger(for: "windows.snapLeft")
        let key = Key(keyCode: KeyNames.code(for: "h")!, modifiers: .ctrl)
        let bound = await rig.ask("bind", "windows.snapLeft", "h", "--mods", "ctrl")
        #expect(bound.ok, "\(bound.error?.message ?? "")")
        #expect(Self.field(bound, "key") == .string(key.label))
        #expect(try rig.onDisk().trigger(for: "windows.snapLeft") == key)
        #expect(rig.log.asked.isEmpty, "a plain action binds without asking")

        let taken = await rig.ask("bind", "windows.snapRight", "h", "--mods", "ctrl")
        #expect(taken.error?.code == .taken)
        #expect(taken.error?.message.contains("windows.snapLeft") == true)
        #expect(try rig.onDisk().trigger(for: "windows.snapLeft") == key, "a refused bind changes nothing")

        let cleared = await rig.ask("unbind", "windows.snapLeft")
        #expect(Self.field(cleared, "key") == .null)
        #expect(try rig.onDisk().trigger(for: "windows.snapLeft") == nil)

        let reset = await rig.ask("bind", "windows.snapLeft", "--reset")
        #expect(Self.field(reset, "key") == original.map { .string($0.label) } ?? .null)
        #expect(try rig.onDisk().trigger(for: "windows.snapLeft") == original)

        #expect(await rig.ask("bind", "windows.snapLeft", "h", "--mods", "ctrl").ok)
        // Reset all asks first, as the page confirms it (CLI W5).
        rig.allow = true
        #expect(await rig.ask("bind", "all", "--reset").ok)
        rig.allow = false
        #expect(try rig.onDisk().trigger(for: "windows.snapLeft") == original)

        #expect(await rig.ask("bind", "windows.snapLeft", "h", "--plain").error?.code == .badValue, "a plain combo needs cmd, ctrl or alt")
        #expect(await rig.ask("bind", "windows.snapLeft", "nokey").error?.code == .badValue)
        #expect(await rig.ask("bind", "windows.snapLeft", "h", "--mods", "hyper").error?.code == .badValue)
        #expect(await rig.ask("bind", "no.such.action", "h").error?.code == .unknownAction)
        #expect(await rig.ask("unbind", "no.such.action").error?.code == .unknownAction)
    }

    @Test("bind --preset switches the preset after Allow; an unknown one answers unknown-preset naming them; My binds only for a file holding it")
    func presets() async throws {
        let rig = Rig(allow: true)
        #expect(await rig.ask("bind", "--preset", "myBinds").error?.code == .unknownPreset, "a new user's file never lists My binds")
        // Sven's file's shape: on My binds, both built-ins listed.
        try Data(#"{"version": 3, "preset": "myBinds", "binds": [], "presets": [{"id": "pilot", "name": "Pilot default", "base": "pilot", "binds": []}, {"id": "myBinds", "name": "My binds", "base": "myBinds", "binds": []}]}"#.utf8)
            .write(to: rig.engine.binds.fileURL)
        rig.engine.binds.load()
        #expect(rig.engine.binds.store.preset.id == "myBinds" && rig.engine.binds.lastError == nil)
        #expect(await rig.ask("bind", "--preset", "pilot").ok)
        let switched = await rig.ask("bind", "--preset", "myBinds")
        #expect(Self.field(switched, "preset") == .string("myBinds"))
        #expect(rig.engine.binds.store.preset.id == "myBinds")
        let unknown = await rig.ask("bind", "--preset", "nosuch")
        #expect(unknown.error?.code == .unknownPreset)
        #expect(unknown.error?.message.contains("myBinds") == true)
        #expect(await rig.ask("bind", "--preset", "pilot").ok, "back to the preset the next rig starts on")
    }

    @Test("A bind of a command asks first: Deny writes nothing, Allow writes it")
    func gatedBind() async throws {
        let rig = Rig()
        let id = "drive.shell:echo hello"
        let key = Key(keyCode: KeyNames.code(for: "F12")!, modifiers: [.ctrl, .alt, .shift])
        let denied = await rig.ask("bind", id, "F12", "--mods", "ctrl,alt,shift")
        #expect(denied.error?.code == .denied)
        #expect(rig.log.asked == ["Run shell: echo hello"])
        #expect(try rig.onDisk().trigger(for: id) == nil)

        rig.allow = true
        let allowed = await rig.ask("bind", id, "F12", "--mods", "ctrl,alt,shift")
        #expect(allowed.ok, "\(allowed.error?.message ?? "")")
        #expect(try rig.onDisk().trigger(for: id) == key)
    }

    @Test("run: an unknown id answers unknown-action with it; a command is denied unrun; a plain action dispatches, after --app comes forward")
    func running() async throws {
        let rig = Rig()
        let unknown = await rig.ask("run", "no.such.action")
        #expect(unknown.error?.code == .unknownAction)
        #expect(await rig.ask("run", "engine.hyper", "--ap", "Finder").error?.code == .unknownFlag)
        #expect(unknown.error?.message.contains("no.such.action") == true)

        let marker = FileManager.default.temporaryDirectory.appending(path: "pilot-run-\(UUID().uuidString)")
        let denied = await rig.ask("run", "drive.shell:touch \(marker.path(percentEncoded: false))", "--app", "Finder")
        #expect(denied.error?.code == .denied)
        #expect(rig.log.asked == ["Run shell: touch \(marker.path(percentEncoded: false))"])
        #expect(rig.log.fronted.isEmpty, "nothing comes forward for a denied run")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))

        // engine.hyper flips the test engine's own Hyper switch; its tap never started.
        let on = rig.engine.hyperSwitch.isOn
        let ran = await rig.ask("run", "engine.hyper", "--app", "Finder")
        #expect(ran.ok, "\(ran.error?.message ?? "")")
        #expect(Self.field(ran, "dispatched") == .string("engine.hyper"))
        #expect(Self.field(ran, "hud") == .null)
        #expect(Self.field(ran, "error") == .null)
        #expect(rig.engine.hyperSwitch.isOn != on)
        #expect(rig.log.fronted == ["Finder"])
        _ = await rig.ask("run", "engine.hyper")
        #expect(rig.engine.hyperSwitch.isOn == on)
    }

    @Test("The readback answers only tips the run raised: one up before it is left out, a changed one is kept")
    func readback() async {
        @MainActor final class Tip { var text: String; init(_ text: String) { self.text = text } }
        // `next` goes up right after the readback's first look, so the second tip comes while it watches, never after: a
        // 40 ms timer against a 150 ms watch lost that race under the full suite's load.
        @MainActor final class Screen {
            var tip: Tip? = Tip("old"), next: Tip?
            func look() -> Tip? { defer { if let next { tip = next; self.next = nil } }; return tip }
        }
        let screen = Screen(), b = Tip("Done")
        let readback = RunReadback(wait: .milliseconds(150), every: .milliseconds(10)) { screen.look().map { (ObjectIdentifier($0), $0.text) } }
        #expect(await readback.watch {}.isEmpty, "the tip up before the run")
        let raised = await readback.watch {
            screen.tip = Tip("Copied")
            screen.next = b
        }
        #expect(raised == ["Copied", "Done"])
        let changed = await readback.watch { b.text = "Done twice" }
        #expect(changed == ["Done twice"])
    }

    @Test("An extension command's tips are withheld from run's answer; other actions' are read back")
    func withheld() {
        #expect(RunReadback.withheld("ext.vault.copy") != nil)
        #expect(RunReadback.withheld("windows.snapLeft") == nil)
        #expect(RunReadback.withheld("apps.launcher") == nil)
    }

    @Test("Without the key engine the action verbs answer not-ready")
    func notReady() async {
        let rig = Rig()
        rig.app.engine = { nil }
        #expect(await rig.ask("actions").error?.code == .notReady)
        #expect(await rig.ask("run", "engine.hyper").error?.code == .notReady)
    }

    @Test("press needs --app and asks first; denied, nothing comes forward or is pressed")
    func pressing() async {
        let rig = Rig()
        #expect(await rig.ask("press", "h").error?.code == .badRequest)
        let denied = await rig.ask("press", "h", "--mods", "shift", "--app", "TextEdit")
        #expect(denied.error?.code == .denied)
        #expect(rig.log.asked == ["Press \(Key(keyCode: KeyNames.code(for: "h")!, modifiers: .shift).label) in: TextEdit"])
        #expect(rig.log.fronted.isEmpty)
    }

    @Test("open: a page or an old name opens its place; an unknown page answers unknown-page listing the pages")
    func opening() async {
        let rig = Rig()
        #expect(await rig.ask("open", "tiling").ok)
        #expect(await rig.ask("open", "pilot").ok, "an old name")
        #expect(rig.log.opened == [AppPlace(.tiling), AppPlace(.general)])
        let unknown = await rig.ask("open", "nosuchpage")
        #expect(unknown.error?.code == .unknownPage)
        #expect(AppPage.allCases.filter { !$0.isDeveloper }.allSatisfy { unknown.error?.message.contains($0.rawValue) == true })
        #expect(await rig.ask("open", "system", "--section", "nosuch").error?.code == .unknownSection)
        #expect(rig.log.opened.count == 2)
    }

    @Test("import previews a pack without changing a bind; --apply asks with its summary and applies it on Allow")
    func importing() async throws {
        let rig = Rig()
        let key = Key(keyCode: KeyNames.code(for: "F11")!, modifiers: [.ctrl, .alt, .shift])
        var pack = BindStore(defaults: rig.engine.registry.defaults, actions: Array(rig.engine.registry.actions.keys))
        try pack.set("windows.snapLeft", to: key)
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try pack.json().write(to: folder.appending(path: "pack.json"))
        let cwd = folder.path(percentEncoded: false)

        let preview = await rig.ask("import", "pack.json", cwd: cwd)
        #expect(Self.field(preview, "applied") == .bool(false))
        guard case .string(let summary)? = Self.field(preview, "summary") else { Issue.record("no summary: \(preview)"); return }
        #expect(summary.hasPrefix("pack.json: 1 new bind"))
        #expect(rig.engine.binds.store.trigger(for: "windows.snapLeft") != key)
        #expect(rig.log.asked.isEmpty)

        let link = BindStore.link(for: pack.json()).absoluteString
        #expect(Self.field(await rig.ask("import", link), "applied") == .bool(false), "a pilot://import link")

        #expect(await rig.ask("import", "pack.json", "--apply", cwd: cwd).error?.code == .denied)
        #expect(rig.log.asked == ["Apply import: \(summary)"])
        #expect(try rig.onDisk().trigger(for: "windows.snapLeft") != key)

        rig.allow = true
        let applied = await rig.ask("import", "pack.json", "--apply", cwd: cwd)
        #expect(Self.field(applied, "applied") == .bool(true), "\(applied.error?.message ?? "")")
        #expect(try rig.onDisk().trigger(for: "windows.snapLeft") == key)
        #expect(await rig.ask("import", "missing.json", cwd: cwd).error?.code == .badValue)
    }
}
