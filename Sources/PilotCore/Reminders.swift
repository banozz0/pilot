import Foundation

/// One reminder: what to show and when (card agent-bo-95422935).
public struct Reminder: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let due: Date
}

/// The pending reminders, soonest first.
public struct ReminderList: Codable, Equatable, Sendable {
    public private(set) var upcoming: [Reminder] = []

    public init() {}

    @discardableResult
    public mutating func add(_ text: String, in seconds: TimeInterval, now: Date) -> Reminder {
        let r = Reminder(id: UUID(), text: text, due: now.addingTimeInterval(seconds))
        upcoming.append(r)
        upcoming.sort { $0.due < $1.due }
        return r
    }

    public mutating func cancel(_ id: UUID) { upcoming.removeAll { $0.id == id } }

    /// The reminders due at `now`, taken off the list.
    public mutating func due(at now: Date) -> [Reminder] {
        let due = upcoming.prefix { $0.due <= now }
        upcoming.removeFirst(due.count)
        return Array(due)
    }
}

/// ~/Library/Application Support/Pilot/reminders.json, so a reminder outlives a restart.
public struct ReminderStore: Sendable {
    public static let standard = ReminderStore(url: PilotFolder.support.appending(path: "reminders.json"))
    public let url: URL

    public init(url: URL) { self.url = url }

    /// An empty list when there is no file yet.
    public func load() throws -> ReminderList { try JSONFile(url: url).load(or: ReminderList()) }

    public func save(_ list: ReminderList) throws { try JSONFile(url: url).save(list) }
}

/// Quick reminders (card agent-bo-95422935; Omarchy's Super+Ctrl+R): "20m stretch" typed at the menu's root sets one;
/// Trigger › Reminders lists them.
public enum Reminders {
    /// What a reminder row does on Return: set one (at the root) or cancel one (Trigger › Reminders).
    public enum Pick: Hashable, Sendable { case set(seconds: TimeInterval, text: String), cancel(UUID) }

    /// At most a day ahead.
    public static let longest: TimeInterval = 24 * 3600

    /// "1h30m", "20m", "90s" in seconds, any case; nil for anything else. `pilot log --last` reads its span with it too.
    public static func duration(_ token: String) -> TimeInterval? { compact(token.lowercased()) }

    /// A duration ("20m", "1h30m", "90s", or "10 min") then at least one word.
    public static func parse(_ query: String) -> (seconds: TimeInterval, text: String)? {
        let words = query.split(separator: " ").map { $0.lowercased() }
        guard let first = words.first else { return nil }
        let duration: (seconds: TimeInterval, words: Int)
        if let s = compact(first) { duration = (s, 1) }
        else if words.count >= 2, let n = Double(first), let unit = unitSeconds[words[1]] { duration = (n * unit, 2) }
        else { return nil }
        let text = query.split(separator: " ").dropFirst(duration.words).joined(separator: " ")
        guard duration.seconds > 0, duration.seconds <= longest, !text.isEmpty else { return nil }
        return (duration.seconds, text)
    }

    private static let unitSeconds: [String: TimeInterval] = ["s": 1, "sec": 1, "m": 60, "min": 60, "mins": 60, "minutes": 60,
                                                              "h": 3600, "hour": 3600, "hours": 3600]

    /// "1h30m", "20m", "90s": every part a number and a unit, nothing else.
    private static func compact(_ token: String) -> TimeInterval? {
        guard let match = token.wholeMatch(of: /(?:(\d+)h)?(?:(\d+)(?:min|m))?(?:(\d+)s)?/), token.contains(where: \.isNumber) else { return nil }
        let h = match.1.flatMap { Double($0) } ?? 0, m = match.2.flatMap { Double($0) } ?? 0, s = match.3.flatMap { Double($0) } ?? 0
        return h * 3600 + m * 60 + s
    }

    /// The root's answer row for what was typed, if it is a reminder.
    public static func entries(for query: String, now: Date) -> [MenuEntry] {
        guard let (seconds, text) = parse(query) else { return [] }
        let at = now.addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
        return [MenuEntry(title: "Remind me in \(span(seconds)): \(text)", target: .reminder(.set(seconds: seconds, text: text)),
                          detail: "at \(at) · Return sets it", isAnswer: true)]
    }

    /// Trigger › Reminders: each pending one, Return cancels it.
    public static func rows(_ list: ReminderList, now: Date) -> [MenuEntry] {
        list.upcoming.map { r in
            let left = r.due.timeIntervalSince(now)
            return MenuEntry(title: r.text, target: .reminder(.cancel(r.id)), home: .reminders,
                             detail: "\(left < 60 ? "in under a minute" : "in \(span((left / 60).rounded(.up) * 60))") · Return cancels",
                             inSearch: false)
        }
    }

    /// "20 min", "1 h 30 min", "1 min 30 s".
    static func span(_ seconds: TimeInterval) -> String {
        let s = Int(seconds), parts = [(s / 3600, "h"), (s % 3600 / 60, "min"), (s % 60, "s")]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " ")
    }
}

/// The menu's root answers in one provider, so none replaces another: a question for Claude ("ask …", QuickAI), a line
/// for Scratch ("note …", Notes) or a calendar event ("event …", QuickEvent), else a sum or a conversion (Calculator), else money, a time zone or a date
/// (CalculatorWorld), else a colour (ColourAnswer), else a reminder, so "10 min in s" is never also "Remind me in 10 min: in s".
public enum RootAnswers {
    /// A question for Claude ("ask …"), a line for Scratch ("note …") or an event ("event …") alone; else a quicklink's keyword and words first
    /// (card agent-bo-95423030), then a script's title and arguments (card agent-bo-95423048), then an extension command's
    /// keyword and words ("todo buy milk"), then a sum, a colour or
    /// CalculatorWorld's answer, else a reminder.
    public static func entries(for query: String, now: Date, links: [Quicklink] = [], scripts: [ScriptCommand] = [],
                               extensions: [Extension] = [], zone: TimeZone = .current,
                               rates: RateState? = nil) -> [MenuEntry] {
        let alone = QuickAI.entries(for: query) + Notes.entries(for: query) + QuickEvent.entries(for: query, timeZone: zone)
        if !alone.isEmpty { return alone }
        var sums = Calculator.entries(for: query)
        if sums.isEmpty { sums = ColourAnswer.entries(for: query) }
        if sums.isEmpty { sums = CalculatorWorld.entries(for: query, now: now, zone: zone, rates: rates) }
        return Quicklink.answers(for: query, in: links) + ScriptCommand.answers(for: query, in: scripts)
            + Extension.answers(for: query, in: extensions)
            + (sums.isEmpty ? Reminders.entries(for: query, now: now) : sums)
    }
}
