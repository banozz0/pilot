import Foundation
import Testing
@testable import PilotCore

/// Convert's ways in (card agent-bo-95423211): the picker's rows and a batch's
/// progress and summary lines. Files live in a fresh temporary folder.
@Suite("Convert entries")
final class ConvertBatchTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "pilot-convert-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @Test("The picker's rows are the formats the files share, a missing tool named on its row")
    func rows() {
        let none = Converter(tools: [:])
        let rows = Convert.rows(none.options(for: [URL(filePath: "/x/a.png"), URL(filePath: "/x/b.jpg")]))
        #expect(rows.map(\.title) == ["PNG", "JPG", "HEIC", "WebP", "PDF"])
        #expect(rows.map(\.detail) == [nil, nil, nil, "needs webp", nil], "the formula Install would add")
    }

    @Test("A batch skips files already in the format, converts the rest, and says so")
    func batch() async throws {
        let png = try Fixture.png(in: dir), jpg = try Fixture.image(.jpeg, "photo.jpg", in: dir)
        let batch = ConvertBatch([png, jpg], to: .jpg)
        #expect(batch.urls == [png])
        #expect(batch.skipped == [jpg])
        #expect(batch.progress(0) == "Converting pixel.png to JPG…")
        let seen = Seen()
        let outcome = await batch.run(with: Converter(tools: [:])) { seen.add($0) }
        #expect(outcome.written == [dir.appending(path: "pixel.jpg")])
        #expect(seen.all.isEmpty, "one file: nothing to report between files")
        #expect(batch.summary(outcome) == "pixel.jpg is ready; photo.jpg was already JPG")
        let many = ConvertBatch([png, try Fixture.image(.heic, "photo.heic", in: dir)], to: .jpg)
        #expect(many.progress(1) == "Converting 2 of 2 to JPG…")
        let both = await many.run(with: Converter(tools: [:])) { seen.add($0) }
        #expect(seen.all == [1], "before the second file")
        #expect(both.written.map(\.lastPathComponent) == ["pixel 2.jpg", "photo 2.jpg"])
        #expect(many.summary(both) == "2 files converted to JPG")
    }

    @Test("One file failing is named in the summary; the others still convert")
    func failure() async throws {
        let png = try Fixture.png(in: dir)
        let broken = dir.appending(path: "broken.heic")
        try Data("not a picture".utf8).write(to: broken)
        let batch = ConvertBatch([broken, png], to: .jpg)
        let outcome = await batch.run(with: Converter(tools: [:])) { _ in }
        #expect(outcome.written.map(\.lastPathComponent) == ["pixel.jpg"])
        #expect(outcome.failed.map(\.0) == [broken])
        #expect(batch.summary(outcome) == "1 file converted to JPG; broken.heic failed: broken.heic did not read as a picture")
    }

    @Test("A cancelled batch stops at the file in hand, keeps the ones finished and says so")
    func cancel() async throws {
        let sources = try (1...3).map { try Fixture.image(.png, "p\($0).png", in: dir) }
        let batch = ConvertBatch(sources, to: .jpg)
        let job = Task { await batch.run(with: Converter(tools: [:])) { done in if done == 1 { withUnsafeCurrentTask { $0?.cancel() } } } }
        let outcome = await job.value
        #expect(outcome.cancelled)
        #expect(outcome.written.map(\.lastPathComponent) == ["p1.jpg"])
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jpg") }
        #expect(left == ["p1.jpg"], "the first stays, nothing after the cancel")
        #expect(batch.summary(outcome) == "Conversion cancelled; 1 file converted to JPG")
        var none = ConvertBatch.Outcome()
        none.cancelled = true
        #expect(batch.summary(none) == "Conversion cancelled")
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int] = []
        func add(_ n: Int) { lock.withLock { seen.append(n) } }
        var all: [Int] { lock.withLock { seen } }
    }
}
