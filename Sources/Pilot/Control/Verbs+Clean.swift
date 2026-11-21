import Foundation
import PilotCore

extension ControlVerbs {
    /// `clean`: Hyper+Space › Clean through Mole, and Update & Clean's ticked list (W89). The list is Mole's read-only dry
    /// run, shared with the menu and kept 15 minutes, each path it would remove with its id; `clean <id>…` asks Allow
    /// with what goes, then moves only those paths to the Trash. `run` (Mole's whole clean) and Disk usage ask Allow with
    /// the exact command, then run in the visible terminal.
    func registerClean(_ jobs: ControlJobs) {
        let words = ["list", "preview", "run", "analyze"], subcommands = words + ["<id>…"]
        register(ControlVerb("clean", help: "What Clean would remove, part by part with each path's id and size (Mole's read-only preview); the ids you name moved to the Trash after Allow; or Mole's whole clean or Disk usage after Allow, as the menu's Clean does (Hyper+Space › Clean and Mac › Update & Clean tick them, one set of ticks).",
                             usage: "pilot clean [list] [--wait] | clean <id> [<id>…] | clean run | clean analyze",
                             flags: [.init("wait", help: "list: waits for Mole's dry run to finish (a minute or two, at most 15 min) rather than answering its progress", takesValue: false)],
                             schema: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             index: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             detail: { word in
                                 switch word {
                                 case "list", "preview": "pilot clean [list] [--wait]: what Mole's dry run says it would remove, each part with its total and each path with its id, size and tick (ticked until unticked in Hyper+Space or on Update & Clean); removes nothing, and starts the run when none is kept. preview is the same"
                                 case "<id>…": "pilot clean <id> [<id>…]: asks Allow with the paths, then moves only those to the Trash, one at a time; a path that fails says why and the rest go on. Ids come from the kept list; pilot clean lists them"
                                 case "run": "pilot clean run: asks Allow with mo clean, then Mole cleans everything it listed in a terminal window, where it asks for your password; answers the run's report"
                                 case "analyze": "pilot clean analyze: asks Allow, then opens Mole's disk explorer in a terminal window; it needs the user's hands"
                                 default: nil
                                 }
                             }) { call throws(ControlError) in
            let args = call.arguments()
            let sub = args.positional.first ?? "list"
            let ids = args.positional.filter(Self.isCleanID)
            guard words.contains(sub) || (!ids.isEmpty && ids.count == args.positional.count) else {
                throw ControlError(.badValue, "no clean \(sub); subcommands: \(subcommands.joined(separator: ", ")); pilot clean lists the ids")
            }
            guard jobs.mole() != nil else {
                throw ControlError(.notReady, "Mole is not installed; pilot install helper mole installs it after Allow")
            }
            switch sub {
            case "list", "preview": return await Self.cleanPreview(jobs, wait: args.has("wait"))
            case "run":
                return try await jobs.gate.allow(ControlGate.Ask("Clean", Mole.clean), peer: call.peer) { () throws(ControlError) in
                    // The report keeps what the preview listed, before the clean drops it (CleanModule.pick).
                    let report = RunReport.clean(command: Mole.clean, preview: jobs.previewer.ready)
                    jobs.previewer.drop()
                    jobs.terminal(Mole.clean, "Clean", VisibleRun.waitForReturn, report)
                    return Self.started(Mole.clean, report: report.id, in: jobs.store)
                }
            case "analyze":
                return try await jobs.gate.allow(ControlGate.Ask("Disk usage", Mole.analyze), peer: call.peer) { () throws(ControlError) in
                    jobs.terminal(Mole.analyze, "Disk usage", "true", nil)
                    return .object(["ran": .string(Mole.analyze), "opens": .string("window"),
                                    "note": .string("Mole's disk explorer is open in a terminal window; the rest needs the user's hands, and it asks before it moves anything to the Trash")])
                }
            default: return try await Self.cleanTicked(ids, jobs, peer: call.peer)
            }
        })
    }

    /// A row's id: CleanList.id's 10 hex digits.
    private static func isCleanID(_ word: String) -> Bool { word.count == 10 && word.allSatisfy(\.isHexDigit) }

