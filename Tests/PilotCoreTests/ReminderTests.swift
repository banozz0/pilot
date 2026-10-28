import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95422935: "20m stretch" at the menu's root, Pilot's own pop-up when due.
@Suite("Reminders")
struct ReminderTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A duration then words parses; anything else does not")
    func parse() {
        let cases: [(String, TimeInterval, String)] = [("20m stretch", 1200, "stretch"), ("1h30m call mum", 5400, "call mum"),
                                                       ("90s tea", 90, "tea"), ("2h walk", 7200, "walk"), ("10 min break", 600, "break")]
        for (text, seconds, words) in cases {
            let parsed = Reminders.parse(text)
            #expect(parsed?.seconds == seconds && parsed?.text == words, "\(text)")
        }
        for text in ["20m", "20 stretch", "stretch", "25h nap", "5 km in mi", "0m nothing", ""] {
            #expect(Reminders.parse(text) == nil, "\(text)")
        }
    }

    @Test("The answer row says when it fires and Return sets it; it is no pick")
    func answer() throws {
        let entries = Reminders.entries(for: "20m stretch", now: Self.t0)
        let row = try #require(entries.first)
        #expect(row.title == "Remind me in 20 min: stretch")
        #expect(row.target == .reminder(.set(seconds: 1200, text: "stretch")))
        #expect(row.isAnswer && row.frecencyKey == nil && row.kind == .answer)
        #expect(Reminders.entries(for: "stretch", now: Self.t0).isEmpty)
        var nav = MenuNavigator(entries: [])
        nav.query = "20m stretch"
        nav.provide(.answer, entries)
        #expect(nav.handle(.return) == .run(row))
    }

    @Test("The list keeps due order, cancels one, and hands over only what is due")
    func list() {
        var list = ReminderList()
        let a = list.add("tea", in: 600, now: Self.t0), b = list.add("stretch", in: 60, now: Self.t0), c = list.add("call", in: 3600, now: Self.t0)
        #expect(list.upcoming.map(\.id) == [b.id, a.id, c.id])
        list.cancel(c.id)
        #expect(list.upcoming.map(\.id) == [b.id, a.id])
        #expect(list.due(at: Self.t0.addingTimeInterval(120)).map(\.id) == [b.id])
        #expect(list.upcoming.map(\.id) == [a.id])
        #expect(list.due(at: Self.t0.addingTimeInterval(120)).isEmpty)
    }

    @Test("A saved list reads back at the next launch; a missing file is an empty list")
    func saved() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pilot-reminders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ReminderStore(url: url)
        #expect(try store.load().upcoming.isEmpty)
        var list = ReminderList()
        _ = list.add("stretch", in: 1200, now: Self.t0)
        try store.save(list)
        #expect(try store.load() == list)
    }

    @Test("Trigger lists Reminders; a pending one is a row whose Return cancels it")
    func branch() {
        #expect(MenuLayout.rows[.trigger]?.contains(.branch(.reminders)) == true)
        var list = ReminderList()
        let r = list.add("stretch", in: 720, now: Self.t0)
        let rows = Reminders.rows(list, now: Self.t0)
        #expect(rows.map(\.title) == ["stretch"])
        #expect(rows.first?.detail == "in 12 min · Return cancels")
        #expect(rows.first?.target == .reminder(.cancel(r.id)) && rows.first?.home == .reminders)
        #expect(rows.allSatisfy { !$0.inSearch }, "a cancel row never answers a search at the root")
    }

    @Test("The root's answers: a conversion stays the calculator's, a reminder shows when nothing else answers")
    func rootAnswers() {
        let conversion = RootAnswers.entries(for: "10 min in s", now: Self.t0)
        #expect(conversion.count == 1 && conversion.map(\.title) == Calculator.entries(for: "10 min in s").map(\.title))
        #expect(RootAnswers.entries(for: "20m stretch", now: Self.t0).map(\.title) == ["Remind me in 20 min: stretch"])
        #expect(RootAnswers.entries(for: "2+2", now: Self.t0).count == 1)
    }
}
