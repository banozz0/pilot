import Foundation
import Observation
import PilotCore

/// Shortcut conflicts (stories 34, 35 and 101; SPEC.md, Conflicts): turns off each macOS shortcut one of Pilot's plain
/// combos lands on, backing up each row first, and puts them all back with one button. The domain is
/// com.apple.symbolichotkeys, a private preference and not a public API; every write is logged, never silent.
@Observable @MainActor
final class ShortcutConflicts {
    /// The AppleSymbolicHotKeys table: the live preference, or a test's copy. `apply` makes a written table take effect.
    struct Domain {
        var read: () -> [String: Any]
        var write: ([String: Any]) throws -> Void
        var apply: () async throws -> Void
    }

    static let shared = ShortcutConflicts(domain: .live, backupURL: PilotFolder.support.appending(path: "symbolichotkeys-backup.plist"))

    enum Problem: LocalizedError {
        case unreadableBackup(String), notWritten
        var errorDescription: String? {
            switch self {
            case .unreadableBackup(let path): "\(path) could not be read, so nothing was changed: it holds the shortcuts to put back."
            case .notWritten: "macOS's shortcut settings were not written; the backup is kept."
            }
        }
    }

    private let domain: Domain
    private let backupURL: URL
    /// What `Put all macOS shortcuts back` writes: read once, kept in step with the file. nil is no backup.
    private var backup: [String: Any]?
    /// Why the last write did not take effect, for the page; nil when it did.
    private(set) var problem: String?

    init(domain: Domain, backupURL: URL) {
        self.domain = domain
        self.backupURL = backupURL
        backup = try? Self.read(backupURL)
    }

    var hasBackup: Bool { backup != nil }
    /// The rows Pilot switched off and can put back, by id.
    var turnedOff: [Int] { backup.map(SymbolicHotKeys.ids(in:)) ?? [] }

    func clashes(binds: [Key: String]) -> [SymbolicHotKeys.Clash] { SymbolicHotKeys.clashes(in: domain.read(), binds: binds) }

    /// Writes the backup first; the domain is written only once the backup is on disk. A backup file that cannot be read
    /// stops it, since writing a new one would lose the rows it holds.
    func switchOff(binds: [Key: String]) throws {
        let earlier = try Self.read(backupURL)
        let current = domain.read(), clashes = SymbolicHotKeys.clashes(in: current, binds: binds)
        guard !clashes.isEmpty else { return log.notice("conflicts: nothing clashes") }
        let (table, backup) = SymbolicHotKeys.switchOff(clashes.map(\.hotkey.id), in: current, backup: earlier ?? [:])
        try save(backup)
        // A write that did not land may still have changed some rows, so the backup stays either way.
        try land(table)
        for c in clashes {
            log.notice("conflicts: macOS \(c.hotkey.name, privacy: .public) (\(c.hotkey.key?.label ?? "?", privacy: .public), row \(c.hotkey.id)) turned off for \(c.action, privacy: .public)")
        }
    }

    /// Puts every row Pilot switched off back as it was, then removes the backup.
    func restore() throws {
        guard let backup = try Self.read(backupURL) else { return log.notice("conflicts: nothing to put back") }
        try land(SymbolicHotKeys.restore(backup, in: domain.read()))
        try FileManager.default.removeItem(at: backupURL)
        self.backup = nil
        log.notice("conflicts: macOS shortcuts put back from \(self.backupURL.path, privacy: .public)")
    }

    private func save(_ backup: [String: Any]) throws {
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: backup, format: .xml, options: 0).write(to: backupURL, options: .atomic)
        self.backup = backup
    }

    /// Writes the table, reads it back to be sure it landed, then has macOS apply it.
    private func land(_ table: [String: Any]) throws {
        do { try domain.write(table) } catch { throw Problem.notWritten }
        guard NSDictionary(dictionary: domain.read()).isEqual(to: table) else { throw Problem.notWritten }
        problem = nil
        Task {
            do { try await domain.apply() }
            catch {
                problem = "Written, but macOS did not apply it until you log out again: \(error)"
                log.error("conflicts: \(self.problem ?? "", privacy: .public)")
            }
        }
    }

    /// nil when there is no backup; throws when there is one that cannot be read.
    private static func read(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let backup = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Problem.unreadableBackup(url.path) }
        return backup
    }
}

@MainActor
extension ShortcutConflicts.Domain {
    private static let name = "com.apple.symbolichotkeys", key = "AppleSymbolicHotKeys"
    private static let activateSettings = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    /// The user's own preference. A written table is applied without a logout by `activateSettings -u`, the private tool
    /// System Settings uses; that it takes effect live on macOS 27 is unverified until lane 1's check.
    static let live = Self(
        read: { CFPreferencesCopyAppValue(key as CFString, name as CFString) as? [String: Any] ?? [:] },
        write: { table in
            CFPreferencesSetAppValue(key as CFString, table as CFDictionary, name as CFString)
            guard CFPreferencesAppSynchronize(name as CFString) else { throw ShortcutConflicts.Problem.notWritten }
        },
        apply: { _ = try await ChildProcess.run(activateSettings, ["-u"], timeout: .seconds(10)) })
}
