import Foundation
import OSLog
import PilotCore
import Testing
@testable import Pilot

/// The verbs Ask Pilot's agent needs (G1–G4): bind, unbind and set planned and applied through `pilot plan`, `keys
/// --free`, `key <combo>` and `list apps`. On ControlBindsTests' rig: a test engine whose binds file is put back, and a
/// fake com.apple.symbolichotkeys table. Keys under Hyper+Shift+Ctrl, which no preset gives.
@MainActor
@Suite("Ask Pilot verbs")
struct AskPilotVerbsTests {
    typealias Rig = ControlBindsTests.Rig

    static func rig() -> Rig {
        let rig = Rig()
        rig.verbs.registerPlan(gate: rig.app.gate)
        rig.verbs.registerKeys(rig.app, conflicts: { [unowned rig] in rig.conflicts })
        return rig
    }

    /// Two window actions no other suite binds.
    static func actions(_ rig: Rig) -> (String, String) {
        let used: Set = ["windows.snapLeft", "windows.focusDisplayLeft", "windows.focusDisplayRight"]
        let ids = rig.engine.registry.actions.keys.filter { $0.hasPrefix("windows.") && !used.contains($0) }.sorted()
        return (ids[0], ids[1])
    }

    static let mods = ["--mods", "shift,ctrl"]

    static func ask(_ rig: Rig, _ verb: String, _ args: [String]) async -> ControlAnswer {
        await rig.verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
    }

    @Test("bind --plan changes nothing and names old, new and free; apply asks once, binds and reads back")
    func bindPlan() async throws {
        let rig = Self.rig()
        let (one, _) = Self.actions(rig)
        let key = Key("j", [.shift, .ctrl])
        try rig.free(key)
        let before = rig.store.trigger(for: one)
        let planned = await Self.ask(rig, "bind", [one, "j", "--plan"] + Self.mods)
        #expect(planned.ok, "\(planned.error?.message ?? "")")
        #expect(rig.store.trigger(for: one) == before && rig.asked.isEmpty)
        let row = try #require(rig.verbs.plan.changes.first)
        #expect(row.old == (before?.label ?? "none") && row.new == key.label && row.key == key.label && row.free == true && row.asks == nil)

        rig.allow = true
        let applied = await rig.ask("plan", "apply")
        #expect(applied.ok, "\(applied.error?.message ?? "")")
        #expect(rig.asked == ["Apply 1 change: \(row.line)"])
        #expect(rig.store.trigger(for: one) == key && rig.verbs.plan.changes.isEmpty)
    }

    @Test("The agent's bind is planned without --plan; a taken key is refused when planned, also by an earlier row")
    func agentAndTaken() async throws {
        let rig = Self.rig()
        let (one, two) = Self.actions(rig)
        let key = Key("k", [.shift, .ctrl])
        try rig.free(key)
        let agent = await rig.verbs.answer(ControlRequest(verb: "bind", args: [one, "k"] + Self.mods, agent: true), peer: nil)
        #expect(agent.ok && rig.store.action(for: key) == nil && rig.verbs.plan.changes.count == 1)
        #expect(await Self.ask(rig, "bind", [two, "k", "--plan"] + Self.mods).error?.code == .taken, "planned for one already")
        try rig.engine.binds.set(one, to: key)
        rig.verbs.plan.clear()
        #expect(await Self.ask(rig, "bind", [two, "k", "--plan"] + Self.mods).error?.code == .taken)
        #expect(await Self.ask(rig, "bind", [two, "k", "--plan", "--replace"] + Self.mods).ok)
        #expect(rig.verbs.plan.changes.first?.new == "\(key.label), taking it from \(one)")
        #expect(await rig.ask("unbind", one, "--plan").ok && rig.store.trigger(for: one) == key)
        #expect(rig.verbs.plan.changes.last?.line == "Unbind \(rig.engine.action(one)?.label ?? one): \(key.label) → none")
    }

