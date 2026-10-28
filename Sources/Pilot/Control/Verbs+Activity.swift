import PilotCore

/// What `pilot processes` and `pilot quit` reach (CLI W9): Activity's reader and its quit, as the Activity page uses them.
/// The tests hand in their own reader and quit, so nothing on this Mac is listed or signalled.
@MainActor
final class ControlActivity {
    var monitor = ActivityMonitor.shared
    var gate = AllowPrompt.gate
    /// Quits a row as the page's Quit and Force quit do; false when macOS refused it or it is gone.
    var quit: @MainActor (Activity.Row, Bool) -> Bool = { ActivityMonitor.shared.quit($0, force: $1) }
    /// How long a sent quit is watched for the row to go: the page reads again a second after a quit.
    var settle: Duration = .seconds(2)

    /// A fresh read, as the page's next tick would give; not-ready when ps could not be read and nothing was read before.
    func snapshot() async throws(ControlError) -> Activity.Snapshot {
        guard await monitor.refresh() || monitor.hasRead else { throw ControlError(.notReady, "ps could not be read, so nothing is listed") }
        return monitor.snapshot
    }

    /// The row a pid or a row id names, an app's helper included.
    static func row(_ word: String, in snapshot: Activity.Snapshot) -> Activity.Row? {
        snapshot.row(word) ?? snapshot.row("app." + word) ?? snapshot.row("pid." + word)
    }

    /// The page's confirm, as an Allow question: what the quit does to it.
    static func ask(_ row: Activity.Row, force: Bool) -> ControlGate.Ask {
        let what = force ? "Anything unsaved in it is lost."
            : row.kind == .app ? "It may ask to save first."
            : row.rights == .quitOnly ? "macOS starts it again when it needs it." : nil
        return ControlGate.Ask((force ? "Force quit " : "Quit ") + row.name, (["pid \(row.pid)."] + [what].compactMap(\.self)).joined(separator: " "))
    }

    /// Why the page shows no Quit (or no Force quit) on `row`, nil when it does.
    static func refusal(_ row: Activity.Row, force: Bool) -> String? {
        if case .none(let reason) = row.rights {
            return reason == .pilot ? "\(row.name) is Pilot, or Pilot started it; quit Pilot from its menu"
                : "Pilot can't quit \(row.name): \(reason == .macOS ? "macOS needs it" : "it is the system's or another user's")"
        }
        if force && !row.rights.canForce { return "\(row.name) is macOS's own: quit it without --force, macOS starts it again" }
        return nil
    }

    /// One row as the page shows it: its cost, its heat, what Pilot may do to it, and an app's helpers under it.
    func entry(_ row: Activity.Row, quitting: Set<String>) -> JSONValue {
        var entry: [String: JSONValue] = [
            "id": .string(row.id), "kind": .string(row.kind == .app ? "app" : "process"), "pid": .number(Double(row.pid)),
            "name": .string(row.name), "cpu": .number((row.cpu * 10).rounded() / 10), "memory": .number(Double(row.memory)),
            "memoryText": .string(Activity.memoryText(row.memory)),
            "heat": .string(String(describing: Activity.heat(cpu: row.cpu, memory: row.memory, physicalMemory: monitor.physicalMemory))),
            "quit": .bool(row.rights.canQuit), "force": .bool(row.rights.canForce),
        ]
        entry["bundlePath"] = row.bundlePath.map(JSONValue.string)
        if case .none(let reason) = row.rights { entry["locked"] = .string(reason.rawValue) }
        if row.rights == .quitOnly { entry["owner"] = .string("macOS") }
        if quitting.contains(row.id) { entry["quitting"] = .bool(true) }
        if row.kind == .app {
            entry["processes"] = .number(Double(row.processCount))
            entry["helpers"] = .array(row.children.map { self.entry($0, quitting: quitting) })
        }
        return .object(entry)
    }

    /// Reads until `id` is no longer listed or `settle` passes: false once it has gone.
    func stillRunning(_ id: String) async -> Bool {
        let clock = ContinuousClock(), end = clock.now.advanced(by: settle)
        while clock.now < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if await monitor.refresh(), monitor.snapshot.row(id) == nil { return false }
        }
        return true
    }
}

