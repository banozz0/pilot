import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Files › Duplicates (Homy-style Files T5, check 4): a stand-in helper answers the scan as pilot-files does (its own
/// cargo test proves the hashing), real files on disk, and a fake Trash that moves them into a scratch folder, so
/// nothing reaches Sven's Trash. PILOT_RENDER_DIR keeps the tab's PNG.
@MainActor
@Suite("Duplicates")
struct DuplicatesTests {
    /// A scratch folder holding two identical 2 MB files, the original and its older Finder copy (modified at unix
    /// 1_700_000_500 and 1_700_000_000), and a third of the same size that differs, which the helper's hashing leaves
    /// out of the group.
    static func files() throws -> (folder: URL, original: URL, copy: URL, other: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "DuplicatesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "old"), withIntermediateDirectories: true)
        let original = folder.appending(path: "video.mov"), copy = folder.appending(path: "old/video copy.mov")
        let other = folder.appending(path: "other.mov")
        let bytes = Data(repeating: 9, count: 2_000_000)
        try bytes.write(to: original)
        try bytes.write(to: copy)
        try (bytes.dropLast() + Data([1])).write(to: other)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_500)], ofItemAtPath: original.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: copy.path)
        return (folder, original, copy, other)
    }

    /// A helper that answers each duplicates scan with `groups` under the scan's own id, and every other line with
    /// nothing, as a search the menu never sent.
    static func helper(answering groups: String, in folder: URL) throws -> URL {
        let helper = folder.appending(path: "pilot-files")
        let script = """
            #!/bin/sh
            while read -r line; do
              case "$line" in *'"dupes":true'*)
                id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
                printf '{"id":%s,"dupes":%s,"more":0,"ms":1}\\n' "$id" '\(groups)' ;;
              esac
            done
            """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }

    /// Moves the files into `bin`, as the Trash would, and records them.
    final class FakeTrash: @unchecked Sendable {
        let bin: URL
        var moved: [URL] = []
        init(_ bin: URL) { self.bin = bin }
        func recycle(_ urls: [URL]) throws {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for url in urls {
                try FileManager.default.moveItem(at: url, to: bin.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
                moved.append(url)
            }
        }
    }

    static func hit(_ path: String, _ days: Double? = nil) -> FileSearch.Hit {
        FileSearch.Hit(path: path, edited: days.map { Date(timeIntervalSince1970: 1_700_000_000 + $0 * 86_400) })
    }

    /// The file as a scan saw it: its path and its modified time now.
    static func seen(_ url: URL) throws -> FileSearch.Hit {
        FileSearch.Hit(path: url.path, edited: try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    @Test("Each group keeps the shortest name, then the shallowest folder, then the oldest, then the path (Q48)")
    func keeper() {
        // The name first: a Finder copy's longer name loses even from a shallower folder and an older date.
        #expect(DuplicatesModel.keeper([Self.hit("/a/video copy.mov", 1), Self.hit("/a/b/c/video.mov", 9)]) == "/a/b/c/video.mov")
        // Names as long: the shallower folder.
        #expect(DuplicatesModel.keeper([Self.hit("/a/b/c/clip.mov", 1), Self.hit("/a/x/clip.mov", 9)]) == "/a/x/clip.mov")
        // Names and depth alike: the oldest, and a file with no date after any dated one.
        #expect(DuplicatesModel.keeper([Self.hit("/a/b/clip.mov", 9), Self.hit("/a/c/clip.mov", 1), Self.hit("/a/d/clip.mov")]) == "/a/c/clip.mov")
        // All alike: the path, so two scans keep the same copy.
        #expect(DuplicatesModel.keeper([Self.hit("/a/d/clip.mov", 1), Self.hit("/a/c/clip.mov", 1)]) == "/a/c/clip.mov")
    }

    @Test("Check 4: one group of two, 2 MB to free; Move to Trash asks, then moves the copy and the kept file stays")
    func scanAndTrash() async throws {
        let (folder, original, copy, other) = try Self.files()
        defer { try? FileManager.default.removeItem(at: folder) }  // the test's own scratch folder only
        let group = #"[{"size":2000000,"files":[{"path":"\#(copy.path)","modified":1700000000},{"path":"\#(original.path)","modified":1700000500}]}]"#
        let index = FileIndex(helper: try Self.helper(answering: group, in: folder), fullDiskAccess: { true })
        defer { index.restart() }
        let trash = FakeTrash(folder.appending(path: "Trash"))
        let model = DuplicatesModel(scan: { index.scanDuplicates(reply: $0) }, recycle: { try trash.recycle($0) })
        #expect(model.state == .ready, "the tab scans only when asked")

        model.scan()
        #expect(model.state == .scanning)
        #expect(try await SystemSamplerTests.wait { model.state != .scanning })
        #expect(model.state == .scanned)
        #expect(model.groups.count == 1 && model.groups[0].files.count == 2)
        #expect(model.groups[0].kept == original.path, "the original's shorter name is kept over the older copy")
        #expect(model.freed == 2_000_000 && model.extras.map(\.path) == [copy.path])
        #expect(DuplicatesView.question(model.extras.count, model.freed) == "Move 1 file (2 MB) to the Trash?")

        // Nothing moves before the question is answered.
        model.askToTrash()
        #expect(model.asking && trash.moved.isEmpty)
        await model.confirmTrash()
        #expect(trash.moved == [copy])
        #expect(FileManager.default.fileExists(atPath: original.path) && FileManager.default.fileExists(atPath: other.path))
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(model.groups.isEmpty && model.moved?.files == 1 && model.moved?.bytes == 2_000_000)
    }

    @Test("A picked Keep is kept; a group whose kept copy is gone moves nothing")
    func keepPicked() async throws {
        let (folder, original, copy, _) = try Self.files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let trash = FakeTrash(folder.appending(path: "Trash"))
        let found = DuplicateScan(groups: [.init(size: 2_000_000, files: [try Self.seen(original), try Self.seen(copy)])])
        let model = DuplicatesModel(scan: { $0(.found(found)) }, recycle: { try trash.recycle($0) })
        model.scan()
        let id = try #require(model.groups.first?.id)
        model.keep(copy.path, in: id)
        model.keep("/not/in/the/group", in: id)
        #expect(model.groups[0].kept == copy.path && model.extras.map(\.path) == [original.path])

        // The kept copy moved away since the scan: its group's other copy is the last one, so it stays.
        let away = folder.appending(path: "away.mov")
        try FileManager.default.moveItem(at: copy, to: away)
        model.askToTrash()
        await model.confirmTrash()
        #expect(trash.moved.isEmpty && FileManager.default.fileExists(atPath: original.path))
        #expect(model.groups.isEmpty, "a group down to one copy leaves the list")
    }

    @Test("A copy edited since the scan is never moved, nor is any copy of a group whose kept file was edited")
    func editedSinceTheScan() async throws {
        for edited in ["kept", "extra"] {
            let (folder, original, copy, _) = try Self.files()
            defer { try? FileManager.default.removeItem(at: folder) }
            let trash = FakeTrash(folder.appending(path: "Trash"))
            let found = DuplicateScan(groups: [.init(size: 2_000_000, files: [try Self.seen(original), try Self.seen(copy)])])
            let model = DuplicatesModel(scan: { $0(.found(found)) }, recycle: { try trash.recycle($0) })
            model.scan()
            #expect(model.groups.first?.kept == original.path)
            // Rewritten in place, the same size: no longer a copy of the other.
            try Data(repeating: 3, count: 2_000_000).write(to: edited == "kept" ? original : copy)
            model.askToTrash()
            await model.confirmTrash()
            #expect(trash.moved.isEmpty, "\(edited)")
            #expect(FileManager.default.fileExists(atPath: original.path) && FileManager.default.fileExists(atPath: copy.path), "\(edited)")
            #expect(model.problem?.hasPrefix("1 copy stayed: a file changed since the scan") == true, "\(edited): \(model.problem ?? "")")
            #expect(model.moved == nil, "nothing moved, so no Moved line")
        }
    }

    @Test("A copy the user moved away themselves after the scan is not counted as moved to the Trash")
    func goneByHand() async throws {
        let (folder, original, copy, _) = try Self.files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let trash = FakeTrash(folder.appending(path: "Trash"))
        let found = DuplicateScan(groups: [.init(size: 2_000_000, files: [try Self.seen(original), try Self.seen(copy)])])
        let model = DuplicatesModel(scan: { $0(.found(found)) }, recycle: { try trash.recycle($0) })
        model.scan()
        try FileManager.default.moveItem(at: copy, to: folder.appending(path: "elsewhere.mov"))
        model.askToTrash()
        await model.confirmTrash()
        #expect(trash.moved.isEmpty && model.moved == nil && model.problem == nil)
        #expect(model.groups.isEmpty && FileManager.default.fileExists(atPath: original.path))
    }

    @Test("A copy inside a package (an .rtfd, a sparse bundle) is never listed and never moved; a group left with one copy goes")
    func packagesKeepTheirInsides() async throws {
        let (folder, original, copy, _) = try Self.files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rtfd = folder.appending(path: "Notes.rtfd/video.mov"), sparse = folder.appending(path: "Disk.sparsebundle/bands/video.mov")
        for inside in [rtfd, sparse] {
            try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: inside)
        }
        let trash = FakeTrash(folder.appending(path: "Trash"))
        // The rtfd's copy is the shallowest with the shortest name, so Q48 would keep it and move the others, were it listed.
        let found = DuplicateScan(groups: [
            .init(size: 2_000_000, files: [try Self.seen(rtfd), try Self.seen(original), try Self.seen(copy)]),
            .init(size: 2_000_000, files: [try Self.seen(sparse), try Self.seen(original)]),
        ])
        let model = DuplicatesModel(scan: { $0(.found(found)) }, recycle: { try trash.recycle($0) })
        model.scan()
        #expect(model.groups.count == 1, "the sparse bundle's group has one copy left outside it")
        #expect(model.groups.first?.files.map(\.path) == [original.path, copy.path] && model.groups.first?.kept == original.path)
        model.askToTrash()
        await model.confirmTrash()
        #expect(trash.moved == [copy])
        #expect(FileManager.default.fileExists(atPath: rtfd.path) && FileManager.default.fileExists(atPath: sparse.path))
    }

    /// A Trash that holds its move until the test lets it go.
    final class HeldTrash: @unchecked Sendable {
        let trash: FakeTrash
        var asked = false
        private var release: CheckedContinuation<Void, Never>?
        init(_ trash: FakeTrash) { self.trash = trash }
        func recycle(_ urls: [URL]) async throws {
            await withCheckedContinuation { release = $0; asked = true }
            try trash.recycle(urls)
        }
        func letGo() { release?.resume() }
    }

    @Test("While the Trash is moving, Scan, Keep and Move to Trash do nothing, so a second move never takes the kept copy")
    func waitsForTheMove() async throws {
        let (folder, original, copy, _) = try Self.files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let held = HeldTrash(FakeTrash(folder.appending(path: "Trash")))
        let found = DuplicateScan(groups: [.init(size: 2_000_000, files: [try Self.seen(original), try Self.seen(copy)])])
        var scans = 0
        let model = DuplicatesModel(scan: { scans += 1; $0(.found(found)) }, recycle: { try await held.recycle($0) })
        model.scan()
        model.askToTrash()
        let first = Task { await model.confirmTrash() }
        #expect(try await SystemSamplerTests.wait { held.asked })
        #expect(model.state == .moving)
        let id = try #require(model.groups.first?.id)
        model.keep(copy.path, in: id)
        model.askToTrash()
        model.scan()
        #expect(model.groups.first?.kept == original.path && !model.asking && scans == 1)
        await model.confirmTrash()  // a second yes while moving does nothing
        held.letGo()
        await first.value
        #expect(model.state == .scanned && held.trash.moved == [copy])
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test("No Full Disk Access says so at once; a helper that dies before answering stops the scan")
    func noAnswer() async throws {
        let none = FileIndex(helper: FileIndexTests.stand, fullDiskAccess: { false })
        let refused = DuplicatesModel(scan: { none.scanDuplicates(reply: $0) })
        refused.scan()
        #expect(refused.state == .noAccess && !none.isRunning)

        let dies = FileIndex(helper: FileIndexTests.stand, fullDiskAccess: { true })
        let model = DuplicatesModel(scan: { dies.scanDuplicates(reply: $0) })
        model.scan()
        #expect(try await SystemSamplerTests.wait { model.state != .scanning })
        #expect(model.state == .stopped)
    }

    @Test("The idle stop waits for a scan still reading")
    func idleStopWaits() throws {
        // A helper that reads and never answers, as one still hashing.
        let helper = try FileIndexTests.saver().helper
        let time = SetupKeepAwakeTests.FakeTime()
        let index = FileIndex(helper: helper, fullDiskAccess: { true }, after: time.after)
        var results: [DuplicateScan.Result] = []
        index.scanDuplicates { results.append($0) }
        time.pass(FileIndex.idleStop * 3)
        #expect(index.isRunning && results.isEmpty)
        index.cancel()  // the menu closing leaves the scan alone
        index.restart()
        #expect(results == [.stopped])
    }

    @Test("The tab draws its groups, the kept copy and what moving frees")
    func renders() throws {
        let (folder, original, copy, _) = try Self.files()
        defer { try? FileManager.default.removeItem(at: folder) }
        let look = LookPageTests().look().0
        let found = DuplicateScan(groups: [.init(size: 2_000_000, files: [Self.hit(copy.path, 1), Self.hit(original.path, 2)])], more: 0)
        let model = DuplicatesModel(scan: { $0(.found(found)) })
        model.scan()
        var text = ""
        let view = DuplicatesView(model: model).frame(width: 1000, height: 600).background(Theme.background).pilotTheme(look: look)
        try LookPageTests().hosted(view, height: 600) { host in
            let rep = try #require(snapshot(host, scale: 2))
            if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "duplicates.png"))
            }
            text = try recognisedText(in: rep).map(\.text).joined(separator: "\n")
        }
        for line in ["Duplicates", "2 MB to free", "Move to Trash", "video.mov", "video copy.mov", "Kept", "Keep this"] {
            #expect(text.contains(line), "\(line) missing, read: \(text)")
        }
    }
}
