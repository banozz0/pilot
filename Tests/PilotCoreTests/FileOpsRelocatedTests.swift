import Foundation
import Testing
@testable import PilotCore

/// After a move, the Files window maps its folder and history through `FileOps.relocated`. A URL from a folder listing is
/// NSURL-backed: its parent walk goes from / to /.. and on, so the walk must stop at "/" itself (build 2379 hung there
/// after a cut picture was pasted into another folder).
@Suite("FileOps.relocated")
struct FileOpsRelocatedTests {
    static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "relocated-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "a/b"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "a/b/pic.png"))
        try Data().write(to: root.appending(path: "other.png"))
        return root
    }

    @Test("A listed folder outside the move comes back as it was, not walked past /")
    func unrelated() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let listed = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let shown = try #require(listed.first { $0.lastPathComponent == "a" })
        let moves = [root.appending(path: "other.png").resolvingSymlinksInPath(): URL(filePath: "/nowhere/other.png")]
        #expect(FileOps.relocated(shown, by: moves) == shown)
    }

    @Test("A listed item under a renamed folder follows it")
    func follows() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let b = try #require(FileManager.default.contentsOfDirectory(at: root.appending(path: "a"), includingPropertiesForKeys: nil).first)
        let pic = try #require(FileManager.default.contentsOfDirectory(at: b, includingPropertiesForKeys: nil).first)
        let real = root.resolvingSymlinksInPath()
        try FileManager.default.moveItem(at: root.appending(path: "a"), to: root.appending(path: "c"))
        let moved = FileOps.relocated(pic, by: [real.appending(path: "a"): real.appending(path: "c")])
        #expect(moved.path == real.appending(path: "c/b/pic.png").path)
    }
}
