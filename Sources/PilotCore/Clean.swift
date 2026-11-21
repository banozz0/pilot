import Foundation
import Observation

/// Mole (tw93/Mole, GPL-3.0; Pilot runs its CLI and holds none of its code): the only commands Pilot runs through it
/// (story 117). Never its whitelist, which replaces Mole's built-in protections rather than adding to them, nor purge,
/// optimize or uninstall (card agent-bo-95422881 says why).
public enum Mole {
    /// The read-only preview, run off the main thread with NO_COLOR=1 and stdin closed.
    public static let preview = ["clean", "--dry-run"]
    /// The clean itself, run only in the visible terminal after the confirm step, where Mole asks for admin access.
    public static let clean = "mo clean"
    /// Mole's disk explorer, in the visible terminal; what it moves to the Trash it asks about first.
    public static let analyze = "mo analyze"
}

/// What `mo clean --dry-run` says it would remove (story 117): each item line under its `➤` section, in Mole's words,
/// and the summary's potential space. Mole marks an item `→` up to 1.54 and `○` (its ICON_DRY_RUN) from 1.72; both
/// mean it would clean it. Review-only (`⊙`) and skipped (`◎`) lines are not cleaned, so they are left out.
public struct CleanPreview: Equatable, Sendable {
    public struct Item: Equatable, Sendable { public let section: String, title: String, detail: String }

    public let items: [Item]
    /// The summary's "Potential space", nil when Mole printed none (nothing to clean, or a run cut short).
    public let total: String?
    /// Mole skipped the system caches for want of a cached admin session; the real clean asks for it.
    public let systemSkipped: Bool
    /// Every path the run listed in its file list, what Clean's ticks act on (W89); empty when the file did not read.
    public var list: CleanList = .empty

    public static func parse(_ text: String) -> CleanPreview {
        var items: [Item] = [], section = "", total: String?, systemSkipped = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("➤ ") { section = String(line.dropFirst(2)) }
            else if let rest = itemLine(line) { items.append(item(rest, section: section)) }
            else if line.hasPrefix("Potential space: ") {
                // "28.75GB | Items: 834 | Categories: 6" up to 1.54, "2.09GB · 212 items" from 1.72: the size alone.
                total = line.dropFirst("Potential space: ".count).components(separatedBy: " | ").first?
                    .components(separatedBy: " · ").first
            } else if line.contains("System caches need sudo") { systemSkipped = true }
        }
        return CleanPreview(items: items, total: total, systemSkipped: systemSkipped)
    }

    /// An item line's text after its marker, `→ ` (Mole 1.54) or `○ ` (Mole 1.72); nil for any other line.
    static func itemLine(_ line: String) -> String? {
        line.hasPrefix("→ ") || line.hasPrefix("○ ") ? String(line.dropFirst(2)) : nil
    }

    /// "Chrome cache · 1.73GB dry" or "Chrome Service Worker, would clean 270.4MB, 0 protected": the title, then the rest
    /// without Mole's "dry" tag.
    private static func item(_ line: String, section: String) -> Item {
        let split = line.range(of: " · ") ?? line.range(of: ", ")
        let title = split.map { String(line[..<$0.lowerBound]) } ?? line
        var detail = split.map { String(line[$0.upperBound...]) } ?? ""
        if detail.hasSuffix(" dry") { detail.removeLast(4) }
        return Item(section: section, title: title, detail: detail)
    }
}

