import AppKit
@testable import Clipboard
import Foundation
import Testing
@testable import Pilot

/// Sven on build 31 (2026-10-11): a screenshot's words never found it in an open panel. Its text came about a minute
/// after the copy (Vision's first image on a new build), and the panel listed only what it read when the search changed.
/// A throwaway store and a fake reader; nothing touches the real clipboard.
@MainActor
@Suite("Clipboard image text while the panel is open", .serialized)
final class ClipboardReadingTests {
    let database = FileManager.default.temporaryDirectory.appending(path: "pilot-clip-reading-\(UUID().uuidString).sqlite")

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
    }

    struct Reads: TextRecognizing {
        func text(in image: Data) async -> String { "SCREENSHOT\nTEXT" }
        func boxes(of words: [String], in image: Data) async -> [CGRect] { [] }
        var found: [String] = []
        func codes(in image: Data) async -> [String] { found }
    }

    func add(_ store: ClipboardStore, _ text: String, at seconds: Double) throws -> Int64 {
        try store.add(ClipItem.plainText(text, sourceApp: nil), at: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    }

    @Test("A search typed before an image is read finds it once its text lands, the cursor kept on its row, and says it is reading meanwhile")
    func searchFindsLateText() async throws {
        let store = try ClipboardStore(path: database)
        let older = try add(store, "screenshot notes", at: 1)
        let shot = try store.add(ClipItem(kind: .image, text: "", contents: [["public.png": Data([1])]], sourceApp: nil),
                                 at: Date(timeIntervalSince1970: 1_800_000_002))
        let model = PanelModel(store: store, recognizer: Reads())
        model.query = "screenshot"
        #expect(model.rows.map(\.id) == [older])
        #expect(model.readingLine == "Reading the text in 1 image…")

        // As ClipboardHistory wires it: each image read refreshes the open panel.
        let ocr = ClipboardOCR(store: store, recognizer: Reads())
        ocr.onRead = { model.refresh() }
        await ocr.read()
        #expect(model.rows.map(\.id) == [shot, older])
        // The cursor stays on the row it was on, now the second.
        #expect(model.selected?.id == older)
        #expect(model.readingLine == nil)
    }

    @Test("An image still being read says so; one read, with text or none, does not")
    func readingFlag() throws {
        let store = try ClipboardStore(path: database)
        let shot = try store.add(ClipItem(kind: .image, text: "", contents: [["public.png": Data([1])]], sourceApp: nil))
        try add(store, "plain", at: 1)
        let clips = { try store.recent().first { $0.id == shot }! }
        #expect(try clips().isReadingText)
        #expect(try store.recent().filter(\.isReadingText).count == 1)
        try store.setRecognised(shot, "")
        #expect(try !clips().isReadingText)
        // No search, no line: the unread row is in the list with its own hint.
        let model = PanelModel(store: store, recognizer: Reads())
        #expect(model.readingLine == nil)
        // A search where no image is listed (the Text tab) says nothing; the Image tab does.
        try store.add(ClipItem(kind: .image, text: "", contents: [["public.png": Data([2])]], sourceApp: nil))
        model.query = "plain"
        #expect(model.readingLine == "Reading the text in 1 image…")
        model.tab = .kind(.text)
        #expect(model.readingLine == nil)
        model.tab = .kind(.image)
        #expect(model.readingLine == "Reading the text in 1 image…")
    }

    @Test("A previewed image's QR code offers Open link for a web link and Copy text for anything else, read once per copy (Sven, Q398)")
    func qrCode() async throws {
        let store = try ClipboardStore(path: database)
        for (payload, want) in [("https://pilot.example/qr", ClipCode.link(URL(string: "https://pilot.example/qr")!)),
                                ("WIFI:S:Home;T:WPA;P:secret;;", .text("WIFI:S:Home;T:WPA;P:secret;;"))] {
            let shot = try store.add(ClipItem(kind: .image, text: payload, contents: [["public.png": Data(payload.utf8)]], sourceApp: nil))
            let codes = ClipCodes()
            let model = PanelModel(store: store, recognizer: Reads(found: [payload]), codes: codes)
            let clip = try #require(model.selected)
            #expect(clip.id == shot)
            for _ in 0..<100 where !codes.knows(clip) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(codes.code(of: clip) == want)
            #expect(model.actionChoices.contains(.code(want)))
            #expect(model.actionChoices.first { $0 == .code(want) }?.title == (payload.hasPrefix("https") ? "Open QR link" : "Copy QR text"))
            #expect(want.title == (payload.hasPrefix("https") ? "Open link" : "Copy text"))
        }
        let none = ClipCodes(), blank = try #require(try store.recent().first)
        none.note(ClipCodes.Key(blank), "")
        #expect(none.knows(blank) && none.code(of: blank) == nil, "an image with no code is read once, and offers nothing")
        var reused = blank
        reused.firstCopiedAt = blank.firstCopiedAt.addingTimeInterval(1)
        #expect(!none.knows(reused), "a new copy given a deleted copy's id is read again")
    }
}
