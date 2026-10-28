import Foundation

/// One Update or Clean run as Pilot asked for it (story 153): when, which, the exact command and what it was to change.
/// Written as the visible terminal opens; how it ended comes from the run's own folder (ReportStore).
public struct RunReport: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case update, clean }

    /// One thing the run was asked to change: an Update row from → to, or an item Mole's preview listed (`detail` its
    /// section and size, no versions).
    public struct Item: Codable, Equatable, Sendable {
        public let name: String, from: String, to: String, detail: String

        public init(name: String, from: String = "", to: String = "", detail: String = "") {
            self.name = name; self.from = from; self.to = to; self.detail = detail
        }
    }

    public let id: String
    public let kind: Kind
    /// "Update all", "Update git", "Clean".
    public let title: String
    public let command: String
    public let started: Date
    public let items: [Item]
    /// Clean: Mole's preview's potential space; nil for Update.
    public let estimate: String?

    public init(id: String = UUID().uuidString, kind: Kind, title: String, command: String, started: Date = .now, items: [Item],
                estimate: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.command = command; self.started = started; self.items = items
        self.estimate = estimate
    }

    /// An Update run: the rows its command upgrades, each from → to, with where it came from.
    public static func update(_ title: String, command: String, rows: [UpdateRow], home: String = NSHomeDirectory()) -> RunReport {
        RunReport(kind: .update, title: title, command: command,
                  items: rows.map { Item(name: $0.item.name, from: $0.from, to: $0.to, detail: $0.item.kindLabel(home: home)) })
    }

    /// A Clean run: what Mole's preview said it would remove, and its potential space; none when no preview was kept.
    public static func clean(command: String, preview: CleanPreview?) -> RunReport {
        RunReport(kind: .clean, title: "Clean", command: command,
                  items: (preview?.items ?? []).map { Item(name: $0.title, detail: $0.detail.isEmpty ? $0.section : "\($0.section) · \($0.detail)") },
                  estimate: preview?.total)
    }
}

/// How a run ended, read from its folder: the exit status the script wrote, else whether its shell still lives.
public enum RunEnd: Equatable, Sendable {
    case running, done
    case failed(Int32)
    /// Ctrl+C (130), the window closed (129, or a shell gone with no status) or a stop (143); nil when no status came.
    case cancelled(Int32?)

    /// `alive` is nil before the script wrote its pid: the terminal has not started it yet, and two minutes on it never will.
    public init(exit: Int32?, alive: Bool?, started: Date, now: Date) {
        switch exit {
        case 0?: self = .done
        case let code? where [129, 130, 143].contains(code): self = .cancelled(code)
        case let code?: self = .failed(code)
        case nil: self = alive ?? (now.timeIntervalSince(started) < 120) ? .running : .cancelled(nil)
        }
    }

    /// How a settled run ended, from its exit status alone.
    public init(settled exit: Int32?) { self.init(exit: exit, alive: false, started: .distantPast, now: .distantPast) }

    /// The list's word for it.
    public var word: String {
        switch self {
        case .running: "running"
        case .done: "done"
        case .failed(let code): "failed · exit \(code)"
        case .cancelled(let code?): "cancelled · exit \(code)"
        case .cancelled(nil): "cancelled"
        }
    }
}

/// A run as the Reports view lists it: what was asked, how it ended, when, and Clean's space freed when Mole said it.
public struct RunRecord: Equatable, Sendable, Identifiable {
    public let report: RunReport
    public let end: RunEnd
    public let ended: Date?
    public let freed: String?

    public var id: String { report.id }

    public init(report: RunReport, end: RunEnd, ended: Date? = nil, freed: String? = nil) {
        self.report = report; self.end = end; self.ended = ended; self.freed = freed
    }

    /// The line under its title: what changed, or what it was asked to change when it did not finish.
    public var summary: String {
        let n = report.items.count, things = "\(n) \(n == 1 ? "item" : "items")"
        switch report.kind {
        case .update: return end == .done ? "\(things) updated" : "\(things) asked"
        case .clean: return freed.map { "\($0) freed" } ?? report.estimate.map { "Mole estimated \($0)" } ?? things
        }
    }

    /// The heading over its items: what Update changed or was asked to, or what Mole listed.
    public var itemsHeading: String {
        switch report.kind {
        case .update: end == .done ? "Updated" : "Asked to update"
        case .clean: "Mole listed"
        }
    }
}

/// The text a run printed, made readable: terminal colours and cursor moves out, a progress line overwritten in place
/// kept as its last state, and only the end kept past `limit` bytes, which says that the start was cut.
public enum ReportText {
    public static let limit = 128 * 1024
    static let cut = "… the start of the output was cut; the end is kept."

