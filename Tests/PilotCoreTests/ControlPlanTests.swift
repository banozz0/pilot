import Foundation
@testable import PilotCore
import Testing

/// The plan (Ask Pilot G1): `--plan` and the AI agent's requests collect a change instead of making it, `pilot plan
/// apply` asks once and applies every row in order with the asks it showed allowed, and a denial runs nothing. A fake
/// verb stands in for bind and set; their own dry runs are proved in the app's tests.
@MainActor
@Suite("Control plan")
struct ControlPlanTests {
    @MainActor final class Rig {
        let verbs = ControlVerbs()
        var store: [String: String] = [:]
        /// Every question the gate showed.
        var asked: [ControlGate.Ask] = []
        var allow = true

        init() {
            let gate = ControlGate { [unowned self] ask, _ in asked.append(ask); return allow }
            verbs.registerPlan(gate: gate)
            // `put <key> <value>`: asks "Put shell" for a value starting `!`, as a shell bind asks; `reject` never plans,
            // `none` takes the key out, `once` has no way back.
            verbs.register(ControlVerb("put", help: "", flags: [], plan: { [unowned self] call throws(ControlError) in
                let words = call.words
                guard words.count == 2 else { throw ControlError(.badRequest, "put <key> <value>") }
                if words[1] == "reject" { return nil }
                return .init("Put \(words[0])", old: store[words[0]] ?? "none", new: words[1], asks: Self.ask(words[1]))
            }, inverse: { [unowned self] call throws(ControlError) in
                let (key, value) = (call.words[0], call.words[1])
                return value == "once" ? .cannot("once is for good") : .requests([ControlRequest(verb: "put", args: [key, store[key] ?? "none"])])
            }) { [unowned self] call throws(ControlError) in
                let (key, value) = (call.words[0], call.words[1])
                return try await gate.allow(Self.ask(value), peer: nil) { () throws(ControlError) in
                    if value == "fail" { throw ControlError(.taken, "\(key) is taken") }
                    store[key] = value == "none" ? nil : value
                    return .string(value)
                }
            })
        }

        static func ask(_ value: String) -> ControlGate.Ask? { value.hasPrefix("!") ? .init("Put shell", value) : nil }

