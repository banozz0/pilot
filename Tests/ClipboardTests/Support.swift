import AppKit
import Testing

/// A temporary store file, removed with its WAL side files when the suite instance goes.
final class TemporaryDatabase {
    let path = FileManager.default.temporaryDirectory.appending(path: "pilot-clips-\(UUID().uuidString).sqlite")

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path.path + suffix) }
    }
}

/// Suites on the main run loop's clock run one at a time: the watcher's menu test holds the main run loop in
/// event-tracking mode, where no main-actor work runs, and the paste steps timed on the real clock overlapped it in a
/// loaded full run, so the app's 20 ms read came after the 1 s wait (Cmd+V at 0, 1.57 and 2.91 s; OW P4).
@MainActor
@Suite("Main run loop clock", .serialized)
enum MainLoopClock {}

/// Runs what a paste schedules only when the test says so, and records the delays it asked for.
final class Scheduler {
    var waiting: [() -> Void] = []
    var delays: [TimeInterval] = []
    func after(_ delay: TimeInterval, _ run: @escaping () -> Void) { delays.append(delay); waiting.append(run) }
    func flush() { let runs = waiting; waiting = []; runs.forEach { $0() } }
}

/// Main actor: every pasteboard call blocks its thread on a synchronous XPC reply, and once each thread of Swift's
/// pool (one per core) blocks that way the run deadlocks; ten parallel pasteboard tests hung 12 runs in 12.
@MainActor
extension NSPasteboard {
    /// A private pasteboard, so tests never touch the user's clipboard.
    static func makePrivate() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("dev.banozz.pilot.test.\(UUID().uuidString)"))
    }

    /// Copies `text`, marked with each of `markers` (nspasteboard.org types) the way a password manager does.
    func copy(_ text: String, marking markers: [NSPasteboard.PasteboardType] = []) {
        clearContents()
        declareTypes([.string] + markers, owner: nil)
        setString(text, forType: .string)
        for marker in markers { setString("", forType: marker) }
    }

    /// Copies a 2×2 PNG and nothing else.
    func copyPNG() throws -> Data {
        let png = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]))
        clearContents()
        setData(png, forType: .png)
        return png
    }
}
