import Foundation

/// Who asked, read off the socket: the Allow prompt names the program (ADR 0013).
public struct ControlPeer: Equatable, Sendable {
    public let pid: pid_t
    public let uid: uid_t
    public init(pid: pid_t, uid: uid_t) { self.pid = pid; self.uid = uid }
}

/// One request as a verb's handler sees it.
public struct ControlCall: Sendable {
    /// The command's words after the verb, as typed.
    public let words: [String]
    public let cwd: String?
    public let peer: ControlPeer?
    /// The switches the verb declares, so `arguments()` parses them without being told again.
    public let switches: Set<String>
    /// The request's secret, read from the command's stdin; never put in a message, a prompt or a log line.
    public let secret: String?
    /// The request came from Pilot's AI agent (ControlRequest.agent).
    public let agent: Bool

    public init(words: [String], cwd: String? = nil, peer: ControlPeer? = nil, switches: Set<String> = [], secret: String? = nil, agent: Bool = false) {
        self.words = words; self.cwd = cwd; self.peer = peer; self.switches = switches; self.secret = secret; self.agent = agent
    }

    /// The words parsed; `switches`, with the verb's declared ones, are the flags that never take a value.
    public func arguments(switches more: Set<String> = []) -> ControlArguments { ControlArguments(words, switches: switches.union(more)) }
}

/// One thing the pilot command can ask. The handler runs on the main actor; slow work awaits off it, so nothing on
/// this path blocks the tap's run loop.
public struct ControlVerb: Sendable {
    public typealias Handler = @Sendable @MainActor (ControlCall) async throws(ControlError) -> JSONValue
    /// The verb's dry run (ControlPlan): what the call would change, checked as the handler checks it and nothing
    /// changed; nil for a call that is not planned (it asks Allow on its own), which then runs as it is.
    public typealias Planner = @Sendable @MainActor (ControlCall) async throws(ControlError) -> ControlPlan.Draft?
    /// What puts the call's change back, read just before a plan applies it (pilot undo).
    public typealias Inverter = @Sendable @MainActor (ControlCall) async throws(ControlError) -> ControlPlan.Undo

    /// A `--flag` the verb takes: with a value, or bare (a switch, which never takes the next word).
    public struct Flag: Sendable {
        public let name: String
        public let help: String
        public let takesValue: Bool
        public init(_ name: String, help: String, takesValue: Bool = true) { self.name = name; self.help = help; self.takesValue = takesValue }
    }

    public let name: String
    /// One line: what it does.
    public let help: String
    /// "pilot get <key>".
    public let usage: String
    /// Every flag the verb takes; any other is refused with unknown-flag before the handler runs. Nil takes any flag,
    /// as verbs did before flags were declared.
    public let flags: [Flag]?
    /// The verb's part of `pilot schema` (its keys, collections, pages), read when asked so it is never stale.
    public let schema: (@Sendable @MainActor () -> JSONValue)?
    /// A short, cheap summary of the part for `pilot schema --index` (the names a caller asks for next); the part
    /// itself is never built there.
    public let index: (@Sendable @MainActor () -> JSONValue)?
    /// `pilot help <verb> <word>`: more about one thing the verb takes, nil when the word means nothing to it.
    public let detail: (@Sendable @MainActor (String) throws(ControlError) -> String?)?
    /// With one, the verb takes `--plan`, and the AI agent's calls are always planned.
    public let plan: Planner?
    /// With none, an applied change of the verb cannot be undone.
    public let inverse: Inverter?
    public let handler: Handler

    public init(_ name: String, help: String, usage: String? = nil, flags: [Flag]? = nil,
                schema: (@Sendable @MainActor () -> JSONValue)? = nil, index: (@Sendable @MainActor () -> JSONValue)? = nil,
                detail: (@Sendable @MainActor (String) throws(ControlError) -> String?)? = nil, plan: Planner? = nil,
                inverse: Inverter? = nil, handler: @escaping Handler) {
        self.name = name; self.help = help; self.usage = usage ?? "pilot \(name)"
        self.flags = plan == nil ? flags : flags.map { $0 + [Flag("plan", help: "collect the change into pilot plan instead of making it", takesValue: false)] }
        self.schema = schema; self.index = index; self.detail = detail; self.plan = plan; self.inverse = inverse; self.handler = handler
    }

    /// The switches among `flags`.
    var switches: Set<String> { Set((flags ?? []).filter { !$0.takesValue }.map(\.name)) }

    /// Help's two columns: each name padded to the longest, then its text.
    public static func columns(_ rows: [(name: String, text: String)], prefix: String = "") -> [String] {
        let width = rows.map(\.name.count).max() ?? 0
        return rows.map { prefix + $0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.text }
    }

