import CryptoKit
import Foundation
import PilotCore
import UserNotifications

/// Reminders from a quick note (P66, Q776): a note line with a date in it (NSDataDetector, on the Mac) reminds at that
/// time with Done, which ticks the line, and Snooze, ten minutes on; once per line. A relative date ("tomorrow 6pm") is
/// read once, the first time the line is seen, and kept in note-reminders.json (each line as its `id` and its time,
/// never its words; a fired one too, so a relaunch never arms it again), so it never moves on a day; an edited
/// line is a new line, read again, and a line deleted or ticked takes its reminder with it. A dated line first seen in
/// a note last edited over a day ago keeps none: its "tomorrow" was another day's (the notes Pilot finds at the first
/// launch with reminders). Ticked to-dos and code blocks are never read.
@MainActor
final class NoteReminders: NSObject {
    static let shared = NoteReminders()

    /// One line's reminder: the note it is in, the line as written (trimmed), and when.
    struct Reminder: Equatable, Sendable {
        let note: String
        let line: String
        let at: Date
    }

    nonisolated static let prefix = "note.reminder."
    static let category = "note.reminder"
    static let snooze: TimeInterval = 10 * 60
    /// A line first seen in a note edited longer ago than this gets no reminder.
    static let fresh: TimeInterval = 24 * 3600