/// Mole's own file list from its dry run, `~/.config/mole/clean-list.txt` (Mole 1.72): each path it would remove, under
/// its `=== part ===` heading, with its size (W89). Clean shows them as ticked rows, every one ticked as Mole's clean took
/// them all, and moves only the ticked ones to the Trash. Left out, so never offered: a path counted under another listed
/// one (it goes with that one), anything in the Trash (Mole empties it; it cannot go to the Trash again), and any line
/// that is not one absolute path.
public struct CleanList: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        /// A short hash of the path: the same path keeps its id from one run to the next.
        public let id: String
        public let path: String, part: String
        /// Mole's measure, nil when it said "size unknown".
        public let bytes: Int64?
        /// The files and folders it holds, as Mole counted them (1 for one).
        public let count: Int

        public init(path: String, part: String, bytes: Int64?, count: Int = 1) {
            id = CleanList.id(path); self.path = path; self.part = part; self.bytes = bytes; self.count = count
        }

        public var size: String { bytes.map(RemoveList.size) ?? "size unknown" }
    }

    /// One `=== part ===` heading's rows, in Mole's order.
    public struct Part: Equatable, Sendable, Identifiable {
        public let name: String
        public let rows: [Row]
        public var id: String { name }
        public var bytes: Int64 { CleanList.bytes(rows) }
    }

    public let rows: [Row]
    /// The rows by part, grouped once here, not on every read.
    public let parts: [Part]
    public static let empty = CleanList(rows: [])

    public init(rows: [Row]) {
        self.rows = rows
        var order: [String] = [], grouped: [String: [Row]] = [:]
        for row in rows {
            if grouped[row.part] == nil { order.append(row.part) }
            grouped[row.part, default: []].append(row)
        }
        parts = order.map { Part(name: $0, rows: grouped[$0] ?? []) }
    }

    public var bytes: Int64 { Self.bytes(rows) }
    public static func bytes(_ rows: [Row]) -> Int64 { rows.compactMap(\.bytes).reduce(0, +) }

    /// The rows `ids` name, in the list's order; an id it does not hold is dropped, so nothing outside it can be named.
    public func rows(_ ids: some Collection<String>) -> [Row] {
        let wanted = Set(ids)
        return rows.filter { wanted.contains($0.id) }
    }

    /// The list once `ids` are gone: what a clean left.
    public func without(_ ids: Set<String>) -> CleanList { CleanList(rows: rows.filter { !ids.contains($0.id) }) }

    /// `/Users/me/Library/Caches/Foo  # 57.9MB, 12 items` under `=== App caches ===`; `home` places its Trash.
    public static func parse(_ text: String, home: String) -> CleanList {
        let trash = (home.hasSuffix("/") ? home : home + "/") + ".Trash/"
        var rows: [Row] = [], part = "", seen = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("=== "), line.hasSuffix(" ===") { part = String(line.dropFirst(4).dropLast(4)); continue }
            guard !line.hasPrefix("#"), let mark = line.range(of: "  # ", options: .backwards) else { continue }
            let path = String(line[..<mark.lowerBound]), notes = line[mark.upperBound...].components(separatedBy: ", ")
            guard path.hasPrefix("/"), !path.contains("*"), !path.hasPrefix(trash), (path as NSString).standardizingPath == path,
                  !notes.contains(where: { $0.hasPrefix("counted under ") }), seen.insert(path).inserted else { continue }
            let count = notes.dropFirst().lazy.compactMap { $0.hasSuffix(" items") ? Int($0.dropLast(6)) : nil }.first ?? 1
            rows.append(Row(path: path, part: part, bytes: size(notes[0]), count: count))
        }
        return CleanList(rows: rows)
    }

    /// Mole's sizes are decimal ("57.9MB", "1.02GB", "4KB", "0B"); nil for "size unknown".
    public static func size(_ words: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (unit, scale) in units where words.hasSuffix(unit) {
            return Double(words.dropLast(unit.count)).map { Int64(($0 * scale).rounded()) }
        }
        return nil
    }

    /// FNV-1a of the path, its first 10 hex digits.
    public static func id(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let hex = String(hash, radix: 16)
        return String((String(repeating: "0", count: 16 - hex.count) + hex).prefix(10))
    }

    /// Moves each row to the Trash through `trash`, one at a time: a row that fails says why and the rest go on. A path
    /// that is gone, or is `home` or a folder above it, is not moved.
    public static func move(_ rows: [Row], home: String, trash: (URL) async throws -> Void) async -> CleanOutcome {
        var outcome = CleanOutcome()
        let homeParts = URL(filePath: home).standardizedFileURL.pathComponents
        for row in rows {
            let url = URL(filePath: row.path)
            if homeParts.starts(with: url.standardizedFileURL.pathComponents) {
                outcome.failed.append(.init(row: row, why: "it holds the home folder, so Clean leaves it"))
            } else if (try? FileManager.default.attributesOfItem(atPath: row.path)) == nil {
                outcome.failed.append(.init(row: row, why: "it is no longer there"))
            } else {
                do {
                    try await trash(url)
                    outcome.moved.append(row)
                } catch { outcome.failed.append(.init(row: row, why: error.localizedDescription)) }
            }
        }
        return outcome
    }
}

