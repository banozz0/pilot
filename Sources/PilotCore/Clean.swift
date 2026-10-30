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

/// What `mo clean --dry-run` says it would remove (story 117): each `→` line under its `➤` section, in Mole's words,
/// and the summary's potential space. Review-only (`⊙`) and skipped (`◎`) lines are not cleaned, so they are left out.
public struct CleanPreview: Equatable, Sendable {
    public struct Item: Equatable, Sendable { public let section: String, title: String, detail: String }

    public let items: [Item]
    /// The summary's "Potential space", nil when Mole printed none (nothing to clean, or a run cut short).
    public let total: String?
    /// Mole skipped the system caches for want of a cached admin session; the real clean asks for it.
    public let systemSkipped: Bool

    public static func parse(_ text: String) -> CleanPreview {
        var items: [Item] = [], section = "", total: String?, systemSkipped = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("➤ ") { section = String(line.dropFirst(2)) }
            else if line.hasPrefix("→ ") { items.append(item(String(line.dropFirst(2)), section: section)) }
            else if line.hasPrefix("Potential space: ") {
                total = line.dropFirst("Potential space: ".count).components(separatedBy: " | ").first
            } else if line.contains("System caches need sudo") { systemSkipped = true }
        }
        return CleanPreview(items: items, total: total, systemSkipped: systemSkipped)
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

/// How far Mole's preview has got (card agent-bo-95423002): the `➤` section it is on and the `→` items found so far.
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
        if line.hasPrefix("➤ ") { section = String(line.dropFirst(2)) } else if line.hasPrefix("→ ") { items += 1 }
    }
}

/// The Clean branch's rows (story 117).
public enum CleanMenu {
    /// What a Clean row is: the clean, the disk explorer, Install Mole, or a line to read (an item, a note), by its place,
    /// since a row's target is its id in the list and Mole repeats titles ("Obsolete VS Code extension").
    public enum Pick: Hashable, Sendable { case run, analyze, install, note(Int), reports }

    /// With Mole missing, one row installs it through Install's confirm step, Homebrew with it in one run when that is
    /// missing too (Sven, 2026-10-29, Q557). While the preview runs, nothing, so the menu says it is previewing. Then the
    /// clean with its total and exact command, each item, a note when the system caches were skipped, and Disk usage.
    /// Reports (story 153) ends the list.
    public static func entries(_ preview: CleanPreview?, mole: Bool, homebrew: Bool = true) -> [MenuEntry] {
        func row(_ title: String, _ pick: Pick, _ detail: String? = nil, _ icon: MenuIcon) -> MenuEntry {
            MenuEntry(title: title, target: .clean(pick), home: .clean, detail: detail, inSearch: false, icon: icon)
        }
        let reports = row("Reports", .reports, "every Update and Clean run, kept", MenuIcon.reports)
        guard mole else {
            let install = homebrew ? row("Install Mole", .install, Helper.mole.install, .glyph("arrow.down.circle", .accent))
                : row("Install Homebrew and Mole", .install, "one Terminal run · asks your password there", .glyph("arrow.down.circle", .accent))
            return [install, reports]
        }
        guard let preview else { return [] }
        let items = preview.items.enumerated().map { i, item in
            row(item.title, .note(i), item.detail.isEmpty ? item.section : "\(item.section) · \(item.detail)",
                MenuIcon.clean(title: item.title, section: item.section))
        }
        let system = preview.systemSkipped
            ? [row("System caches: the clean asks for your password", .note(items.count), nil, .glyph("lock", .amber))] : []
        return [row(["Clean", preview.total].compactMap(\.self).joined(separator: " "), .run, Mole.clean, .glyph("sparkles", .good))] + items + system
            + [row("Disk usage", .analyze, Mole.analyze, .glyph("chart.pie", .third)), reports]
    }

    /// What the branch says while Mole previews: the section it is on and what it found so far, once it has printed any.
    public static func waiting(_ progress: CleanProgress?) -> String {
        let keeps = "it keeps going if you close the menu."
        guard let section = progress?.section else { return "Mole is starting its preview, which takes a minute or two; \(keeps)" }
        let items = progress?.items ?? 0
        return "Mole is checking \(section), \(items) item\(items == 1 ? "" : "s") so far; \(keeps)"
    }

    /// The tip when a preview ends with Clean not on screen; nil while it shows, since its rows (or its failure) say it.
    public static func tip(_ preview: CleanPreview?, showing: Bool) -> String? {
        guard !showing else { return nil }
        guard let preview else { return "Mole's preview did not finish; open Clean to try again" }
        return "Mole's preview is ready: " + (preview.total.map { "Clean \($0) in Pilot's menu" } ?? "nothing to clean")
    }
}

/// Mole's preview, run once and kept for 15 minutes (it takes a minute or two and keeps going when the menu closes);
/// a menu opening meanwhile waits on the same run and reads its progress. `run` is the dry run's output, nil when it
/// failed; it hands each line Mole prints to its argument as it goes.
@MainActor @Observable
public final class CleanPreviewer {
    public static let keep: TimeInterval = 15 * 60

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let run: (@escaping @Sendable (String) -> Void) async -> String?
    @ObservationIgnored private var kept: (at: Date, preview: CleanPreview)?
    @ObservationIgnored private var running: Task<CleanPreview?, Never>?
    /// Bumped by `drop`, so a run let go of before a clean neither reports nor is kept.
    @ObservationIgnored private var generation = 0
    /// How far the run has got; nil when none runs.
    public private(set) var progress: CleanProgress?
    /// Each run's end, once, whether or not a menu waits on it: its preview, or nil when it failed.
    @ObservationIgnored public var onFinish: ((CleanPreview?) -> Void)?

    public init(now: @escaping () -> Date = { .now }, run: @escaping (@escaping @Sendable (String) -> Void) async -> String?) {
        self.now = now
        self.run = run
    }

    /// The kept preview while it is fresh.
    public var ready: CleanPreview? {
        guard let kept, now().timeIntervalSince(kept.at) < Self.keep else { return nil }
        return kept.preview
    }

    /// The fresh preview, or Mole's next one; nil when the run failed, which is not kept. Cancelling the caller only stops
    /// its wait: the run carries on and ends in `finish`.
    public func preview() async -> CleanPreview? {
        if let ready { return ready }
        if let running { return await running.value }
        let mine = generation
        progress = CleanProgress()
        let task = Task { [run] in
            let preview = await run { line in Task { @MainActor [weak self] in self?.heard(line, in: mine) } }.map(CleanPreview.parse)
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
        progress = nil
        running?.cancel()
        running = nil
    }

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
        if let preview { kept = (now(), preview) }
        onFinish?(preview)
    }
}