    @Test("A shell bind's plan row names its command, and the plan's one Allow covers it")
    func shellBind() async throws {
        let rig = Self.rig()
        let key = Key("l", [.shift, .ctrl])
        try rig.free(key)
        let id = "drive.shell:echo plan"
        #expect(await Self.ask(rig, "bind", [id, "l", "--plan"] + Self.mods).ok)
        #expect(rig.verbs.plan.changes.first?.asks?.text == "Run shell: echo plan")
        rig.allow = true
        #expect(await rig.ask("plan", "apply").ok)
        #expect(rig.asked.count == 1 && rig.store.action(for: key) == id)
        try rig.free(key)
    }

    @Test("keys --free leaves out held keys; --plain leaves out macOS's shortcuts and keys that type")
    func freeKeys() async throws {
        let rig = Self.rig()
        let key = Key("m", [.shift, .ctrl])
        try rig.free(key)
        let free = await Self.ask(rig, "keys", ["--free"] + Self.mods)
        #expect(Self.strings(ControlBindsTests.field(free, "free")).contains("M"))
        #expect(ControlBindsTests.field(free, "layer") == .string("Hyper+Shift+Ctrl"))
        let (one, _) = Self.actions(rig)
        try rig.engine.binds.set(one, to: key)
        #expect(!Self.strings(ControlBindsTests.field(await Self.ask(rig, "keys", ["--free"] + Self.mods), "free")).contains("M"))
        try rig.free(key)

        let plain = await rig.ask("keys", "--free", "--plain", "--mods", "cmd")
        #expect(!Self.strings(ControlBindsTests.field(plain, "free")).contains("Space"), "Spotlight holds Cmd+Space")
        guard case .array(let shadowed)? = ControlBindsTests.field(plain, "shadowed") else { return #expect(Bool(false)) }
        #expect(shadowed.contains(.object(["key": .string("Cmd+Space"), "why": .string("Shadows macOS's Spotlight.")])))
        #expect(await rig.ask("keys").error?.code == .badRequest)
        #expect(await rig.ask("keys", "--free", "--plain").error?.code == .badValue)
    }

    @Test("key names what a combo runs and where it came from, or that it is free; a plain combo names its macOS clash")
    func keyLookup() async throws {
        let rig = Self.rig()
        let (one, _) = Self.actions(rig)
        let key = Key("n", [.shift, .ctrl])
        try rig.free(key)
        #expect(ControlBindsTests.field(await rig.ask("key", "hyper+shift+ctrl+n"), "free") == .bool(true))
        try rig.engine.binds.set(one, to: key)
        let held = await rig.ask("key", "Hyper+Shift+Ctrl+N")
        #expect(ControlBindsTests.field(held, "action") == .string(one))
        #expect(ControlBindsTests.field(held, "from") == .string("set by hand"))
        #expect(ControlBindsTests.field(held, "key") == .string(key.label))
        try rig.free(key)
        #expect(ControlBindsTests.field(await rig.ask("key", "cmd+space"), "clash") == .string("Shadows macOS's Spotlight."))
        #expect(await rig.ask("key", "hyper+nokey").error?.code == .badValue)
    }

    @Test("A key written as bind's words reads back as the same key", arguments: [
        Key("j", [.shift, .ctrl]), Key("k"), Key("h", .leftAlt, hyper: false), Key("space", [.cmd, .rightShift], hyper: false), Key("f5", .alt),
    ])
    func keyWords(_ key: Key) throws {
        let words = ControlVerbs.words(key)
        #expect(try ControlVerbs.key(ControlArguments(words), at: 0, plain: words.contains("--plain")) == key)
    }

    @Test("combo reads Hyper by default and a plain combo when it names cmd, ctrl or alt without Hyper")
    func combos() throws {
        #expect(try ControlVerbs.combo("k") == Key("k"))
        #expect(try ControlVerbs.combo("Hyper+Shift+N") == Key("n", .shift))
        #expect(try ControlVerbs.combo("shift+k") == Key("k", .shift))
        #expect(try ControlVerbs.combo("leftAlt+h") == Key("h", .leftAlt, hyper: false))
        #expect(try ControlVerbs.combo("hyper+cmd+k") == Key("k", .cmd))
    }

    @Test("set --plan shows old and new; apply covers a confirmed setting's ask and reads it back; a secret is never planned")
    func setPlan() async {
        var flag = false, confirmed = false
        var decided: [String] = [], asked: [String] = []
        let schema = SettingsSchema()
        schema.register([
            .bool("test.flag", "Flag", page: "general", standard: false, read: { flag }, write: { flag = $0 }),
            .bool("test.confirmed", "Confirmed", page: "general", standard: false, confirms: true, read: { confirmed }, write: { confirmed = $0 }),
        ])
        let verbs = ControlVerbs()
        verbs.registerSettings(schema) { key, value, _ in decided.append("\(key)=\(value)"); return false }
        verbs.registerPlan(gate: ControlGate { ask, _ in asked.append(ask.title); return true })
        func ask(_ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: "set", args: args), peer: nil) }

