import Foundation
import Testing
@testable import Clipboard

@Suite("Clipboard store")
struct StoreTests {
    let database = TemporaryDatabase()
    var path: URL { database.path }

    func text(_ s: String) -> ClipItem {
        ClipItem(kind: .text, text: s, contents: [["public.utf8-plain-text": Data(s.utf8)]], sourceApp: "com.apple.TextEdit")
    }

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    @Test("Newest copy first, contents intact")
    func recentNewestFirst() throws {
        let store = try ClipboardStore(path: path)
        try store.add(text("one"), at: at(1))
        try store.add(text("two"), at: at(2))
        let clips = try store.recent()
        #expect(clips.map(\.text) == ["two", "one"])
        #expect(clips[0].kind == .text && clips[0].sourceApp == "com.apple.TextEdit")
        #expect(try store.contents(of: clips[0].id) == text("two").contents)
    }

    @Test("Over the cap the oldest unpinned copy goes; a pinned one stays however old")
    func capEvictsOldestUnpinned() throws {
        let store = try ClipboardStore(path: path, cap: 3)
        let oldest = try store.add(text("pinned, oldest"), at: at(1))
        try store.setPinned(oldest, true)
        try store.add(text("a"), at: at(2))
        try store.add(text("b"), at: at(3))
        try store.add(text("c"), at: at(4))
        try store.add(text("d"), at: at(5))
        #expect(try store.recent().map(\.text) == ["d", "c", "b", "pinned, oldest"])
        #expect(try store.recent().first { $0.id == oldest }?.pinned == true)
    }

    @Test("Keep-last set to 3 in settings: five copies leave three unpinned rows")
    func keepLastFromSettings() throws {
        let store = try ClipboardStore(path: path)
        store.cap = 3
        for (i, s) in ["a", "b", "c", "d", "e"].enumerated() { try store.add(text(s), at: at(Double(i))) }
        #expect(try store.recent().map(\.text) == ["e", "d", "c"])
    }

    @Test("Lowering the limits prunes at once, pins exempt")
    func pruneOnChange() throws {
        let store = try ClipboardStore(path: path)
        let pinned = try store.add(text("pinned"), at: at(0))
        try store.setPinned(pinned, true)
        for (i, s) in ["a", "b", "c"].enumerated() { try store.add(text(s), at: at(Double(i + 1))) }
        store.cap = 1
        try store.prune(now: at(10))
        #expect(try store.recent().map(\.text) == ["c", "pinned"])
    }

    @Test("Days set to 1: an item stamped two days old is gone after the next copy; a pin stays")
    func dayLimit() throws {
        let day: TimeInterval = 86_400
        let store = try ClipboardStore(path: path)
        store.maxAge = day
        try store.add(text("two days old"), at: at(0))
        let pinned = try store.add(text("pinned, two days old"), at: at(1))
        try store.setPinned(pinned, true)
        try store.add(text("half a day later"), at: at(day / 2))
        #expect(try store.recent().count == 3, "nothing is a day old yet")
        try store.add(text("new"), at: at(2 * day))
        #expect(try store.recent().map(\.text) == ["new", "pinned, two days old"])
    }

    @Test("Days set to 1: copying something already in the history also drops the two-day-old item")
    func dayLimitOnRecopy() throws {
        let day: TimeInterval = 86_400
        let store = try ClipboardStore(path: path)
        store.maxAge = day
        try store.add(text("two days old"), at: at(0))
        try store.add(text("again"), at: at(day / 2))
        try store.add(text("again"), at: at(2 * day))
        #expect(try store.recent().map(\.text) == ["again"])
    }

    @Test("Clear history leaves only the pinned rows")
    func clearKeepsPins() throws {
        let store = try ClipboardStore(path: path)
        let pinned = try store.add(text("pinned"), at: at(1))
        try store.setPinned(pinned, true)
        try store.add(text("a"), at: at(2))
        try store.add(text("b"), at: at(3))
        try store.clear()
        #expect(try store.recent().map(\.text) == ["pinned"])
        #expect(try store.contents(of: pinned) == text("pinned").contents)
    }

    @Test("Copying the same thing again moves it to the top instead of adding it twice")
    func recopyMovesToTop() throws {
        let store = try ClipboardStore(path: path)
        let first = try store.add(text("same"), at: at(1))
        try store.add(text("other"), at: at(2))
        let again = try store.add(text("same"), at: at(3))
        #expect(again == first)
        #expect(try store.recent().map(\.text) == ["same", "other"])
    }

    @Test("Search matches plain text anywhere, ignoring case")
    func search() throws {
        let store = try ClipboardStore(path: path)
        try store.add(text("Hello Pilot"), at: at(1))
        try store.add(text("goodbye"), at: at(2))
        try store.add(text("50% off_sale"), at: at(3))
        #expect(try store.search(ClipQuery("pilot")).map(\.text) == ["Hello Pilot"])
        #expect(try store.search(ClipQuery("%")).map(\.text) == ["50% off_sale"])
        #expect(try store.search(ClipQuery("_s")).map(\.text) == ["50% off_sale"])
    }

    @Test("History survives reopening the store; delete removes an item")
    func persistsAndDeletes() throws {
        let id = try ClipboardStore(path: path).add(text("kept"), at: at(1))
        let reopened = try ClipboardStore(path: path)
        #expect(try reopened.recent().map(\.text) == ["kept"])
        try reopened.delete(id)
        #expect(try reopened.recent().isEmpty)
    }

    @Test("An empty representation is stored as empty data, not refused")
    func emptyRepresentation() throws {
        let store = try ClipboardStore(path: path)
        let item = ClipItem(kind: .text, text: "x", contents: [["public.utf8-plain-text": Data("x".utf8), "public.html": Data()]],
                            sourceApp: nil)
        let id = try store.add(item)
        #expect(try store.contents(of: id) == item.contents)
    }
}
