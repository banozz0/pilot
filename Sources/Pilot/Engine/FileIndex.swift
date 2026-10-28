import Foundation
import OSLog
import PilotCore

private let flog = Logger(subsystem: "dev.banozz.pilot", category: "files")

/// The menu's file index (story 77, card agent-bo-95422765): Contents/Helpers/pilot-files, built on Cardinal's engine,
/// run as Pilot's child on pipes. It walks the home folder once (about 5 s for a million files), then reads its saved
/// index on each start (about 1.6 s for 19 MB) and follows FSEvents, so Spotlight's switch does not matter. It runs
/// only while it is used (2026-10-09, Sven's yes): the Hyper+Space menu opening starts it, so it is warm by the first
/// file search (which starts it too), and `idleStop` without a file search stops it, giving back its ~140 MB.
/// Stopping closes its pipe, as Pilot quitting does: the helper saves its index with the last FSEvents id it applied
/// and exits; the next start reads it and replays FSEvents from that id, so files changed while it was stopped are
/// found. It skips the never-index list (FileExclusions, Defaults › File search), passed as `--ignore` at each start;
/// a changed list stops it, and the next start walks again (N5). A child runs under Pilot's own privacy grants, so it waits for Full Disk Access (onboarding asks, card
/// agent-bo-95422768): without it the first walk would raise macOS's Desktop, Documents and Downloads prompts in
/// Pilot's name. Files › Duplicates asks it for identical files (`scanDuplicates`), on demand only.
@MainActor
final class FileIndex {
    static let shared = FileIndex()

    /// The helper stops after this long without a file search; the menu opening starts it again.
    static let idleStop: TimeInterval = 10 * 60

    /// The helper binary; Pilot's own copy unless a test passes another.
    private let helper: URL
    /// Whether Pilot holds Full Disk Access, asked again at each start until it does.
    private let fullDiskAccess: () -> Bool
    /// The idle stop's timer; the tests pass a fake clock.
    private let after: Watch.After
    /// The never-index list as the helper's gitignore lines, read at each start.
    private let ignore: () -> [String]

    init(helper: URL = FileIndex.bundled, fullDiskAccess: @escaping () -> Bool = FileIndex.hasFullDiskAccess,
         after: @escaping Watch.After = Watch.after,
         ignore: @escaping () -> [String] = { FileExclusions.lines(FileSearchSettings.shared.excluded) }) {
        self.helper = helper
        self.fullDiskAccess = fullDiskAccess
        self.after = after
        self.ignore = ignore
    }

