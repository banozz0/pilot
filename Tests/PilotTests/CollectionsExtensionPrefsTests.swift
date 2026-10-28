import Foundation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// `pilot list|add|remove ext-prefs` (CLI W15): the Extensions page's preference fields through the registry the socket
/// answers from. Each test has its own Extensions and ExtensionData in a temporary folder and a fake Keychain, so nothing
/// reaches Sven's; the gate is the test's and records each question.
@MainActor
@Suite("Collections: extension preferences", .serialized)
struct CollectionsExtensionPrefsTests {
    /// The Keychain as a dictionary; `reads` counts the secret reads, which the command must never make.
    final class Keychain: ExtensionKeychain {
        let items = Mutex<[String: String]>([:]), reads = Mutex(0)
        func password(extension id: String, preference name: String) -> String? {
            reads.withLock { $0 += 1 }
            return items.withLock { $0["\(id)/\(name)"] }
        }
        func setPassword(_ password: String?, extension id: String, preference name: String) throws { items.withLock { $0["\(id)/\(name)"] = password } }
        func hasPassword(extension id: String, preference name: String) -> Bool { items.withLock { $0["\(id)/\(name)"] != nil } }
    }

    static let secret = "hunt3r2"

    @MainActor final class Rig {
        let tools = ExtensionTools()
        let verbs = ControlVerbs()
        let keychain = Keychain()
        let work = FileManager.default.temporaryDirectory.appending(path: "pilot-ext-prefs-\(UUID().uuidString)").resolvingSymlinksInPath()
        var asked: [ControlGate.Ask] = []
        var allow = false

