import Foundation

/// An event typed in plain words (Sven, 2026-10-23, Q420): "lunch with Ana tomorrow 1pm" in the clock's popover's New
/// event field, or after `event ` in the Hyper+Space menu. NSDataDetector finds the day and time; the words left over
/// are the title. No time typed is the whole day, which ends on its own day as EventKit has it; no end or length typed
/// is an hour.
public struct QuickEvent: Hashable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool

    public init(title: String, start: Date, end: Date, allDay: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
    }

    /// An event's length when none was typed.
    static let length: TimeInterval = 3600

    /// The event `text` describes, nil without a day or time in it, in any order: "barber tomorrow 10am", "10am barber
    /// tomorrow". "for 2 hours" sets its length. Read as Malta does (T65): 6/11 is 6 November, 9:30 is 09:30. A time with
    /// no day that has passed today is tomorrow's ("barber 10am" at 13:00); a date with no year that has passed is next
    /// year's ("4/11" on 5 Nov); "today" and a typed year stay as typed.
    public static func parse(_ text: String, timeZone: TimeZone = .autoupdatingCurrent) -> QuickEvent? {
        // The detector misses "noon" and "midday" alone: they are 12pm. It also misses a day glued to its month
        // ("10november", "nov10", "10thnov"): they get their space.
        let text = text.trimmingCharacters(in: .whitespaces).replacing(midday, with: "12pm")
            .replacing(dayMonth) { "\($0.1) \($0.2)" }.replacing(monthDay) { "\($0.1) \($0.2)" } as NSString
        let found = detector?.matches(in: text as String, range: NSRange(location: 0, length: text.length)) ?? []
        guard let match = found.first, var date = match.date else { return nil }
        let calendar = ClockMonth.calendar(timeZone, locale: Locale(identifier: "en_GB")), now = Date()
        var used = [match]
        // A title between the day and the time ("tomorrow barber 10am") splits them into two matches: one when.
        if let second = found.dropFirst().first, let other = second.date {
            let first = text.substring(with: match.range), next = text.substring(with: second.range)
            let firstTime = first.contains(timed), firstDay = first.contains(dayed)
            // One is a time alone, the other a day alone.
            if firstTime != firstDay, next.contains(timed) == firstDay, next.contains(dayed) == firstTime {
                let (day, time) = firstDay ? (date, other) : (other, date)
                let clock = calendar.dateComponents([.hour, .minute], from: time)
                date = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day) ?? date
                used.append(second)
            }
        }
        let said = used.map { text.substring(with: $0.range) }.joined(separator: " ")
        let saidTime = said.contains(timed)
        // The detector takes "9:30" for the next 9:30, which may be 21:30; after noon words ("dinner 7:30") it stands.
        if !said.contains(later), let typed = said.firstMatch(of: clock), let hour = Int(typed.1), let minute = Int(typed.2), hour < 24, minute < 60 {
            date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
        if saidTime, !said.contains(dayed), date <= now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        } else if said.contains(dated), !said.contains(year), calendar.startOfDay(for: date) < calendar.startOfDay(for: now) {
            date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
        // The words around the matches are the title. "dentist on friday": the word joining the title to the day goes
        // with the day; a meal the day swallowed ("dinner tonight" is one match) stays in the title.
        var cut = 0, pieces: [String] = []
        for range in used.map(\.range).sorted(by: { $0.location < $1.location }) {
            pieces.append(text.substring(with: NSRange(location: cut, length: range.location - cut)).replacing(joining, with: ""))
            cut = NSMaxRange(range)
        }
        pieces.append(text.substring(from: cut))
        if let meal = text.substring(with: match.range).firstMatch(of: meals) { pieces.insert(String(meal.output), at: 1) }
        var rest = pieces.joined(separator: " ")
        var length = match.duration > 0 ? match.duration : Self.length
        if let typed = rest.firstMatch(of: lasting), let n = Double(typed.1.replacing(",", with: ".")) {
            length = n * (typed.2.lowercased().hasPrefix("h") ? 3600 : 60)
            rest.removeSubrange(typed.range)
        }
        var title = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;-–·"))
        if title.isEmpty { title = text as String }
        title = title.prefix(1).uppercased() + title.dropFirst()
        guard saidTime else {
            let day = calendar.startOfDay(for: date)
            return QuickEvent(title: title, start: day, end: day, allDay: true)
        }
        return QuickEvent(title: title, start: date, end: date.addingTimeInterval(length))
    }

    /// "Tomorrow, 13:00–14:00", "Sat 24 Oct, all day": the day as the popover lists it (ClockMonth.dayName); `time`
    /// writes a time as the clock is set to, else in the locale's short time.
    public func when(now: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent,
                     time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String {
        "\(ClockMonth.dayName(start, now: now, timeZone: timeZone, locale: locale)), " + (allDay ? "all day" : "\(time(start))–\(time(end))")
    }

    /// The menu's answer to `event …` with a day or time in it (Sven, 2026-10-23, Q420): Return adds it to the default
    /// calendar without opening Calendar.
    public static func entries(for query: String, timeZone: TimeZone = .autoupdatingCurrent) -> [MenuEntry] {
        guard query.prefix(6).lowercased() == "event ", let event = parse(String(query.dropFirst(6)), timeZone: timeZone) else { return [] }
        return [MenuEntry(title: "Add “\(event.title)” · \(event.when(timeZone: timeZone))", target: .calendarEvent(event),
                          detail: "Return adds it to your calendar", isAnswer: true,
                          icon: MenuIcon.glyph("calendar.badge.plus", .accent).app(bundle: "com.apple.iCal"))]
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    /// A time in what the detector matched; without one it gives noon, which is a date alone ("friday", "3 nov").
    nonisolated(unsafe) private static let timed =
        /\d[:.]\d\d|\d\s*(?:am|pm|a\.m\.|p\.m\.)|\bat\s+\d|\b(?:midnight|tonight|morning|afternoon|evening|night|breakfast|brunch|lunch|dinner|supper)\b/
        .ignoresCase()
    /// A day in what the detector matched: a word for one, a weekday, a month, a day number or "in 3 days".
    nonisolated(unsafe) private static let dayed =
        /\b(?:today|tonight|tomorrow|tmrw?|yesterday|mon|tue|wed|thu|fri|sat|sun|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|days?\b|weeks?\b)|\d\s*\/\s*\d|\d(?:st|nd|rd|th)\b/
        .ignoresCase()
    /// A calendar date: a month by name or day/month, `dayed`'s two date parts.
    nonisolated(unsafe) private static let dated = /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|\d\s*\/\s*\d/.ignoresCase()
    nonisolated(unsafe) private static let year = /\b\d{4}\b|\d\s*\/\s*\d{1,2}\s*\/\s*\d/
    /// A clock time with no am or pm, read as 24-hour.
    nonisolated(unsafe) private static let clock = /\b(\d{1,2})[:.](\d\d)\b(?!\s*(?:am|pm|a\.m\.|p\.m\.))/.ignoresCase()
    /// A part of the day after noon, where "7:30" is the evening's.
    nonisolated(unsafe) private static let later = /\b(?:tonight|afternoon|evening|night|lunch|dinner|supper)\b/.ignoresCase()
    nonisolated(unsafe) private static let midday = /\b(?:noon|midday)\b/.ignoresCase()
    nonisolated(unsafe) private static let dayMonth =
        /\b(\d{1,2}(?:st|nd|rd|th)?)((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*)\b/.ignoresCase()
    nonisolated(unsafe) private static let monthDay =
        /\b((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*?)(\d{1,2}(?:st|nd|rd|th)?)\b/.ignoresCase()
    nonisolated(unsafe) private static let meals = /^(?:breakfast|brunch|lunch|dinner|supper)\b/.ignoresCase()
    nonisolated(unsafe) private static let joining = /\s*\b(?:on|at|from|by|this|next|starting)\s*$/.ignoresCase()
    nonisolated(unsafe) private static let lasting = /\bfor\s+(\d+(?:[.,]\d+)?)\s*(h|hrs?|hours?|m|mins?|minutes?)\b/.ignoresCase()
}
