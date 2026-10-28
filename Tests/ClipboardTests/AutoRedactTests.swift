import Clipboard
import CoreGraphics
import Foundation
import Testing

/// Auto-redact's finder (story 195). The samples are made up and assembled at run time, so no line of this file looks
/// like a real credential to the commit guard.
@Suite("Auto-redact")
struct AutoRedactTests {
    /// A made-up run of letters and digits as random as a real key: `prefix` then `length` characters.
    static func sample(_ prefix: String, _ length: Int) -> String {
        let pool = Array("q7Z2mX9vK4tR8wB1nC6yH3jL5pD0fG")
        return prefix + String((0..<length).map { pool[($0 * 7 + 3) % pool.count] })
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001 && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }

    static func found(_ text: String) -> [(Sensitive, String)] {
        Sensitive.find(in: text).map { ($0.kind, String(text[$0.range])) }
    }

    @Test("Each kind is found, alone, in a line of other words")
    func kinds() {
        #expect(Self.found("Billing email maya.lind@northwind.studio Edit").map(\.0) == [.email])
        #expect(Self.found("Billing email maya.lind@northwind.studio Edit").map(\.1) == ["maya.lind@northwind.studio"])
        #expect(Self.found("Card 4242 4242 4242 4242 exp 12/29").map(\.1) == ["4242 4242 4242 4242"])
        #expect(Self.found("server at 192.168.1.20.").map(\.1) == ["192.168.1.20"])
        #expect(Self.found("link-local fe80::1ff:fe23:4567:890a here").map(\.0) == [.address])
        #expect(Self.found("Call +356 2123 4567 today").map(\.1) == ["+356 2123 4567"])
        #expect(Self.found("Office (415) 555-0100").map(\.1) == ["(415) 555-0100"])
        let live = Self.sample("nw_live_", 24)
        #expect(Self.found("Live key " + live + " Copy").map(\.1) == [live])
    }

    @Test("A labelled value is covered without its label, a JWT whole")
    func labelled() {
        let value = Self.sample("", 10)
        #expect(Self.found("Password: " + value).map(\.1) == [value])
        #expect(Self.found("Authorization: Bearer " + value).map(\.1) == [value])
        let jwt = "ey" + "J" + Self.sample("", 12) + "." + Self.sample("", 14) + "." + Self.sample("", 16)
        #expect(Self.found("jwt " + jwt).map(\.1) == [jwt])
    }

    @Test("What only looks like one is left alone")
    func misses() {
        for line in ["Renews on 1 November 2026 · Visa ending 4242", "INV-0142   $12.00   Paid", "1 Oct 2026", "at 12:30:45 on 2026-10-16",
                     "CaptureEditorRenders and MarkupRenderer", "Card 4242 4242 4242 4241", "version 3.11", "Settings / Billing",
                     "Token count: 42", "std::vector<int>"] {
            #expect(Self.found(line).isEmpty, "\(line)")
        }
    }

    @Test("An email is never also cut into a key; matches come left to right")
    func overlap() {
        let long = Self.sample("a", 22) + "@example.com"
        #expect(Self.found(long).map(\.0) == [.email])
        #expect(Self.found("10.0.0.1 then ops@example.com").map(\.0) == [.address, .email])
    }

    @Test("A match is boxed by its own words, a part word by its share, the line when words have no boxes")
    func boxes() throws {
        let text = "email maya@example.com now"
        // Three words side by side across the line's box.
        let line = ReadLine(text: text, box: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.05),
                            words: [CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.05), CGRect(x: 0.22, y: 0.2, width: 0.36, height: 0.05),
                                    CGRect(x: 0.6, y: 0.2, width: 0.1, height: 0.05)])
        let range = try #require(text.range(of: "maya@example.com"))
        #expect(Self.near(line.box(of: range), line.words![1]))
        // Inside a word: "key=VALUE" covers VALUE and half a character more, never the label.
        let glued = "key=ABCDEF"
        let one = ReadLine(text: glued, box: CGRect(x: 0, y: 0, width: 1, height: 0.1), words: [CGRect(x: 0, y: 0, width: 1, height: 0.1)])
        let part = one.box(of: try #require(glued.range(of: "ABCDEF")))
        #expect(Self.near(part, CGRect(x: 0.35, y: 0, width: 0.65, height: 0.1)))
        // No word boxes: the line's box, cut the same way.
        let bare = ReadLine(text: glued, box: CGRect(x: 0, y: 0, width: 1, height: 0.1))
        #expect(bare.box(of: try #require(glued.range(of: "ABCDEF"))) == part)
    }

    @Test("Cover gives points padded two; a code is covered whole; Text only keeps the words half inside, a box a line")
    func cover() {
        let size = CGSize(width: 1000, height: 500)
        let text = ReadLine(text: "ops@example.com", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.04),
                            words: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.04)])
        let code = ReadLine(text: "mailto:ops@example.com", box: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.2), code: true)
        let covers = AutoRedact.cover([text, code], size: size)
        #expect(covers.map(\.kind) == [.email, .email])
        #expect(Self.near(covers[0].rect, CGRect(x: 98, y: 48, width: 204, height: 24)))
        #expect(Self.near(covers[1].rect, CGRect(x: 498, y: 248, width: 104, height: 104)))

        let two = ReadLine(text: "left right", box: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.04),
                           words: [CGRect(x: 0, y: 0.5, width: 0.2, height: 0.04), CGRect(x: 0.3, y: 0.5, width: 0.2, height: 0.04)])
        // The area takes all of "right" and a sliver of "left".
        let area = CGRect(x: 180, y: 240, width: 400, height: 40)
        let kept = AutoRedact.text([two, code], in: area, size: size)
        #expect(kept.count == 1 && Self.near(kept[0], CGRect(x: 298, y: 248, width: 204, height: 24)))
        #expect(AutoRedact.text([two], in: CGRect(x: 0, y: 0, width: 50, height: 50), size: size).isEmpty)
    }

    @Test("Word boxes survive pilot-text's JSON, and lines without them still parse")
    func json() {
        let line = ReadLine(text: "a b", box: CGRect(x: 0, y: 0, width: 1, height: 1), words: [CGRect(x: 0, y: 0, width: 0.4, height: 1), CGRect(x: 0.6, y: 0, width: 0.4, height: 1)])
        #expect(ReadLines.parse(ReadLines.json([line])) == [line])
        #expect(ReadLines.parse(#"{"text":"a","box":[[0,0],[1,1]],"code":false}"#) == [ReadLine(text: "a", box: CGRect(x: 0, y: 0, width: 1, height: 1))])
        #expect(ReadLine.wordRanges("  two  words ").count == 2)
    }
}
