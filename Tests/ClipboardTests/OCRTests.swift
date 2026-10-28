import AppKit
import Testing
@testable import Clipboard

/// Text read from copied images (card agent-bo-95423070): Apple's on-device recognition, a fake here, so default runs
/// never call Vision; PILOT_RENDER_OCR=1 runs the one real read.
@Suite("Clipboard image text")
struct OCRTests {
    let database = TemporaryDatabase()

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    func image(_ bytes: [UInt8]) -> ClipItem {
        ClipItem(kind: .image, text: "", contents: [["public.png": Data(bytes)]], sourceApp: nil)
    }

    func text(_ text: String) -> ClipItem {
        ClipItem(kind: .text, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: nil)
    }

    /// Gives each image's text by its first byte, and records what it was sent.
    final class FakeRecognizer: TextRecognizing, @unchecked Sendable {
        let texts: [UInt8: String]
        private(set) var sent: [Data] = []
        init(_ texts: [UInt8: String]) { self.texts = texts }
        func text(in image: Data) async -> String {
            sent.append(image)
            return texts[image.first ?? 0] ?? ""
        }
        func boxes(of words: [String], in image: Data) async -> [CGRect] { [] }
    }

    /// An image with text read from it and one with none, both read.
    @MainActor func shotAndBlank(_ store: ClipboardStore) async throws -> (shot: StoredClip, blank: StoredClip) {
        let shot = try store.add(image([1]), at: at(1)), blank = try store.add(image([2]), at: at(2))
        await ClipboardOCR(store: store, recognizer: FakeRecognizer([1: "Invoice 42"])).read()
        let clips = try store.recent()
        return (try #require(clips.first { $0.id == shot }), try #require(clips.first { $0.id == blank }))
    }

    @Test("An older history opens with its images unread: no text yet, each waiting to be read")
    func migrates() throws {
        try TagTests.writeVersion1(at: database.path)
        let store = try ClipboardStore(path: database.path)
        #expect(try store.recent().map(\.recognised) == [nil, nil])
        #expect(try store.unreadImages() == [2])
        #expect(try TagTests.userVersion(at: database.path) == Int32(ClipboardStore.migrations.count))
    }

    @Test("Catching up reads each unread image once, newest first, stores its text or an empty one, and never sends a text copy")
    @MainActor func catchUp() async throws {
        let store = try ClipboardStore(path: database.path)
        let shot = try store.add(image([1, 9]), at: at(1))
        let blank = try store.add(image([2, 9]), at: at(2))
        try store.add(text("plain words"), at: at(3))
        let fake = FakeRecognizer([1: "Invoice 42\nTotal"])
        let ocr = ClipboardOCR(store: store, recognizer: fake)
        #expect(await ocr.read() == 2)
        let byID = Dictionary(uniqueKeysWithValues: try store.recent().map { ($0.id, $0) })
        #expect(byID[shot]?.recognised == "Invoice 42\nTotal")
        #expect(byID[blank]?.recognised == "")
        #expect(fake.sent == [Data([2, 9]), Data([1, 9])])
        #expect(try store.unreadImages() == [])
        // Nothing left: a second catch-up sends nothing.
        #expect(await ocr.read() == 0)
        #expect(fake.sent.count == 2)
    }

    @Test("catchUp reads in the background; a call while it runs reads the image copied meanwhile, each image once")
    @MainActor func catchUpCoalesces() async throws {
        let store = try ClipboardStore(path: database.path)
        try store.add(image([1]), at: at(1))
        let fake = FakeRecognizer([1: "first", 2: "second"])
        let ocr = ClipboardOCR(store: store, recognizer: fake)
        ocr.catchUp()
        try store.add(image([2]), at: at(2))
        ocr.catchUp()
        for _ in 0..<200 where try !store.unreadImages().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try store.unreadImages().isEmpty)
        #expect(Set(try store.recent().compactMap(\.recognised)) == ["first", "second"])
        #expect(fake.sent.count == 2)
    }

