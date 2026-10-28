import AppKit
import Testing
@testable import Clipboard

extension MainLoopClock {
@Suite("Clipboard watcher")
@MainActor
final class WatcherTests {
    let pasteboard = NSPasteboard.makePrivate()
    let database = TemporaryDatabase()
    lazy var store = try! ClipboardStore(path: database.path)

    /// Polls the store every 50 ms until `found` holds or `seconds` pass; returns how long it took.
    func waitFor(_ seconds: Double, _ found: () throws -> Bool) async throws -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if try found() { return Date().timeIntervalSince(start) }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Spins the main run loop in event-tracking mode, as AppKit does while a menu is open.
    static func trackMenu(until found: () throws -> Bool, seconds: Double = 30) rethrows -> Bool {
        let closesAt = Date().addingTimeInterval(seconds)
        while Date() < closesAt {
            if try found() { return true }
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        return try found()
    }

    /// Within a second by the poll's interval; on a loaded Mac the main run loop fires the timer late, so the landing
    /// itself is waited for with only a hang guard (the live pbcopy test times the real second).
    @Test("The pasteboard is polled every half second, late by a tolerance macOS can coalesce, and a copy lands in the store; what was there at start is not recorded")
    func copyLands() async throws {
        #expect(ClipboardWatcher.interval <= 0.5)
        // At least a tenth of the interval, as Apple's energy guide asks of a repeating timer, and still within a second.
        #expect(ClipboardWatcher.tolerance >= ClipboardWatcher.interval / 10)
        #expect(ClipboardWatcher.interval + ClipboardWatcher.tolerance < 1)
        pasteboard.clearContents()
        pasteboard.setString("already there", forType: .string)
        let watcher = ClipboardWatcher(pasteboard: pasteboard, store: store, sourceApp: { "com.apple.TextEdit" })
        watcher.start()
        defer { watcher.stop() }

        pasteboard.clearContents()
        pasteboard.setString("probe \(UUID().uuidString)", forType: .string)
        let took = try await waitFor(30) { try store.recent().contains { $0.text.hasPrefix("probe ") } }
        #expect(took != nil)
        #expect(try store.recent().map(\.text).contains("already there") == false)
    }

    @Test("Two copies one after the other both land while a menu is open (the run loop in event-tracking mode)")
    func closeCopiesLandDuringMenuTracking() async throws {
        _ = NSApplication.shared   // as in Pilot.app, whose NSApplication puts event tracking in the common modes
        let watcher = ClipboardWatcher(pasteboard: pasteboard, store: store, sourceApp: { "com.apple.TextEdit" })
        watcher.start()
        defer { watcher.stop() }

        // Pilot's dropdown open: AppKit runs the main run loop in event-tracking mode until the menu closes. Each copy is
        // waited for in that mode alone, so a timer left in the default mode never stores it.
        pasteboard.copy("first \(UUID().uuidString)")
        #expect(try Self.trackMenu { try store.recent().count == 1 })
        pasteboard.copy("second \(UUID().uuidString)")
        let landed = try Self.trackMenu { try store.recent().count == 2 }
        let stored = try store.recent().map(\.text)
        #expect(landed, "stored: \(stored)")
    }

    @Test("A concealed copy never reaches the store, and nothing is stored after stop")
    func concealedAndStop() async throws {
        let watcher = ClipboardWatcher(pasteboard: pasteboard, store: store, sourceApp: { nil })
        watcher.start()
        pasteboard.copy("hunter2", marking: [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")])
        #expect(try await waitFor(1) { try !store.recent().isEmpty } == nil)

        watcher.stop()
        pasteboard.clearContents()
        pasteboard.setString("after stop", forType: .string)
        #expect(try await waitFor(1) { try !store.recent().isEmpty } == nil)
    }

    /// The card's live check on the real clipboard. It puts the user's clipboard back afterwards.
    @Test("Live: pbcopy of a probe string shows up in the store within 1 second",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func livePbcopy() async throws {
        let general = NSPasteboard.general
        let saved = (general.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        }
        defer {
            general.clearContents()
            general.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }
        let watcher = ClipboardWatcher(store: store)
        watcher.start()
        defer { watcher.stop() }

        let probe = "pilot-probe-\(UUID().uuidString)"
        let pbcopy = Process()
        pbcopy.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let input = Pipe()
        pbcopy.standardInput = input
        try pbcopy.run()
        input.fileHandleForWriting.write(Data(probe.utf8))
        try input.fileHandleForWriting.close()
        pbcopy.waitUntilExit()

        let took = try await waitFor(1) { try store.recent().contains { $0.text == probe } }
        print("PILOT_LIVE pbcopy probe stored after \(took.map { String(format: "%.2f s", $0) } ?? "never")")
        #expect(took != nil)
    }

    @Test("Each copy stored is announced, so a new image goes to be read (card agent-bo-95423070); a skipped copy is not")
    func announcesStored() throws {
        let watcher = ClipboardWatcher(pasteboard: pasteboard, store: store, sourceApp: { nil })
        var stored = 0
        watcher.onStore = { stored += 1 }
        _ = try pasteboard.copyPNG()
        watcher.poll()
        #expect(stored == 1)
        pasteboard.copy("secret", marking: [.init("org.nspasteboard.ConcealedType")])
        watcher.poll()
        #expect(stored == 1)
    }
}
}