        init() throws {
            tools.extensions = work.appending(path: "Extensions")
            tools.data = work.appending(path: "ExtensionData")
            tools.cache = work.appending(path: "Caches")
            tools.keychain = keychain
            tools.label = { _ in nil }
            tools.gate = ControlGate { [unowned self] ask, _ in asked.append(ask); return allow }
            let dir = tools.extensions.appending(path: "demo")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"""
                {"id": "demo", "title": "Demo", "preferences": [
                  {"name": "user", "type": "text", "title": "User", "required": true, "description": "Your login"},
                  {"name": "token", "type": "password", "title": "Token", "required": true},
                  {"name": "forks", "type": "checkbox", "title": "Show forks", "default": true},
                  {"name": "sort", "type": "dropdown", "title": "Sort", "default": "stars",
                   "data": [{"title": "Stars", "value": "stars"}, {"title": "Recently updated", "value": "updated"}]},
                  {"name": "editor", "type": "app", "title": "Editor"},
                  {"name": "notes", "type": "file", "title": "Notes"},
                  {"name": "clones", "type": "folder", "title": "Clones", "default": "/tmp"}],
                 "commands": [{"name": "go", "title": "Go", "mode": "no-view", "run": "go"}]}
                """#.utf8).write(to: dir.appending(path: Extension.manifestName))
            let program = dir.appending(path: "go")
            try Data("#!/bin/sh\necho '{\"type\":\"hud\",\"text\":\"went\"}'\n".utf8).write(to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            verbs.registerExtensions(tools)
        }

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args, cwd: work.path), peer: nil)
        }

        func rows() async -> [String: [String: JSONValue]] {
            guard case .array(let rows)? = await ask("list", "ext-prefs").result else { return [:] }
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard case .object(let o) = row, case .string(let pref)? = o["pref"] else { return nil }
                return (pref, o)
            })
        }

        func saved() throws -> [String: JSONValue] {
            try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: tools.data.appending(path: "demo/preferences.json")))
        }

        func clean() { try? FileManager.default.removeItem(at: work) }
    }

    static func object(_ answer: ControlAnswer) -> [String: JSONValue] {
        if case .object(let o)? = answer.result { o } else { [:] }
    }

    static func text(_ answer: ControlAnswer) throws -> String {
        try String(decoding: JSONEncoder().encode(answer), as: UTF8.self)
    }

    @Test("list shows every preference with its kind, options, required and missing; a password only set or unset, never read")
    func lists() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        var rows = await rig.rows()
        #expect(rows.keys.sorted() == ["demo.clones", "demo.editor", "demo.forks", "demo.notes", "demo.sort", "demo.token", "demo.user"])
        #expect(rows["demo.user"]?["kind"] == .string("text") && rows["demo.user"]?["missing"] == .bool(true) && rows["demo.user"]?["value"] == nil)
        #expect(rows["demo.user"]?["description"] == .string("Your login"))
        #expect(rows["demo.forks"]?["value"] == .bool(true) && rows["demo.sort"]?["value"] == .string("stars"))
        #expect(rows["demo.sort"]?["options"] == .array([.object(["value": .string("stars"), "title": .string("Stars")]),
                                                         .object(["value": .string("updated"), "title": .string("Recently updated")])]))
        #expect(rows["demo.token"]?["set"] == .bool(false) && rows["demo.token"]?["missing"] == .bool(true))
        #expect(rows["demo.token"]?.keys.contains("value") == false)

        try rig.keychain.setPassword(Self.secret, extension: "demo", preference: "token")
        let listed = await rig.ask("list", "ext-prefs")
        rows = await rig.rows()
        #expect(rows["demo.token"]?["set"] == .bool(true) && rows["demo.token"]?["missing"] == .bool(false))
        #expect(try !Self.text(listed).contains(Self.secret))
        #expect(rig.keychain.reads.withLock { $0 } == 0, "the command never reads a password")
        #expect(await rig.ask("ext", "show", "demo").ok)
        #expect(rig.keychain.reads.withLock { $0 } == 0)
    }

    @Test("add saves each kind as the page's field does and answers the value stored")
    func adds() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        var answer = await rig.ask("add", "ext-prefs", "--pref", "demo.user", "--value", "sven")
        #expect(answer.ok, "\(answer.error?.message ?? "")")
        #expect(Self.object(answer)["value"] == .string("sven") && Self.object(answer)["missing"] == .bool(false))
        answer = await rig.ask("add", "ext-prefs", "--pref", "demo.forks", "--value", "off")
        #expect(Self.object(answer)["value"] == .bool(false))
        answer = await rig.ask("add", "ext-prefs", "--pref", "demo.sort", "--value", "recently updated")
        #expect(Self.object(answer)["value"] == .string("updated"), "an option's title picks it too")
        answer = await rig.ask("add", "ext-prefs", "--pref", "demo.clones", "--value", rig.work.path)
        #expect(Self.object(answer)["value"] == .string(rig.work.path))
        #expect(try rig.saved() == ["user": .string("sven"), "forks": .bool(false), "sort": .string("updated"), "clones": .string(rig.work.path)])

        // Empty text puts the default back, as clearing the page's field does.
        answer = await rig.ask("add", "ext-prefs", "--pref", "demo.user", "--value", "")
        #expect(answer.ok && Self.object(answer)["value"] == nil && Self.object(answer)["missing"] == .bool(true))
        #expect(rig.asked.isEmpty, "the page saves as it changes, so add asks nothing")
    }

    @Test("add refuses a value its kind does not take, saying what it takes; nothing is saved")
    func refuses() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        let cases: [(String, String, ControlError.Code, String)] = [
            ("demo.forks", "maybe", .badValue, "on or off"),
            ("demo.sort", "size", .badValue, "stars (Stars), updated (Recently updated)"),
            ("demo.clones", rig.work.appending(path: "nowhere").path, .badValue, "nothing at"),
            ("demo.clones", "relative/path", .badValue, "full path"),
            ("demo.notes", rig.work.path, .badValue, "is a folder"),
            ("demo.editor", rig.work.path, .badValue, "not one"),
            ("demo.nope", "x", .badValue, "has no preference nope; it has user, token"),
            ("other.user", "x", .badValue, "no extension other"),
            ("demo.token", Self.secret, .keychainOnly, "Extensions page"),
        ]
        for (pref, value, code, says) in cases {
            let answer = await rig.ask("add", "ext-prefs", "--pref", pref, "--value", value)
            #expect(answer.error?.code == code && answer.error?.message.contains(says) == true, "\(pref) \(value): \(answer.error?.message ?? "ok")")
        }
        #expect(!FileManager.default.fileExists(atPath: rig.tools.data.appending(path: "demo/preferences.json").path))
        #expect(rig.keychain.items.withLock { $0.isEmpty })
        let typo = await rig.ask("add", "ext-prefs", "--pref", "demo.user", "--value", "x", "--vaule", "y")
        #expect(typo.error?.code == .unknownFlag)
    }

    @Test("remove puts the default back; a set password is deleted only after Allow, an unset one asks nothing")
    func removes() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        _ = await rig.ask("add", "ext-prefs", "--pref", "demo.sort", "--value", "updated")
        var answer = await rig.ask("remove", "ext-prefs", "demo.sort")
        #expect(answer.ok && Self.object(answer)["value"] == .string("stars"))
        #expect(try rig.saved()["sort"] == nil)

        answer = await rig.ask("remove", "ext-prefs", "demo.token")
        #expect(answer.ok && Self.object(answer)["set"] == .bool(false) && rig.asked.isEmpty)

        try rig.keychain.setPassword(Self.secret, extension: "demo", preference: "token")
        answer = await rig.ask("remove", "ext-prefs", "demo.token")
        #expect(answer.error?.code == .denied && rig.asked.map(\.title) == ["Clear extension password"])
        #expect(rig.asked[0].detail.contains("demo.token") && !rig.asked[0].detail.contains(Self.secret))
        let kept = rig.keychain.items.withLock { $0["demo/token"] }
        #expect(kept == Self.secret, "denied keeps it")
        rig.allow = true
        answer = await rig.ask("remove", "ext-prefs", "demo.token")
        #expect(answer.ok && Self.object(answer)["set"] == .bool(false) && Self.object(answer)["missing"] == .bool(true))
        #expect(rig.keychain.items.withLock { $0["demo/token"] } == nil)
        #expect(rig.keychain.reads.withLock { $0 } == 0)
    }

    @Test("schema names the row key and marks remove as asking")
    func schema() async throws {
        let rig = try Rig()
        defer { rig.clean() }
        guard case .object(let entry) = try rig.verbs.schema(collection: "ext-prefs") else { Issue.record("no entry"); return }
        #expect(entry["rowKey"] == .string("pref") && entry["asks"] == .array([.string("remove")]))
        #expect(entry["add"] == .bool(true) && entry["remove"] == .bool(true))
        #expect(try rig.verbs.verb("remove").detail?("ext-prefs")?.contains("pilot remove ext-prefs <pref>") == true)
    }
}
