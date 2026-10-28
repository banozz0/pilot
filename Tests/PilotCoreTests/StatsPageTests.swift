import Foundation
import Testing
@testable import PilotCore

/// The Stats page and Home's now-first redesign (card agent-bo-95422992, mockups on card agent-bo-95422987): the minute
/// history behind 1 hour and Today, the menu-bar chooser, the keys' short names and today's presses.
@Suite("Stats page")
struct StatsPageTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Malta")!
        return c
    }()
    /// 2026-10-07 22:00 in Malta.
    static let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 22))!

    static func values(cpu: Double, down: Double? = 1000, fan: Double? = nil) -> SystemStats.Values {
        SystemStats.Values(cpu: cpu, ram: 0.5, gpu: nil, down: down, up: 10, cores: nil, diskRead: nil, diskWrite: nil, heat: 50, fan: fan)
    }

    // MARK: Minute history

    @Test("1 hour keeps 60 one-minute points, the newest minute still being read among them")
    func hour() {
        var history = StatsHistory()
        let start = Self.evening
        for minute in 0..<90 { history.record(Self.values(cpu: Double(minute) / 100), at: start.addingTimeInterval(Double(minute) * 60), calendar: Self.calendar) }
        let now = start.addingTimeInterval(89 * 60 + 5)
        let hour = history.points(.hour, now: now, calendar: Self.calendar)
        #expect(hour.count == 60)
        #expect(hour.first?.time == start.addingTimeInterval(30 * 60))
        #expect(hour.last?.time == start.addingTimeInterval(89 * 60))
        #expect(hour.last?.cpu == 0.89)
    }

    @Test("Readings inside one minute average into its one point; a reading with no rate leaves the rate out of the average")
    func average() {
        var history = StatsHistory()
        let t = Self.evening
        history.record(Self.values(cpu: 0.1, down: nil), at: t, calendar: Self.calendar)
        history.record(Self.values(cpu: 0.3, down: 3000), at: t.addingTimeInterval(20), calendar: Self.calendar)
        history.record(Self.values(cpu: 0.5, down: 1000), at: t.addingTimeInterval(40), calendar: Self.calendar)
        let points = history.points(.hour, now: t.addingTimeInterval(50), calendar: Self.calendar)
        #expect(points.count == 1)
        #expect(abs((points[0].cpu ?? 0) - 0.3) < 1e-9)
        #expect(points[0].down == 2000)
        #expect(points[0].gpu == nil, "never read, so no value rather than zero")
    }

    @Test("Today starts over at local midnight: yesterday's minutes are dropped, the hour still reaches back across it")
    func midnight() {
        var history = StatsHistory()
        let beforeMidnight = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 23, minute: 50))!
        for minute in 0..<20 { history.record(Self.values(cpu: 0.2), at: beforeMidnight.addingTimeInterval(Double(minute) * 60), calendar: Self.calendar) }
        let now = beforeMidnight.addingTimeInterval(19 * 60 + 10)   // 00:09:10 on the 8th
        let today = history.points(.today, now: now, calendar: Self.calendar)
        #expect(today.count == 10)
        #expect(today.allSatisfy { Self.calendar.isDate($0.time, inSameDayAs: now) })
        #expect(history.points(.hour, now: now, calendar: Self.calendar).count == 20)
        // Kept points: only today's survive a save, so the file never grows past a day.
        #expect(history.kept(now: now, calendar: Self.calendar).points.count == 9, "the open minute is not saved")
    }

    @Test("Saved and read back as JSON; a fan reading rides along")
    func codable() throws {
        var history = StatsHistory()
        history.record(Self.values(cpu: 0.4, fan: 1020), at: Self.evening, calendar: Self.calendar)
        history.record(Self.values(cpu: 0.4, fan: 1040), at: Self.evening.addingTimeInterval(61), calendar: Self.calendar)
        let kept = history.kept(now: Self.evening.addingTimeInterval(70), calendar: Self.calendar)
        #expect(kept.points.first?.fan == 1020)
        let back = try JSONDecoder().decode(StatsHistory.self, from: JSONEncoder().encode(kept))
        #expect(back == kept)
    }

    @Test("The three ranges, the mockup's words: 2 min, 1 hour, Today, with the axis under each chart")
    func ranges() {
        #expect(StatsRange.allCases.map(\.title) == ["2 min", "1 hour", "Today"])
        #expect(StatsRange.twoMinutes.axis(now: Self.evening, calendar: Self.calendar) == ["2 min ago", "1 min", "now"])
        #expect(StatsRange.hour.axis(now: Self.evening, calendar: Self.calendar) == ["60 min ago", "30 min", "now"])
        #expect(StatsRange.today.axis(now: Self.evening, calendar: Self.calendar) == ["00:00", "11:00", "now"])
    }

    // MARK: Menu bar chooser

    @Test("The chooser lists the eight readings, the ones in the menu bar first in bar order and numbered")
    func chips() {
        var s = BarSettings.defaults
        #expect(BarSettings.readingKinds == [.cpu, .memory, .network, .graphics, .storage, .heat, .battery, .bluetoothBatteries])
        s.toggle(.storage, in: .menuBar)
        let chips = s.readingChips
        #expect(chips.prefix(4).map(\.kind) == [.cpu, .memory, .network, .storage])
        #expect(chips.prefix(4).map(\.order) == [1, 2, 3, 4])
        #expect(chips.dropFirst(4).allSatisfy { $0.order == nil })
        #expect(Set(chips.map(\.kind)) == Set(BarSettings.readingKinds))
    }

    @Test("A click on a chip flips the same menu-bar setting the Menu bar page's switch flips")
    func chipFlips() {
        var stats = BarSettings.defaults, page = BarSettings.defaults
        stats.toggleReading(.heat)
        page.toggle(.heat, in: .menuBar)
        #expect(stats == page)
        #expect(stats.isOn(.heat, in: .menuBar))
        stats.toggleReading(.heat)
        #expect(!stats.isOn(.heat, in: .menuBar))
    }

    @Test("Text, Graph or One item: the readings' styles and the Group, read back from what is set")
    func look() {
        var s = BarSettings.defaults
        #expect(s.readingsLook == .oneItem, "round 4's defaults put CPU, Memory and Network in one group")
        s.setReadingsLook(.graph)
        #expect(!s.isOn(.group, in: .menuBar))
        #expect(s.entry(.cpu).style == .graph && s.entry(.network).style == .graph)
        #expect(s.entry(.storage).style == .text, "Storage has no graph, so it keeps its text")
        #expect(s.readingsLook == .graph)
        s.setReadingsLook(.text)
        #expect(s.entry(.cpu).style == .text && s.readingsLook == .text)
        s.setReadingsLook(.oneItem)
        #expect(s.isOn(.group, in: .menuBar) && s.readingsLook == .oneItem)
    }

    // MARK: Short names on keys

    @Test("Each bind's short name for its key, the mockup's words for the user's binds")
    func shortNames() {
        let cases: [(String, String, String)] = [
            ("apps.terminal", "Terminal", "Terminal"), ("apps.clipboard", "Clipboard history", "Clips"),
            ("apps.open:app.zen-browser.zen", "Open Zen", "Zen"), ("apps.open:com.tdesktop.Telegram", "Telegram", "Telegram"),
            ("apps.url:app.zen-browser.zen:https://open.spotify.com", "Open https://open.spotify.com in Zen", "Spotify"),
            ("apps.url:app.zen-browser.zen:https://youtube.com", "Open https://youtube.com in Zen", "YouTube"),
            ("drive.url:shottr://show", "Open shottr://show", "Shottr"),
            ("windows.firstThreeQuarters", "Left three quarters", "¾ left"), ("windows.lastQuarter", "Right quarter", "¼ right"),
            ("system.lock", "Lock screen", "Lock"),
            ("captures.ocr", "Copy text from the screen", "Text"), ("engine.sheet", "Keybindings", "Keys"),
            ("workspaces.go:2", "Workspace 2", "2"),
            ("windows.focusDisplayLeft", "Focus display left", "← Display"), ("windows.focusDisplayRight", "Focus display right", "Display →"),
        ]
        for (id, label, short) in cases { #expect(BindsKeyboard.short(id, label: label) == short, "\(id)") }
        #expect(BindsKeyboard.short("workspaces.go:1", label: "Workspace 1", workspaceName: { $0 == "1" ? "Work" : nil }) == "Work")
        // Anything else: its label without the verb, cut to a word that fits a key.
        #expect(BindsKeyboard.short("drive.pick:{}", label: "Pick: Open a code folder") == "Code folder")
        #expect(BindsKeyboard.short("x.y", label: "Something with a very long name") == "Something")
    }

    // MARK: Today's presses

    @Test("Today's presses: a total, the busiest binds and presses by hour, starting over at local midnight")
    func todayPresses() {
        var today = TodayPresses()
        let t = Self.evening
        for _ in 0..<3 { today.count("apps.terminal", at: t, calendar: Self.calendar) }
        today.count("apps.open:app.zen-browser.zen", at: t.addingTimeInterval(60), calendar: Self.calendar)
        #expect(today.total(now: t, calendar: Self.calendar) == 4)
        #expect(today.top(2, now: t, calendar: Self.calendar).map(\.action) == ["apps.terminal", "apps.open:app.zen-browser.zen"])
        #expect(today.hours(now: t, calendar: Self.calendar)[22] == 4)
        #expect(today.count(of: "apps.terminal", now: t, calendar: Self.calendar) == 3)
        let tomorrow = t.addingTimeInterval(3 * 3600)
        #expect(today.total(now: tomorrow, calendar: Self.calendar) == 0, "yesterday's presses are not today's")
        #expect(today.count(of: "apps.terminal", now: tomorrow, calendar: Self.calendar) == 0)
        today.count("system.lock", at: tomorrow, calendar: Self.calendar)
        #expect(today.top(5, now: tomorrow, calendar: Self.calendar).map(\.count) == [1])
        let back = try! JSONDecoder().decode(TodayPresses.self, from: JSONEncoder().encode(today))
        #expect(back == today)
    }
}
