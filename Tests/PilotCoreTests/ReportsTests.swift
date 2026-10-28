import Foundation
import Testing
@testable import PilotCore

/// Reports (story 153): every Update and Clean run kept, how it ended read from its folder, its output made readable.
@Suite("Reports")
struct ReportsTests {
    func store(keep: Int = ReportStore.keep) -> ReportStore {
        ReportStore(folder: FileManager.default.temporaryDirectory.appending(path: "reports-\(UUID().uuidString)"), keep: keep)
    }

    /// The visible terminal's script with a report folder, run here with no terminal: its pid, output and status land in
    /// the folder, and the store reads how it ended.
    func run(_ command: String, in store: ReportStore, _ report: RunReport) throws -> Int32 {
        let dir = try store.begin(report)
        let script = dir.deletingLastPathComponent().appending(path: "\(report.id).command")
        try VisibleRun.script(command: command, onSuccess: "true", report: dir).write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = [script.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    @Test("A recorded run keeps the command's own words and exit 0 as done; the script still closes on success")
    func done() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let row = UpdateRow(item: .package(Package(.formula, "hello")!), from: "2.12", to: "2.12.1")
        let report = RunReport.update("Update hello", command: "brew upgrade --formula hello", rows: [row], home: "/Users/x")
        #expect(try run("printf '\\033[32m==> Upgrading hello\\033[0m\\n'; echo '2.12 -> 2.12.1'", in: store, report) == 0)
        let record = try #require(store.list().first)
        #expect(record.end == .done && record.ended != nil)
        #expect(record.report.items == [RunReport.Item(name: "hello", from: "2.12", to: "2.12.1", detail: "formula")])
        #expect(record.summary == "1 item updated")
        let output = store.output(record.id)
        #expect(output.contains("==> Upgrading hello") && output.contains("2.12 -> 2.12.1"), "\(output)")
        #expect(!output.contains("\u{1B}"), "colours stripped")
        // Settled once: the raw capture gave way to the readable text and the outcome.
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(record.id).path)
        #expect(Set(files).isSuperset(of: ["report.json", "end.json", "output.txt"]) && !files.contains("output"), "\(files)")
        #expect(store.list().first == record)
    }

