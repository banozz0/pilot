import Foundation
import Observation

/// The plan (Ask Pilot G1, Sven Q178, 2026-10-16): changes collected instead of applied, then asked once. `--plan` on a
/// verb that plans (bind, unbind, set, add, remove) collects its change; a request from Pilot's AI agent always does.
/// `pilot plan apply` shows every row as one question through the Allow gate, and one Allow applies them all in order,
/// each answered with what it reads back. Edits that ask Allow on their own today (installs, secrets, a collection
/// edit that asks) are not planned: they ask as before. One plan per Pilot, kept across a chat's turns; apply, a
/// denial, `pilot plan clear` and New chat empty it. `pilot undo` (G5) puts back what the last apply changed, after one
/// Allow of its own; it is one step, with no redo, and outlives New chat, since the change it reverts does.
@Observable @MainActor
public final class ControlPlan {
    /// What a verb's dry run says it would change, read from the live stores; nothing is changed making it.
    public struct Draft: Equatable, Sendable {
        /// "Bind Open Linear", "Set menu.width", "Add to aliases".
        public var what: String
        /// "none", "640", "–".
        public var old: String
        public var new: String
        /// The key a bind would take, as its label: "Hyper+L".
        public var key: String?
        /// Whether no action holds that key now.
        public var free: Bool?
        /// The question the change asks today (a shell bind's command, a confirmed setting): shown on the plan and
        /// allowed by its Allow, matched exactly when the change runs.
        public var asks: ControlGate.Ask?
        /// What reads the change back once applied, when its own answer does not (set's get).
        public var readback: ControlRequest?

        public init(_ what: String, old: String, new: String, key: String? = nil, free: Bool? = nil, asks: ControlGate.Ask? = nil,
                    readback: ControlRequest? = nil) {
            self.what = what; self.old = old; self.new = new; self.key = key; self.free = free; self.asks = asks; self.readback = readback
        }
    }

    /// What puts a change back: the requests, in order (none when it changed nothing), or why it cannot be.
    public enum Undo: Equatable, Sendable {
        case requests([ControlRequest])
        case cannot(String)
    }

    /// A row the last apply changed, with what puts it back, read just before it ran.
    public struct Applied: Equatable, Sendable {
        public let change: Change
        public let undo: Undo
    }

    /// One row of the plan: its draft, and the request that applies it.
    public struct Change: Equatable, Sendable, Identifiable {
        public let id: Int
        public let draft: Draft
        /// The request as sent, `--plan` and any secret left out; re-run as it is on apply.
        public let request: ControlRequest

        public var what: String { draft.what }
        public var old: String { draft.old }
        public var new: String { draft.new }
        public var key: String? { draft.key }
        public var free: Bool? { draft.free }
        public var asks: ControlGate.Ask? { draft.asks }

        /// "Bind Open Linear: none → Hyper+L, free"; a change that asks today names its question.
        public var line: String {
            "\(what): \(old) → \(new)" + (free == true ? ", free" : "") + (asks.map { " (\($0.text))" } ?? "")
        }

        var json: JSONValue { .object(fields) }

        var fields: [String: JSONValue] {
            var row: [String: JSONValue] = ["id": .number(Double(id)), "what": .string(what), "old": .string(old), "new": .string(new),
                                            "command": .string((["pilot", request.verb] + request.args).joined(separator: " "))]
            row["key"] = key.map(JSONValue.string)
            row["free"] = free.map(JSONValue.bool)
            row["asks"] = asks.map { .string($0.text) }
            return row
        }
    }

    public private(set) var changes: [Change] = []
    /// What the last `pilot plan apply` changed, for `pilot undo`; empty once undone.
    public internal(set) var lastApplied: [Applied] = []
    @ObservationIgnored private var next = 1

    public init() {}

    public func clear() { changes = [] }

    /// The one question the plan asks: every row a line, so the HUD and the chat show each whole.
    public var ask: ControlGate.Ask { Self.ask(changes) }

    static func ask(_ changes: [Change], _ verb: String = "Apply") -> ControlGate.Ask {
        ControlGate.Ask("\(verb) \(changes.count) \(changes.count == 1 ? "change" : "changes")",
                        changes.map(\.line).joined(separator: "\n"), rows: changes)
    }