        #expect(await ask("test.flag", "on", "--plan").ok && !flag)
        #expect(await ask("test.confirmed", "on", "--plan").ok && !confirmed)
        #expect(verbs.plan.changes.map(\.line) == ["Set test.flag: off → on", "Set test.confirmed: off → on (Set test.confirmed: on)"])
        #expect(await ask("test.flag", "maybe", "--plan").error?.code == .badValue)
        let applied = await verbs.answer(ControlRequest(verb: "plan", args: ["apply"]), peer: nil)
        #expect(applied.ok && flag && confirmed && decided.isEmpty && asked == ["Apply 2 changes"])
        guard case .object(let o)? = applied.result, case .array(let rows)? = o["rows"], case .object(let first)? = rows.first else {
            return #expect(Bool(false))
        }
        #expect(first["now"] == .bool(true))
        // --unset never plans: the agent's runs as set itself does, here refused since the key is no secret.
        let unset = await verbs.answer(ControlRequest(verb: "set", args: ["test.flag", "--unset"], agent: true), peer: nil)
        #expect(unset.error?.code == .badValue && verbs.plan.changes.isEmpty)
    }

    @Test("list apps answers name, bundle id and last opened, the most recent first, undated ones last by name")
    func apps() async {
        let stores = AppCollectionStores()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        stores.installedApps = { [("Zed", "dev.zed.Zed", URL(filePath: "/A/Zed.app")), ("Arc", "company.thebrowser.Browser", URL(filePath: "/A/Arc.app")),
                                  ("Old", "com.example.Old", URL(filePath: "/A/Old.app")), ("Linear", "com.linear", URL(filePath: "/A/Linear.app"))] }
        stores.lastUsed = { url in
            switch url.lastPathComponent {
            case "Linear.app": now
            case "Old.app": now.addingTimeInterval(-86_400)
            default: nil
            }
        }
        let verbs = ControlVerbs()
        verbs.registerAppCollections(stores)
        let rows = ControlBindsTests.rows(await verbs.answer(ControlRequest(verb: "list", args: ["apps"]), peer: nil))
        #expect(rows.map { $0["bundle"] } == ["com.linear", "com.example.Old", "company.thebrowser.Browser", "dev.zed.Zed"].map(JSONValue.string))
        #expect(rows.first?["lastUsed"] == .string(now.ISO8601Format()) && rows.last?["lastUsed"] == .null)
    }

    @Test("undo puts a bind back: a key set by hand to that key, one never set by hand to its default, and --replace's holder to its key")
    func bindUndo() async throws {
        let rig = Self.rig()
        rig.allow = true
        let (one, two) = Self.actions(rig)
        let (k0, k1, k2) = (Key("u", [.shift, .ctrl]), Key("i", [.shift, .ctrl]), Key("o", [.shift, .ctrl]))
        for key in [k0, k1, k2] { try rig.free(key) }

        try rig.engine.binds.set(one, to: k0)
        #expect(await Self.ask(rig, "bind", [one, "i", "--plan"] + Self.mods).ok)
        #expect(await rig.ask("plan", "apply").ok && rig.store.trigger(for: one) == k1)
        let undone = await rig.ask("undo")
        #expect(undone.ok, "\(undone.error?.message ?? "")")
        #expect(rig.store.trigger(for: one) == k0 && rig.asked.last?.hasPrefix("Undo 1 change:") == true)

        // --replace: two held k1 and gets it back; one goes back to k0.
        try rig.engine.binds.set(two, to: k1)
        #expect(await Self.ask(rig, "bind", [one, "i", "--replace", "--plan"] + Self.mods).ok)
        #expect(await rig.ask("plan", "apply").ok && rig.store.trigger(for: one) == k1 && rig.store.trigger(for: two) == nil)
        #expect(await rig.ask("undo").ok)
        #expect(rig.store.trigger(for: one) == k0 && rig.store.trigger(for: two) == k1)

        // Never set by hand: undo resets it to the preset's default.
        try rig.engine.binds.set(two, to: nil)
        try rig.engine.binds.reset(one)
        let standard = rig.store.trigger(for: one)
        #expect(!rig.store.isCustom(one))
        #expect(await Self.ask(rig, "bind", [one, "o", "--plan"] + Self.mods).ok)
        #expect(await rig.ask("plan", "apply").ok && rig.store.trigger(for: one) == k2)
        #expect(await rig.ask("undo").ok)
        #expect(rig.store.trigger(for: one) == standard && !rig.store.isCustom(one))
        for key in [k0, k1, k2] { try rig.free(key) }
    }

    @Test("set's undo puts the old value back, a list of choices included; --find names the closest keys, the title's first")
    func setUndoAndFind() async {
        enum Side: String { case left, right, top }
        var flag = false, sides: [Side] = [.left]
        let schema = SettingsSchema()
        schema.register([
            .bool("test.flag", "Menu flag", page: "general", standard: false, read: { flag }, write: { flag = $0 }),
            .choices("test.sides", "Bar sides", page: "bar", [Side.left, .right, .top], standard: [.left], read: { sides }, write: { sides = $0 }),
            .bool("menu.other", "Other thing", page: "menu", standard: false, read: { false }, write: { _ in }),
        ])
        let verbs = ControlVerbs()
        verbs.registerSettings(schema)
        verbs.registerPlan(gate: ControlGate { _, _ in true })
        func ask(_ verb: String, _ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil) }

        #expect(await ask("set", "test.flag", "on", "--plan").ok)
        #expect(await ask("set", "test.sides", "right,top", "--plan").ok)
        #expect(await ask("plan", "apply").ok && flag && sides == [.right, .top])
        #expect(await ask("undo").ok)
        #expect(!flag && sides == [.left])

        let found = ControlBindsTests.rows(await ask("settings", "--find", "menu flag"))
        #expect(found.map { $0["key"] } == [.string("test.flag")], "both words beat one")
        let menu = ControlBindsTests.rows(await ask("settings", "--find", "menu"))
        #expect(menu.map { $0["key"] } == [.string("test.flag"), .string("menu.other")], "a title hit first")
        #expect(ControlBindsTests.rows(await ask("settings", "--find", "zzz")).isEmpty)
    }

    @Test("log reads back --last's span, the newest first, at most 50, every line redacted")
    func log() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = (0..<60).map { LogLine(date: now.addingTimeInterval(-Double($0) * 5), category: "c", level: "error", message: "line \($0)") }
            + [LogLine(date: now.addingTimeInterval(-7200), category: "c", level: "error", message: "too old")]
        let verbs = ControlVerbs()
        verbs.registerLog(read: { _ in lines.reversed() }, now: { now })
        let answer = await verbs.answer(ControlRequest(verb: "log", args: ["--last", "1h"]), peer: nil)
        guard case .object(let o)? = answer.result, case .array(let rows)? = o["lines"] else { return #expect(Bool(false)) }
        #expect(o["count"] == .number(60) && rows.count == ControlVerbs.logLines)
        #expect(rows.first == .object(["time": .string(now.ISO8601Format()), "category": .string("c"), "level": .string("error"), "message": .string("line 0")]))
        #expect(try ControlVerbs.span("30s") == 30 && ControlVerbs.span("10m") == 600 && ControlVerbs.span("2h") == 7200)
        #expect(await verbs.answer(ControlRequest(verb: "log", args: ["--last", "2d"]), peer: nil).error?.code == .badValue)
        #expect(await verbs.answer(ControlRequest(verb: "log", args: ["--last", "25h"]), peer: nil).error?.code == .outOfRange)
    }

    @Test("Pilot's log store answers this process's errors and warnings, a private value as <private>, notices left out")
    func logStorePrivacy() async throws {
        let hidden = "sk-test-\(UUID().uuidString.prefix(8))", since = Date().addingTimeInterval(-1)
        let logger = Logger(subsystem: "dev.banozz.pilot", category: "log-test")
        logger.error("log test error \(hidden, privacy: .private)")
        logger.warning("log test warning")
        logger.notice("log test notice")
        // Off the main actor, as the verb reads it: in the full suite logd took 10 to 55 s to answer, and on main that
        // held every other main-actor test past its clocks.
        let read = try await Task.detached { try ControlVerbs.pilotLog(since: since) }.value.filter { $0.category == "log-test" }
        #expect(read.map(\.message) == ["log test error <private>", "log test warning"])
        #expect(!read.contains { $0.message.contains(hidden) })
    }

    static func strings(_ value: JSONValue?) -> [String] {
        if case .array(let items)? = value { items.compactMap(\.string) } else { [] }
    }
}

