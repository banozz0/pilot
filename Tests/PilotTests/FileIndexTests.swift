import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The file index waits for Full Disk Access (card agent-bo-95422768): without it the first walk would raise macOS's
/// Desktop, Documents and Downloads prompts in Pilot's name, so no helper starts and no search is sent. /usr/bin/true
/// stands in for the helper, so each case runs a real executable.
@MainActor
@Suite("File index")
struct FileIndexTests {
    static let stand = URL(fileURLWithPath: "/usr/bin/true")

    @Test("No grant: start runs no helper and a search answers at once that the grant is missing (card agent-bo-95423031)")
    func waitsForTheGrant() {
        let index = FileIndex(helper: Self.stand, fullDiskAccess: { false })
        index.start()
        #expect(!index.isRunning)
        var answers: [[FileSearch.Hit]?] = []
        index.search(FileSearch.Ask(text: "keymap")) { answers.append($0) }
        #expect(!index.isRunning)
        #expect(answers.count == 1 && answers[0] == nil)
    }

    @Test("With the grant, start runs the helper as before")
    func startsWithTheGrant() {
        let index = FileIndex(helper: Self.stand, fullDiskAccess: { true })
        index.start()
        #expect(index.isRunning)
    }

    /// A stand-in helper that, like pilot-files, reads searches until its stdin closes, then saves and exits: the
    /// save is a file beside it.
    static func saver() throws -> (helper: URL, saved: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FileIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let helper = folder.appending(path: "pilot-files"), saved = folder.appending(path: "saved")
        try "#!/bin/sh\ncat > /dev/null\ntouch '\(saved.path)'\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return (helper, saved)
    }

    @Test("Idle stop (2026-10-09): 10 minutes after the start or the last search the helper's pipe closes, it saves and exits, and a search runs it again")
    func stopsWhenIdle() async throws {
        let (helper, saved) = try Self.saver()
        let time = SetupKeepAwakeTests.FakeTime()
        let index = FileIndex(helper: helper, fullDiskAccess: { true }, after: time.after)
        index.start()
        #expect(index.isRunning)
        time.pass(FileIndex.idleStop - 1)
        #expect(index.isRunning)
        index.search(FileSearch.Ask(text: "keymap")) { _ in }  // a search counts the 10 minutes again
        time.pass(FileIndex.idleStop - 1)
        #expect(index.isRunning)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        time.pass(1)
        #expect(!index.isRunning)
        #expect(try await SystemSamplerTests.wait { FileManager.default.fileExists(atPath: saved.path) })
        index.search(FileSearch.Ask(text: "keymap")) { _ in }
        #expect(index.isRunning)
        time.pass(FileIndex.idleStop)
        #expect(!index.isRunning)
    }
}