/// What a clean of ticked rows did: the rows now in the Trash, and each one that is not with why.
public struct CleanOutcome: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let row: CleanList.Row, why: String
    }

    public var moved: [CleanList.Row] = [], failed: [Failure] = []
    /// The run's id in Reports, once it is kept there.
    public var report: String?

    public init(moved: [CleanList.Row] = [], failed: [Failure] = []) { self.moved = moved; self.failed = failed }

    public var bytes: Int64 { CleanList.bytes(moved) }

    /// "Moved 2 items, 1.2 MB, to the Trash; 1 not moved."
    public var summary: String {
        let n = moved.count
        let lead = "Moved \(n) item\(n == 1 ? "" : "s"), \(RemoveList.size(bytes)), to the Trash"
        return failed.isEmpty ? lead : "\(lead); \(failed.count) not moved"
    }

    /// What Reports keeps as the run's output: each row moved or not and why, then the summary.
    public func text(home: String) -> String {
        let moved = moved.map { "Moved to the Trash: \(AppConfigs.tilde($0.path, home: home)) (\($0.size))" }
        let failed = failed.map { "Not moved: \(AppConfigs.tilde($0.row.path, home: home)): \($0.why)" }
        return (moved + failed + ["", summary]).joined(separator: "\n")
    }
}

/// How far Mole's preview has got (card agent-bo-95423002): the `➤` section it is on and the items (`→` or `○`) found so far.
public struct CleanProgress: Equatable, Sendable {
    public var section: String?
    public var items = 0

    public init(section: String? = nil, items: Int = 0) {
        self.section = section
        self.items = items
    }

    /// Reads one line of Mole's output as it prints it.
    public mutating func read(_ line: String) {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("➤ ") { section = String(line.dropFirst(2)) } else if CleanPreview.itemLine(line) != nil { items += 1 }
    }
}

/// The Clean branch's rows (story 117).
public enum CleanMenu {
    /// What a Clean row is: Mole's whole clean, the ticked paths to the Trash, the disk explorer, Install Mole, a line to
    /// read (an item, a note) by its place, since a row's target is its id in the list and Mole repeats titles ("Obsolete
    /// VS Code extension"), a part's plain line when Mole listed none of its paths, or a path's tick by its id.
    public enum Pick: Hashable, Sendable {
        case run, ticked, analyze, install, note(Int), unlisted(String), path(String), reports

        /// A line to read or a tick: Return keeps the menu open on it.
        public var staysOpen: Bool {
            switch self {
            case .note, .unlisted, .path: true
            default: false
            }
        }
    }

    /// A part of Mole's preview: its `➤` section, which its file list heads `=== part ===` too (Mole records only the
    /// section a path was found in, never the item line).
    public static func part(_ section: String) -> MenuBranch { .category(section, in: .clean) }