    @Test("A failing run keeps its exit code and the script still waits for Return; Ctrl+C's 130 is cancelled")
    func failed() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        #expect(try run("echo nope; exit 3", in: store, .clean(command: "mo clean", preview: nil)) == 3)
        let record = try #require(store.list().first)
        #expect(record.end == .failed(3) && record.end.word == "failed · exit 3")
        #expect(store.output(record.id).contains("nope"))
        #expect(try run("exit 130", in: store, .clean(command: "mo clean", preview: nil)) == 130)
        #expect(store.list().map(\.end).contains(.cancelled(130)))
    }

    @Test("How a run ended: its status, else its shell alive or gone, else a terminal that never started it")
    func ends() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RunEnd(exit: 0, alive: false, started: t, now: t) == .done)
        #expect(RunEnd(exit: 1, alive: true, started: t, now: t) == .failed(1))
        #expect(RunEnd(exit: 129, alive: false, started: t, now: t) == .cancelled(129))
        #expect(RunEnd(exit: nil, alive: true, started: t, now: t + 3600) == .running)
        #expect(RunEnd(exit: nil, alive: false, started: t, now: t + 5) == .cancelled(nil))
        #expect(RunEnd(exit: nil, alive: nil, started: t, now: t + 5) == .running)
        #expect(RunEnd(exit: nil, alive: nil, started: t, now: t + 600) == .cancelled(nil))
        #expect(RunEnd(settled: nil) == .cancelled(nil) && RunEnd(settled: 0) == .done)
    }

    @Test("A run whose shell died with no status (the window closed) is cancelled; one still running is listed as running")
    func closedWindow() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let gone = try store.begin(RunReport(kind: .update, title: "Update all", command: "brew upgrade", started: .now - 10, items: []))
        try "999999".write(to: gone.appending(path: "pid"), atomically: true, encoding: .utf8)
        let live = try store.begin(RunReport(kind: .clean, title: "Clean", command: "mo clean", items: []))
        try "\(ProcessInfo.processInfo.processIdentifier)".write(to: live.appending(path: "pid"), atomically: true, encoding: .utf8)
        try Data("Cleaning\n 40%\r100%\n".utf8).write(to: live.appending(path: "output"))
        let records = store.list(alive: { $0 == ProcessInfo.processInfo.processIdentifier })
        #expect(records.map(\.report.title) == ["Clean", "Update all"], "newest first")
        #expect(records.map(\.end) == [.running, .cancelled(nil)])
        #expect(store.output(records[0].id) == "Cleaning\n100%", "a running run's output so far, each progress line's last drawing")
    }

    @Test("Only the newest runs are kept")
    func bounded() throws {
        let store = store(keep: 3)
        defer { try? FileManager.default.removeItem(at: store.folder) }
        for i in 0..<5 {
            try store.begin(RunReport(id: "r\(i)", kind: .update, title: "Update \(i)", command: "true", started: Date(timeIntervalSince1970: Double(i)), items: []))
        }
        #expect(store.list().map(\.id) == ["r4", "r3", "r2"])
    }

    @Test("Clean's report keeps Mole's preview and the space its real clean says it freed")
    func clean() {
        let preview = CleanPreview.parse("➤ Browsers\n  → Chrome cache · 1.73GB dry\n\nPotential space: 2.10GB | Items: 2")
        let report = RunReport.clean(command: Mole.clean, preview: preview)
        #expect(report.items == [RunReport.Item(name: "Chrome cache", detail: "Browsers · 1.73GB")] && report.estimate == "2.10GB")
        #expect(RunRecord(report: report, end: .cancelled(nil)).summary == "Mole estimated 2.10GB")
        let freed = ReportText.freed("Cleaning…\nTracked cleanup: 1.95GB | Items cleaned: 140\nFree space: 120GB (+1.9GB)")
        #expect(freed == "1.95GB")
        #expect(RunRecord(report: report, end: .done, freed: freed).summary == "1.95GB freed")
    }

    @Test("Output past the limit keeps its end and says how much was cut; backspaces and stray controls go")
    func text() {
        #expect(ReportText.clean(Data("^D\u{8}\u{8}hi\u{7}\r\nthere\u{1B}]0;title\u{7}".utf8)) == "hi\nthere")
        let long = (1...2000).map { "line \($0)" }.joined(separator: "\n")
        let kept = ReportText.clean(Data(long.utf8), limit: 1000)
        #expect(kept.hasPrefix(ReportText.cut) && kept.hasSuffix("line 2000") && kept.utf8.count < 1100)
        // A long capture is read from its end only, and still says the start was cut.
        let file = FileManager.default.temporaryDirectory.appending(path: "raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try? Data(long.utf8).write(to: file)
        let tail = ReportText.clean(file: file, limit: 1000)
        #expect(tail?.hasPrefix(ReportText.cut) == true && tail?.hasSuffix("line 2000") == true)
    }

    @Test("Update all's report lists what its command upgrades: no macOS update, no pinned formula")
    func updateAll() {
        let rows = [UpdateRow(item: .package(Package(.cask, "zed")!), from: "1", to: "2"),
                    UpdateRow(item: .package(Package(.formula, "git")!), from: "1", to: "2", pinned: true),
                    UpdateRow(item: .macOS(label: "macOS 26.1", title: "macOS Tahoe", restart: true), from: "26.0", to: "26.1")]
        #expect(UpdateList.allRows(rows, includeSelfUpdating: false).map(\.item.name) == ["zed"])
    }

    @Test("Update and Clean each end with a Reports row; while Mole previews Clean stays empty so it says so")
    func menuRows() {
        let update = UpdateList.entries([], includeSelfUpdating: false)
        #expect(update.contains { $0.title == "Reports" && $0.target == .update(.reports) && $0.home == .update })
        #expect(CleanMenu.entries(nil, mole: true).isEmpty)
        #expect(CleanMenu.entries(nil, mole: false).map(\.title) == ["Install Mole", "Reports"])
        #expect(CleanMenu.entries(CleanPreview.parse(""), mole: true).last?.target == .clean(.reports))
    }

    @Test("Without a report the visible script is the one story 97 ran; with one, the same command runs under script(1)")
    func script() {
        let plain = VisibleRun.script(command: "brew upgrade", onSuccess: "true")
        #expect(!plain.contains("/usr/bin/script") && plain.contains("\nbrew upgrade\n"))
        let recorded = VisibleRun.script(command: "brew upgrade 'a b'", onSuccess: "true", report: URL(filePath: "/tmp/r 1"))
        #expect(recorded.contains("r='/tmp/r 1'"))
        #expect(recorded.contains("/usr/bin/script -q \"$r/output\" /bin/zsh -f -c 'brew upgrade '\\''a b'\\'''"))
    }
}