    /// A value as the command's word that sets it again: "on", "640", "a,b"; nil for none or an object.
    nonisolated public static func word(_ value: JSONValue) -> String? {
        switch value {
        case .string(let word): word
        case .bool(let on): on ? "on" : "off"
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .array(let items): items.compactMap(word).joined(separator: ",")
        case .null, .object: nil
        }
    }

    /// Adds `draft` as a row, the same request again replacing its row; refused once the question would be too long to
    /// show whole, since the gate denies one it cannot show.
    func add(_ draft: Draft, request: ControlRequest) throws(ControlError) -> JSONValue {
        var request = request
        request.id = nil
        request.secret = nil
        var rows = changes.filter { $0.request != request }
        let change = Change(id: next, draft: draft, request: request)
        rows.append(change)
        if let tooLong = Self.ask(rows).tooLong {
            throw ControlError(.outOfRange, "not planned: \(tooLong); pilot plan apply or pilot plan clear first")
        }
        next += 1
        changes = rows
        return .object(["planned": change.json, "waiting": .number(Double(rows.count)), "applied": .bool(false),
                        "next": .string("nothing changed yet: pilot plan apply asks the user once and applies every row")])
    }

    var listed: JSONValue { .array(changes.map(\.json)) }
}

/// The asks a plan's Allow covers while it applies, task-local so only the plan's own requests see them: the gate and
/// set's confirm let an ask through only when it is one of these, exactly.
public enum ControlApproval {
    @TaskLocal public static var asks: [ControlGate.Ask] = []

    public static func covers(_ ask: ControlGate.Ask) -> Bool { asks.contains(ask) }
}

extension ControlVerbs {
    /// Takes `--plan` out of `words` (before a `--`), true when it was there.
    static func takePlanFlag(_ words: inout [String]) -> Bool {
        let end = words.firstIndex(of: "--") ?? words.endIndex
        guard words[..<end].contains("--plan") else { return false }
        words = words[..<end].filter { $0 != "--plan" } + words[end...]
        return true
    }

    /// `pilot plan`: the rows waiting, `apply` to ask once and apply them, `clear` to drop them. `gate` asks the question.
    public func registerPlan(gate: ControlGate) {
        register(ControlVerb("plan", help: "The changes waiting on one Allow: --plan on bind, unbind, set, add and remove collects them (the AI chat's always are); apply asks once and applies them all, clear drops them.",
                             usage: "pilot plan [apply | clear]", flags: []) { [unowned self] call throws(ControlError) in
            switch call.words.first {
            case nil: return plan.listed
            case "clear":
                plan.clear()
                return .object(["cleared": .bool(true)])
            case "apply": return try await apply(gate: gate, peer: call.peer)
            case let word?: throw ControlError(.badRequest, "pilot plan takes apply or clear, not \(word)")
            }
        })
        register(ControlVerb("undo", help: "Puts back what the last pilot plan apply changed, after one Allow; a change with no way back is named.",
                             usage: "pilot undo", flags: []) { [unowned self] call throws(ControlError) in
            try await undo(gate: gate, peer: call.peer)
        })
    }

    /// Asks the plan's question once; on Allow applies each row in order with the asks it showed allowed, a row that
    /// fails now (a key taken since) answering its error while the rest still apply, and keeps what puts each back for
    /// `pilot undo`. Denied, nothing runs and the plan empties.
    private func apply(gate: ControlGate, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let shown = plan.changes
        guard !shown.isEmpty else { throw ControlError(.badRequest, "nothing planned: add --plan to bind, unbind, set, add or remove first") }
        do throws(ControlError) {
            return try await gate.allow(plan.changes.isEmpty ? nil : plan.ask, peer: peer) { () throws(ControlError) in
                plan.clear()
                let (rows, done) = await ControlApproval.$asks.withValue(shown.compactMap(\.asks)) { await applied(shown, peer: peer) }
                plan.lastApplied = done
                return .object(["applied": .number(Double(done.count)), "rows": .array(rows.map(JSONValue.object))])
            }
        } catch {
            plan.clear()
            throw error
        }
    }