    private let file: URL
    /// Each dated line's time, as first read or snoozed to, keyed by `id(line)`: its reminder while ahead, none once
    /// passed. Passed ones stay, on disk too, until their line leaves every note, so a line is never read twice.
    private var kept: [String: Date]
    /// Lines read this run, with their date or none, so a save never reads a line twice.
    private var read: [String: Date?] = [:]
    /// What was last handed to Notification Center, so a save that changes no reminder asks it nothing.
    private var scheduled: [String: Date]?
    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    init(file: URL = PilotFolder.support.appending(path: "note-reminders.json")) {
        self.file = file
        let saved = (try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: file))) ?? [:]
        // Files before 1.1 keyed each line by its words: those move to ids, and the words leave the file.
        kept = Dictionary(saved.map { ($0.key.hasPrefix(Self.prefix) ? $0.key : Self.id($0.key), $0.value) },
                          uniquingKeysWith: max)
        super.init()
        if !isTestRun, saved.keys.contains(where: { !$0.hasPrefix(Self.prefix) }) { save() }
    }

    /// The lines of `text` a date is read from: trimmed, not blank, not a ticked to-do, outside code blocks.
    nonisolated static func lines(_ text: String) -> [String] {
        var fenced = false
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fenced.toggle(); return nil }
            guard !fenced, !line.isEmpty, !isTicked(line) else { return nil }
            return line
        }
    }

    nonisolated static func isTicked(_ line: String) -> Bool { line.firstMatch(of: /^[-*+][ \t]+\[[xX]\]/) != nil }

    /// `text` with `line` ticked: a to-do's box checked, a bullet made a ticked to-do, any other line too. Nil when the
    /// note no longer holds it.
    nonisolated static func ticked(_ line: String, in text: String) -> String? {
        var rows = text.components(separatedBy: "\n")
        guard let at = rows.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == line }) else { return nil }
        let row = rows[at]
        let indent = row.prefix { $0 == " " || $0 == "\t" }, rest = row.dropFirst(indent.count)
        if let box = rest.firstMatch(of: /^([-*+][ \t]+)\[ \]/) {
            rows[at] = String(indent + box.1) + "[x]" + rest[box.range.upperBound...]
        } else if let bullet = rest.firstMatch(of: /^[-*+][ \t]+/) {
            rows[at] = String(indent + bullet.output) + "[x] " + rest[bullet.range.upperBound...]
        } else {
            rows[at] = String(indent) + "- [x] " + rest
        }
        return rows.joined(separator: "\n")
    }

    /// The first date in `line`, read against now.
    private func date(_ line: String) -> Date? {
        if let known = read[line] { return known }
        let found = detector?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))?.date
        read[line] = found
        return found
    }

    /// Every dated line's reminder across `notes`, the passed ones too: each line new since the last plan read once and
    /// kept, lines gone dropped. `notes` is every note, so a line missing from it is gone.
    func plan(_ notes: [Note], now: Date = .now) -> [Reminder] {
        var all: [Reminder] = [], seen = Set<String>(), before = kept
        for note in notes where !note.isScratch {
            for line in Self.lines(note.text) {
                let id = Self.id(line)
                seen.insert(id)
                if kept[id] == nil, let at = date(line) {
                    kept[id] = now.timeIntervalSince(note.edited) <= Self.fresh ? at : .distantPast
                }
                if let at = kept[id], at != .distantPast { all.append(Reminder(note: note.id, line: line, at: at)) }
            }
        }
        // No notes is a folder that did not read (not mounted yet at login), never every line gone: what is kept stays.
        if !notes.isEmpty {
            kept = kept.filter { seen.contains($0.key) }
            read = read.filter { seen.contains(Self.id($0.key)) }
        }
        if kept != before { save() }
        return all
    }

    /// The open note's reminders still ahead, for the time under its words: from what was kept, else read now.
    func upcoming(in text: String, now: Date = .now) -> [Reminder] {
        Self.lines(text).compactMap { line in
            (kept[Self.id(line)] ?? date(line)).flatMap { $0 > now ? Reminder(note: "", line: line, at: $0) : nil }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(kept).write(to: file, options: .atomic)
        } catch { noteslog.error("note reminders: \(String(describing: error), privacy: .public)") }
    }

    /// After every change to the notes (NotesModel's list) and at launch: plans, then hands Notification Center the
    /// reminders still ahead, each line's request replaced when its time moved and removed when it went.
    func sync(_ notes: [Note], now: Date = .now) {
        let ahead = plan(notes, now: now).filter { $0.at > now }
        let wanted = Dictionary(ahead.map { (Self.id($0.line), $0) }, uniquingKeysWith: { first, _ in first })
        guard !isTestRun, scheduled != wanted.mapValues(\.at) else { return }
        scheduled = wanted.mapValues(\.at)
        Task {
            let center = UNUserNotificationCenter.current()
            var have: [String: Date] = [:]
            for request in await center.pendingNotificationRequests() where request.identifier.hasPrefix(Self.prefix) {
                have[request.identifier] = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantPast
            }
            let moved = Set(have.keys.filter { id in wanted[id].map { abs($0.at.timeIntervalSince(have[id]!)) >= 1 } ?? true })
            center.removePendingNotificationRequests(withIdentifiers: Array(moved))
            let add = wanted.filter { have[$0.key] == nil || moved.contains($0.key) }
            guard !add.isEmpty, (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            for (id, reminder) in add {
                let content = UNMutableNotificationContent()
                content.title = Notes.title(of: reminder.line)
                let when = NotesText.reminder(reminder.at)
                content.body = when.prefix(1).uppercased() + when.dropFirst()
                content.sound = .default
                content.categoryIdentifier = Self.category
                content.userInfo = ["line": reminder.line, "note": reminder.note]
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.at)
                do {
                    try await center.add(UNNotificationRequest(identifier: id, content: content,
                                                               trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
                } catch { noteslog.error("note reminder: \(String(describing: error), privacy: .public)") }
            }
        }
    }

    /// One line's request id: the same line is one reminder, whichever note it moves to.
    nonisolated static func id(_ line: String) -> String {
        prefix + SHA256.hash(data: Data(line.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// At launch: answers Done, Snooze and a click on a reminder, and schedules what the notes folder holds, read off
    /// the main thread and without writing to it.
    func start() {
        guard !isTestRun else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [
            UNNotificationAction(identifier: Answer.done.rawValue, title: "Done"),
            UNNotificationAction(identifier: Answer.snooze.rawValue, title: "Snooze 10 min"),
        ], intentIdentifiers: [])])
        let folder = NotesPanel.shared.folder
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        Task {
            let notes = await Task.detached { Self.notes(in: folder) }.value
            sync(notes)
        }
    }

    /// The notes in `folder` as they are on disk; nothing written.
    nonisolated static func notes(in folder: URL) -> [Note] {
        NotesFolder.notes(in: folder).compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let edited = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Note(id: url.lastPathComponent, text: text, edited: edited, pinned: false)
        }
    }

    enum Answer: String { case done, snooze }

    /// Done ticks the line in its note (the shared model's write, so the panel and the page follow and the reminder
    /// goes); Snooze keeps the line ten minutes on; a click opens the note in the panel.
    func answer(_ action: String, line: String, note: String) {
        let model = NotesPanel.shared.currentModel()
        switch Answer(rawValue: action) {
        case .done:
            model.flush()
            let notes = (try? model.store.load()) ?? []
            let holding = notes.first { $0.id == note && Self.lines($0.text).contains(line) } ?? notes.first { Self.lines($0.text).contains(line) }
            guard let holding, let text = Self.ticked(line, in: holding.text) else { return }
            do { _ = try model.write(holding.id, text: text) } catch { noteslog.error("note reminder done: \(String(describing: error), privacy: .public)") }
        case .snooze:
            kept[Self.id(line)] = Date.now.addingTimeInterval(Self.snooze)
            save()
            scheduled = nil
            sync(NotesPanel.shared.notes())
        case nil:
            NotesPanel.shared.show(note: note)
        }
    }
}

extension NoteReminders: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        guard request.identifier.hasPrefix(Self.prefix), let line = request.content.userInfo["line"] as? String else { return }
        let note = request.content.userInfo["note"] as? String ?? "", action = response.actionIdentifier
        await MainActor.run { answer(action, line: line, note: note) }
    }

    /// A reminder shows while Pilot is in front too; every other notification as before.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(Self.prefix) ? [.banner, .list, .sound] : []
    }
}
