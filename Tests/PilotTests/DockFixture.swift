import Foundation
import os
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
        // The visualizer never makes a real tap or listens to the Mac here: with no folder it hears nothing.
        dock.visualizer.panels = DockNoBars()
        dock.visualizer.watch = SilentAudioWatch()
        dock.visualizer.source = NoAudioSource()
        guard let folder else { return }
        let root = URL(filePath: folder, directoryHint: .isDirectory)
        // `audio.json` ({"device": true|false, "player": "playing"|"paused"|"unknown"}) stands in for the output device
        // and the now-playing reader, read again as it changes; the tap is DockSyntheticMusic, written in real time on its
        // own thread as Core Audio's would. `audio.log` gets a line per start, stop and ask.
        let audioLog = root.appending(path: "audio.log")
        dock.visualizer.watch = FileAudioWatch(file: root.appending(path: "audio.json"), log: audioLog)
        dock.visualizer.source = SyntheticAudioSource(log: audioLog)
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

/// The sandbox's visualizer with no folder: nothing ever plays.
@MainActor
final class SilentAudioWatch: DockAudioWatch {
    let name = "none (sandbox)"
    func start(_ changed: @escaping @MainActor (Bool, Bool?) -> Void) { changed(false, nil) }
    func stop() {}
}

@MainActor
final class NoAudioSource: DockAudioSource {
    let name = "none (sandbox)"
    func start(into ring: DockSampleRing) throws { throw DockAudioError.notHere }
    func stop() {}
    func ask() async {}
}

/// The fake output device and now-playing reader: `audio.json`, read at start and each time it is written.
@MainActor
final class FileAudioWatch: DockAudioWatch {
    let name = "audio.json (sandbox)"
    let file: URL, log: URL
    private var changed: (@MainActor (Bool, Bool?) -> Void)?
    private var watching = false
    /// The last values read: told and logged only when they change, as the log sits in the folder the watch follows.
    private var last: (Bool, Bool?)?

    init(file: URL, log: URL) { self.file = file; self.log = log }

    func start(_ changed: @escaping @MainActor (Bool, Bool?) -> Void) {
        self.changed = changed
        if !watching {
            watching = true
            DockFixture.watch(file) { [weak self] in self?.read() }
        }
        read()
    }

    func stop() {
        changed = nil
        last = nil
    }

    private func read() {
        guard let changed else { return }
        let row = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let device = row["device"] as? Bool ?? false
        let player: Bool? = switch row["player"] as? String { case "playing": true; case "paused": false; default: nil }
        if let last, last.0 == device, last.1 == player { return }
        last = (device, player)
        FileDockAutohide.append("watch device \(device), player \(player.map { $0 ? "playing" : "paused" } ?? "unknown")", to: log)
        changed(device, player)
    }
}

/// The fake tap: eight seconds of DockSyntheticMusic looped into the ring in 512-frame buffers at 48 kHz, on a queue of its
/// own, as Core Audio's thread writes the real one.
@MainActor
final class SyntheticAudioSource: DockAudioSource {
    let name = "synthetic music (sandbox)"
    let log: URL
    private var timer: (any DispatchSourceTimer)?

    init(log: URL) { self.log = log }

    func start(into ring: DockSampleRing) throws {
        stop()
        ring.rate = DockSyntheticMusic.rate
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sandbox-tap", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(512 / DockSyntheticMusic.rate * 1e9)), leeway: .microseconds(500))
        timer.setEventHandler(handler: Self.feeder(ring))
        timer.resume()
        self.timer = timer
        FileDockAutohide.append("tap started (synthetic)", to: log)
    }

    /// The feed, made outside the main actor, as it runs on the tap's own queue.
    nonisolated private static func feeder(_ ring: DockSampleRing) -> @Sendable () -> Void {
        let music = DockSyntheticMusic.stereo(seconds: 8), frames = 512
        let at = OSAllocatedUnfairLock(initialState: 0)
        return {
            let start = at.withLock { n in
                let now = n % (music.left.count - frames)
                n += frames
                return now
            }
            music.left.withUnsafeBufferPointer { l in
                music.right.withUnsafeBufferPointer { r in ring.write(left: l.baseAddress! + start, right: r.baseAddress! + start, frames: frames) }
            }
        }
    }

    func stop() {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        FileDockAutohide.append("tap stopped", to: log)
    }

    func ask() async { FileDockAutohide.append("asked: a real tap would ask macOS for System Audio Recording Only now", to: log) }
}