    /// With Mole missing, one row installs it through Install's confirm step, Homebrew with it in one run when that is
    /// missing too (Sven, 2026-10-29, Q557). While the preview runs, nothing, so the menu says it is previewing. Then the
    /// clean with its total and exact command (with a path unticked, Clean ticked first, moving only the ticked paths to
    /// the Trash, then Clean all: Q310, Q311), a row per part that opens to Mole's lines for it and its paths one by one,
    /// biggest first, each with its tick, a note when the system caches were skipped, and Disk usage. Reports (story 153)
    /// ends the list.
    public static func entries(_ preview: CleanPreview?, mole: Bool, homebrew: Bool = true, unticked: Set<String> = [],
                               home: String = NSHomeDirectory()) -> [MenuEntry] {
        func row(_ title: String, _ pick: Pick, _ detail: String? = nil, _ icon: MenuIcon, in branch: MenuBranch = .clean) -> MenuEntry {
            MenuEntry(title: title, target: .clean(pick), home: branch, detail: detail, inSearch: false, icon: icon)
        }
        let reports = row("Reports", .reports, "every Update and Clean run, kept", MenuIcon.reports)
        guard mole else {
            let install = homebrew ? row("Install Mole", .install, Helper.mole.install, .glyph("arrow.down.circle", .accent))
                : row("Install Homebrew and Mole", .install, "one Terminal run · asks your password there", .glyph("arrow.down.circle", .accent))
            return [install, reports]
        }
        guard let preview else { return [] }
        let list = preview.list, ticked = list.rows.filter { !unticked.contains($0.id) }
        func clean(_ word: String) -> MenuEntry {
            row([word, preview.total].compactMap(\.self).joined(separator: " "), .run, Mole.clean, .glyph("sparkles", .good))
        }
        var rows = ticked.count == list.rows.count ? [clean("Clean")] : [
            row("Clean ticked \(RemoveList.size(CleanList.bytes(ticked)))", .ticked,
                "\(ticked.count) of \(list.rows.count) paths to the Trash", .glyph("checkmark.square", .good)),
            clean("Clean all")]
        var sections: [String] = []
        for name in preview.items.map(\.section) + list.parts.map(\.name) where !sections.contains(name) { sections.append(name) }
        let parts = Dictionary(list.parts.map { ($0.name, $0.rows) }) { first, _ in first }
        for section in sections {
            let branch = part(section), lines = preview.items.enumerated().filter { $0.element.section == section }
            let paths = (parts[section] ?? []).sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
            let named = lines.map(\.element.title).joined(separator: ", ")
            let on = paths.filter { !unticked.contains($0.id) }
            let state = paths.isEmpty ? "not listed one by one"
                : "\(on.count) of \(paths.count) ticked, \(RemoveList.size(CleanList.bytes(on)))"
            rows.append(MenuEntry(title: section, target: .branch(branch), home: .clean, detail: named.isEmpty ? state : "\(named) · \(state)",
                                  inSearch: false, icon: MenuIcon.clean(title: lines.first?.element.title ?? section, section: section)))
            rows += lines.map { i, item in
                row(item.title, .note(i), item.detail.isEmpty ? nil : item.detail, MenuIcon.clean(title: item.title, section: item.section), in: branch)
            }
            if paths.isEmpty {
                rows.append(row("Mole lists no paths here: Clean all cleans these, Clean ticked leaves them", .unlisted(section), nil,
                                .glyph("info.circle", .neutral), in: branch))
            }
            rows += paths.map { path in
                let tick = !unticked.contains(path.id)
                return row(AppConfigs.tilde(path.path, home: home), .path(path.id), path.count > 1 ? "\(path.count) items · \(path.size)" : path.size,
                           .glyph(tick ? "checkmark.square.fill" : "square", tick ? .good : .neutral), in: branch)
            }
        }
        if preview.systemSkipped {
            rows.append(row("System caches: the clean asks for your password", .note(preview.items.count), nil, .glyph("lock", .amber)))
        }
        return rows + [row("Disk usage", .analyze, Mole.analyze, .glyph("chart.pie", .third)), reports]
    }

    /// What the branch says while Mole previews: the section it is on and what it found so far, once it has printed any.
    public static func waiting(_ progress: CleanProgress?) -> String {
        let keeps = "it keeps going if you close the menu."
        guard let section = progress?.section else { return "Mole is starting its preview, which takes a minute or two; \(keeps)" }
        let items = progress?.items ?? 0
        return "Mole is checking \(section), \(items) item\(items == 1 ? "" : "s") so far; \(keeps)"
    }
}

