import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Shortcut conflicts against a fake domain and a temporary backup (card agent-bo-95422087): the real
/// com.apple.symbolichotkeys is never read or written here.
@MainActor
@Suite("Shortcut conflicts")
struct ShortcutConflictsTests {
    final class FakeDomain {
        var table: [String: Any]
        var writes = 0
        init(_ table: [String: Any]) { self.table = table }
        /// A write that does not land, as when cfprefsd refuses it.
        var drops = false
        var domain: ShortcutConflicts.Domain {
            .init(read: { self.table }, write: { if !self.drops { self.table = $0 }; self.writes += 1 }, apply: {})
        }
    }

    static let original: [String: Any] = [
        "32": ["enabled": true, "value": ["parameters": [65535, 126, 8650752], "type": "standard"]],
        "118": ["enabled": true, "value": ["parameters": [65535, 18, 262144], "type": "standard"]],
    ]
    static let binds: [Key: String] = [Key("up", .ctrl, hyper: false): "system.missionControl"]

    private func backupURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "pilot-shortcuts-\(UUID().uuidString).plist")
    }

    @Test("Turn off backs up first, then writes Mission Control off; restore writes the backup back and removes it")
    func switchOffAndRestore() throws {
        let fake = FakeDomain(Self.original), url = backupURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let conflicts = ShortcutConflicts(domain: fake.domain, backupURL: url)
        #expect(conflicts.clashes(binds: Self.binds).map(\.hotkey.id) == [32])
        #expect(!conflicts.hasBackup)

        try conflicts.switchOff(binds: Self.binds)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(conflicts.hasBackup)
        #expect(conflicts.clashes(binds: Self.binds).isEmpty)
        #expect(SymbolicHotKeys.hotKeys(in: fake.table).first { $0.id == 118 }?.enabled == true)

        try conflicts.restore()
        #expect(NSDictionary(dictionary: fake.table).isEqual(to: Self.original))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!conflicts.hasBackup)
        #expect(fake.writes == 2)
    }

    @Test("With nothing clashing, turn off writes nothing; restore without a backup writes nothing")
    func nothingToDo() throws {
        let fake = FakeDomain(Self.original), url = backupURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let conflicts = ShortcutConflicts(domain: fake.domain, backupURL: url)
        try conflicts.switchOff(binds: [:])
        try conflicts.restore()
        #expect(fake.writes == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A backup file that cannot be read stops turn off, so the rows it holds are never written over")
    func unreadableBackup() throws {
        let fake = FakeDomain(Self.original), url = backupURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a plist".utf8).write(to: url)
        let conflicts = ShortcutConflicts(domain: fake.domain, backupURL: url)
        #expect(throws: ShortcutConflicts.Problem.self) { try conflicts.switchOff(binds: Self.binds) }
        #expect(fake.writes == 0)
        #expect(try Data(contentsOf: url) == Data("not a plist".utf8))
    }

    @Test("A write that does not land is an error, and turn off and restore both keep the backup")
    func writeThatDoesNotLand() throws {
        let fake = FakeDomain(Self.original), url = backupURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let conflicts = ShortcutConflicts(domain: fake.domain, backupURL: url)
        fake.drops = true
        #expect(throws: ShortcutConflicts.Problem.self) { try conflicts.switchOff(binds: Self.binds) }
        // The backup stays: a write that did not land may still have changed some rows.
        #expect(conflicts.hasBackup && FileManager.default.fileExists(atPath: url.path))
        #expect(NSDictionary(dictionary: fake.table).isEqual(to: Self.original))
        fake.drops = false
        try conflicts.switchOff(binds: Self.binds)
        fake.drops = true
        #expect(throws: ShortcutConflicts.Problem.self) { try conflicts.restore() }
        #expect(FileManager.default.fileExists(atPath: url.path) && conflicts.hasBackup)
    }
}
