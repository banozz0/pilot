import AppKit
import Testing
@testable import Clipboard

/// The 0.5 s poll stops while the screen is locked or asleep (card agent-bo-95422839) and looks again at once on unlock,
/// so a copy a script made meanwhile is still kept. A private pasteboard, never the real one.
@Suite("Clipboard watcher pause")
@MainActor
final class WatcherPauseTests {
    let pasteboard = NSPasteboard.makePrivate()
    let database = TemporaryDatabase()
    lazy var store = try! ClipboardStore(path: database.path)

    @Test("Paused, nothing is read; resumed, a copy made meanwhile is kept at once; stopped while paused, it stays stopped")
    func pauseAndResume() async throws {
        let watcher = ClipboardWatcher(pasteboard: pasteboard, store: store, sourceApp: { "com.apple.TextEdit" })
        watcher.start()
        defer { watcher.stop() }
        watcher.pause()
        pasteboard.copy("while locked")
        try await Task.sleep(for: .milliseconds(1200))   // two of the poll's ticks
        #expect(try store.recent().isEmpty)
        watcher.resume()
        #expect(try store.recent().map(\.text) == ["while locked"])

        watcher.pause()
        watcher.stop()
        watcher.resume()
        pasteboard.copy("after the stop")
        try await Task.sleep(for: .milliseconds(1200))
        #expect(try store.recent().map(\.text) == ["while locked"])
    }
}
