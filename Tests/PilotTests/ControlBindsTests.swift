import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The Binds page through the pilot command (CLI W5): presets, the gated preset switch and reset, --replace, --on,
/// export, import's folder rule and Add as preset, overlay picks and Conflicts. A test engine writes its own binds file;
/// Conflicts runs on a table in memory and a backup in the temp folder, so com.apple.symbolichotkeys is never touched.
/// The binds edited here are ones Control actions' tests leave alone: with CFFIXED_USER_HOME both share one binds file.
@MainActor
@Suite("Control binds")
struct ControlBindsTests {
    @MainActor final class Rig {
        let engine = Engine()
        let app = ControlActions()
        let verbs = ControlVerbs()
        var asked: [String] = []
        var allow = false
        /// The fake AppleSymbolicHotKeys table and the backup beside it.
        var table: [String: Any] = [:]
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-binds-\(UUID().uuidString)")
        private(set) lazy var conflicts = ShortcutConflicts(
            domain: .init(read: { [unowned self] in table }, write: { [unowned self] in table = $0 }, apply: {}),
            backupURL: folder.appending(path: "symbolichotkeys-backup.plist"))

        /// The binds file as this rig found it, put back when it goes: with CFFIXED_USER_HOME every engine in the run
        /// shares one, and the next suite's must not start on a preset or a key a test here left.
        private let bindsFile: URL
        private let found: Data?

        init() {
            let engine = engine
            bindsFile = engine.binds.fileURL
            found = try? Data(contentsOf: bindsFile)
            app.engine = { engine }
            app.gate = ControlGate { [unowned self] ask, _ in
                asked.append(ask.text)
                return allow
            }
            app.readback = RunReadback(wait: .zero, tip: { nil })
            verbs.registerActions(app)
            verbs.registerBindCollections(app, conflicts: { [unowned self] in conflicts })
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: folder)
            if let found { try? found.write(to: bindsFile, options: .atomic) } else { try? FileManager.default.removeItem(at: bindsFile) }
        }

