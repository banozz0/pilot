import Foundation
@testable import PilotCore
import Testing

/// The control socket's wire format, argument parser and verb registry (ADR 0013), without a socket.
@MainActor
@Suite("Control protocol")
struct ControlProtocolTests {
    static func answer(_ verbs: ControlVerbs, _ verb: String, _ args: [String] = []) async -> ControlAnswer {
        await verbs.answer(ControlRequest(id: .number(1), verb: verb, args: args), peer: nil)
    }

    static func decoded(_ line: Data) throws -> [String: JSONValue] {
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: line) else { throw ControlError(.badRequest, "not an object") }
        return object
    }

    @Test("A request line decodes with its id kept as sent; args and cwd are optional")
    func requestLine() throws {
        let full = try ControlLine.request(Data(#"{"id":"a7","verb":"get","args":["look.theme"],"cwd":"/tmp"}"#.utf8))
        #expect(full == ControlRequest(id: .string("a7"), verb: "get", args: ["look.theme"], cwd: "/tmp"))
        #expect(try ControlLine.request(Data(#"{"verb":"ping"}"#.utf8)) == ControlRequest(verb: "ping"))
    }

    @Test("A malformed line is bad-request", arguments: ["not json", "{}", #"{"verb":3}"#, #"{"verb":"x","args":"y"}"#, "[]"])
    func malformed(_ line: String) {
        let error = #expect(throws: ControlError.self) { try ControlLine.request(Data(line.utf8)) }
        #expect(error?.code == .badRequest)
    }

    @Test("An answer is one line: ok with result, or ok false with a typed error")
    func answerLine() throws {
        let ok = ControlLine.encode(.success(.number(3), .string("pong")))
        #expect(ok.last == 0x0A && ok.dropLast().contains(0x0A) == false)
        #expect(try Self.decoded(ok.dropLast()) == ["id": .number(3), "ok": .bool(true), "result": .string("pong")])
        let failed = ControlLine.encode(.failure(nil, ControlError(.unknownVerb, "no verb x")))
        #expect(try Self.decoded(failed.dropLast()) == ["ok": .bool(false),
                                                         "error": .object(["code": .string("unknown-verb"), "message": .string("no verb x")])])
    }

    @Test("A result JSON cannot hold answers bad-value under the request's id, never a bare {}")
    func unencodable() throws {
        let line = ControlLine.encode(.success(.number(4), .object(["level": .number(.nan)])))
        #expect(try Self.decoded(line.dropLast()) == ["id": .number(4), "ok": .bool(false),
                                                       "error": .object(["code": .string("bad-value"), "message": .string("answer is not JSON")])])
    }

    @Test("Words parse into positional words, --flag value, --flag=value and switches; -- ends the flags")
    func arguments() throws {
        let args = ControlArguments(["windows.snapLeft", "h", "--mods", "ctrl", "--json", "--app=Finder", "--", "--literal"], switches: ["json"])
        #expect(args.positional == ["windows.snapLeft", "h", "--literal"])
        #expect(args.values == ["mods": "ctrl", "app": "Finder"])
        #expect(args.switches == ["json"])
        #expect(args.has("json") && args.has("mods") && !args.has("preset"))
        #expect(try args.word(1, "key") == "h")
        #expect(throws: ControlError(.badRequest, "missing name")) { try args.word(3, "name") }
        // An unknown flag followed by another flag, or last, is a switch.
        let bare = ControlArguments(["--reset", "--preset"])
        #expect(bare.switches == ["reset", "preset"] && bare.values.isEmpty)
    }

    @Test("An unknown verb answers unknown-verb, with the request's id")
    func unknownVerb() async {
        let answer = await Self.answer(ControlVerbs(), "frobnicate")
        #expect(answer.id == .number(1) && !answer.ok && answer.error?.code == .unknownVerb)
    }

    @Test("A verb's result is the answer; a handler that throws answers its typed error")
    func handlers() async {
        let verbs = ControlVerbs()
        verbs.register(ControlVerb("echo", help: "Echoes.") { call in .string(call.words.joined(separator: " ")) })
        verbs.register(ControlVerb("fail", help: "Fails.") { _ throws(ControlError) in throw ControlError(.outOfRange, "gap 99 is past 0…40") })
        verbs.register(ControlVerb("slow", help: "Answers from a background task.") { _ in
            .string(await Task.detached { "later" }.value)
        })
        #expect(await Self.answer(verbs, "echo", ["a", "b"]) == .success(.number(1), .string("a b")))
        #expect(await Self.answer(verbs, "fail") == .failure(.number(1), ControlError(.outOfRange, "gap 99 is past 0…40")))
        #expect(await Self.answer(verbs, "slow") == .success(.number(1), .string("later")))
    }

    @Test("A collection registered through ControlCollections answers list, add and remove")
    func collection() async {
        @MainActor final class Rows { var rows: [String: String] = [:] }
        let store = Rows()
        let verbs = ControlVerbs()
        verbs.register(ControlCollection("aliases", help: "Words that open an action.",
                                         fields: [ControlCollection.Field("word", help: "what is typed"),
                                                  ControlCollection.Field("action", help: "the action id")],
                                         list: { .object(store.rows.mapValues { .string($0) }) },
                                         add: { args in
                                             store.rows[args.value("word")!] = args.value("action")!
                                             return .string("added")
                                         },
                                         remove: { args throws(ControlError) in
                                             let word = try args.word(0, "word")
                                             guard store.rows.removeValue(forKey: word) != nil else { throw ControlError(.badValue, "no alias \(word)") }
                                             return .string("removed")
                                         }))
        verbs.register(ControlCollection("scripts", help: "Script commands.", list: { .array([]) }))

        #expect(await Self.answer(verbs, "add", ["aliases", "--word", "gh", "--action", "apps.ghostty"]).result == .string("added"))
        #expect(await Self.answer(verbs, "list", ["aliases"]).result == .object(["gh": .string("apps.ghostty")]))
        #expect(await Self.answer(verbs, "remove", ["aliases", "gh"]).result == .string("removed"))
        #expect(await Self.answer(verbs, "list", ["aliases"]).result == .object([:]))

        #expect(await Self.answer(verbs, "add", ["aliases", "--word", "gh"]).error
            == ControlError(.badValue, "aliases needs --action: the action id"))
        #expect(await Self.answer(verbs, "remove", ["aliases", "gh"]).error == ControlError(.badValue, "no alias gh"))
        #expect(await Self.answer(verbs, "add", ["scripts", "--name", "x"]).error == ControlError(.badValue, "scripts is read-only"))
        #expect(await Self.answer(verbs, "list", ["nope"]).error == ControlError(.unknownCollection, "no collection nope; there are aliases, scripts"))
        #expect(await Self.answer(verbs, "add", []).error?.code == .badRequest)
        #expect(await Self.answer(verbs, "list").result == .array([
            .object(["name": .string("aliases"), "help": .string("Words that open an action.")]),
            .object(["name": .string("scripts"), "help": .string("Script commands.")]),
        ]))
    }

    @Test("schema lists every registered verb, with the collections under list")
    func schema() throws {
        let verbs = ControlVerbs()
        verbs.register(ControlVerb("ping", help: "Pong.") { _ in .string("pong") })
        verbs.register(ControlCollection("snippets", help: "Text snippets.", fields: [.init("name", help: "its name")], list: { .array([]) }))
        guard case .object(let schema) = verbs.schema, case .array(let entries) = schema["verbs"] else { Issue.record("no verbs"); return }
        let names = entries.compactMap { entry -> String? in
            guard case .object(let o) = entry, case .string(let name) = o["name"] else { return nil }
            return name
        }
        #expect(names == verbs.sorted.map(\.name))
        #expect(Set(names) == ["add", "list", "ping", "remove"])
        let list = entries.first { if case .object(let o) = $0 { o["name"] == .string("list") } else { false } }
        guard case .object(let listEntry) = list, case .object(let part) = listEntry["schema"],
              case .array(let collections) = part["collections"] else { Issue.record("list has no collections"); return }
        #expect(collections == [.object(["name": .string("snippets"), "help": .string("Text snippets."), "add": .bool(false), "remove": .bool(false),
                                         "fields": .array([.object(["name": .string("name"), "help": .string("its name"), "required": .bool(true)])]),
                                         "asks": .array([])])])
    }

    @Test("A verb that declares flags refuses any other before its handler runs; one that declares none takes any")
    func flags() async {
        @MainActor final class Calls { var words: [[String]] = [] }
        let calls = Calls()
        let verbs = ControlVerbs()
        verbs.register(ControlVerb("open", help: "Opens a page.", flags: [.init("section", help: "a section"), .init("plain", help: "bare", takesValue: false)]) { call in
            calls.words.append(call.words); return .string("opened")
        })
        verbs.register(ControlVerb("ping", help: "Pong.", flags: []) { _ in .string("pong") })
        verbs.register(ControlVerb("old", help: "Takes anything.") { _ in .string("ok") })

        #expect(await Self.answer(verbs, "open", ["system", "--section", "keys"]).ok)
        #expect(await Self.answer(verbs, "open", ["system", "--section=keys", "--plain"]).ok)
        // A switch never takes the next word, and after -- a flag-shaped word is positional.
        #expect(await Self.answer(verbs, "open", ["--plain", "system", "--", "--sectoin"]).ok)
        #expect(await Self.answer(verbs, "open", ["system", "--sectoin", "keys"]).error
            == ControlError(.unknownFlag, "pilot open takes no --sectoin; it takes --section, --plain"))
        #expect(await Self.answer(verbs, "open", ["system", "--x=1"]).error?.code == .unknownFlag)
        #expect(await Self.answer(verbs, "ping", ["--json"]).error
            == ControlError(.unknownFlag, "pilot ping takes no --json; it takes no flags; --json goes before the verb: pilot --json <verb> …"))
        #expect(calls.words.count == 3, "a refused request never reaches the handler")
        #expect(await Self.answer(verbs, "old", ["--mod", "ctrl"]).ok)
    }

    @Test("add refuses a flag its collection has no field for, after read-only and before a missing field")
    func addFlags() async {
        @MainActor final class Rows { var added: [String] = [] }
        let rows = Rows()
        let verbs = ControlVerbs()
        verbs.register(ControlCollection("snippets", help: "Text snippets.",
                                         fields: [.init("name", help: "its name"), .init("keyword", help: "its keyword", required: false)],
                                         list: { .array([]) }, add: { args in rows.added.append(args.value("name")!); return .string("added") }))
        verbs.register(ControlCollection("scripts", help: "Script commands.", list: { .array([]) }))

        #expect(await Self.answer(verbs, "add", ["snippets", "--name", "a", "--keywrod", ";x"]).error
            == ControlError(.unknownFlag, "pilot add snippets takes no --keywrod; it takes --name, --keyword"))
        #expect(await Self.answer(verbs, "add", ["snippets", "--nmae", "a"]).error?.code == .unknownFlag, "a typo'd required flag is named, not missing")
        #expect(await Self.answer(verbs, "add", ["scripts", "--file", "x"]).error == ControlError(.badValue, "scripts is read-only"))
        #expect(await Self.answer(verbs, "add", ["snippets", "--name", "a", "--keyword", ";x"]).ok)
        #expect(await Self.answer(verbs, "list", ["snippets", "--json"]).error?.code == .unknownFlag)
        #expect(rows.added == ["a"])
    }

    @Test("schema lists a verb's declared flags, a collection's row key and the edits that ask Allow")
    func schemaMarks() throws {
        let verbs = ControlVerbs()
        verbs.register(ControlVerb("open", help: "Opens.", flags: [.init("section", help: "a section"), .init("plain", help: "bare", takesValue: false)]) { _ in .null })
        verbs.register(ControlVerb("old", help: "Anything.") { _ in .null })
        verbs.register(ControlCollection("packages", help: "Installs.", fields: [.init("package", help: "a key")], rowKey: "package", list: { .array([]) },
                                         askerAdd: { _, _ in .null }, askerRemove: { _, _ in .null }))
        verbs.register(ControlCollection("roles", help: "Picks.", list: { .array([]) }, add: { _ in .null }, remove: { _ in .null }))
        verbs.register(ControlCollection("half", help: "Removal asks.", asks: [.remove], list: { .array([]) }, askerAdd: { _, _ in .null }, askerRemove: { _, _ in .null }))
        guard case .object(let schema) = verbs.schema, case .array(let entries) = schema["verbs"] else { Issue.record("no verbs"); return }
        let byName = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, [String: JSONValue])? in
            guard case .object(let o) = entry, case .string(let name) = o["name"] else { return nil }
            return (name, o)
        })
        #expect(byName["open"]?["flags"] == .array([.object(["name": .string("section"), "help": .string("a section"), "value": .bool(true)]),
                                                     .object(["name": .string("plain"), "help": .string("bare"), "value": .bool(false)])]))
        #expect(byName["old"]?["flags"] == nil, "no flags declared: none listed, not an empty list")
        #expect(byName["list"]?["flags"] == .array([]))
        guard case .object(let part) = byName["list"]?["schema"], case .array(let collections) = part["collections"] else { Issue.record("no collections"); return }
        let marks = collections.compactMap { c -> (JSONValue?, JSONValue?)? in
            guard case .object(let o) = c else { return nil }
            return (o["asks"], o["rowKey"])
        }
        #expect(marks.map(\.0) == [.array([.string("remove")]), .array([.string("add"), .string("remove")]), .array([])])
        #expect(marks.map(\.1) == [nil, .string("package"), nil])
    }

    @Test("The schema index gives each verb its summary in place of its part, never building a part; one verb or collection reads alone")
    func schemaParts() throws {
        @MainActor final class Built { var parts = 0 }
        let built = Built()
        let verbs = ControlVerbs()
        verbs.register(ControlVerb("settings", help: "Settings.", schema: { built.parts += 1; return .array([]) },
                                   index: { .object(["pages": .array([.string("look")])]) }) { _ in .null })
        verbs.register(ControlVerb("binds", help: "Binds.", schema: { built.parts += 1; return .array([]) }) { _ in .null })
        verbs.register(ControlVerb("ping", help: "Pong.", flags: []) { _ in .null })
        verbs.register(ControlCollection("snippets", help: "Text snippets.", fields: [.init("name", help: "its name")], rowKey: "name", list: { .array([]) }))
        guard case .object(let index) = verbs.schemaIndex, case .array(let listed) = index["verbs"] else { Issue.record("no index"); return }
        let parts = Dictionary(uniqueKeysWithValues: listed.compactMap { entry -> (String, JSONValue)? in
            guard case .object(let o) = entry, case .string(let name) = o["name"] else { return nil }
            #expect(o["schema"] == nil && o["help"] != nil && o["usage"] != nil, "\(name): no part in the index, help and usage kept")
            return (name, o["part"] ?? .null)
        })
        #expect(parts == ["add": .null, "binds": .bool(true), "list": .object(["collections": .array([.string("snippets")])]), "ping": .null,
                          "remove": .null, "settings": .object(["pages": .array([.string("look")])])])
        #expect(built.parts == 0, "the index builds no part")
        #expect(try verbs.schema(verb: "ping") == .object(["name": .string("ping"), "help": .string("Pong."), "usage": .string("pilot ping"), "flags": .array([])]))
        #expect(try verbs.schema(collection: "snippets") == .object([
            "name": .string("snippets"), "help": .string("Text snippets."), "add": .bool(false), "remove": .bool(false),
            "fields": .array([.object(["name": .string("name"), "help": .string("its name"), "required": .bool(true)])]),
            "asks": .array([]), "rowKey": .string("name")]))
        #expect(throws: ControlError(.unknownVerb, "no verb nope; pilot help lists them")) { try verbs.schema(verb: "nope") }
        #expect(throws: ControlError(.unknownCollection, "no collection nope; there are snippets")) { try verbs.schema(collection: "nope") }
    }

    @Test("help for list, add and remove with a collection: its fields, its row key, and whether it asks Allow")
    func collectionHelp() throws {
        let verbs = ControlVerbs()
        verbs.register(ControlCollection("snippets", help: "Text snippets.",
                                         fields: [.init("name", help: "its name"), .init("keyword", help: "typed to paste it", required: false)],
                                         rowKey: "name", list: { .array([]) }, add: { _ in .null }, remove: { _ in .null }))
        verbs.register(ControlCollection("packages", help: "Installs.", fields: [.init("package", help: "a key")], list: { .array([]) },
                                         askerAdd: { _, _ in .null }, askerRemove: nil))
        #expect(try verbs.collectionHelp("add", "snippets") == """
            pilot add snippets --name <…> [--keyword <…>]
            Text snippets.
              --name     its name
              --keyword  typed to paste it (optional)
            """)
        #expect(try verbs.collectionHelp("remove", "snippets") == "pilot remove snippets <name>\nText snippets.")
        #expect(try verbs.collectionHelp("list", "snippets") == "pilot list snippets\nText snippets.")
        #expect(try verbs.collectionHelp("add", "packages").hasSuffix("\nAsks Allow first."))
        #expect(throws: ControlError(.badValue, "packages is read-only")) { try verbs.collectionHelp("remove", "packages") }
        #expect(throws: ControlError(.unknownCollection, "no collection nope; there are packages, snippets")) { try verbs.collectionHelp("add", "nope") }
    }
}
