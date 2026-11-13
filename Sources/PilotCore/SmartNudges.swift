import Foundation

/// Smart nudges (spec smart-nudges, from Lumabar's automations, Sven Q217), each behind its own switch, all off by
/// default: pause what plays before a meeting, warn once when an AI window passes a share used, and quiet hours that
/// hold Pilot's own notifications for one summary after. "Smart" keeps them apart from bind nudges (BindNudges).
public enum SmartNudges {
    /// Pause music's lead, in minutes before an event starts.
    public static let minutes = 1...30, standardMinutes = 2
    /// The AI limit warning's share used, in percent.
    public static let thresholds = 50...99, standardThreshold = 80
    /// Quiet hours' range as the settings first hold it.
    public static let standardFrom = "22:00", standardTo = "08:00"
}

// MARK: Pause music

/// The hosts of the video calls an event can link to, in its URL, location or notes.
public enum MeetingLink {
    static let hosts = ["zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                        "facetime.apple.com", "whereby.com", "meet.jit.si", "chime.aws", "gotomeeting.com", "meet.goto.com"]

    /// The first video-call link in `texts`; nil when none links to one.
    public static func find(in texts: [String?]) -> URL? {
        for text in texts.compactMap(\.self) {
            for match in text.matches(of: /https?:\/\/[^\s<>"')\]]+/) {
                guard let url = URL(string: String(match.output)), let host = url.host()?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}

/// One calendar event as Pause music reads it.
public struct MeetingEvent: Codable, Equatable, Sendable {
    public let id: String, title: String, start: Date, allDay: Bool
    /// Whether it links to a video call.
    public let video: Bool

    public init(id: String, title: String, start: Date, allDay: Bool = false, video: Bool) {
        self.id = id; self.title = title; self.start = start; self.allDay = allDay; self.video = video
    }

    /// One occurrence: a recurring event shares its id, so its start tells them apart.
    public var occurrence: String { "\(id)@\(Int(start.timeIntervalSince1970))" }
}

public enum MusicPause {
    /// The events Pause music acts on: timed, and a video call unless any event counts.
    static func counted(_ events: [MeetingEvent], anyEvent: Bool) -> [MeetingEvent] {
        events.filter { !$0.allDay && ($0.video || anyEvent) }
    }

    /// The event to pause for at `now`: one not started yet that starts within `minutes`, not paused for already; the
    /// soonest first.
    public static func due(_ events: [MeetingEvent], at now: Date, minutes: Int, anyEvent: Bool, done: Set<String>) -> MeetingEvent? {
        let lead = TimeInterval(minutes * 60)
        return counted(events, anyEvent: anyEvent)
            .filter { $0.start > now && $0.start.timeIntervalSince(now) <= lead && !done.contains($0.occurrence) }
            .min { $0.start < $1.start }
    }

    /// When the next one comes due after `now`: its start less `minutes`; nil when none is ahead.
    public static func next(_ events: [MeetingEvent], after now: Date, minutes: Int, anyEvent: Bool, done: Set<String>) -> Date? {
        let lead = TimeInterval(minutes * 60)
        return counted(events, anyEvent: anyEvent)
            .filter { !done.contains($0.occurrence) }
            .map { $0.start.addingTimeInterval(-lead) }
            .filter { $0 > now }
            .min()
    }

    /// The tip once it paused: "Paused for “Standup”, in 2 min".
    public static func tip(_ event: MeetingEvent, at now: Date) -> String {
        let minutes = max(1, Int((event.start.timeIntervalSince(now) / 60).rounded(.up)))
        return "Paused for “\(event.title)”, in \(minutes) min"
    }
}

// MARK: AI limit warning

/// One AI usage window as its bar answer shows it: a provider card's meter.
public struct AIWindow: Equatable, Sendable {
    /// The card's title and account, then the meter's label: "Claude · Session", "Codex · me@… · Weekly".
    public let key: String
    /// Its share used, in percent.
    public let used: Double
    public let resetsAt: Date?

    public init(key: String, used: Double, resetsAt: Date?) { self.key = key; self.used = used; self.resetsAt = resetsAt }
}

public enum AILimit {
    /// The AI usage extension's id, whose bar answer is read.
    public static let extensionID = "ai-usage"

    /// Its windows in a bar answer's dropdown blocks: each card's meters, whose percent is the share left.
    public static func windows(in answer: Extension.BarAnswer) -> [AIWindow] {
        answer.blocks.flatMap { block -> [AIWindow] in
            guard case .section(let title, _, let aside, _, let blocks, _, _) = block else { return [] }
            let card = [title, aside].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            return blocks.compactMap { inner in
                guard case .meter(let meter) = inner else { return nil }
                return AIWindow(key: card.isEmpty ? meter.label : "\(card) · \(meter.label)",
                                used: min(max(100 - meter.percent, 0), 100), resetsAt: meter.resetsAt)
            }
        }
    }

    /// The answer in what a bar command printed (its JSON lines), read as the bar round reads it, or why not.
    public static func answer(printed output: String) -> (answer: Extension.BarAnswer?, problem: String?) {
        switch ExtensionRun.surfaceAnswer(output, kind: .bar) {
        case .bar(let answer): (answer, nil)
        case .error(let why): (nil, why)
        case .blocks: (nil, ExtensionRun.unreadable)
        }
    }

    /// The notification's words: "Claude · Session is 82% used, resets 14:40", its reset when known as a time, never a
    /// countdown, which a summary after quiet hours would show stale.
    public static func text(_ window: AIWindow, now: Date) -> String {
        let used = "\(window.key) is \(Int(window.used.rounded()))% used"
        return window.resetsAt.map { used + ", r" + Extension.Block.Meter.resets(at: $0, now: now).dropFirst() } ?? used
    }
}

/// Which AI windows were warned about, so each warns once: kept in defaults across launches.
public struct AILimitWatch: Codable, Equatable, Sendable {
    /// Each warned window's reset time when warned (0 when it had none).
    public private(set) var warned: [String: Double] = [:]
    /// A reset time moving less than this is the same window read again, not a new one.
    static let sameWindow: TimeInterval = 10 * 60

    public init() {}

    /// The windows to warn about now: at or past `threshold` and not warned in this window. One that fell below it, or
    /// whose reset time moved on, may warn again.
    public mutating func record(_ windows: [AIWindow], threshold: Int) -> [AIWindow] {
        var fresh: [AIWindow] = []
        for window in windows {
            let stamp = window.resetsAt?.timeIntervalSince1970 ?? 0
            guard window.used >= Double(threshold) else { warned[window.key] = nil; continue }
            if let last = warned[window.key], abs(stamp - last) < Self.sameWindow { continue }
            warned[window.key] = stamp
            fresh.append(window)
        }
        return fresh
    }
}

// MARK: Quiet hours

/// A range of clock times, "22:00" to "08:00", across midnight when it ends before it starts; empty when both match.
public struct QuietHours: Equatable, Sendable {
    /// Minutes after midnight.
    public let from: Int, to: Int

    public init?(from: String, to: String) {
        guard let start = Self.minutes(from), let end = Self.minutes(to) else { return nil }
        self.from = start; self.to = end
    }

    /// "8:00" or "22:30" as minutes after midnight; nil for anything else.
    public static func minutes(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m)
        else { return nil }
        return h * 60 + m
    }

    /// "22:00" as the settings show it.
    public static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    public func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return from <= to ? (from..<to).contains(now) : now >= from || now < to
    }

    /// When it next ends after `date`: the next `to` on the clock.
    public func end(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(hour: to / 60, minute: to % 60), matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(86400)
    }
}

/// A notification Pilot held in quiet hours.
public struct HeldNudge: Codable, Equatable, Sendable {
    public let title: String, body: String, at: Date
    public init(title: String, body: String, at: Date) { self.title = title; self.body = body; self.at = at }

    /// The one notification that sums them up after: "While quiet: 3 held", then each as "Low battery: Mouse is at 10%",
    /// one said twice listed once.
    public static func summary(_ held: [HeldNudge]) -> (title: String, body: String) {
        var seen = Set<String>(), lines: [String] = []
        for item in held.reversed() where seen.insert(item.title + item.body).inserted { lines.insert("\(item.title): \(item.body)", at: 0) }
        return ("While quiet: \(held.count) held", lines.joined(separator: "\n"))
    }
}