        func ask(_ verb: String, _ args: String..., cwd: String? = nil) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args, cwd: cwd), peer: nil)
        }

        var store: BindStore { engine.binds.store }

        /// `key` with nothing on it: a run with CFFIXED_USER_HOME reads the binds file the runs before it left.
        func free(_ key: Key) throws {
            if let holder = store.action(for: key) { try engine.binds.set(holder, to: nil) }
        }
    }

    static func field(_ answer: ControlAnswer, _ name: String) -> JSONValue? {
        if case .object(let o)? = answer.result { o[name] } else { nil }
    }

    static func rows(_ answer: ControlAnswer) -> [[String: JSONValue]] {
        guard case .array(let rows)? = answer.result else { return [] }
        return rows.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    @Test("list presets names each with its base, built-in flag and the active one; add makes one and switches; --preset renames")
    func presetsListAndAdd() async throws {
        let rig = Rig()
        let listed = Self.rows(await rig.ask("list", "presets"))
        #expect(listed.map { $0["id"] } == rig.store.presets.map { .string($0.id) })
        #expect(listed.first { $0["id"] == .string("pilot") }?["builtIn"] == .bool(true))
        #expect(listed.filter { $0["active"] == .bool(true) }.map { $0["id"] } == [.string(rig.store.preset.id)])

        // Names of their own: a run with CFFIXED_USER_HOME shares one binds file with the runs before.
        let work = "Work \(UUID().uuidString.prefix(8))"
        let made = await rig.ask("add", "presets", "--name", work)
        #expect(Self.field(made, "name") == .string(work), "\(made.error?.message ?? "")")
        #expect(Self.field(made, "base") == .string("empty"), "from scratch")
        #expect(Self.field(made, "active") == .bool(true))
        #expect(rig.store.preset.name == work)

        let copy = await rig.ask("add", "presets", "--name", work, "--copy")
        #expect(Self.field(copy, "name") == .string("\(work) 2"), "a taken name gets a number")
        #expect(rig.asked.isEmpty, "the page asks a name, not a confirm")

        guard case .string(let id)? = Self.field(made, "id") else { Issue.record("no id: \(made)"); return }
        let desk = "Desk \(UUID().uuidString.prefix(8))"
        let renamed = await rig.ask("add", "presets", "--preset", id, "--name", desk)
        #expect(Self.field(renamed, "name") == .string(desk), "\(renamed)")
        #expect(rig.store.preset(id: id)?.name == desk)
        #expect(await rig.ask("add", "presets", "--preset", "pilot", "--name", "X").error?.code == .badValue, "a built-in keeps its name")
        #expect(await rig.ask("add", "presets", "--preset", "nosuch", "--name", "X").error?.code == .unknownPreset)
        #expect(await rig.ask("add", "presets", "--nmae", "X").error?.code == .unknownFlag)
    }

    @Test("remove presets asks first: Deny keeps it, Allow deletes it and the first built-in takes over; a built-in is refused")
    func presetsRemove() async throws {
        let rig = Rig()
        let gone = "Gone \(UUID().uuidString.prefix(8))"
        guard case .string(let id)? = Self.field(await rig.ask("add", "presets", "--name", gone), "id") else { Issue.record("not made"); return }
        #expect(await rig.ask("remove", "presets", "pilot").error?.code == .badValue)
        #expect(await rig.ask("remove", "presets", "nosuch").error?.code == .unknownPreset)
        #expect(rig.asked.isEmpty, "a refusal asks nothing")

        #expect(await rig.ask("remove", "presets", id).error?.code == .denied)
        #expect(rig.asked == ["Delete bind preset \(gone): its keys go with it"])
        #expect(rig.store.preset(id: id) != nil)

        rig.allow = true
        let removed = await rig.ask("remove", "presets", id)
        #expect(Self.field(removed, "deleted") == .string(id), "\(removed.error?.message ?? "")")
        #expect(Self.field(removed, "active") == .string(rig.store.presets.first!.id))
        #expect(rig.store.preset(id: id) == nil)

        guard case .object(let schema) = try rig.verbs.schema(collection: "presets") else { Issue.record("no schema"); return }
        #expect(schema["rowKey"] == .string("id") && schema["asks"] == .array([.string("remove")]))
    }

    @Test("bind --preset and bind all --reset ask as the page confirms; Deny changes nothing; an unknown preset is unknown-preset")
    func gatedPresetAndReset() async throws {
        let rig = Rig()
        // A new user has Pilot default alone (SH8): a second preset to switch to.
        rig.engine.binds.addPreset(named: "Other", copying: false)
        let start = rig.store.preset.id, other = rig.store.presets.first { $0.id != start }!
        #expect(await rig.ask("bind", "--preset", other.id).error?.code == .denied)
        #expect(rig.asked.count == 1 && rig.asked[0].hasPrefix("Switch bind preset to \(other.title)"))
        #expect(rig.store.preset.id == start)
        #expect(await rig.ask("bind", "--preset", "nosuch").error?.code == .unknownPreset)

        let key = Key(keyCode: KeyNames.code(for: "h")!, modifiers: .ctrl)
        try rig.free(key)
        rig.allow = true
        #expect(await rig.ask("bind", "windows.focusDisplayLeft", "h", "--mods", "ctrl").ok)
        rig.allow = false
        #expect(await rig.ask("bind", "all", "--reset").error?.code == .denied)
        #expect(rig.asked.last?.hasPrefix("Reset every bind") == true)
        #expect(rig.store.trigger(for: "windows.focusDisplayLeft") == key)

        rig.allow = true
        #expect(await rig.ask("bind", "all", "--reset").ok)
        #expect(rig.store.trigger(for: "windows.focusDisplayLeft") != key)
        #expect(Self.field(await rig.ask("bind", "--preset", other.id), "preset") == .string(other.id))
        #expect(rig.store.preset.id == other.id)
        #expect(await rig.ask("bind", "x", "h", "--mod", "ctrl").error?.code == .unknownFlag)
    }

    @Test("bind --replace takes a taken key and names the action left with none")
    func replacing() async throws {
        let rig = Rig()
        let key = Key(keyCode: KeyNames.code(for: "h")!, modifiers: .ctrl)
        try rig.free(key)
        #expect(await rig.ask("bind", "windows.focusDisplayLeft", "h", "--mods", "ctrl").ok)
        let taken = await rig.ask("bind", "windows.focusDisplayRight", "h", "--mods", "ctrl")
        #expect(taken.error?.code == .taken)
        #expect(taken.error?.message.contains("--replace") == true)

        let replaced = await rig.ask("bind", "windows.focusDisplayRight", "h", "--mods", "ctrl", "--replace")
        #expect(Self.field(replaced, "left") == .string("windows.focusDisplayLeft"), "\(replaced.error?.message ?? "")")
        #expect(rig.store.trigger(for: "windows.focusDisplayRight") == key)
        #expect(rig.store.trigger(for: "windows.focusDisplayLeft") == nil)
    }

    /// A bind file in its own temp folder holding one shell bind, which arrives switched off.
    static func shellPack(_ rig: Rig, _ id: String) throws -> (cwd: String, data: Data) {
        var pack = BindStore(defaults: rig.engine.registry.defaults, actions: Array(rig.engine.registry.actions.keys))
        try pack.set(id, to: Key(keyCode: KeyNames.code(for: "F11")!, modifiers: [.ctrl, .alt, .shift]))
        let data = pack.json()
        try data.write(to: rig.folder.appending(path: "pack.json"))
        return (rig.folder.path(percentEncoded: false), data)
    }

    @Test("bind --on turns on an imported shell bind after the Allow running it asks")
    func turningOn() async throws {
        let rig = Rig()
        let id = "drive.shell:echo on"
        let (cwd, _) = try Self.shellPack(rig, id)
        rig.allow = true
        #expect(await rig.ask("import", "pack.json", "--apply", cwd: cwd).ok)
        #expect(rig.store.isDisabled(id), "an imported shell bind arrives off")

        rig.allow = false
        rig.asked = []
        #expect(await rig.ask("bind", id, "--on").error?.code == .denied)
        #expect(rig.asked == ["Run shell: echo on"])
        #expect(rig.store.isDisabled(id))

        rig.allow = true
        let on = await rig.ask("bind", id, "--on")
        #expect(Self.field(on, "off") == .bool(false), "\(on.error?.message ?? "")")
        #expect(!rig.store.isDisabled(id))
    }

    @Test("export answers the bind file, every preset in it; --link answers the pilot://import link that reads back as it")
    func exporting() async throws {
        let rig = Rig()
        let file = await rig.ask("export")
        #expect(Self.field(file, "version") == .number(Double(BindStore.version)))
        guard case .array(let presets)? = Self.field(file, "presets") else { Issue.record("no presets: \(file)"); return }
        #expect(presets.count == rig.store.presets.count)

        guard case .string(let link)? = Self.field(await rig.ask("export", "--link"), "link"), let url = URL(string: link) else {
            Issue.record("no link"); return
        }
        #expect(link.hasPrefix("pilot://import?pack="))
        #expect(BindStore.pack(in: url) == rig.store.json())
        #expect(rig.asked.isEmpty)
    }

    @Test("import reads a file only from a temp folder or Downloads, alike whether it is there; a link outside one is refused")
    func importFolders() async throws {
        let rig = Rig()
        let outside = ["/etc/hosts", "/etc/no-such-bind-file.json", "/Library/Preferences/x.json"]
        var refusals: [ControlError?] = []
        for path in outside { refusals.append(await rig.ask("import", path).error) }
        #expect(refusals.allSatisfy { $0?.code == .badValue && $0?.message.contains("~/Downloads or a temp folder") == true }, "\(refusals)")

        let link = rig.folder.appending(path: "hosts.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(await rig.ask("import", "hosts.json", cwd: rig.folder.path(percentEncoded: false)).error?.message.contains("temp folder") == true,
                "a link in a temp folder to a file outside it")
        #expect(await rig.ask("import", "../../../../../../etc/hosts", cwd: rig.folder.path(percentEncoded: false)).error?.message.contains("temp folder") == true)
        #expect(rig.asked.isEmpty)
    }

    @Test("import --preset asks with the summary, then adds the file's preset and switches to it")
    func importAsPreset() async throws {
        let rig = Rig()
        let (cwd, _) = try Self.shellPack(rig, "drive.shell:echo preset")
        let count = rig.store.presets.count
        let denied = await rig.ask("import", "pack.json", "--preset", cwd: cwd)
        #expect(denied.error?.code == .denied)
        #expect(rig.asked.count == 1 && rig.asked[0].hasPrefix("Add import as a preset: pack.json: "))
        #expect(rig.store.presets.count == count)

        rig.allow = true
        let added = await rig.ask("import", "pack.json", "--preset", cwd: cwd)
        #expect(Self.field(added, "applied") == .bool(true), "\(added.error?.message ?? "")")
        #expect(rig.store.presets.count == count + 1)
        guard case .object(let preset)? = Self.field(added, "preset") else { Issue.record("no preset"); return }
        #expect(preset["active"] == .bool(true) && preset["id"] == .string(rig.store.preset.id))
    }

    @Test("overlay-picks lists every Hyper bind with shown; add and remove switch one and turn the overlay to My own pick; remove all empties it")
    func overlayPicks() async throws {
        let rig = Rig()
        let (mode, picks) = (rig.engine.settings.overlayMode, rig.engine.settings.overlayPicks)
        defer { (rig.engine.settings.overlayPicks, rig.engine.settings.overlayMode) = (picks, mode) }
        rig.engine.settings.overlayMode = .every
        let rows = Self.rows(await rig.ask("list", "overlay-picks"))
        let shown = rows.filter { $0["shown"] == .bool(true) }
        #expect(!shown.isEmpty && shown.count == rig.engine.overlayShown().count, "\(shown.count) of \(rows.count)")
        guard case .string(let id)? = shown.first?["action"] else { Issue.record("no rows"); return }

        let hidden = await rig.ask("remove", "overlay-picks", id)
        #expect(Self.field(hidden, "shown") == .bool(false), "\(hidden.error?.message ?? "")")
        #expect(Self.field(hidden, "mode") == .string("pick"))
        #expect(rig.engine.settings.overlayPicks.count == shown.count - 1, "every other bind stays shown")

        #expect(Self.field(await rig.ask("remove", "overlay-picks", "all"), "shown") == .number(0))
        #expect(rig.engine.settings.overlayPicks.isEmpty)
        #expect(Self.field(await rig.ask("add", "overlay-picks", "--action", id), "shown") == .bool(true))
        #expect(rig.engine.settings.overlayPicks == [id])
        #expect(Self.rows(await rig.ask("list", "overlay-picks")).filter { $0["shown"] == .bool(true) }.map { $0["action"] } == [.string(id)])
        #expect(await rig.ask("add", "overlay-picks", "--action", "no.such").error?.code == .unknownAction)
    }

    @Test("conflicts lists the macOS shortcuts a plain combo clashes with; --off and --restore ask, then turn them off and put them back")
    func conflicts() async throws {
        let rig = Rig()
        // Spotlight's Cmd+Space, on in macOS's table, under a plain combo.
        rig.table = ["64": ["enabled": true, "value": ["parameters": [32, 49, 1048576], "type": "standard"]]]
        let spotlight = Key(keyCode: KeyNames.code(for: "space")!, modifiers: .cmd, hyper: false)
        try rig.free(spotlight)
        try rig.engine.binds.set("windows.focusDisplayLeft", to: spotlight)

        let listed = await rig.ask("conflicts")
        guard case .array(let clashes)? = Self.field(listed, "clashes") else { Issue.record("no clashes: \(listed)"); return }
        #expect(clashes.contains(.object(["id": .number(64), "name": .string("Spotlight"), "key": .string(spotlight.label),
                                          "action": .string("windows.focusDisplayLeft")])))
        #expect(Self.field(listed, "canPutBack") == .bool(false))

        #expect(await rig.ask("conflicts", "--off").error?.code == .denied)
        #expect(rig.asked.first?.hasPrefix("Change macOS shortcut: turn off ") == true && rig.asked.first?.contains("Spotlight") == true)
        #expect(((rig.table["64"] as? [String: Any])?["enabled"] as? Bool) == true, "Deny writes nothing")

        rig.allow = true
        let off = await rig.ask("conflicts", "--off")
        #expect(Self.field(off, "canPutBack") == .bool(true), "\(off.error?.message ?? "")")
        guard case .array(let turnedOff)? = Self.field(off, "turnedOff") else { Issue.record("no turnedOff"); return }
        #expect(turnedOff.contains(.object(["id": .number(64), "name": .string("Spotlight")])))
        #expect(((rig.table["64"] as? [String: Any])?["enabled"] as? Bool) == false)

        let back = await rig.ask("conflicts", "--restore")
        #expect(Self.field(back, "canPutBack") == .bool(false), "\(back.error?.message ?? "")")
        #expect(((rig.table["64"] as? [String: Any])?["enabled"] as? Bool) == true)
        #expect(rig.asked.last?.hasPrefix("Change macOS shortcut: put back ") == true)
        #expect(await rig.ask("conflicts", "--off", "--restore").error?.code == .badRequest)
    }
}
