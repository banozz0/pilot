import Foundation
import PilotCore
import Testing
@testable import Pilot

/// CLI W10: Reports, Update, Clean and the speed test through the registry the socket answers from. Reports live in a
/// temp folder, Update's rows and Mole's preview are fixtures, the visible terminal is a recorder that keeps the run's
/// report as the real one does, the gate's decider is the test's, and the speed test measures nothing: no brew, Mole,
/// networkQuality or terminal runs.
@MainActor
@Suite("Control jobs")
final class ControlJobsTests {
    let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "pilot-jobs-\(UUID().uuidString)", directoryHint: .isDirectory)
    let jobs = ControlJobs()
    let verbs = ControlVerbs()
    var asked: [ControlGate.Ask] = []
    var allow = true
    var ran: [(command: String, title: String, onSuccess: String, report: RunReport?)] = []
    var rows: [UpdateRow]? = ControlJobsTests.outdated
    var reads = 0
    var mole: String? = "/opt/homebrew/bin/mo"
    var previews = 0
    var speedTest = SpeedTest(measure: { #"{"dl_throughput":887000000,"ul_throughput":54000000,"responsiveness":384}"# }, say: { _ in })
    var speedTests = 0

    static let outdated = [
        UpdateRow(item: .package(Package(.formula, "git")!), from: "2.40", to: "2.41"),
        UpdateRow(item: .package(Package(.cask, "zed")!), from: "1.0", to: "1.1", selfUpdating: true),
        UpdateRow(item: .package(Package(.formula, "node")!), from: "20", to: "22", pinned: true),
        UpdateRow(item: .macOS(label: "macOS 26.1", title: "macOS 26.1", restart: true), from: "26.0", to: "26.1"),
    ]

    static let moleOutput = """
    ➤ Browsers
    → Chrome cache · 1.73GB dry
    ➤ Developer tools
    → Xcode DerivedData · 4.2GB dry
    Potential space: 5.93GB | Items: 2
    """

    init() {
        jobs.gate = ControlGate(wait: .seconds(5)) { [unowned self] ask, _ in asked.append(ask); return allow }
        jobs.store = ReportStore(folder: folder)
        jobs.terminal = { [unowned self] command, title, onSuccess, report in
            ran.append((command, title, onSuccess, report))
            if let report { _ = try? jobs.store.begin(report) }
        }
        jobs.readUpdates = { [unowned self] in reads += 1; return rows }
        jobs.includeSelfUpdating = { false }
        jobs.previewer = CleanPreviewer { [unowned self] _ in previews += 1; return Self.moleOutput }
        jobs.mole = { [unowned self] in mole }
        jobs.speedTest = { [unowned self] () throws(ControlError) in
            if let run = speedTest.run { return run }
            speedTests += 1
            return speedTest.start()!
        }
        jobs.every = .milliseconds(20)
        verbs.registerCore()
        verbs.registerJobs(jobs)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func ask(_ verb: String, _ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil) }

    func object(_ verb: String, _ args: String...) async -> [String: JSONValue] {
        let answer = await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
        guard case .object(let o)? = answer.result else { Issue.record("not an object: \(answer)"); return [:] }
        return o
    }

    static func fields(_ value: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = value { o } else { [:] } }
    static func list(_ value: JSONValue?) -> [JSONValue] { if case .array(let a)? = value { a } else { [] } }

    /// A run as the visible terminal leaves it: its report kept, then its script's output and exit status.
    @discardableResult
    func run(_ report: RunReport, output: String? = nil, exit: Int32? = nil) throws -> RunReport {
        let dir = try jobs.store.begin(report)
        if let output { try Data(output.utf8).write(to: dir.appending(path: "output")) }
        if let exit { try "\(exit)\n".write(to: dir.appending(path: "status"), atomically: true, encoding: .utf8) }
        return report
    }

    // MARK: Reports

    @Test("list reports answers every run newest first with how it ended; report reads one whole, as the Reports page opens it")
    func reports() async throws {
        let old = try run(RunReport(kind: .update, title: "Update git", command: "brew upgrade --formula git", started: .now.addingTimeInterval(-600),
                                    items: [.init(name: "git", from: "2.40", to: "2.41", detail: "formula")]), output: "\u{1B}[32mUpgraded git\u{1B}[0m\n", exit: 0)
        let clean = try run(RunReport(kind: .clean, title: "Clean", command: "mo clean", started: .now.addingTimeInterval(-60), items: [], estimate: "5.93GB"),
                            output: "Tracked cleanup: 4.1GB | Items cleaned: 2\n", exit: 1)

        let rows = Self.list(await ask("list", "reports").result).map(Self.fields)
        #expect(rows.map { $0["id"] } == [.string(clean.id), .string(old.id)])
        #expect(rows[0]["end"] == .string("failed") && rows[0]["exit"] == .number(1) && rows[0]["endLabel"] == .string("failed · exit 1"))
        #expect(rows[0]["freed"] == .string("4.1GB") && rows[0]["summary"] == .string("4.1GB freed") && rows[0]["estimate"] == .string("5.93GB"))
        #expect(rows[1]["end"] == .string("done") && rows[1]["summary"] == .string("1 item updated"))

        let one = await object("report", old.id)
        #expect(one["command"] == .string("brew upgrade --formula git"))
        #expect(one["output"] == .string("Upgraded git"))
        #expect(one["itemsHeading"] == .string("Updated"))
        #expect(Self.list(one["items"]).map(Self.fields).first?["to"] == .string("2.41"))
        #expect(one["folder"] == .string(jobs.store.directory(old.id).path(percentEncoded: false)))
        if case .number(let took)? = one["took"] { #expect(took >= 0) } else { Issue.record("no took: \(one)") }
        #expect(await object("report", "latest")["id"] == .string(clean.id))

        #expect(await ask("report", "nope").error?.code == .badValue)
        #expect(await ask("report").error?.code == .badRequest)
        let schema = Self.fields(try verbs.schema(collection: "reports"))
        #expect(schema["rowKey"] == .string("id") && schema["add"] == .bool(false))
    }

    @Test("report --wait follows a running run to its end; past its longest wait it answers timeout")
    func reportWait() async throws {
        let report = try run(RunReport(kind: .update, title: "Update all", command: "brew upgrade", items: []))
        #expect(await object("report", report.id)["end"] == .string("running"))
        let dir = jobs.store.directory(report.id)
        Task { try? await Task.sleep(for: .milliseconds(100)); try? "0\n".write(to: dir.appending(path: "status"), atomically: true, encoding: .utf8) }
        #expect(await object("report", report.id, "--wait")["end"] == .string("done"))

        let still = try run(RunReport(kind: .clean, title: "Clean", command: "mo clean", items: []))
        jobs.longest = .milliseconds(60)
        #expect(await ask("report", still.id, "--wait").error?.code == .timeout)
        #expect(await ask("report", still.id, "--follow").error?.code == .unknownFlag)
    }

    // MARK: Update

    @Test("update list answers the rows the menu shows: self-updating casks left out by the setting, pinned and macOS rows outside Update all; an unread list is not-ready")
    func updateList() async {
        let list = await object("update")
        let rows = Self.list(list["rows"]).map(Self.fields)
        #expect(rows.map { $0["key"] } == [.string("formula:git"), .string("formula:node"), .string("macos:macOS 26.1")])
        #expect(rows.map { $0["inUpdateAll"] } == [.bool(true), .bool(false), .bool(false)])
        #expect(rows[1]["pinned"] == .bool(true) && rows[2]["restartsMac"] == .bool(true) && rows[2]["category"] == .string("macOS"))
        #expect(list["updateAll"] == .string("brew upgrade --formula git"))
        #expect(list["leftOut"] == .number(1) && list["includeSelfUpdating"] == .bool(false))
        #expect(asked.isEmpty && ran.isEmpty)

        self.rows = nil
        #expect(await ask("update", "list").error?.code == .notReady)
    }

    @Test("update all asks Allow with the exact command, then runs it in the terminal with its report, and answers the run as Reports lists it")
    func updateAll() async {
        allow = false
        #expect(await ask("update", "all").error?.code == .denied)
        #expect(asked == [ControlGate.Ask("Update all", "brew upgrade --formula git")])
        #expect(ran.isEmpty && jobs.store.list().isEmpty)

        allow = true
        let answer = await object("update", "all")
        #expect(ran.count == 1 && ran[0].command == "brew upgrade --formula git" && ran[0].title == "Update")
        let report = Self.fields(answer["report"])
        #expect(report["id"] == .string(ran[0].report?.id ?? "") && report["end"] == .string("running") && report["title"] == .string("Update all"))
        #expect(ran[0].report?.items.map(\.name) == ["git"])
        // The list read once for both asks, as the menu's picks act on the rows it shows.
        #expect(reads == 1)
    }

    @Test("update all with nothing that goes asks nothing and says why, as the menu's tip does")
    func updateAllNothing() async {
        rows = [ControlJobsTests.outdated[2], ControlJobsTests.outdated[3]]
        let answer = await object("update", "all")
        #expect(answer["ran"] == .null && answer["note"] == .string("Only macOS updates or pinned formulae left; pick each one"))
        rows = []
        jobs.updates = nil
        #expect(await object("update", "all")["note"] == .string("Everything is up to date"))
        #expect(asked.isEmpty && ran.isEmpty)
    }

    @Test("update <key> asks for that row alone; a pinned row points at unpin, an unknown key at the list, a hidden self-updating cask is not offered")
    func updateOne() async {
        let answer = await object("update", "macos:macOS 26.1")
        #expect(asked == [ControlGate.Ask("Update macOS 26.1", "softwareupdate -i 'macOS 26.1'")])
        #expect(Self.fields(answer["report"])["title"] == .string("Update macOS 26.1"))
        #expect(await ask("update", "formula:node").error?.message.contains("pilot update unpin formula:node") == true)
        #expect(await ask("update", "formula:nope").error?.code == .badValue)
        #expect(await ask("update", "cask:zed").error?.code == .badValue)
        #expect(asked.count == 1)
    }

    @Test("update unpin asks with brew unpin and runs it in the terminal, unrecorded; a row that is not pinned is refused")
    func unpin() async {
        let answer = await object("update", "unpin", "formula:node")
        #expect(asked == [ControlGate.Ask("Unpin node", "brew unpin node")])
        #expect(ran.map(\.command) == ["brew unpin node"] && ran[0].title == "Unpin" && ran[0].report == nil)
        #expect(answer["ran"] == .string("brew unpin node"))
        #expect(await ask("update", "unpin", "formula:git").error?.code == .badValue)
        #expect(await ask("update", "unpin").error?.code == .badRequest)
    }

    // MARK: Clean

    @Test("clean preview --wait answers Mole's dry run, kept for the next ask; without --wait a run in progress answers its progress")
    func cleanPreview() async {
        let ready = await object("clean", "preview", "--wait")
        #expect(ready["state"] == .string("ready") && ready["total"] == .string("5.93GB"))
        #expect(Self.list(ready["items"]).map(Self.fields).map { $0["title"] } == [.string("Chrome cache"), .string("Xcode DerivedData")])
        #expect(await object("clean", "preview")["state"] == .string("ready"))
        #expect(previews == 1)

        jobs.previewer = CleanPreviewer { _ in try? await Task.sleep(for: .seconds(30)); return nil }
        let running = await object("clean", "preview")
        #expect(running["state"] == .string("running"))
        jobs.previewer.drop()
    }

    @Test("clean run asks with mo clean, then cleans in the terminal, its report keeping the preview's items; the preview is dropped")
    func cleanRun() async {
        _ = await object("clean", "preview", "--wait")
        allow = false
        #expect(await ask("clean", "run").error?.code == .denied)
        #expect(jobs.previewer.ready != nil && ran.isEmpty)
        allow = true
        let answer = await object("clean", "run")
        #expect(asked.last == ControlGate.Ask("Clean", "mo clean"))
        #expect(ran.count == 1 && ran[0].onSuccess == VisibleRun.waitForReturn)
        #expect(ran[0].report?.items.map(\.name) == ["Chrome cache", "Xcode DerivedData"] && ran[0].report?.estimate == "5.93GB")
        #expect(Self.fields(answer["report"])["kind"] == .string("clean"))
        #expect(jobs.previewer.ready == nil)
    }

    @Test("clean analyze asks, then opens Mole's disk explorer; with Mole missing every clean says how to install it")
    func cleanAnalyzeAndMissing() async {
        let answer = await object("clean", "analyze")
        #expect(asked == [ControlGate.Ask("Disk usage", "mo analyze")] && ran.map(\.command) == ["mo analyze"])
        #expect(answer["opens"] == .string("window"))
        #expect(await ask("clean", "sweep").error?.code == .badValue)
        mole = nil
        let missing = await ask("clean", "run")
        #expect(missing.error?.code == .notReady && missing.error?.message.contains("pilot install helper mole") == true)
        #expect(asked.count == 1)
    }

    // MARK: Speed test

    @Test("speedtest starts the key's run and answers its line; a run already going is joined, not doubled")
    func speedtest() async {
        let answer = await object("speedtest")
        #expect(answer["result"] == .string("Download 887 Mbit/s · Upload 54 Mbit/s · Responsiveness 384 RPM") && answer["measured"] == .bool(true))
        #expect(speedTests == 1)

        speedTest.start()
        _ = await object("speedtest")
        #expect(speedTests == 1)

        speedTest = SpeedTest(measure: { "networkQuality: no network" }, say: { _ in })
        let failed = await object("speedtest")
        #expect(failed["result"] == .string(SpeedTest.failed) && failed["measured"] == .bool(false))
    }

    @Test("every job verb declares its flags and reads in help")
    func help() async {
        for verb in ["report", "update", "clean", "speedtest"] {
            #expect(verbs.verbs[verb]?.flags != nil, "\(verb) declares no flags")
        }
        #expect(await ask("help", "update", "all").result.map { "\($0)".contains("asks Allow") } == true)
        #expect(await ask("update", "--force").error?.code == .unknownFlag)
    }
}