    /// `pilot undo`: the last apply's rows put back, the last first, each inverse dry-run as a planned row is so the card
    /// names it and its own question; a row with no way back is named, never dropped. One Allow, then the plan is spent.
    private func undo(gate: ControlGate, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard plan.changes.isEmpty else { throw ControlError(.badRequest, "a plan is waiting: pilot plan apply or pilot plan clear first") }
        let last = plan.lastApplied
        guard !last.isEmpty else { throw ControlError(.badRequest, "nothing to undo: pilot undo puts back the last pilot plan apply") }
        var changes: [ControlPlan.Change] = [], skipped: [(what: String, why: String)] = []
        for row in last.reversed() {
            guard case .requests(let requests) = row.undo else {
                if case .cannot(let why) = row.undo { skipped.append((row.change.what, why)) }
                continue
            }
            for request in requests {
                do throws(ControlError) {
                    guard let draft = try await dryRun(request, peer: peer) else { skipped.append((row.change.what, "putting it back asks Allow on its own")); continue }
                    changes.append(ControlPlan.Change(id: changes.count + 1, draft: draft, request: request))
                } catch {
                    skipped.append((row.change.what, error.message))
                }
            }
        }
        guard !changes.isEmpty else {
            plan.lastApplied = []
            throw ControlError(.badValue, "nothing can be put back: \(skipped.map(\.why).joined(separator: "; "))")
        }
        let ask = ControlPlan.ask(changes, "Undo")
        // Never nil, which would run unasked: a plan applied while the card was up changes the question, which denies.
        return try await gate.allow(plan.lastApplied == last ? ask : ControlGate.Ask("Undo", "the last plan changed while asking"), peer: peer) { () throws(ControlError) in
            plan.lastApplied = []
            let (rows, done) = await ControlApproval.$asks.withValue(changes.compactMap(\.asks)) { await applied(changes, peer: peer, keeping: false) }
            return .object(["undone": .number(Double(done.count)), "rows": .array(rows.map(JSONValue.object)),
                            "skipped": .array(skipped.map { .object(["what": .string($0.what), "why": .string($0.why)]) })])
        }
    }

    /// The verb's dry run of `request`, as it would plan now.
    private func dryRun(_ request: ControlRequest, peer: ControlPeer?) async throws(ControlError) -> ControlPlan.Draft? {
        let verb = try verb(request.verb)
        guard let planner = verb.plan else { return nil }
        return try await planner(ControlCall(words: request.args, cwd: request.cwd, peer: peer, switches: verb.switches))
    }

    /// What puts `request`'s change back, read now; why not, when its verb cannot say.
    private func inverse(_ request: ControlRequest, peer: ControlPeer?) async -> ControlPlan.Undo {
        guard let verb = verbs[request.verb], let inverse = verb.inverse else { return .cannot("pilot \(request.verb) has no undo") }
        do throws(ControlError) {
            return try await inverse(ControlCall(words: request.args, cwd: request.cwd, peer: peer, switches: verb.switches))
        } catch {
            return .cannot(error.message)
        }
    }

    /// Each row applied in order and read back, with the rows that changed; `keeping` also reads what puts each back,
    /// just before it runs, so it is the state it replaced.
    private func applied(_ changes: [ControlPlan.Change], peer: ControlPeer?, keeping: Bool = true) async -> (rows: [[String: JSONValue]], done: [ControlPlan.Applied]) {
        var rows: [[String: JSONValue]] = [], done: [ControlPlan.Applied] = []
        for change in changes {
            var row = change.fields
            let undo = keeping ? await inverse(change.request, peer: peer) : .requests([])
            let answered = await answer(change.request, peer: peer, applying: true)
            if let error = answered.error {
                row["error"] = .string(error.message)
            } else if let readback = change.draft.readback {
                let read = await answer(readback, peer: peer, applying: true)
                row["now"] = read.result ?? .string(read.error?.message ?? "not read")
            } else {
                row["now"] = answered.result ?? .null
            }
            if answered.error == nil { done.append(ControlPlan.Applied(change: change, undo: undo)) }
            rows.append(row)
        }
        return (rows, done)
    }
}
