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

    /// The event `text` describes, nil without a day or time in it. "for 2 hours" sets its length.
    public static func parse(_ text: String, timeZone: TimeZone = .autoupdatingCurrent) -> QuickEvent? {
        let text = text.trimmingCharacters(in: .whitespaces) as NSString
        guard let match = detector?.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)),
              let date = match.date else { return nil }
        let said = text.substring(with: match.range)
        var before = text.substring(to: match.range.location), after = text.substring(from: NSMaxRange(match.range))
        var length = match.duration > 0 ? match.duration : Self.length
        if let typed = after.firstMatch(of: lasting), let n = Double(typed.1.replacing(",", with: ".")) {
            length = n * (typed.2.lowercased().hasPrefix("h") ? 3600 : 60)
            after.removeSubrange(typed.range)
        } else if let typed = before.firstMatch(of: lasting), let n = Double(typed.1.replacing(",", with: ".")) {
            length = n * (typed.2.lowercased().hasPrefix("h") ? 3600 : 60)
            before.removeSubrange(typed.range)
        }
        // "dentist on friday": the word joining the title to the day goes with the day; a meal the day swallowed
        // ("dinner tonight" is one match) stays in the title.
        before = before.replacing(joining, with: "")
        let meal = said.firstMatch(of: meals).map { String($0.output) } ?? ""
        var title = [before, meal, after].joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;-–·"))
        if title.isEmpty { title = text as String }
        title = title.prefix(1).uppercased() + title.dropFirst()
        guard said.contains(timed) else {
            let day = ClockMonth.calendar(timeZone, locale: Locale(identifier: "en_GB")).startOfDay(for: date)
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
        /\d[:.]\d\d|\d\s*(?:am|pm|a\.m\.|p\.m\.)|\bat\s+\d|\b(?:noon|midday|midnight|tonight|morning|afternoon|evening|night|breakfast|brunch|lunch|dinner|supper)\b/
        .ignoresCase()
    nonisolated(unsafe) private static let meals = /^(?:breakfast|brunch|lunch|dinner|supper)\b/.ignoresCase()
    nonisolated(unsafe) private static let joining = /\s*\b(?:on|at|from|by|this|next|starting)\s*$/.ignoresCase()
    nonisolated(unsafe) private static let lasting = /\bfor\s+(\d+(?:[.,]\d+)?)\s*(h|hrs?|hours?|m|mins?|minutes?)\b/.ignoresCase()
}