    public static func clean(_ raw: Data, limit: Int = limit) -> String {
        var text = String(decoding: raw, as: UTF8.self)
        text = text.replacing(/\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)/, with: "")   // OSC: titles, links
        text = text.replacing(/\x1B\[[0-?]*[ -\/]*[@-~]/, with: "")           // CSI: colours, cursor
        text = text.replacing(/\x1B[()][0-9A-Za-z]|\x1B[@-Z\\-_=>]/, with: "")
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line in
            // A carriage return redraws the line: its last drawing stands.
            let drawn = line.split(separator: "\r").last(where: { !$0.isEmpty }).map(String.init) ?? ""
            var kept: [Character] = []
            for c in drawn {
                if c == "\u{8}" { _ = kept.popLast() } else if c == "\t" || !(c.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) { kept.append(c) }
            }
            return String(kept)
        }
        let all = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard all.utf8.count > limit else { return all }
        let tail = String(decoding: all.utf8.suffix(limit), as: UTF8.self)
        return cut + "\n" + (tail.firstIndex(of: "\n").map { String(tail[tail.index(after: $0)...]) } ?? tail)
    }

    /// A raw capture's last `2 × limit` bytes, enough for the kept end once colours are out, so a long run's whole
    /// output is never read; marked cut when there was more.
    public static func clean(file: URL, limit: Int = limit) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0, start = size > UInt64(2 * limit) ? size - UInt64(2 * limit) : 0
        try? handle.seek(toOffset: start)
        let text = clean((try? handle.readToEnd()) ?? Data(), limit: limit)
        return start > 0 && !text.hasPrefix(cut) ? cut + "\n" + text : text
    }

    /// Mole's real clean ends with "Tracked cleanup: 12.3GB | Items cleaned: 140": the space it freed; nil otherwise.
    public static func freed(_ output: String) -> String? {
        guard let found = output.range(of: "Tracked cleanup: ", options: .backwards) else { return nil }
        let line = output[found.upperBound...].prefix { !$0.isNewline }
        return line.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Every Update and Clean run, one folder each under ~/Library/Application Support/Pilot/Reports (story 153): Pilot writes
/// `report.json` as the terminal opens; the run's script writes `pid`, its output through script(1) to `output` (the
/// command's own words only, never what is typed, so no password) and its exit status to `status`. The first read after
/// the end keeps the readable text in `output.txt` and the outcome in `end.json`. The newest `keep` runs stay.
public struct ReportStore: Sendable {
    public static let standard = ReportStore(folder: PilotFolder.support.appending(path: "Reports"))
    public static let keep = 50
    /// Posted as a run's report is written, so an open Reports view lists it.
    public static let began = Notification.Name("dev.banozz.pilot.reportBegan")

    public let folder: URL
    public let keep: Int

    public init(folder: URL, keep: Int = ReportStore.keep) {
        self.folder = folder
        self.keep = keep
    }

    public func directory(_ id: String) -> URL { folder.appending(path: id, directoryHint: .isDirectory) }

    /// The run's folder, its report written, and the oldest runs past `keep` gone; the folder the script writes into.
    @discardableResult
    public func begin(_ report: RunReport) throws -> URL {
        let dir = directory(report.id)
        try JSONFile<RunReport>(url: dir.appending(path: "report.json")).save(report)
        let folders = folders()
        if folders.count > keep {
            // Read, not settled: a run is settled only once its own script has written to its folder.
            let all = folders.compactMap { Self.read(RunReport.self, $0.appending(path: "report.json")) }.sorted { $0.started > $1.started }
            for old in all.dropFirst(keep) { try? FileManager.default.removeItem(at: directory(old.id)) }
        }
        NotificationCenter.default.post(name: Self.began, object: nil)
        return dir
    }

    private struct End: Codable { let exit: Int32?, ended: Date, freed: String? }

    /// Every run, newest first; a run that ended since the last read is settled first. A folder that does not read is
    /// left out.
    public func list(now: Date = .now, alive: (Int32) -> Bool = { KillProcess.send(0, to: $0) }) -> [RunRecord] {
        folders().compactMap { record($0, now: now, alive: alive) }.sorted { $0.report.started > $1.report.started }
    }

    /// One run by its id, settled as `list` settles it; nil when its folder does not read.
    public func record(_ id: String, now: Date = .now, alive: (Int32) -> Bool = { KillProcess.send(0, to: $0) }) -> RunRecord? {
        record(directory(id), now: now, alive: alive)
    }

    private func folders() -> [URL] { (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] }

    /// The readable output of a run: what it printed so far while it runs, else the kept text.
    public func output(_ id: String) -> String {
        let dir = directory(id)
        return (try? String(contentsOf: dir.appending(path: "output.txt"), encoding: .utf8)) ?? ReportText.clean(file: dir.appending(path: "output")) ?? ""
    }

    private func record(_ dir: URL, now: Date, alive: (Int32) -> Bool) -> RunRecord? {
        guard let report = Self.read(RunReport.self, dir.appending(path: "report.json")) else { return nil }
        let endFile = JSONFile<End>(url: dir.appending(path: "end.json"))
        if let end = Self.read(End.self, endFile.url) {
            return RunRecord(report: report, end: RunEnd(settled: end.exit), ended: end.ended, freed: end.freed)
        }
        func number(_ name: String) -> Int32? {
            (try? String(contentsOf: dir.appending(path: name), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let exit = number("status")
        let how = RunEnd(exit: exit, alive: number("pid").map(alive), started: report.started, now: now)
        guard how != .running else { return RunRecord(report: report, end: how) }
        // Ended: keep the readable text and the outcome, and drop the raw capture.
        let raw = dir.appending(path: "output")
        let text = output(report.id)
        let freed = report.kind == .clean ? ReportText.freed(text) : nil
        // To the second, as end.json keeps it, so a later read lists the same record.
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: dir.appending(path: exit == nil ? "output" : "status").path))?[.modificationDate] as? Date) ?? now
        let ended = Date(timeIntervalSince1970: stamp.timeIntervalSince1970.rounded(.down))
        try? text.write(to: dir.appending(path: "output.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: raw)
        try? endFile.save(End(exit: exit, ended: ended, freed: freed))
        return RunRecord(report: report, end: how, ended: ended, freed: freed)
    }

    private static func read<T: Codable>(_ type: T.Type, _ url: URL) -> T? { (try? JSONFile<T?>(url: url).load(or: nil)) ?? nil }
}
