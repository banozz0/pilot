import Foundation
import Testing
@testable import Clipboard

/// Kinds and richer search (card agent-bo-95422781, ClipBook's filter by type and search behaviour, no ClipBook code).
@Suite("Clipboard kinds and search")
struct SearchTests {
    let database = TemporaryDatabase()

    func item(_ text: String, _ kind: ClipKind = .text, app: String? = "com.apple.TextEdit") -> ClipItem {
        ClipItem(kind: kind, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: app)
    }

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    @Test("A whole-copy URL reads as a link and one address as an email; a sentence with a URL stays text, a colour stays a colour")
    func derivedKinds() throws {
        let store = try ClipboardStore(path: database.path)
        try store.add(item("https://example.com/a?b=1"), at: at(1))
        try store.add(item("me@example.com"), at: at(2))
        try store.add(item("see https://x.y now"), at: at(3))
        try store.add(item("#ff0000", .colour), at: at(4))
        try store.add(item("not@an email"), at: at(5))
        let kinds = Dictionary(uniqueKeysWithValues: try store.recent().map { ($0.text, $0.kind) })
        #expect(kinds["https://example.com/a?b=1"] == .link)
        #expect(kinds["me@example.com"] == .email)
        #expect(kinds["see https://x.y now"] == .text)
        #expect(kinds["#ff0000"] == .colour)
        #expect(kinds["not@an email"] == .text)
    }

    @Test("Several words match in any order; type:, app: and is:pinned filter; tokens and words combine")
    func tokens() throws {
        let store = try ClipboardStore(path: database.path)
        try store.add(item("alpha and beta"), at: at(1))
        try store.add(item("alpha"), at: at(2))
        let pinned = try store.add(item("beta from zen", app: "app.zen-browser.zen"), at: at(3))
        try store.setPinned(pinned, true)
        try store.add(ClipItem(kind: .image, text: "", contents: [["public.png": Data([1])]], sourceApp: nil), at: at(4))
        try store.add(item("https://alpha.example"), at: at(5))
        // A fake name lookup, so the test never depends on what is installed: Messages's bundle id is not its name.
        try store.add(item("hola", app: "com.apple.MobileSMS"), at: at(0))
        let names = ["com.apple.MobileSMS": "Messages", "com.apple.TextEdit": "TextEdit", "app.zen-browser.zen": "Zen"]
        func texts(_ q: String) throws -> [String] { try store.search(ClipQuery(q), appName: { names[$0] }).map(\.text) }
        #expect(try texts("beta alpha") == ["alpha and beta"])
        #expect(try texts("BETA") == ["beta from zen", "alpha and beta"])
        #expect(try store.search(ClipQuery("type:image")).map(\.kind) == [.image])
        #expect(try texts("type:link") == ["https://alpha.example"])
        #expect(try texts("app:textedit alpha") == ["https://alpha.example", "alpha", "alpha and beta"])
        #expect(try texts("app:zen") == ["beta from zen"])
        #expect(try texts("app:textedit") == ["https://alpha.example", "alpha", "alpha and beta"])
        #expect(try texts("app:messages") == ["hola"])
        #expect(try texts("app:mobilesms") == ["hola"])
        #expect(try texts("is:pinned") == ["beta from zen"])
        #expect(try texts("type:text alpha") == ["alpha", "alpha and beta"])
        // An unknown token is just a word.
        #expect(try texts("type:nonsense").isEmpty)
        #expect(try store.search(ClipQuery("")).count == 6)
    }

    @Test("type:pinned lists only pinned copies and type:all every kind; neither is searched as a word (card agent-bo-95422994, G7)")
    func pinnedAndAllTokens() throws {
        let store = try ClipboardStore(path: database.path)
        try store.add(item("plain"), at: at(1))
        let pinned = try store.add(item("https://a.b"), at: at(2))
        try store.setPinned(pinned, true)
        try store.add(ClipItem(kind: .image, text: "", contents: [["public.png": Data([1])]], sourceApp: nil), at: at(3))
        #expect(try store.search(ClipQuery("type:pinned")).map(\.text) == ["https://a.b"])
        #expect(try store.search(ClipQuery("TYPE:ALL")).count == 3)
        #expect(try store.search(ClipQuery("type:all plain")).map(\.text) == ["plain"])
        #expect(try store.search(ClipQuery("type:pinned", filter: .link)).map(\.text) == ["https://a.b"])
    }

    @Test("Rich text reads as two words wherever a kind is named; the other kinds as one capitalised word (G7)")
    func kindLabels() {
        #expect(ClipKind.richText.label == "Rich text")
        #expect(ClipKind.text.label == "Text")
        #expect(ClipKind.colour.label == "Colour")
    }

    @Test("Tab and Shift+Tab step the tabs; a kind filter lists only that kind")
    func kindFilter() throws {
        #expect(PanelCommand(key: .tab, searchEmpty: false) == .cycleFilter(1))
        #expect(PanelCommand(key: .tab, shift: true, searchEmpty: true) == .cycleFilter(-1))

        let store = try ClipboardStore(path: database.path)
        try store.add(item("plain"), at: at(1))
        try store.add(item("https://a.b"), at: at(2))
        try store.add(item("#123456", .colour), at: at(3))
        #expect(try store.search(ClipQuery("", filter: .link)).map(\.text) == ["https://a.b"])
        #expect(try store.search(ClipQuery("", filter: .colour)).map(\.text) == ["#123456"])
        #expect(try store.search(ClipQuery("", filter: .text)).map(\.text) == ["plain"])
        #expect(try store.search(ClipQuery("", filter: .pinned)).isEmpty)
    }

    @Test("Each typed word is highlighted where it matches, ignoring case; tokens are not")
    func highlights() {
        let text = "Alpha and beta"
        let ranges = ClipQuery("be alp type:text").highlights(in: text).map { String(text[$0]) }
        #expect(ranges.sorted() == ["Alp", "be"])
    }

    /// The search's own CPU time on this thread, not the wall clock, which a loaded Mac stretches while the thread waits
    /// its turn.
    @Test("Searching 500 rows takes under 50 ms of CPU")
    func speed() throws {
        let store = try ClipboardStore(path: database.path)
        for i in 0..<500 { try store.add(item("row \(i) lorem ipsum dolor sit amet \(i % 7 == 0 ? "needle" : "hay")"), at: at(Double(i))) }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let found = try store.search(ClipQuery("needle lorem app:textedit"), appName: { _ in "TextEdit" })
        let spent = Duration.nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start))
        #expect(found.count == 72)
        #expect(spent < .milliseconds(50), "\(spent)")
    }
}
