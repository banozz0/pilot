import Foundation
import PilotCore

extension ControlVerbs {
    /// `clean`: Hyper+Space › Clean through Mole. The preview is Mole's read-only dry run, shared with the menu and kept
    /// 15 minutes; the clean and Disk usage ask Allow with the exact command, then run in the visible terminal.
    func registerClean(_ jobs: ControlJobs) {
        let subcommands = ["preview", "run", "analyze"]
        register(ControlVerb("clean", help: "Mole's preview of what Clean would remove, and the clean or Disk usage after Allow, as the menu's Clean does (Mac › Update & Clean opens it too).",
                             usage: "pilot clean preview [--wait] | clean run | clean analyze",
                             flags: [.init("wait", help: "preview: waits for Mole's dry run to finish (a minute or two, at most 15 min) rather than answering its progress", takesValue: false)],
                             schema: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             index: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             detail: { word in
                                 switch word {
                                 case "preview": "pilot clean preview [--wait]: what Mole's dry run says it would remove and the potential space; starts the run when none is kept"
                                 case "run": "pilot clean run: asks Allow with mo clean, then cleans in a terminal window, where Mole asks for your password; answers the run's report"
                                 case "analyze": "pilot clean analyze: asks Allow, then opens Mole's disk explorer in a terminal window; it needs the user's hands"
                                 default: nil
                                 }
                             }) { call throws(ControlError) in
            let args = call.arguments()
            let sub = try args.word(0, "subcommand: \(subcommands.joined(separator: ", "))")
            guard subcommands.contains(sub) else { throw ControlError(.badValue, "no clean \(sub); subcommands: \(subcommands.joined(separator: ", "))") }
            guard jobs.mole() != nil else {
                throw ControlError(.notReady, "Mole is not installed; pilot install helper mole installs it after Allow")
            }
            switch sub {
            case "preview": return await Self.cleanPreview(jobs, wait: args.has("wait"))
            case "run":
                return try await jobs.gate.allow(ControlGate.Ask("Clean", Mole.clean), peer: call.peer) { () throws(ControlError) in
                    // The report keeps what the preview listed, before the clean drops it (CleanModule.pick).
                    let report = RunReport.clean(command: Mole.clean, preview: jobs.previewer.ready)
                    jobs.previewer.drop()
                    jobs.terminal(Mole.clean, "Clean", VisibleRun.waitForReturn, report)
                    return Self.started(Mole.clean, report: report.id, in: jobs.store)
                }
            default:
                return try await jobs.gate.allow(ControlGate.Ask("Disk usage", Mole.analyze), peer: call.peer) { () throws(ControlError) in
                    jobs.terminal(Mole.analyze, "Disk usage", "true", nil)
                    return .object(["ran": .string(Mole.analyze), "opens": .string("window"),
                                    "note": .string("Mole's disk explorer is open in a terminal window; the rest needs the user's hands, and it asks before it moves anything to the Trash")])
                }
            }
        })
    }

    /// The kept preview; else Mole's run, waited on with `wait`, or started (or joined) and its progress answered.
    private static func cleanPreview(_ jobs: ControlJobs, wait: Bool) async -> JSONValue {
        if let ready = jobs.previewer.ready { return preview(ready) }
        let run = Task { await jobs.previewer.preview() }
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
        return Self.preview(preview)
    }

    private static func preview(_ p: CleanPreview) -> JSONValue {
        .object(["state": .string("ready"), "total": p.total.map(JSONValue.string) ?? .null, "systemSkipped": .bool(p.systemSkipped),
                 "items": .array(p.items.map { .object(["section": .string($0.section), "title": .string($0.title), "detail": .string($0.detail)]) }),
                 "clean": .string(Mole.clean)])
    }
}