    @Test("Each image's text is stored before onRead hears of it, once an image, so an open panel can show it (Sven, build 31)")
    @MainActor func tellsEachRead() async throws {
        let store = try ClipboardStore(path: database.path)
        let first = try store.add(image([1]), at: at(1)), second = try store.add(image([2]), at: at(2))
        let ocr = ClipboardOCR(store: store, recognizer: FakeRecognizer([1: "first", 2: "second"]))
        var heard: [[String?]] = []
        ocr.onRead = { heard.append(try! store.recent().filter { [first, second].contains($0.id) }.map(\.recognised)) }
        await ocr.read()
        // Newest first: the second image's text is in when the first call comes.
        #expect(heard == [["second", nil], ["second", "first"]])
    }

    @Test("A word from an image's text finds the image; a word in no copy finds nothing")
    @MainActor func search() async throws {
        let store = try ClipboardStore(path: database.path)
        let shot = try store.add(image([1]), at: at(1))
        try store.add(text("other"), at: at(2))
        await ClipboardOCR(store: store, recognizer: FakeRecognizer([1: "Quarterly Invoice"])).read()
        #expect(try store.search(ClipQuery("invoice")).map(\.id) == [shot])
        #expect(try store.search(ClipQuery("quarterly type:image")).map(\.id) == [shot])
        #expect(try store.search(ClipQuery("absent")).isEmpty)
    }

    @Test("A plain paste of an image with text writes the text, transient; a paste writes the image; an image with no text pastes whole")
    @MainActor func plainPaste() async throws {
        let store = try ClipboardStore(path: database.path)
        let (shot, blank) = try await shotAndBlank(store)
        let pasteboard = NSPasteboard.makePrivate()

        try PanelRows.write([shot], from: store, plain: true, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "Invoice 42")
        #expect(pasteboard.data(forType: .png) == nil)
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)

        try PanelRows.write([shot], from: store, plain: false, to: pasteboard)
        #expect(pasteboard.data(forType: .png) == Data([1]))
        #expect(pasteboard.string(forType: .string) == nil)

        try PanelRows.write([blank], from: store, plain: true, to: pasteboard)
        #expect(pasteboard.data(forType: .png) == Data([2]))
    }

    @Test("Cmd+K lists Copy text for one image with text, and it copies exactly that text; an image with none does not list it")
    @MainActor func copyText() async throws {
        let store = try ClipboardStore(path: database.path)
        let (shot, blank) = try await shotAndBlank(store)
        #expect(ClipAction.copyText.title == "Copy text")
        #expect(ClipAction.available(for: [shot]).contains(.copyText))
        #expect(!ClipAction.available(for: [blank]).contains(.copyText))
        #expect(!ClipAction.available(for: [shot, blank]).contains(.copyText))
        let fake = ActionTests.FakeOpener()
        try ClipActions(store: store, opener: fake).run(.copyText, on: [shot])
        #expect(fake.calls == ["copy Invoice 42 · Text copied"])
    }

    @Test("Vision reads the words in a rendered image, and finds a searched word's box there, any case", .enabled(if: ProcessInfo.processInfo.environment["PILOT_RENDER_OCR"] == "1"))
    func vision() async throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 160, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 160).fill()
        ("Pilot clipboard 42" as NSString).draw(at: NSPoint(x: 40, y: 50),
                                                withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(await VisionText().text(in: png) == "Pilot clipboard 42")
        // The preview's highlight: "CLIP" is the start of the second word, so its box is right of "Pilot", origin top left.
        let boxes = await VisionText().boxes(of: ["CLIP"], in: png)
        let box = try #require(boxes.first)
        #expect(boxes.count == 1)
        #expect(box.minX > 0.15 && box.maxX < 0.6 && box.minY > 0.1 && box.maxY < 0.9)
    }
}
