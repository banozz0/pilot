import Foundation
@testable import PilotCore
import Testing

/// The clock's popover (card agent-bo-95423011, SPEC story 168): a month by ISO weeks, Monday first, with each week's
/// number, today marked, a dot on each day with events, ‹ › to other months, and the next days' events listed.
@Suite("Clock month")
struct ClockMonthTests {
    static let malta = TimeZone(identifier: "Europe/Malta")!
    /// Wed 7 Oct 2026 21:04 in Malta.
    static let now = date(7, 21, 4)

    static func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 10) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = malta
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    static let call = ClockEvent(title: "Shippers Club call", start: date(7, 21, 30), end: date(7, 22, 15))
    static let dentist = ClockEvent(title: "Dentist", start: date(12, 10, 0), end: date(12, 11, 0))

    @Test("With events on 7 and 12 October 2026 the grid marks exactly those days, and today")
    func marks() {
        let month = ClockMonth(now: Self.now, timeZone: Self.malta, locale: Locale(identifier: "en_GB"), events: [Self.dentist, Self.call])
        let days = month.weeks.joined()
        #expect(days.filter(\.hasEvents).map(\.number) == [7, 12])
        #expect(days.filter(\.isToday).map(\.number) == [7])
        #expect(month.title == "October 2026" && month.week == 41)
        #expect(month.weekdays == ["M", "T", "W", "T", "F", "S", "S"])
        // Monday 28 September to Sunday 1 November: five weeks, the other months' days not in it.
        #expect(month.weeks.count == 5 && month.weeks.allSatisfy { $0.count == 7 })
        #expect(month.weeks[0].prefix(3).map(\.number) == [28, 29, 30] && month.weeks[0].prefix(3).allSatisfy { !$0.inMonth })
        #expect(month.weeks[4].last.map { ($0.number, $0.inMonth) } ?? (0, true) == (1, false))
        #expect(ClockMonth.range(now: Self.now, timeZone: Self.malta) == DateInterval(start: Self.date(28, 0, 0, month: 9), end: Self.date(2, 0, 0, month: 11)))
        #expect(month.weekNumbers == [40, 41, 42, 43, 44] && month.isCurrent)
    }

    @Test("Monday first in any locale: en_US's Sunday-first weekdays still start on Monday")
    func mondayFirst() {
        let month = ClockMonth(now: Self.now, timeZone: Self.malta, locale: Locale(identifier: "en_US"), events: [])
        #expect(month.weekdays == ["M", "T", "W", "T", "F", "S", "S"])
        let first = Calendar(identifier: .gregorian).dateComponents(in: Self.malta, from: month.weeks[0][0].date)
        #expect(first.weekday == 2 && first.day == 28)
    }

    @Test("ISO week numbers across a year's turn: 29 Dec 2025 opens week 1 of 2026, December 2026 ends in week 53")
    func weekNumbers() {
        let january = ClockMonth(showing: Self.date(1, 12, 0, month: 1), now: Self.now, timeZone: Self.malta, locale: Locale(identifier: "en_GB"), events: [])
        #expect(january.weekNumbers == [1, 2, 3, 4, 5] && january.weeks[0][0].number == 29 && !january.isCurrent)
        let december = ClockMonth(showing: Self.date(1, 12, 0, month: 12), now: Self.now, timeZone: Self.malta, locale: Locale(identifier: "en_GB"), events: [])
        #expect(december.weekNumbers == [49, 50, 51, 52, 53] && december.weeks.last?.last?.number == 3)
    }

    @Test("‹ › move by whole months from today's, across the year either way, and the title follows")
    func months() {
        let title = { (offset: Int) in
            ClockMonth(showing: ClockMonth.month(offset, from: Self.now, timeZone: Self.malta), now: Self.now, timeZone: Self.malta,
                       locale: Locale(identifier: "en_GB"), events: []).title
        }
        #expect(title(0) == "October 2026" && title(1) == "November 2026" && title(3) == "January 2027")
        #expect(title(-1) == "September 2026" && title(-10) == "December 2025" && title(-12) == "October 2025")
        // The 31st moving on lands in the next month, never skipping one.
        #expect(ClockMonth.month(1, from: Self.date(31, 12, 0), timeZone: Self.malta) == Self.date(1, 0, 0, month: 11))
        #expect(ClockMonth.step(keyCode: 123) == -1 && ClockMonth.step(keyCode: 126) == -1)
        #expect(ClockMonth.step(keyCode: 124) == 1 && ClockMonth.step(keyCode: 125) == 1 && ClockMonth.step(keyCode: 53) == nil)
    }

    @Test("Leap years: February 2028 has 29 days, 2026 and 2100 have 28, 2000 has 29")
    func leapYears() {
        func february(_ year: Int) -> Int {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.malta
            let shown = calendar.date(from: DateComponents(year: year, month: 2, day: 10))!
            let month = ClockMonth(showing: shown, now: Self.now, timeZone: Self.malta, locale: Locale(identifier: "en_GB"), events: [])
            #expect(month.weeks.allSatisfy { $0.count == 7 })
            return month.weeks.joined().filter(\.inMonth).count
        }
        #expect(february(2028) == 29 && february(2026) == 28 && february(2100) == 28 && february(2000) == 29)
    }

    static let ship = ClockEvent(title: "Ship Pilot", start: date(9, 0, 0), end: date(10, 0, 0), allDay: true)
    static let lunch = ClockEvent(title: "Lunch", start: date(9, 13, 0), end: date(9, 14, 0))
    static let done = ClockEvent(title: "Standup", start: date(7, 9, 0), end: date(7, 9, 15))

    @Test("The listed days: today with what is still to come, then the next days with events, all-day first; Dentist on day 6 is past the list")
    func upcoming() {
        let days = ClockMonth.upcoming([Self.dentist, Self.lunch, Self.call, Self.done, Self.ship], now: Self.now, timeZone: Self.malta)
        #expect(days.map(\.date) == [Self.date(7, 0, 0), Self.date(9, 0, 0)])
        #expect(days[0].events == [Self.call] && days[1].events == [Self.ship, Self.lunch])
        // Nothing to come: today is still listed, empty.
        #expect(ClockMonth.upcoming([Self.done], now: Self.now, timeZone: Self.malta) == [ClockMonth.Listed(date: Self.date(7, 0, 0), events: [])])
        // The read span covers both a month shown later and the listed days.
        let november = ClockMonth.month(1, from: Self.now, timeZone: Self.malta)
        #expect(ClockMonth.reading(showing: november, now: Self.now, timeZone: Self.malta)
            == DateInterval(start: Self.date(7, 0, 0), end: Self.date(7, 0, 0, month: 12)))
        let gb = Locale(identifier: "en_GB")
        #expect(ClockMonth.dayName(Self.date(7, 0, 0), now: Self.now, timeZone: Self.malta, locale: gb) == "Today")
        #expect(ClockMonth.dayName(Self.date(8, 0, 0), now: Self.now, timeZone: Self.malta, locale: gb) == "Tomorrow")
        #expect(ClockMonth.dayName(Self.date(9, 0, 0), now: Self.now, timeZone: Self.malta, locale: gb) == "Fri 9 Oct")
        #expect(ClockMonth.fullDate(Self.now, timeZone: Self.malta, locale: gb) == "Wednesday, 7 October 2026")
    }

    @Test("The year rail: the share of the year gone, in real hours across summer time, 0 at its start, a leap year by 366 days")
    func yearDone() {
        // 1 January 00:00 CET to 7 October 21:04 CEST: 279 days and 20 h 04 of the year's 365 days, summer time's lost hour out.
        let done = ClockMonth.yearDone(Self.now, timeZone: Self.malta)
        #expect(abs(done - (279 * 24 + 20 + 4.0 / 60) / (365 * 24)) < 1e-9 && Int(done * 100) == 76)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.malta
        let at = { (year: Int, month: Int, day: Int) in calendar.date(from: DateComponents(year: year, month: month, day: day))! }
        #expect(ClockMonth.yearDone(at(2026, 1, 1), timeZone: Self.malta) == 0)
        #expect(ClockMonth.yearDone(at(2027, 1, 1).addingTimeInterval(-1), timeZone: Self.malta) > 0.99999)
        // 2028: 182 days to 1 July, less summer time's hour, of 366.
        #expect(abs(ClockMonth.yearDone(at(2028, 7, 1), timeZone: Self.malta) - (182 * 24 - 1.0) / (366 * 24)) < 1e-9)
        #expect(ClockMonth.heroDate(Self.now, timeZone: Self.malta, locale: Locale(identifier: "en_US")) == "October 7")
        #expect(ClockMonth.heroDate(Self.now, timeZone: Self.malta, locale: Locale(identifier: "en_GB")) == "7 October")
    }

    @Test("An event's Calendar link: its identifier, and a repeating one's occurrence in UTC before it")
    func calendarURL() {
        #expect(ClockEvent.calendarURL(id: "ABC-123:XYZ")?.absoluteString == "ical://ekevent/ABC-123:XYZ?method=show&options=more")
        #expect(ClockEvent.calendarURL(id: "A/B", occurrence: Self.date(7, 21, 30))?.absoluteString
            == "ical://ekevent/20261007T193000Z/A%2FB?method=show&options=more")
    }
}