    /// ~/Library/Safari opens only with Full Disk Access, and refusing it raises no prompt.
    nonisolated static func hasFullDiskAccess() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }

    var isRunning: Bool { process != nil }
    /// Whether the last start found no Full Disk Access, so a search can say so without asking again.
    private var lacksAccess = false
    /// The missing grant is logged once, not on every keystroke.
    private var toldNoAccess = false

    private var process: Process?
    private var input: FileHandle?
    /// The request the menu waits on, by id; an answer to any other is dropped, since the menu has moved on.
    private var waiting: (id: Int, reply: ([FileSearch.Hit]?) -> Void)?
    /// The duplicates scan Files › Duplicates waits on, by id: the menu closing leaves it running, and the idle stop
    /// waits for it.
    private var scanning: (id: Int, reply: (DuplicateScan.Result) -> Void)?
    /// The last request's id.
    private var asked = 0
    /// Counts `idleStop` from the helper's start or its last search.
    private var idleTimer: Watch?

    static let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/pilot-files")

    /// Started by the menu opening, so the saved index is read before the first file search; a search starts it too,
    /// after an idle stop or a crash.
    func start() {
        guard process == nil else { return }
        lacksAccess = !fullDiskAccess()
        guard !lacksAccess else {
            if !toldNoAccess { flog.notice("files: no Full Disk Access yet, so the menu lists no files") }
            toldNoAccess = true
            return
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            return flog.error("files: no helper at \(self.helper.path, privacy: .public), so the menu lists no files")
        }
        let p = Process(), toHelper = Pipe(), fromHelper = Pipe(), errors = Pipe()
        p.executableURL = helper
        p.arguments = ["--ignore", ignore().joined(separator: "\n")]
        p.standardInput = toHelper
        p.standardOutput = fromHelper
        p.standardError = errors
        // A write after the helper died must fail, not raise SIGPIPE, which would kill Pilot.
        _ = fcntl(toHelper.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let answers = LineBuffer(), complaints = LineBuffer()
        fromHelper.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let lines = answers.append(data)
            DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach { self?.received($0) } } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            for line in complaints.append(data) { flog.error("files: \(line, privacy: .public)") }
        }
        p.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(p, status) } }
        }
        do {
            try p.run()
            process = p
            input = toHelper.fileHandleForWriting
            used()
            flog.notice("files: helper started, pid \(p.processIdentifier)")
        } catch {
            flog.error("files: helper not started, \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asks for the files matching `ask` (the Files view's words and filters); `reply` gets them, best first, unless a
    /// newer search replaced this one first, or nil at once while Pilot lacks Full Disk Access, so the menu can say so.
    func search(_ ask: FileSearch.Ask, reply: @escaping ([FileSearch.Hit]?) -> Void) {
        start()
        guard isRunning else { return reply(lacksAccess ? nil : []) }
        asked += 1
        waiting = (asked, reply)
        used()
        send(ask.request(id: asked, home: NSHomeDirectory()), "search")
    }

    /// Asks for identical files (Homy-style Files, T5): `reply` gets them once the helper has read the files that share
    /// a size, `.noAccess` at once without Full Disk Access, `.stopped` when the helper stops first. A newer scan
    /// replaces this one.
    func scanDuplicates(reply: @escaping (DuplicateScan.Result) -> Void) {
        start()
        guard isRunning else { return reply(lacksAccess ? .noAccess : .stopped) }
        asked += 1
        scanning = (asked, reply)
        used()
        send(#"{"dupes":true,"id":\#(asked)}"#, "duplicates scan")
    }

    private func send(_ line: String, _ what: String) {
        do { try input?.write(contentsOf: Data((line + "\n").utf8)) } catch {
            flog.error("files: \(what, privacy: .public) not sent, \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The menu closed or left the root: whatever answer is on its way is dropped.
    func cancel() { waiting = nil }

    /// The idle stop counts from now.
    private func used() {
        idleTimer?.cancel()
        idleTimer = after(Self.idleStop) { [weak self] in self?.stop() }
    }

    /// The never-index list changed: the helper stops, saving its index, and the next start walks with the new list.
    func restart() {
        guard let process else { return }
        flog.notice("files: never-index list changed, helper \(process.processIdentifier) stops")
        try? input?.close()
        clear()
    }

    /// Uninstall trashes the saved index: the helper is killed rather than stopped, since only stdin closing saves it,
    /// and the next start walks again.
    func discard() {
        guard let process else { return }
        flog.notice("files: index going to the Trash, helper \(process.processIdentifier) ends unsaved")
        process.terminate()
        clear()
    }

    /// `idleStop` passed without a file search; a duplicates scan still reading counts as one.
    private func stop() {
        guard let process else { return }
        guard scanning == nil else { return used() }
        flog.notice("files: no file search for \(Int(Self.idleStop)) s, helper \(process.processIdentifier) stops")
        // Its stdin closing is Pilot quitting to the helper: it saves its index and exits on its own.
        try? input?.close()
        clear()
    }

    private func received(_ line: String) {
        if let (id, scan) = DuplicateScan.answer(line) {
            guard let scanning, scanning.id == id else { return }
            self.scanning = nil
            used()
            return scanning.reply(.found(scan))
        }
        guard let answer = FileSearch.answer(line) else {
            return flog.notice("files: \(line, privacy: .public)")  // the ready line: files indexed, walked or read
        }
        guard let waiting, waiting.id == answer.id else { return }
        self.waiting = nil
        waiting.reply(answer.files)
    }

    /// The next start or search runs a new helper. A stopped helper exits once it has saved, perhaps after a new one
    /// started, so only the running helper's exit clears the state.
    private func exited(_ helper: Process, _ status: Int32) {
        flog.notice("files: helper \(helper.processIdentifier) exited, status \(status)")
        if helper === process { clear() }
    }

    private func clear() {
        process = nil
        input = nil
        waiting = nil
        idleTimer?.cancel()
        idleTimer = nil
        let scan = scanning
        scanning = nil
        scan?.reply(.stopped)
    }
}

/// Identical files the index found (pilot-files, dupes.rs): groups of files with the same contents, the ones that free
/// the most first, at most 200; `more` counts the groups left out.
struct DuplicateScan: Equatable, Sendable {
    struct Group: Equatable, Sendable, Decodable {
        /// Each copy's size in bytes.
        var size: Int64
        var files: [FileSearch.Hit]
    }

    enum Result: Equatable, Sendable {
        case found(DuplicateScan)
        /// Pilot lacks Full Disk Access, so no helper runs.
        case noAccess
        /// The helper stopped (or never started) before it answered.
        case stopped
    }

    var groups: [Group]
    var more = 0

    /// A scan's answer line, with its request id; nil for any other line.
    static func answer(_ line: String) -> (id: Int, scan: DuplicateScan)? {
        struct Answer: Decodable {
            var id: Int
            var dupes: [Group]
            var more: Int
        }
        // Every search answer passes here: only a line naming dupes is decoded.
        guard line.contains(#""dupes""#) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let answer = try? decoder.decode(Answer.self, from: Data(line.utf8)) else { return nil }
        return (answer.id, DuplicateScan(groups: answer.dupes, more: answer.more))
    }
}