/// `pilot guide <topic>` (Sven Q180; skills since P29, Q268): every skill has its folder and SKILL.md, every guide a line
/// in the agent's prompt written from its when-line, and every `pilot` verb and collection a skill or the prompt names
/// exists in the app's registry.
@MainActor
@Suite("Agent guides")
struct AgentGuidesTests {
    static let packaging = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Packaging")
    static let folder = packaging.appending(path: "skills")

    /// The repo's skills, as the app reads its bundle's.
    static let skills = AISkills.load { try? String(contentsOf: folder.appending(path: "\($0)/SKILL.md"), encoding: .utf8) }
    static var guides: [AISkill] { AISkills.guides(skills) }

    @Test("Each skill has its SKILL.md and each folder a skill; the prompt has a line per guide naming pilot guide <name>")
    func index() throws {
        let folders = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path).filter { !$0.hasPrefix(".") }
        #expect(Set(folders) == Set(AISkills.names))
        #expect(Self.skills.map(\.name) == AISkills.names)
        let prompt = try String(contentsOf: Self.packaging.appending(path: "pilot-agent.md"), encoding: .utf8)
        for guide in Self.guides {
            #expect(prompt.contains("- \(guide.when): `pilot guide \(guide.name)`."), "\(guide.name)")
        }
    }

    @Test("Every pilot verb and collection the skills and the prompt name is registered")
    func verbsExist() throws {
        let verbs = ControlSocket.registered()
        let lists = verbs.verbs["list"].map { _ in try? verbs.schema(verb: "list") } ?? nil
        guard case .object(let list)? = lists, case .object(let part)? = list["schema"], case .array(let collections)? = part["collections"] else {
            return #expect(Bool(false), "list's schema")
        }
        let names = Set(collections.compactMap { if case .object(let c) = $0 { c["name"]?.string } else { nil } })
        let texts = Self.skills.map(\.body) + [try String(contentsOf: Self.packaging.appending(path: "pilot-agent.md"), encoding: .utf8)]
        #expect(texts.count == AISkills.names.count + 1)
        let command = try Regex(#"`pilot ([a-z-]+)(?: ([a-z-]+))?"#)
        var seen = 0
        for text in texts {
            for match in text.matches(of: command) {
                seen += 1
                let verb = String(match.output[1].substring!)
                #expect(verbs.verbs[verb] != nil, "no verb \(verb)")
                if ["list", "add", "remove"].contains(verb), let collection = match.output[2].substring.map(String.init) {
                    #expect(names.contains(collection), "no collection \(collection)")
                }
            }
        }
        #expect(seen > 30)
    }

    @Test("guide lists the topics, reads one by its name or its old one, and refuses any other word, a path included")
    func verb() async {
        let verbs = ControlVerbs()
        verbs.registerGuides(skills: { Self.guides })
        func ask(_ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: "guide", args: args), peer: nil) }
        #expect(await ask().result?.string?.contains("troubleshoot") == true)
        #expect(await ask("binds").result?.string?.hasPrefix("# Suggesting and making binds") == true)
        #expect(await ask("catalogue").result?.string?.hasPrefix("# Extensions") == true)
        #expect(await ask("extensions").result?.string?.hasPrefix("# Extensions") == true)
        #expect(await ask("troubleshooting").result?.string?.hasPrefix("# Troubleshooting") == true)
        #expect(await ask("extension").error?.code == .badValue)
        #expect(await ask("../pilot-agent").error?.code == .badValue)
        #expect(await ask("nope").error?.code == .badValue)
    }
}
