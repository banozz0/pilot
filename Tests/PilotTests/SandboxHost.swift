import AppKit
import Clipboard
import CryptoKit
import Foundation
@testable import Pilot
import PilotCore
import Testing

/// Sandbox E2E's host (AGENTS.md), a harness, not a test: with PILOT_SANDBOX=<socket>, the app's whole verb set and an
/// Engine that never launches, served on that socket from this run's throwaway folder and defaults: never Sven's socket,
/// stores or running Pilot. It holds until the `<socket>.hold` file it writes is removed, or 10 minutes pass. Drive it
/// with `PILOT_SOCKET=<socket> .build/debug/PilotCLI …`; plain `swift test` skips it.
@MainActor
@Suite("sandbox host")
struct SandboxHost {
    nonisolated static let socket = ProcessInfo.processInfo.environment["PILOT_SANDBOX"] ?? ProcessInfo.processInfo.environment["PILOT_THEME_FIXTURE"] ?? ProcessInfo.processInfo.environment["PILOT_BAR_FIXTURE"]

    @Test("Serves the app's verbs on PILOT_SANDBOX until its hold file goes", .enabled(if: socket != nil))
    func serve() async throws {
        if let fixture = ProcessInfo.processInfo.environment["PILOT_BAR_FIXTURE"] {
            try await BarFixture.serve(fixture)
            return
        }
        if let fixture = ProcessInfo.processInfo.environment["PILOT_THEME_FIXTURE"] {
            try await ThemeFixture.serve(fixture)
            return
        }
        let path = URL(filePath: try #require(Self.socket))
        let hold = path.appendingPathExtension("hold")
        // PILOT_SANDBOX_AI=<provider>:<fallback>: the AI page's picks on its store (each store has its own throwaway suite here),
        // so a stand-in `claude` or `codex` first on the PATH answers an extension's `ai` action without a `set` (P95).
        if let picks = ProcessInfo.processInfo.environment["PILOT_SANDBOX_AI"]?.split(separator: ":").map(String.init) {
            AISettings.shared.provider = picks.first.flatMap(AIProvider.init(rawValue:)) ?? .claudeCode
            AISettings.shared.fallback = picks.count > 1 ? AIProvider(rawValue: picks[1]) : nil
        }
        // Before the verbs: registering reads Engine.shared, which is weak.
        let engine = Engine()
        // PILOT_SANDBOX_ALLOW=1 answers every Allow yes and prints its question, so a gated verb runs on the throwaway stores
        // without a prompt on Sven's screen (P49's publish, against a local bare remote).
        if ProcessInfo.processInfo.environment["PILOT_SANDBOX_ALLOW"] == "1" {
            AllowPrompt.gate.decider = { ask, _ in print("ALLOW asked: \(ask.text)"); return true }
        }
        // PILOT_SANDBOX_ALLOW_HOLD=<path> holds each Allow up as a prompt would, so a client can change files while it is up:
        // the nth question is printed and written to <path>.asked.<n>, and answered yes once <path>.go.<n> exists, or no
        // after 50 s.
        if let held = ProcessInfo.processInfo.environment["PILOT_SANDBOX_ALLOW_HOLD"] {
            let asked = Counter()
            AllowPrompt.gate.decider = { ask, _ in
                asked.n += 1
                let n = asked.n
                print("ALLOW asked: \(ask.text)"); fflush(stdout)
                try? Data(ask.text.utf8).write(to: URL(filePath: "\(held).asked.\(n)"))
                for _ in 0..<250 {
                    if FileManager.default.fileExists(atPath: "\(held).go.\(n)") { return true }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                return false
            }
        }
        // PILOT_SANDBOX_NOTIFICATIONS=<folder>: Notification Center's tree as a file there, read through the real reader and
        // feed; the live source is never made in a test run, so nothing on the Mac is observed or moved.
        if let folder = ProcessInfo.processInfo.environment["PILOT_SANDBOX_NOTIFICATIONS"] { NotificationFixture.install(folder) }
        // A test run's bundle has no Pilot Info.plist: the app's, so `status --part update` names the feed a bundle would, or
        // PILOT_SANDBOX_INFO's, a built bundle's Contents/Info.plist, to read the route that build takes.
        let info = ProcessInfo.processInfo.environment["PILOT_SANDBOX_INFO"].map { URL(filePath: $0) }
            ?? URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Info.plist")
        // The notes in this run's throwaway folder, never Sven's Documents › Pilot Notes, which a fresh Engine's nil setting
        // names; PILOT_SANDBOX_NOTES=<file.md> copies that note in first, so `pilot list notes` reads its reminders (P66).
        let notes = PilotFolder.support.appending(path: "Sandbox Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        if let file = ProcessInfo.processInfo.environment["PILOT_SANDBOX_NOTES"].map({ URL(filePath: $0) }) {
            // Edited now, as a note just written: a line first seen in a note older than a day gets no reminder.
            let copy = notes.appending(path: file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: copy)
            try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: copy.path)
        }
        engine.settings.notesFolder = notes.path
        print("notes folder: \(notes.path)")
        fflush(stdout)
        let status = ControlStatus()
        status.updates = PilotUpdates(info: NSDictionary(contentsOf: info) as? [String: Any])
        // PILOT_SANDBOX_HOME_BLOCKS=<file>: Home's layout as a build saved it, written to this run's defaults before its store
        // first reads them, so `pilot list home-blocks` shows what that layout converts to on first launch (P91), its
        // extensions' pages listed as installed.
        var homeBlocks = HomeBlockStores()
        if let file = ProcessInfo.processInfo.environment["PILOT_SANDBOX_HOME_BLOCKS"] {
            let defaults = UserDefaults.pilot(), bytes = try Data(contentsOf: URL(filePath: file))
            let sha = { (data: Data?) in data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "none" }
            defaults.set(bytes, forKey: HomeLayoutStore.key)
            print("home.blocks sha256 before: \(sha(bytes))")
            let store = HomeLayoutStore(defaults: defaults)
            print("home.blocks sha256 after:  \(sha(defaults.data(forKey: HomeLayoutStore.key)))")
            print("home.blocks.lanes kept: \(defaults.data(forKey: HomeLayoutStore.lanesKey)?.count ?? 0) bytes; grid \(store.layout.grid.map(String.init) ?? "none"); "
                  + "drawn as the default: \(store.layout == .standard)")
            fflush(stdout)
            homeBlocks.layout = { store }
            // Its extensions' pages as installed, so their rows list too.
            let pages = store.layout.rows.compactMap { HomeLayout.extensionID($0.id) }.map { ExtensionPages.Link(id: $0, title: $0, icon: "🧩") }
            homeBlocks.pages = { pages }
        }
        // PILOT_SANDBOX_CLIPS=<file>: a throwaway clipboard history in this run's folder, one text copy a line (`\n` for a new
        // line in it), oldest first, timed as the app times them (P65), so `pilot clip list` reads it. A line starting `@old `
        // was copied an hour ago with no timer, as a row from before the timers or from while the switch was off. Other lines
        // may start `@app=<bundle id> ` and `@at=<ISO 8601 time> ` (P64's "hex from figma", "link from monday"); a colour
        // literal is a colour copy, as capture reads it. Its watcher
        // reads a pasteboard of its own, never the Mac's, so only the expiry runs: a due secret is deleted from the file.
        var clipWatcher: ClipboardWatcher?, clipBoard: NSPasteboard?
        if let file = ProcessInfo.processInfo.environment["PILOT_SANDBOX_CLIPS"] {
            let lines = try String(contentsOf: URL(filePath: file), encoding: .utf8).split(whereSeparator: \.isNewline)
                .map { $0.replacingOccurrences(of: "\\n", with: "\n") }
            let path = PilotFolder.support.appending(path: "clipboard.sqlite")
            let store = try ClipboardStore(path: path)
            let old = lines.filter { $0.hasPrefix("@old ") }, new = lines.filter { !$0.hasPrefix("@old ") }
            for (index, line) in old.enumerated() {
                try store.add(.plainText(String(line.dropFirst(5)), sourceApp: "dev.banozz.pilot.sandbox"),
                              at: Date().addingTimeInterval(-3600 + Double(index - old.count) / 1000))
            }
            try store.setSecretLifetime(ClipboardHistory.shared.settings.secretLifetime)
            let copies = new.enumerated().map { index, line in
                var text = Substring(line), app = "dev.banozz.pilot.sandbox", at = Date().addingTimeInterval(Double(index - new.count) / 1000)
                while let space = text.firstIndex(of: " ") {
                    let field = text[..<space]
                    if field.hasPrefix("@app=") { app = String(field.dropFirst("@app=".count)) }
                    else if field.hasPrefix("@at=") { at = (try? Date(String(field.dropFirst("@at=".count)), strategy: .iso8601)) ?? at }
                    else { break }
                    text = text[space...].dropFirst()
                }
                var item = ClipItem.plainText(String(text), sourceApp: app)
                if ClipboardCapture.colourValue(item.text) != nil { item.kind = .colour }
                return (item, at)
            }
            for (item, at) in copies.sorted(by: { $0.1 < $1.1 }) { try store.add(item, at: at) }
            ClipboardHistory.shared.useStore(store)
            let board = NSPasteboard(name: NSPasteboard.Name("dev.banozz.pilot.sandbox.\(UUID().uuidString)"))
            clipWatcher = ClipboardWatcher(pasteboard: board, store: store, sourceApp: { nil })
            clipWatcher?.start()
            clipBoard = board
            print("clipboard seeded: \(lines.count) copies, \(try store.recent().filter { $0.expiresAt != nil }.count) timed, at \(path.path)")
            fflush(stdout)
        }
        defer { clipWatcher?.stop(); clipBoard?.releaseGlobally() }
        let served = ControlSocket(path: path, verbs: ControlSocket.registered(status: status, homeBlocks: homeBlocks))
        #expect(served.start())
        defer { served.stop() }
        try Data().write(to: hold)
        let deadline = Date.now.addingTimeInterval(600)
        while FileManager.default.fileExists(atPath: hold.path(percentEncoded: false)) && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        withExtendedLifetime(engine) {}
    }
}

/// The sandbox's Allow hold's question count.
@MainActor private final class Counter { var n = 0 }