    /// Moves the rows `ids` name to the Trash after Allow; every id must be in the kept list, so nothing else can go.
    private static func cleanTicked(_ ids: [String], _ jobs: ControlJobs, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard let list = jobs.previewer.ready?.list else {
            throw ControlError(.notReady, "no list is kept; pilot clean --wait lists what Clean would remove and its ids")
        }
        let listed = Set(list.rows.map(\.id))
        if let unknown = ids.first(where: { !listed.contains($0) }) {
            throw ControlError(.badValue, "no path \(unknown) in the kept list; pilot clean lists the ids")
        }
        return try await jobs.gate.allow(Self.trashAsk(ids, jobs), peer: peer) { () throws(ControlError) in
            guard let outcome = await jobs.trash(ids) else {
                throw ControlError(.notReady, "the list ran out while asking; pilot clean --wait lists it again")
            }
            let home = CleanModule.home
            return .object([
                "moved": .array(outcome.moved.map { .object(["id": .string($0.id), "path": .string(AppConfigs.tilde($0.path, home: home)), "size": .string($0.size)]) }),
                "failed": .array(outcome.failed.map { .object(["id": .string($0.row.id), "path": .string(AppConfigs.tilde($0.row.path, home: home)), "why": .string($0.why)]) }),
                "toTrash": .string(RemoveList.size(outcome.bytes)),
                "summary": .string(outcome.summary),
                "left": .number(Double(jobs.previewer.ready?.list.rows.count ?? 0)),
                "report": outcome.report.map(JSONValue.string) ?? .null,
                "note": .string("in the Trash, so the space comes back once it is emptied; pilot clean lists what is left"),
            ])
        }
    }

    /// The question for `ids`, read again after Allow: the paths that go, as many as the prompt shows whole, then how
    /// many more.
    private static func trashAsk(_ ids: [String], _ jobs: ControlJobs) -> ControlGate.Ask {
        let rows = jobs.previewer.ready?.list.rows(ids) ?? [], home = CleanModule.home
        let n = rows.count, total = RemoveList.size(CleanList.bytes(rows))
        var lines = ["Moves \(n) path\(n == 1 ? "" : "s"), \(total), to the Trash; nothing else Mole listed is touched:"], length = lines[0].count
        for (i, row) in rows.enumerated() {
            let line = "\(AppConfigs.tilde(row.path, home: home)) (\(row.size))"
            guard lines.count < 15, length + line.count < 900 else { lines.append("and \(n - i) more"); break }
            lines.append(line)
            length += line.count + 1
        }
        return ControlGate.Ask("Clean", lines: lines).summed("Move \(n) path\(n == 1 ? "" : "s") to the Trash?", ["\(total) from Mole's list; the Trash keeps them until it is emptied"])
    }

    /// The kept preview; else Mole's run, waited on with `wait`, or started (or joined) and its progress answered.
    private static func cleanPreview(_ jobs: ControlJobs, wait: Bool) async -> JSONValue {
        if let ready = jobs.previewer.ready { return preview(ready, unticked: jobs.previewer.unticked) }
        let run = Task { await jobs.previewer.preview(caller: "pilot clean preview") }
        guard wait else {
            // The run is under way once the main actor lets it start; its progress shows from then.
            await Task.yield()
            let progress = jobs.previewer.progress
            return .object(["state": .string("running"), "section": progress?.section.map(JSONValue.string) ?? .null,
                            "found": .number(Double(progress?.items ?? 0)), "note": .string(CleanMenu.waiting(progress))])
        }
        guard let preview = await run.value else {
            return .object(["state": .string("failed"), "note": .string("Mole's preview did not finish; pilot clean preview tries again")])
        }
        return Self.preview(preview, unticked: jobs.previewer.unticked)
    }

    /// Mole's own lines as `items`, as before W89, then its file list as `parts`: each with its total and every path's id,
    /// size and tick (every one ticked until it is unticked in Hyper+Space or on Update & Clean), and the ticked total.
    private static func preview(_ p: CleanPreview, unticked: Set<String>) -> JSONValue {
        let home = CleanModule.home, ticked = p.list.rows.filter { !unticked.contains($0.id) }
        let parts = p.list.parts.map { part -> JSONValue in
            .object(["part": .string(part.name), "total": .string(RemoveList.size(part.bytes)), "count": .number(Double(part.rows.count)),
                     "rows": .array(part.rows.map { r in
                         .object(["id": .string(r.id), "path": .string(AppConfigs.tilde(r.path, home: home)), "size": .string(r.size),
                                  "items": .number(Double(r.count)), "ticked": .bool(!unticked.contains(r.id))])
                     })])
        }
        return .object(["state": .string("ready"), "total": p.total.map(JSONValue.string) ?? .null, "systemSkipped": .bool(p.systemSkipped),
                        "items": .array(p.items.map { .object(["section": .string($0.section), "title": .string($0.title), "detail": .string($0.detail)]) }),
                        "parts": .array(parts), "ticked": .string(RemoveList.size(CleanList.bytes(ticked))),
                        "cleanTicked": .string("pilot clean <id> [<id>…]"), "clean": .string(Mole.clean)])
    }
}