    /// Unknown-flag for the first of `given` not among `known`, naming the ones taken; nil when all are known.
    /// `--json` is the command's own and goes before the verb, so its refusal says so.
    public static func unknownFlag(_ given: Set<String>, known: [String], in place: String) -> ControlError? {
        guard let flag = given.subtracting(known).sorted().first else { return nil }
        let takes = known.isEmpty ? "no flags" : known.map { "--" + $0 }.joined(separator: ", ")
        let json = flag == "json" ? "; --json goes before the verb: pilot --json <verb> …" : ""
        return ControlError(.unknownFlag, "\(place) takes no --\(flag); it takes \(takes)\(json)")
    }
}

/// Every verb the socket answers. Each family registers its own from its module's file, as modules register their
/// actions, so no family edits another's file. The first collection brings `list`, `add` and `remove`, which route to
/// the collections.
@MainActor
public final class ControlVerbs {
    public private(set) var verbs: [String: ControlVerb] = [:]
    var collections: [String: ControlCollection] = [:]
    /// The changes waiting on one Allow (pilot plan).
    public let plan: ControlPlan

    public init(plan: ControlPlan = ControlPlan()) { self.plan = plan }

    /// A second verb on one name is a bug, caught by the first test that builds the registry.
    public func register(_ verb: ControlVerb) {
        precondition(verbs[verb.name] == nil, "control verb \(verb.name) registered twice")
        verbs[verb.name] = verb
    }

    /// The verb named, or unknown-verb.
    public func verb(_ name: String) throws(ControlError) -> ControlVerb {
        guard let verb = verbs[name] else { throw ControlError(.unknownVerb, "no verb \(name); pilot help lists them") }
        return verb
    }

    public var sorted: [ControlVerb] { verbs.values.sorted { $0.name < $1.name } }

    /// The answer to one request: the handler's result, or its typed error. A verb that plans collects the change into
    /// `plan` instead when asked `--plan` or asked by the AI agent; `applying` is a plan's own request, run as it is.
    public func answer(_ request: ControlRequest, peer: ControlPeer?) async -> ControlAnswer {
        await answer(request, peer: peer, applying: false)
    }

    func answer(_ request: ControlRequest, peer: ControlPeer?, applying: Bool) async -> ControlAnswer {
        do throws(ControlError) {
            let verb = try verb(request.verb)
            var words = request.args
            let planning = verb.plan != nil && Self.takePlanFlag(&words)
            let call = ControlCall(words: words, cwd: request.cwd, peer: peer, switches: verb.switches, secret: request.secret,
                                   agent: request.agent == true)
            if let flags = verb.flags, let refusal = ControlVerb.unknownFlag(call.arguments().flags, known: flags.map(\.name), in: "pilot \(verb.name)") {
                throw refusal
            }
            if let planner = verb.plan, !applying, planning || call.agent {
                if let draft = try await planner(call) {
                    var stored = request
                    stored.args = words
                    return .success(request.id, try plan.add(draft, request: stored))
                }
                if planning { throw ControlError(.badRequest, "not planned: this asks Allow on its own; run it without --plan") }
            }
            return .success(request.id, try await verb.handler(call))
        } catch {
            return .failure(request.id, error)
        }
    }

    /// `pilot schema`: every verb with its help, usage, flags (when it declares them) and part.
    public var schema: JSONValue { .object(["verbs": .array(sorted.map { entry($0, "schema", $0.schema?()) })]) }

    /// One verb's entry in `pilot schema`, part included.
    public func schema(verb name: String) throws(ControlError) -> JSONValue {
        let verb = try verb(name)
        return entry(verb, "schema", verb.schema?())
    }

    /// `pilot schema --index`: each verb's entry with its index summary in place of its part (list's names the
    /// collections, open's the pages), so a caller reads only the part it needs next.
    public var schemaIndex: JSONValue {
        .object([
            // A part with no summary is only marked: building it may read live state (the settings read every value).
            "verbs": .array(sorted.map { entry($0, "part", $0.index?() ?? ($0.schema == nil ? nil : .bool(true))) }),
            "next": .string("pilot schema --verb <verb> for one verb's part; pilot schema --collection <name> for one collection; pilot settings --page <page> for one page's settings, a page as open names it; pilot help <verb> in words"),
        ])
    }

    /// A verb's name, help, usage, declared flags, and `part` under `key`.
    private func entry(_ verb: ControlVerb, _ key: String, _ part: JSONValue?) -> JSONValue {
        var entry: [String: JSONValue] = ["name": .string(verb.name), "help": .string(verb.help), "usage": .string(verb.usage)]
        entry["flags"] = verb.flags.map { .array($0.map { .object(["name": .string($0.name), "help": .string($0.help), "value": .bool($0.takesValue)]) }) }
        entry[key] = part
        return .object(entry)
    }
}
