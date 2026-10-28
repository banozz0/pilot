import Foundation
import Testing
@testable import PilotCore

/// The menu's frecency (story 75; SPEC.md, Frecency): pure, no GUI.
@Suite("Frecency")
struct FrecencyTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    static let calendar = MenuEntry(title: "Calendar", target: .app("com.apple.iCal"), home: .apps)
    static let calculator = MenuEntry(title: "Calculator", target: .app("com.apple.calculator"), home: .apps)
    static let chess = MenuEntry(title: "Chess", target: .app("com.apple.Chess"), home: .apps)

    @Test("A pick weighs 100 at 4 days or less, 70 at 14, 50 at 31, 30 at 90 and 10 when older; the score sums them")
    func score() {
        var f = Frecency()
        // Two picks in each band, at its edges: 2 × (100 + 70 + 50 + 30 + 10).
        for days in [0, 4, 4.001, 14, 14.001, 31, 31.001, 90, 90.001, 400] { f.record("app:x", at: Self.ago(days: days)) }
        #expect(f.score("app:x", now: Self.now) == 520)
        #expect(f.score("app:never", now: Self.now) == 0)
    }

    @Test("Only the last 20 picks of an entry are kept")
    func keepsTwenty() {
        var f = Frecency()
        for days in stride(from: 200.0, through: 176, by: -1) { f.record("app:x", at: Self.ago(days: days)) }
        #expect(f.picks["app:x"]?.count == 20)
        #expect(f.picks["app:x"]?.first == Self.ago(days: 195))
        // The 20 kept, 176 to 195 days old, weigh 10 each.
        #expect(f.score("app:x", now: Self.now) == 200)
    }

    @Test("A picked entry outranks an equal match: Calculator passes Calendar for c once picked")
    func pickedOutranks() {
        let entries = [Self.calendar, Self.calculator, Self.chess]
        var nav = MenuNavigator(entries: entries, branch: .apps)
        nav.query = "c"
        #expect(nav.rows.map(\.title) == ["Chess", "Calendar", "Calculator"])
        var f = Frecency()
        for _ in 0..<5 { f.record(Self.calculator.target.key!, at: Self.ago(days: 1)) }
        nav = MenuNavigator(entries: entries, branch: .apps, frecency: f, now: Self.now)
        nav.query = "c"
        #expect(nav.rows.map(\.title) == ["Calculator", "Chess", "Calendar"])
    }

    @Test("A picked weaker match never passes a title prefix (P53, Sven on Build 68), and a non-match never lists")
    func boundedBoost() {
        let textEdit = MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps)
        let context = MenuEntry(title: "Context", target: .app("dev.context"), home: .apps)
        let notes = MenuEntry(title: "Notes", target: .app("com.apple.Notes"), home: .apps)
        var nav = MenuNavigator(entries: [context, textEdit, notes], branch: .apps, frecency: Frecency(), now: Self.now)
        nav.query = "tex"
        #expect(nav.rows.map(\.title) == ["TextEdit", "Context"])
        var f = Frecency()
        for _ in 0..<20 { f.record(context.target.key!, at: Self.ago(days: 1)); f.record(notes.target.key!, at: Self.ago(days: 1)) }
        nav = MenuNavigator(entries: [context, textEdit, notes], branch: .apps, frecency: f, now: Self.now)
        nav.query = "tex"
        #expect(nav.rows.map(\.title) == ["TextEdit", "Context"])
    }

    @Test("Inside a branch an empty search lists its entries by frecency, unpicked ones in their order")
    func emptyQuery() {
        var f = Frecency()
        f.record(Self.chess.target.key!, at: Self.ago(days: 1))
        f.record(Self.calculator.target.key!, at: Self.ago(days: 1))
        f.record(Self.calculator.target.key!, at: Self.ago(days: 2))
        let nav = MenuNavigator(entries: [Self.calendar, Self.calculator, Self.chess], branch: .apps, frecency: f, now: Self.now)
        #expect(nav.rows.map(\.title) == ["Calculator", "Chess", "Calendar"])
        let root = MenuNavigator(entries: [Self.calendar, Self.calculator, Self.chess], frecency: f, now: Self.now)
        #expect(root.rows.first?.title == "Apps")
    }

    @Test("Each entry has its own id: an app, an action and a branch never share one")
    func keys() {
        #expect(MenuEntry.Target.app("com.apple.iCal").key == "app:com.apple.iCal")
        #expect(MenuEntry.Target.action("windows.close").key == "action:windows.close")
        #expect(MenuEntry.Target.branch(.apps).key == "branch:apps")
    }

    @Test("The store keeps the picks in a JSON file and reads an absent file as no picks")
    func store() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frecency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FrecencyStore(url: dir.appending(path: "Pilot/frecency.json"))
        #expect(try store.load() == Frecency())
        var f = Frecency()
        f.record("app:com.apple.calculator", at: Self.now)
        try store.save(f)
        #expect(try store.load() == f)
        try Data("not json".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
    }
}