/// Mole's preview, run once and kept for 15 minutes (it takes a minute or two and keeps going when the menu closes);
/// a menu opening meanwhile waits on the same run and reads its progress. `run` is the dry run's output, nil when it
/// failed; it hands each line Mole prints to its argument as it goes. `list` reads the file list that run wrote, given
/// when it started, so an older run's file is never read as this one's (W89).
@MainActor @Observable
public final class CleanPreviewer {
    public static let keep: TimeInterval = 15 * 60

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let run: (@escaping @Sendable (String) -> Void) async -> String?
    @ObservationIgnored private let list: @Sendable (Date) -> CleanList?
    @ObservationIgnored private var kept: (at: Date, preview: CleanPreview)?
    @ObservationIgnored private var running: Task<CleanPreview?, Never>?
    /// Bumped by `drop`, so a run let go of before a clean neither reports nor is kept.
    @ObservationIgnored private var generation = 0
    /// How far the run has got; nil when none runs.
    public private(set) var progress: CleanProgress?
    /// The kept list's paths unticked, by id, in Hyper+Space or on Update & Clean (one set for both, and `pilot clean`
    /// lists it): they stay when Clean ticked runs. A new run ticks them all again.
    public private(set) var unticked: Set<String> = []
    /// Each run's end, once, whether or not a menu waits on it: its preview, or nil when it failed.
    @ObservationIgnored public var onFinish: ((CleanPreview?) -> Void)?
    /// Each new run's start, with who asked for it (the menu, the command), so a log says what started Mole.
    @ObservationIgnored public var onStart: ((String) -> Void)?

    public init(now: @escaping () -> Date = { .now }, list: @escaping @Sendable (Date) -> CleanList? = { _ in nil },
                run: @escaping (@escaping @Sendable (String) -> Void) async -> String?) {
        self.now = now
        self.list = list
        self.run = run
    }

    /// The kept preview while it is fresh.
    public var ready: CleanPreview? {
        guard let kept, now().timeIntervalSince(kept.at) < Self.keep else { return nil }
        return kept.preview
    }

    /// The fresh preview, or Mole's next one; nil when the run failed, which is not kept. Cancelling the caller only stops
    /// its wait: the run carries on and ends in `finish`.
    public func preview(caller: String = "unknown") async -> CleanPreview? {
        if let ready { return ready }
        if let running { return await running.value }
        let mine = generation
        onStart?(caller)
        progress = CleanProgress()
        let task = Task { [run, list] in
            let started = Date.now
            var preview = await run { line in Task { @MainActor [weak self] in self?.heard(line, in: mine) } }.map(CleanPreview.parse)
            // The file list is read and parsed off the main thread.
            if preview != nil { preview?.list = await Task.detached { list(started) }.value ?? .empty }
            finish(preview, in: mine)
            return preview
        }
        running = task
        return await task.value
    }

    /// After a clean the kept preview is wrong, so the next open runs Mole again; a preview still running stops, rather
    /// than scan beside the clean.
    public func drop() {
        generation += 1
        kept = nil
        unticked = []
        progress = nil
        running?.cancel()
        running = nil
    }

    /// After a clean of ticked rows the rows it moved leave the kept list; the rest stay to tick, and Mole's own lines
    /// stay as it printed them.
    public func cleaned(_ ids: Set<String>) {
        guard let at = kept?.at, var preview = kept?.preview else { return }
        preview.list = preview.list.without(ids)
        kept = (at, preview)
        unticked.subtract(ids)
    }

    /// Ticks the path `id` names when it is unticked, else unticks it.
    public func toggle(_ id: String) { tick([id], on: unticked.contains(id)) }

    /// Ticks the paths `ids` name when `on`, else unticks them (a part's tick on Update & Clean).
    public func tick(_ ids: some Sequence<String>, on: Bool) {
        if on { unticked.subtract(ids) } else { unticked.formUnion(ids) }
    }

    /// The kept list's ticked paths' ids; none when no list is kept.
    public var ticked: [String] { (ready?.list.rows ?? []).map(\.id).filter { !unticked.contains($0) } }

    private func heard(_ line: String, in run: Int) {
        guard run == generation, var next = progress else { return }
        next.read(line)
        // Only a change redraws the menu: Mole prints blank and review lines too.
        if next != progress { progress = next }
    }

    private func finish(_ preview: CleanPreview?, in run: Int) {
        guard run == generation else { return }
        running = nil
        progress = nil
        if let preview { kept = (now(), preview); unticked = [] }
        onFinish?(preview)
    }
}