        func ask(_ verb: String, _ args: String..., agent: Bool = false) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args, agent: agent), peer: nil)
        }
    }

    static func field(_ answer: ControlAnswer, _ name: String) -> JSONValue? {
        if case .object(let o)? = answer.result { o[name] } else { nil }
    }

    @Test("--plan collects the change and changes nothing; the agent's request is planned without it; the user's own runs at once")
    func collects() async {
        let rig = Rig()
        let planned = await rig.ask("put", "a", "1", "--plan")
        #expect(planned.ok && rig.store.isEmpty)
        #expect(Self.field(planned, "applied") == .bool(false) && Self.field(planned, "waiting") == .number(1))
        _ = await rig.ask("put", "b", "2", agent: true)
        #expect(rig.store.isEmpty && rig.verbs.plan.changes.map(\.line) == ["Put a: none → 1", "Put b: none → 2"])
        #expect(rig.verbs.plan.changes.allSatisfy { !$0.request.args.contains("--plan") })
        _ = await rig.ask("put", "c", "3")
        #expect(rig.store == ["c": "3"] && rig.verbs.plan.changes.count == 2)
        // The same request again keeps one row.
        _ = await rig.ask("put", "a", "1", "--plan")
        #expect(rig.verbs.plan.changes.count == 2)
    }

    @Test("apply asks once with every row, applies them in order and reads each back; the plan empties")
    func applies() async {
        let rig = Rig()
        _ = await rig.ask("put", "a", "1", "--plan")
        _ = await rig.ask("put", "b", "!rm -rf", "--plan")
        let applied = await rig.ask("plan", "apply")
        #expect(applied.ok, "\(applied.error?.message ?? "")")
        #expect(rig.asked.count == 1, "the shell row's own ask is covered by the plan's Allow")
        #expect(rig.asked.first?.title == "Apply 2 changes")
        #expect(rig.asked.first?.detail == "Put a: none → 1\nPut b: none → !rm -rf (Put shell: !rm -rf)")
        #expect(rig.asked.first?.rows.count == 2)
        #expect(rig.store == ["a": "1", "b": "!rm -rf"])
        #expect(Self.field(applied, "applied") == .number(2) && rig.verbs.plan.changes.isEmpty)
        guard case .array(let rows)? = Self.field(applied, "rows"), case .object(let first)? = rows.first else { return #expect(Bool(false)) }
        #expect(first["now"] == .string("1"))
        // Outside a plan the same ask is asked again.
        _ = await rig.ask("put", "c", "!ls")
        #expect(rig.asked.count == 2 && rig.asked.last?.text == "Put shell: !ls")
    }

    @Test("A denied plan runs nothing and empties; a row that fails still lets the rest apply")
    func denyAndFail() async {
        let rig = Rig()
        rig.allow = false
        _ = await rig.ask("put", "a", "1", "--plan")
        let denied = await rig.ask("plan", "apply")
        #expect(denied.error?.code == .denied && rig.store.isEmpty && rig.verbs.plan.changes.isEmpty)

        rig.allow = true
        _ = await rig.ask("put", "a", "fail", "--plan")
        _ = await rig.ask("put", "b", "2", "--plan")
        let applied = await rig.ask("plan", "apply")
        #expect(applied.ok && rig.store == ["b": "2"] && Self.field(applied, "applied") == .number(1))
        guard case .array(let rows)? = Self.field(applied, "rows"), case .object(let first)? = rows.first else { return #expect(Bool(false)) }
        #expect(first["error"] == .string("a is taken"))
    }

    @Test("Nothing planned asks nothing; plan lists and clears; --plan on a change that asks on its own is refused, the agent's runs as it is")
    func edges() async {
        let rig = Rig()
        #expect(await rig.ask("plan", "apply").error?.code == .badRequest && rig.asked.isEmpty)
        _ = await rig.ask("put", "a", "1", "--plan")
        guard case .array(let listed)? = await rig.ask("plan").result else { return #expect(Bool(false)) }
        #expect(listed.count == 1)
        #expect(await rig.ask("plan", "clear").ok && rig.verbs.plan.changes.isEmpty)
        #expect(await rig.ask("put", "a", "reject", "--plan").error?.code == .badRequest)
        #expect(await rig.ask("put", "a", "reject", agent: true).ok && rig.store == ["a": "reject"])
        #expect(await rig.ask("plan", "--plan").error?.code == .unknownFlag, "a verb that does not plan takes no --plan")
        #expect(await rig.ask("plan", "nope").error?.code == .badRequest)
    }

    @Test("A plan too long for the gate to show whole refuses the row that would overflow it")
    func cap() async {
        let rig = Rig()
        for n in 0...ControlGate.Ask.mostLines { #expect(await rig.ask("put", "k\(n)", "v", "--plan").ok) }
        let over = await rig.ask("put", "over", "v", "--plan")
        #expect(over.error?.code == .outOfRange && rig.verbs.plan.changes.count == ControlGate.Ask.mostLines + 1)
        #expect(rig.verbs.plan.ask.tooLong == nil)
    }

    @Test("A request line carries agent; one without it is the user's")
    func wire() throws {
        let line = try ControlLine.request(Data(#"{"verb":"bind","args":["x","k"],"agent":true}"#.utf8))
        #expect(line.agent == true)
        #expect(try ControlLine.request(Data(#"{"verb":"ping"}"#.utf8)).agent == nil)
    }

    @Test("undo asks once with every inverse, the last row first, and puts the state before apply back; then nothing is left to undo")
    func undoes() async {
        let rig = Rig()
        rig.store = ["a": "0"]
        _ = await rig.ask("put", "a", "1", "--plan")
        _ = await rig.ask("put", "b", "!ls", "--plan")
        #expect(await rig.ask("plan", "apply").ok && rig.store == ["a": "1", "b": "!ls"])
        #expect(rig.verbs.plan.lastApplied.count == 2)
        let undone = await rig.ask("undo")
        #expect(undone.ok, "\(undone.error?.message ?? "")")
        #expect(rig.asked.count == 2 && rig.asked.last?.title == "Undo 2 changes")
        #expect(rig.asked.last?.detail == "Put b: !ls → none\nPut a: 1 → 0")
        #expect(rig.store == ["a": "0"] && rig.verbs.plan.lastApplied.isEmpty)
        #expect(Self.field(undone, "undone") == .number(2))
        #expect(await rig.ask("undo").error?.code == .badRequest)
    }

    @Test("undo puts back the state each row replaced when it ran, not when it was planned; a failed row leaves nothing to undo")
    func undoAtApplyTime() async {
        let rig = Rig()
        _ = await rig.ask("put", "a", "1", "--plan")
        _ = await rig.ask("put", "x", "fail", "--plan")
        _ = await rig.ask("put", "a", "5")
        #expect(await rig.ask("plan", "apply").ok)
        #expect(rig.verbs.plan.lastApplied.map(\.change.what) == ["Put a"])
        #expect(await rig.ask("undo").ok && rig.store == ["a": "5"])
    }

    @Test("undo refuses while a plan waits, names a row with no way back, and refuses when no row can go back")
    func undoEdges() async {
        let rig = Rig()
        #expect(await rig.ask("undo").error?.code == .badRequest)
        _ = await rig.ask("put", "a", "1", "--plan")
        _ = await rig.ask("put", "b", "once", "--plan")
        #expect(await rig.ask("plan", "apply").ok)
        _ = await rig.ask("put", "c", "1", "--plan")
        #expect(await rig.ask("undo").error?.code == .badRequest, "a plan waits")
        _ = await rig.ask("plan", "clear")
        let undone = await rig.ask("undo")
        #expect(undone.ok && rig.store == ["b": "once"])
        #expect(Self.field(undone, "skipped") == .array([.object(["what": .string("Put b"), "why": .string("once is for good")])]))

        _ = await rig.ask("put", "d", "once", "--plan")
        #expect(await rig.ask("plan", "apply").ok)
        #expect(await rig.ask("undo").error?.code == .badValue && rig.verbs.plan.lastApplied.isEmpty)
    }

    @Test("A denied undo changes nothing and keeps the last plan to undo")
    func undoDenied() async {
        let rig = Rig()
        _ = await rig.ask("put", "a", "1", "--plan")
        _ = await rig.ask("plan", "apply")
        rig.allow = false
        #expect(await rig.ask("undo").error?.code == .denied && rig.store == ["a": "1"] && rig.verbs.plan.lastApplied.count == 1)
    }

    @Test("A collection's added row undoes as a remove, one changed in place has no way back, and a removed row adds back with its fields")
    func collectionUndo() async {
        let rig = Rig()
        var rows: [String: String] = ["old": "1"]
        rig.verbs.register(ControlCollection("things", help: "", fields: [.init("name", help: ""), .init("size", help: "")], rowKey: "name",
                                             list: { .array(rows.sorted { $0.key < $1.key }.map { .object(["name": .string($0.key), "size": .number(Double($0.value)!)]) }) },
                                             add: { args in rows[args.value("name")!] = args.value("size")!; return .null },
                                             remove: { args throws(ControlError) in rows[try args.word(0, "name")] = nil; return .null }))
        _ = await rig.ask("add", "things", "--name", "new", "--size", "2", "--plan")
        _ = await rig.ask("add", "things", "--name", "old", "--size", "9", "--plan")
        _ = await rig.ask("plan", "apply")
        #expect(rig.verbs.plan.lastApplied.map(\.undo) == [.requests([ControlRequest(verb: "remove", args: ["things", "new"])]),
                                                           .cannot("it changed the old row that was there; its old fields are not kept")])
        #expect(await rig.ask("undo").ok && rows == ["old": "9"])

        _ = await rig.ask("remove", "things", "old", "--plan")
        _ = await rig.ask("plan", "apply")
        #expect(rig.verbs.plan.lastApplied.first?.undo == .requests([ControlRequest(verb: "add", args: ["things", "--name", "old", "--size", "9"])]))
        #expect(rows.isEmpty)
        #expect(await rig.ask("undo").ok && rows == ["old": "9"])
    }

    @Test("A value as the word that sets it again", arguments: [
        (JSONValue.bool(true), "on"), (.number(640), "640"), (.number(0.5), "0.5"), (.array([.string("a"), .string("b")]), "a,b"), (.string("x y"), "x y"),
    ])
    func words(_ value: JSONValue, _ word: String) {
        #expect(ControlPlan.word(value) == word)
        #expect(ControlPlan.word(.null) == nil)
    }
}
