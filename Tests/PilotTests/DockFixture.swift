import Foundation
@testable import Pilot
import PilotCore

/// PILOT_SANDBOX_DOCK=<folder> (spec pilot-dock): a fake macOS Dock for the sandbox host. `com.apple.dock.plist` there
/// stands in for the Dock's preferences (its pins and its `autohide`), `autohide` holds the auto-hide the fake Dock has
/// now, and `autohide.log` gets a line per read and write, so `pilot set dock.on` proves save, set and restore without
/// touching the real Dock. The dock never draws in the sandbox, with or without the folder.
@MainActor
enum DockFixture {
    static func install(_ folder: String?, on dock: DockController) {
        dock.panels = DockNoWindow()
        guard let folder else { return }
        let root = URL(filePath: folder, directoryHint: .isDirectory)
        let prefs = root.appending(path: "com.apple.dock.plist")
        dock.readPins = { DockPins.read(file: prefs) }
        let plist = (try? Data(contentsOf: prefs)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let start = plist?["autohide"] as? Bool ?? false
        let state = root.appending(path: "autohide")
        if !FileManager.default.fileExists(atPath: state.path(percentEncoded: false)) { try? String(start).write(to: state, atomically: true, encoding: .utf8) }
        dock.autohide = FileDockAutohide(state: state, log: root.appending(path: "autohide.log"))
        // The reveal delay: `autohide-delay` holds it, no file while the key is absent; seeded from the plist's.
        let delay = root.appending(path: "autohide-delay")
        if let seconds = plist?["autohide-delay"] as? Double, !FileManager.default.fileExists(atPath: delay.path(percentEncoded: false)) {
            try? String(seconds).write(to: delay, atomically: true, encoding: .utf8)
        }
        dock.delay = FileDockDelay(state: delay, log: root.appending(path: "autohide.log"))
        // `running.json` ([{"name", "bundleID", "path"}]), when there: the running apps in place of the Mac's, read again
        // as the file changes, standing in for NSWorkspace's list the real dock follows (Sven on build 2459).
        let running = root.appending(path: "running.json")
        if FileManager.default.fileExists(atPath: running.path(percentEncoded: false)) {
            dock.readRunning = { readRunning(running) }
            watch(running) { dock.refreshRunning() }
        }
        print("dock fixture: \(prefs.path(percentEncoded: false)), autohide \(start)")
        fflush(stdout)
    }

    /// The sandbox's running apps, pid 1000 on.
    static func readRunning(_ file: URL) -> [DockRunning] {
        let rows = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: String]] } ?? []
        return rows.enumerated().map { i, row in
            DockRunning(bundleID: row["bundleID"], url: row["path"].map { URL(filePath: $0, directoryHint: .isDirectory) }, name: row["name"] ?? "App", pid: Int32(1000 + i))
        }
    }

    /// Calls `changed` on the main queue each time `file` is written in place or replaced.
    static func watch(_ file: URL, _ changed: @escaping @MainActor () -> Void) {
        let folder = file.deletingLastPathComponent()
        let fd = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { changed() } }
        source.resume()
        watches.append(source)
    }

    nonisolated(unsafe) static var watches: [any DispatchSourceFileSystemObject] = []
}

/// The fake Dock's reveal delay: a file holding the seconds, none while the key is absent; each call logged.
struct FileDockDelay: DockRevealDelay {
    let state: URL, log: URL

    func read() async throws -> Double? {
        let now = (try? String(contentsOf: state, encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        FileDockAutohide.append("delay read \(now.map { String($0) } ?? "absent")", to: log)
        return now
    }

    func write(_ seconds: Double?) async throws {
        if let seconds { try String(seconds).write(to: state, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: state) }
        FileDockAutohide.append("delay set \(seconds.map { String($0) } ?? "absent"), Dock restarted", to: log)
    }
}

/// The fake Dock's auto-hide: a file holding true or false, each call logged.
struct FileDockAutohide: DockAutohide {
    let state: URL, log: URL

    func isHidden() async throws -> Bool {
        let now = (try? String(contentsOf: state, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        Self.append("read \(now)", to: log)
        return now
    }

    func setHidden(_ hidden: Bool) async throws {
        try String(hidden).write(to: state, atomically: true, encoding: .utf8)
        Self.append("set \(hidden)", to: log)
    }

    static func append(_ line: String, to log: URL) {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try? (text + line + "\n").write(to: log, atomically: true, encoding: .utf8)
    }
}
