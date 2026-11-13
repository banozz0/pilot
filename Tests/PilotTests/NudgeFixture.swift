import Foundation
@testable import Pilot
@testable import PilotCore

/// The sandbox's smart nudges (a harness, not a test; spec smart-nudges), from a throwaway folder:
/// - `events.json`: Calendar, `[{"id", "title", "start" (ISO 8601), "allDay"?, "url"?, "location"?, "notes"?}]`, read at
///   each look, its video links found as EventKit's are; `access` holds `granted` (the default), `denied` or `undetermined`.
/// - `playing`: what plays, `playing` or `paused`; a pause of something playing writes `paused`.
/// - `ai-usage.jsonl`: AI usage's bar answer, the lines its bar command prints, read through the bar round's decoder.
/// - `posted.jsonl`: what reached macOS's Notification Center and Pilot's tip, one line each, and every media step.
@MainActor
enum NudgeFixture {
    static func install(_ folder: String) {
        let dir = URL(filePath: folder, directoryHint: .isDirectory)
        let log = NudgeLog(file: dir.appending(path: "posted.jsonl"))
        let center = SmartNudgeCenter.shared
        center.makeCalendar = { NudgeCalendarFile(folder: dir, log: log) }
        center.media = NudgeMediaFile(file: dir.appending(path: "playing"), log: log)
        center.deliver = { post in
            log.write(["kind": "post", "id": post.id, "title": post.title, "body": post.body, "tip": post.tip ?? post.body,
                       "notifies": post.notifies, "sound": post.sound])
        }
        center.lastAIAnswer = {
            guard let printed = try? String(contentsOf: dir.appending(path: "ai-usage.jsonl"), encoding: .utf8) else { return nil }
            switch ExtensionRun.surfaceAnswer(printed, kind: .bar) {
            case .bar(let answer): return answer
            case .error(let why): log.write(["kind": "ai-usage", "problem": why])
            case .blocks: log.write(["kind": "ai-usage", "problem": ExtensionRun.unreadable])
            }
            return nil
        }
        print("smart nudges sandbox: \(dir.path)")
        fflush(stdout)
    }
}

/// One JSON line per step, appended.
@MainActor
final class NudgeLog {
    let file: URL
    init(file: URL) { self.file = file }

    func write(_ line: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: .sortedKeys) else { return }
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
        try? handle.close()
    }
}

/// Calendar as a file: Pause music's events, and access as the `access` file says.
@MainActor
final class NudgeCalendarFile: CalendarStore {
    private let folder: URL, log: NudgeLog
    private var asked: CalendarAccess?

    init(folder: URL, log: NudgeLog) { self.folder = folder; self.log = log }

    var access: CalendarAccess {
        if let asked { return asked }
        switch (try? String(contentsOf: folder.appending(path: "access"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "denied": return .denied
        case "undetermined": return .undetermined
        default: return .granted
        }
    }

    /// macOS's prompt, answered yes and logged.
    func requestAccess() async -> Bool {
        log.write(["kind": "calendar", "asked": true])
        asked = .granted
        return true
    }

    func events(in range: DateInterval) -> [ClockEvent] { [] }
    var newEventsCalendar: String? { nil }
    func add(_ event: QuickEvent) throws { throw CocoaError(.featureUnsupported) }

    func meetings(in range: DateInterval) -> [MeetingEvent] {
        guard let data = try? Data(contentsOf: folder.appending(path: "events.json")),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let text = row["start"] as? String, let start = try? Date(text, strategy: .iso8601),
                  range.contains(start) else { return nil }
            return MeetingEvent(id: id, title: row["title"] as? String ?? "", start: start, allDay: row["allDay"] as? Bool ?? false,
                                video: MeetingLink.find(in: [row["url"] as? String, row["location"] as? String, row["notes"] as? String]) != nil)
        }
    }
}

/// What plays as a file: `playing` until paused.
@MainActor
final class NudgeMediaFile: MediaControlling {
    private let file: URL, log: NudgeLog
    init(file: URL, log: NudgeLog) { self.file = file; self.log = log }

    func pauseIfPlaying(_ done: @escaping @MainActor (Bool) -> Void) {
        let playing = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "playing"
        if playing { try? Data("paused\n".utf8).write(to: file) }
        log.write(["kind": "media", "pause": playing ? "paused" : "nothing playing"])
        done(playing)
    }

    func play() {
        try? Data("playing\n".utf8).write(to: file)
        log.write(["kind": "media", "play": true])
    }
}
