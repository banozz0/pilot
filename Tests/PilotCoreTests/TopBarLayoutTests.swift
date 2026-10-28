import Foundation
import Testing
@testable import PilotCore

@Suite("Top bar layout, saved before the bar items")
struct TopBarLayoutTests {
    static let clock = TopBarItem(.clock), workspaces = TopBarItem(.workspaces)

    @Test("The clock's presets for a fixed time in a fixed zone")
    func clockFormats() {
        let date = Date(timeIntervalSince1970: 1_791_158_400 + 13 * 3600 + 5 * 60 + 9)   // 2026-10-05 13:05:09 UTC, a Monday
        let utc = TimeZone(identifier: "UTC")!, locale = Locale(identifier: "en_GB")
        let text = { (format: TopBarClockFormat) in format.text(date, timeZone: utc, locale: locale) }
        #expect(text(.time24) == "13:05")
        #expect(text(.time12) == "1:05 pm")
        #expect(text(.dateTime24) == "Mon 5 Oct  13:05")
        #expect(text(.seconds24) == "13:05:09")
        #expect(TopBarClockFormat.presets.map(\.format) == [.time24, .time12, .seconds24])
        #expect(TopBarSettings().clock == .dateTime24)
        #expect(!TopBarClockFormat.time24.showsSeconds && TopBarClockFormat.seconds24.showsSeconds)
        #expect(!TopBarClockFormat(rawValue: "HH:mm 'hours'").showsSeconds)
        // An event's times in the clock's own hours, never its seconds (card agent-bo-95423011).
        #expect(TopBarClockFormat.time12.hoursAndMinutes == .time12 && TopBarClockFormat(rawValue: "K:mm").hoursAndMinutes == .time12)
        #expect(TopBarClockFormat.seconds24.hoursAndMinutes == .time24 && TopBarClockFormat(rawValue: "HH:mm 'h'").hoursAndMinutes == .time24)
    }

    @Test("Saved settings read back for the carry-over; a module this Pilot does not know is dropped, never a crash")
    func codable() throws {
        let saved = #"{"standard":{"left":[{"module":"workspaces","style":"sparkle"},{"module":"weather"}],"centre":[],"right":[{"module":"clock","style":"graph"}]},"screens":{},"clock":"HH:mm"}"#
        let read = try JSONDecoder().decode(TopBarSettings.self, from: Data(saved.utf8))
        #expect(read.standard == TopBarLayout(left: [Self.workspaces], centre: [], right: [TopBarItem(.clock, style: .graph)]))
        #expect(read.clock == .time24)
    }
}