extension ControlVerbs {
    /// `processes` and `quit` over Activity, then `stats` over the sampler: the Mac › Activity and Stats pages.
    func registerActivity(_ app: ControlActivity, stats: ControlStats) {
        let sorts = Activity.Sort.allCases.map(\.rawValue)
        register(ControlVerb("processes", help: "What runs on this Mac, as Activity lists it: apps with their helpers, then the background.",
                             usage: "pilot processes [--sort cpu|memory] [--query <text>] [--limit <n>]",
                             flags: [.init("sort", help: "heaviest first by \(sorts.joined(separator: " or ")); cpu when left out"),
                                     .init("query", help: "rows whose name holds it (any case) or whose pid it is; an app keeps the helpers that match"),
                                     .init("limit", help: "at most this many rows in each of apps and background")],
                             schema: {
                                 .object(["sorts": .array(sorts.map(JSONValue.string)), "rows": .object([
                                     "id": .string("app.<pid> or pid.<pid>; pilot quit takes it or the pid"),
                                     "kind": .string("app (a Dock app, its helpers summed in) or process"),
                                     "cpu": .string("percent of one core, as Activity Monitor counts it"),
                                     "memory": .string("bytes; memoryText as the page words it"),
                                     "heat": .string("calm, busy or hog: the page's Heavy chip is hog"),
                                     "quit": .string("true: pilot quit may quit it"), "force": .string("true: pilot quit --force may force it"),
                                     "locked": .string("why Pilot may not quit it: System, Needed by macOS or Pilot"),
                                     "owner": .string("macOS: its own program, asked to quit and started again, never forced"),
                                     "quitting": .string("true: asked to quit and still listed"),
                                     "helpers": .string("an app's own processes, rows of the same shape"),
                                 ])])
                             },
                             index: { .object(["sorts": .array(sorts.map(JSONValue.string))]) }) { call throws(ControlError) in
            let args = call.arguments()
            let sortWord = args.value("sort") ?? Activity.Sort.cpu.rawValue
            guard let sort = Activity.Sort(rawValue: sortWord) else {
                throw ControlError(.badValue, "no sort \(sortWord); sorts: \(sorts.joined(separator: ", "))")
            }
            let limit: Int?
            if let word = args.value("limit") {
                guard let n = Int(word), n > 0 else { throw ControlError(.outOfRange, "--limit takes a whole number above 0, not \(word)") }
                limit = n
            } else { limit = nil }
            let query = args.value("query") ?? ""
            let shown = Activity.sorted(Activity.filtered(try await app.snapshot(), query: query), by: sort)
            let quitting = app.monitor.quitting
            let section = { @MainActor (rows: [Activity.Row]) in JSONValue.array(rows.prefix(limit ?? rows.count).map { app.entry($0, quitting: quitting) }) }
            var answer: [String: JSONValue] = ["sort": .string(sort.rawValue), "apps": section(shown.apps), "background": section(shown.background),
                                               "counts": .object(["apps": .number(Double(shown.apps.count)), "background": .number(Double(shown.background.count))])]
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { answer["query"] = .string(query) }
            return .object(answer)
        })
        register(ControlVerb("quit", help: "Quits an app or process by pid or row id, after Allow, as Activity's Quit and Force quit do.",
                             usage: "pilot quit <pid|id> [--force]",
                             flags: [.init("force", help: "force quit: at once, anything unsaved in it is lost", takesValue: false)],
                             detail: { word throws(ControlError) in
                                 guard let row = ControlActivity.row(word, in: app.monitor.snapshot) else { return nil }
                                 return ["\(row.id): \(row.name)", ControlActivity.refusal(row, force: false) ?? "asks Allow: \(ControlActivity.ask(row, force: false).text)",
                                         row.rights.canForce ? "--force asks Allow: \(ControlActivity.ask(row, force: true).text)" : nil].compactMap(\.self).joined(separator: "\n")
                             }) { call throws(ControlError) in
            let args = call.arguments()
            let word = try args.word(0, "pid or id (pilot processes lists them)")
            let force = args.has("force")
            guard let row = ControlActivity.row(word, in: try await app.snapshot()) else {
                throw ControlError(.badValue, "nothing runs as \(word); pilot processes lists what does")
            }
            // What the page shows no button for is refused before Sven is asked.
            if let refusal = ControlActivity.refusal(row, force: force) { throw ControlError(.badValue, refusal) }
            let ask = ControlActivity.ask(row, force: force)
            return try await app.gate.allow(ask, peer: call.peer) { () throws(ControlError) in
                let sent = app.quit(row, force)
                log.notice("quit: \(row.name, privacy: .public) pid \(row.pid)\(force ? " forced" : "", privacy: .public), from the pilot command")
                var answer: [String: JSONValue] = ["id": .string(row.id), "name": .string(row.name), "pid": .number(Double(row.pid)),
                                                   "force": .bool(force), "sent": .bool(sent)]
                if sent {
                    let running = await app.stillRunning(row.id)
                    answer["running"] = .bool(running)
                    if running, row.kind == .app, !force { answer["note"] = .string("still running: it may be asking to save; pilot quit --force ends it") }
                } else {
                    answer["error"] = .string("\(row.name) is gone or not yours to quit")
                }
                return .object(answer)
            }
        })
        registerStats(stats)
    }
}
