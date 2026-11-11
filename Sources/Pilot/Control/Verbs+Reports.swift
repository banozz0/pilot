import Foundation
import PilotCore

/// What the job verbs reach (CLI W10): the Reports folder, Update's lists, Mole's preview, the visible terminal, the
/// Allow gate and the key's speed test. Each is reached on the first request; a test sets its own before then, so nothing
/// reads brew, runs Mole or networkQuality, or opens a terminal.
@MainActor
final class ControlJobs {
    lazy var gate = AllowPrompt.gate
    lazy var store = ReportStore.standard
    /// The visible terminal Update and Clean run in: the command, the window's title, what runs on exit 0, and the run's
    /// report, kept in `store` as the window opens.
    typealias Terminal = @MainActor (_ command: String, _ title: String, _ onSuccess: String, _ report: RunReport?) -> Void
    lazy var terminal: Terminal = { [unowned self] in VisibleTerminal.run($0, title: $1, onSuccess: $2, report: $3, store: store) }
    /// Update's whole list as the menu ends up with it: Homebrew's and uv's rows, then macOS, the App Store, npm, bun and
    /// cargo (story 118), from the menu's own check (InstallModule.updates), joined while it runs and kept while fresh;
    /// nil when Homebrew's could not be read.
    lazy var readUpdates: @MainActor () async -> [UpdateRow]? = { await InstallModule.updates.checked() }
    /// After an update or an unpin the menu's kept rows are wrong, so its next open checks again.
    lazy var dropUpdates: @MainActor () -> Void = { InstallModule.updates.drop() }
    lazy var includeSelfUpdating: @MainActor () -> Bool = { Engine.shared?.settings.updateSelfUpdatingCasks ?? false }
    lazy var previewer = CleanModule.previewer
    lazy var mole: @MainActor () -> String? = { CleanModule.mole }
    /// The speed test's run going now, else one started as its key starts it (system.speedTest), so one run at a time holds
    /// across both.
    lazy var speedTest: @MainActor () throws(ControlError) -> Task<String, Never> = { () throws(ControlError) in
        if let run = SpeedTest.current { return run }
        guard let action = Engine.shared?.action("system.speedTest") else { throw ControlError(.notReady, "Pilot's key engine is not running yet") }
        action.run()
        guard let run = SpeedTest.current else {
            throw ControlError(.badValue, "the speed test did not start; system.speedTest may be switched off (pilot actions lists it)")
        }
        return run
    }
    /// How often `report --wait` reads the run again, as the Reports page does, and how long it waits at most.
    var every: Duration = .seconds(2)
    var longest: Duration = .seconds(30 * 60)
    /// Update's rows as `update list` last read them, which `update all|<key>|unpin` act on while fresh, as the menu's
    /// picks act on the rows it shows.
    var updates: (rows: [UpdateRow], at: Date)?
    static let keepUpdates: TimeInterval = 15 * 60
}

extension ControlVerbs {
    /// Reports, Update, Clean and the speed test: Pilot's jobs that end after the request.
    func registerJobs(_ jobs: ControlJobs) {
        registerReports(jobs)
        registerUpdate(jobs)
        registerClean(jobs)
        registerSpeedTest(jobs)
    }

    /// `list reports` and `report <id>`: Update & Clean › Reports, every Update and Clean run.
    private func registerReports(_ jobs: ControlJobs) {
        register(ControlCollection("reports", help: "Every Update and Clean run, newest first, as Update & Clean › Reports lists it; pilot report <id> reads one.",
                                   rowKey: "id", list: { .array(jobs.store.list().map { .object(Self.reportRow($0)) }) }))
        register(ControlVerb("report", help: "One Update or Clean run as Reports opens it: how it ended, the command, its items and its output.",
                             usage: "pilot report <id>|latest [--wait]",
                             flags: [.init("wait", help: "follows a running run to its end, read every 2 s as the page does, for at most 30 min", takesValue: false)],
                             detail: { word in word == "latest" ? "pilot report latest: the newest run" : nil }) { call throws(ControlError) in
            let args = call.arguments()
            let id = try args.word(0, "run id or latest; pilot list reports lists them")
            var record = try Self.record(id, in: jobs.store)
            if args.has("wait") {
                let end = ContinuousClock.now + jobs.longest
                while record.end == .running {
                    guard ContinuousClock.now < end else {
                        throw ControlError(.timeout, "\(record.report.title) still runs after \(jobs.longest.components.seconds / 60) min; pilot report \(record.id) reads it later")
                    }
                    try? await Task.sleep(for: jobs.every)
                    record = try Self.record(record.id, in: jobs.store)
                }
            }
            var answer = Self.reportRow(record)
            answer["command"] = .string(record.report.command)
            answer["itemsHeading"] = .string(record.itemsHeading)
            answer["items"] = .array(record.report.items.map { .object(["name": .string($0.name), "from": .string($0.from), "to": .string($0.to), "detail": .string($0.detail)]) })
            answer["took"] = record.ended.map { .number($0.timeIntervalSince(record.report.started).rounded()) }
            answer["output"] = .string(jobs.store.output(record.id))
            answer["folder"] = .string(jobs.store.directory(record.id).path(percentEncoded: false))
            return .object(answer)
        })
    }

    /// The run `id` names, or the newest for `latest`.
    private static func record(_ id: String, in store: ReportStore) throws(ControlError) -> RunRecord {
        guard id == "latest" else {
            guard let record = store.record(id) else { throw ControlError(.badValue, "no run \(id); pilot list reports lists them") }
            return record
        }
        guard let newest = store.list().first else { throw ControlError(.badValue, "no runs yet: Update and Clean keep each run") }
        return newest
    }

    /// A run as the Reports list shows it: what, when, how it ended (`end` running, done, failed or cancelled, with `exit`).
    static func reportRow(_ r: RunRecord) -> [String: JSONValue] {
        let (end, exit): (String, Int32?) = switch r.end {
        case .running: ("running", nil)
        case .done: ("done", 0)
        case .failed(let code): ("failed", code)
        case .cancelled(let code): ("cancelled", code)
        }
        return ["id": .string(r.id), "kind": .string(r.report.kind.rawValue), "title": .string(r.report.title),
                "started": .string(r.report.started.ISO8601Format()), "end": .string(end), "exit": exit.map { .number(Double($0)) } ?? .null,
                "endLabel": .string(r.end.word), "ended": r.ended.map { .string($0.ISO8601Format()) } ?? .null, "summary": .string(r.summary),
                "estimate": r.report.estimate.map(JSONValue.string) ?? .null, "freed": r.freed.map(JSONValue.string) ?? .null]
    }

    /// What a job answers as its terminal opens: the command it ran and its run as Reports now lists it.
    static func started(_ command: String, report id: String, in store: ReportStore) -> JSONValue {
        let record = store.record(id)
        let note = record.map { "runs in a terminal window; pilot report \($0.id) --wait follows it to its end" }
            ?? "runs in a terminal window; its report was not kept, so how it ends is read there"
        return .object(["ran": .string(command), "report": record.map { .object(reportRow($0)) } ?? .null, "note": .string(note)])
    }
}
