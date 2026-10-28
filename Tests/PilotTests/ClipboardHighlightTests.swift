import AppKit
@testable import Clipboard
import Foundation
import SwiftUI
import Testing
@testable import Pilot

/// The clipboard preview's highlight (Sven, 2026-10-10): the searched words lit in the text, the cut that scrolls the first
/// match into view, and the boxes on an image that matched through its read text, from a fake reader on a throwaway store.
@MainActor
@Suite("Clipboard preview highlight", .serialized)
final class ClipboardHighlightTests {
    let database = FileManager.default.temporaryDirectory.appending(path: "pilot-clip-highlight-\(UUID().uuidString).sqlite")

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
    }

    /// Answers one box for any word, and records the words it was asked for.
    final class FakeReader: TextRecognizing, @unchecked Sendable {
        static let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        private(set) var asked: [[String]] = []
        func text(in image: Data) async -> String { "" }
        func boxes(of words: [String], in image: Data) async -> [CGRect] {
            asked.append(words)
            return [Self.box]
        }
    }

    @Test("Every match is lit, any case, as the search matches; nothing is lit with no words")
    func lit() {
        let runs = { (text: String, typed: String) in
            let lit = ClipHighlight.lit(text, ClipQuery(typed), .red)
            return lit.runs.filter { $0.backgroundColor != nil }.map { String(lit[$0.range].characters) }
        }
        #expect(runs("Total due, TOTAL paid, subtotal", "total") == ["Total", "TOTAL", "total"])
        #expect(runs("Total due", "due total") == ["Total", "due"])
        #expect(runs("Total due", "").isEmpty)
        #expect(runs("Total due", "app:mail").isEmpty)
    }

    @Test("A match past the third line cuts the text two lines above it; one near the top, or none, does not cut")
    func cut() throws {
        let text = "one\ntwo\nthree\nfour\nfive match\nsix"
        let cut = try #require(ClipHighlight.cut(text, ClipQuery("MATCH")))
        #expect(cut.head == "one\ntwo")
        #expect(cut.tail == "three\nfour\nfive match\nsix")
        #expect(ClipHighlight.cut(text, ClipQuery("three")) == nil)
        #expect(ClipHighlight.cut(text, ClipQuery("absent")) == nil)
    }

    @Test("An image found through its read text gets the searched words' boxes; found by its name, or not searched, none")
    func boxes() async throws {
        let store = try ClipboardStore(path: database)
        let id = try store.add(ClipItem(kind: .image, text: "", contents: [["public.png": SharedLook.ClipboardTabsRenders.png(CGSize(width: 40, height: 30), seed: 0)]],
                                        sourceApp: nil))
        try store.setRecognised(id, "Invoice 42\nTotal due")
        let reader = FakeReader()
        let model = PanelModel(store: store, snippets: { [] }, recognizer: reader)
        model.tab = .kind(.image)
        try #require(model.selected?.id == id)
        #expect(model.previewBoxes.isEmpty && reader.asked.isEmpty)

        model.query = "invoice zzz-not-there"
        #expect(model.rows.isEmpty)
        model.query = "INVOICE due"
        for _ in 0..<200 where model.previewBoxes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.previewBoxes == [FakeReader.box])
        #expect(reader.asked == [["INVOICE", "due"]])

        try store.rename(id, to: "Receipt")
        model.query = "receipt"
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.selected?.id == id)
        #expect(model.previewBoxes.isEmpty && reader.asked.count == 1)
    }
}
