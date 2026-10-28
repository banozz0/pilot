import Foundation

/// A calendar event as the clock's popover shows it (card agent-bo-95423011, SPEC story 168), read from EventKit by the
/// app.
public struct ClockEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    /// Its calendar's colour.
    public var colour: Paint?
    /// Where Calendar shows it (`calendarURL`); nil opens Calendar itself.
    public var url: URL?
    /// From a holidays calendar (`isHolidays`): its day red in the month, its title a red chip in the list.
    public var holiday: Bool

    public init(title: String, start: Date, end: Date, allDay: Bool = false, colour: Paint? = nil, url: URL? = nil, holiday: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.colour = colour
        self.url = url
        self.holiday = holiday
    }

    /// Whether a calendar holds public holidays (Sven, 2026-10-23, Q418): Calendar's Holidays calendar for a region
    /// ("Holidays in Malta", "Malta Holidays") or one subscribed to, read-only both, by its title in English, Spanish,
    /// German, French, Italian, Dutch or Portuguese; never the Birthdays calendar, nor one of Sven's own named for a trip.
    public static func isHolidays(calendar title: String, readOnly: Bool, birthdays: Bool) -> Bool {
        readOnly && !birthdays
            && title.range(of: "holiday|festiv|feriado|feiertag|ferie|feestdag", options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Whether it falls on any part of `day`.
    public func overlaps(_ day: DateInterval) -> Bool { start < day.end && end > day.start }

    /// Calendar's link to an event, by EventKit's identifier; a repeating event's occurrence carries its start in UTC
    /// before the identifier, else Calendar shows the first one.
    public static func calendarURL(id: String, occurrence: Date? = nil) -> URL? {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else { return nil }
        let prefix = occurrence.map { stamp.string(from: $0) + "/" } ?? ""
        return URL(string: "ical://ekevent/\(prefix)\(encoded)?method=show&options=more")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}

/// The clock's popover's month (card agent-bo-95423011, SPEC story 168): a month in whole ISO weeks, Monday first, each
/// week's ISO number, today marked, a dot on each day with events and a holiday's day red.
public struct ClockMonth: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        public let date: Date
        public let number: Int
        /// In this month; the weeks' days either side are drawn dim.
        public let inMonth: Bool
        public let isToday: Bool
        /// "Thursday 8 October", in the locale's order: its card's heading.
        public let title: String
        /// Its events, the whole day's, in the list's order (ClockMonth.listed): its card's rows.
        public let events: [ClockEvent]
        public var hasEvents: Bool { !events.isEmpty }
        /// A holiday falls on it (ClockEvent.holiday).
        public var isHoliday: Bool { events.contains { $0.holiday } }
    }

    /// "October 2026".
    public let title: String
    /// Today's ISO week.
    public let week: Int
    /// Whether the month shown is today's.
    public let isCurrent: Bool
    /// The weekdays' letters, Monday first.
    public let weekdays: [String]
    public let weeks: [[Day]]
    /// Each week's ISO number, beside its row.
    public let weekNumbers: [Int]

    /// The month holding `shown` (today's when it is `now`).
    public init(showing shown: Date? = nil, now: Date, timeZone: TimeZone, locale: Locale, events: [ClockEvent]) {
        let calendar = Self.calendar(timeZone, locale: locale)
        let shown = shown ?? now
        let range = Self.range(now: shown, timeZone: timeZone)
        let month = calendar.component(.month, from: shown)
        // Sorted once; a day's filter keeps the order.
        let sorted = Self.listed(events), titles = DateFormatter.localized("EEEEdMMMM", timeZone: timeZone, locale: locale)
        let days = stride(from: 0, to: calendar.dateComponents([.day], from: range.start, to: range.end).day!, by: 1).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: range.start)!
            let day = DateInterval(start: date, end: calendar.date(byAdding: .day, value: 1, to: date)!)
            return Day(date: date, number: calendar.component(.day, from: date), inMonth: calendar.component(.month, from: date) == month,
                       isToday: calendar.isDate(date, inSameDayAs: now), title: titles.string(from: date), events: sorted.filter { $0.overlaps(day) })
        }
        title = DateFormatter.localized("LLLL yyyy", timeZone: timeZone, locale: locale).string(from: shown)
        week = calendar.component(.weekOfYear, from: now)
        isCurrent = calendar.isDate(shown, equalTo: now, toGranularity: .month)
        // The symbols start on Sunday.
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        weekdays = Array(symbols[1...] + symbols[..<1])
        weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0 + 7]) }
        weekNumbers = weeks.map { calendar.component(.weekOfYear, from: $0[0].date) }
    }

    /// The first of the month `offset` months from today's: the ‹ › and arrow keys' month.
    public static func month(_ offset: Int, from now: Date, timeZone: TimeZone) -> Date {
        let calendar = calendar(timeZone, locale: Locale(identifier: "en_GB"))
        return calendar.date(byAdding: .month, value: offset, to: calendar.dateInterval(of: .month, for: now)!.start)!
    }

    /// The month an arrow key moves by while the popover shows: ← and ↑ back one, → and ↓ on one; nil for any other key.
    public static func step(keyCode: Int64) -> Int? {
        switch keyCode {
        case KeyCode.leftArrow, KeyCode.upArrow: -1
        case KeyCode.rightArrow, KeyCode.downArrow: 1
        default: nil
        }
    }

    /// The grid's days, from the Monday on or before the 1st to the day after the Sunday on or after the month's last.
    public static func range(now: Date, timeZone: TimeZone) -> DateInterval {
        let calendar = calendar(timeZone, locale: Locale(identifier: "en_GB"))
        let month = calendar.dateInterval(of: .month, for: now)!
        let first = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
        let last = calendar.dateInterval(of: .weekOfYear, for: month.end.addingTimeInterval(-1))!.end
        return DateInterval(start: first, end: last)
    }

    /// The span to read events for: the shown month's grid and the days the popover lists.
    public static func reading(showing shown: Date, now: Date, timeZone: TimeZone) -> DateInterval {
        let calendar = calendar(timeZone, locale: Locale(identifier: "en_GB"))
        let grid = range(now: shown, timeZone: timeZone), today = calendar.startOfDay(for: now)
        return DateInterval(start: min(grid.start, today), end: max(grid.end, calendar.date(byAdding: .day, value: listedDays, to: today)!))
    }

    /// A day the popover lists, with its events.
    public struct Listed: Equatable, Sendable {
        public let date: Date
        public let events: [ClockEvent]
    }

    /// How many days the popover lists, today first.
    public static let listedDays = 3

    /// Today, with what is still to come today, then each of the next days that has events: all-day ones first, then by
    /// start.
    public static func upcoming(_ events: [ClockEvent], now: Date, timeZone: TimeZone) -> [Listed] {
        let calendar = calendar(timeZone, locale: Locale(identifier: "en_GB"))
        let today = calendar.startOfDay(for: now)
        return (0..<listedDays).compactMap { offset in
            let start = calendar.date(byAdding: .day, value: offset, to: today)!
            let day = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
            let on = listed(events.filter { $0.overlaps(day) && (offset > 0 || $0.allDay || $0.end > now) })
            return offset == 0 || !on.isEmpty ? Listed(date: start, events: on) : nil
        }
    }

    /// A day's events in the order listed: all-day ones first, then by start.
    static func listed(_ events: [ClockEvent]) -> [ClockEvent] {
        events.sorted { ($0.allDay ? 0 : 1, $0.start, $0.title) < ($1.allDay ? 0 : 1, $1.start, $1.title) }
    }

    /// "Saturday, 10 October 2026", in the locale's order.
    public static func fullDate(_ now: Date, timeZone: TimeZone, locale: Locale) -> String {
        DateFormatter.localized("EEEEdMMMMyyyy", timeZone: timeZone, locale: locale).string(from: now)
    }

    /// The popover's hero: the month and day ("October 7"), in the locale's order.
    public static func heroDate(_ now: Date, timeZone: TimeZone, locale: Locale) -> String {
        DateFormatter.localized("MMMMd", timeZone: timeZone, locale: locale).string(from: now)
    }

    /// The share of `now`'s year gone, 0 at its first instant up to 1: the year rail.
    public static func yearDone(_ now: Date, timeZone: TimeZone) -> Double {
        let year = calendar(timeZone, locale: Locale(identifier: "en_GB")).dateInterval(of: .year, for: now)!
        return min(max(now.timeIntervalSince(year.start) / year.duration, 0), 1)
    }

    /// A listed day's name: Today, Tomorrow, else its weekday and date ("Mon 12 Oct").
    public static func dayName(_ day: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        let calendar = calendar(timeZone, locale: locale)
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) { return "Tomorrow" }
        return DateFormatter.localized("EEEdMMM", timeZone: timeZone, locale: locale).string(from: day)
    }

    /// ISO 8601's calendar: weeks start on Monday, week 1 holds the year's first Thursday.
    static func calendar(_ timeZone: TimeZone, locale: Locale) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }
}

private extension DateFormatter {
    static func localized(_ template: String, timeZone: TimeZone, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
}
