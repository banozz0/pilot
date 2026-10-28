import AppKit
import os

/// The clipboard module's log, beside the app's own clipboard category.
let clipLog = Logger(subsystem: "dev.banozz.pilot", category: "clipboard")

/// Polls the pasteboard's change count every 0.5 s and stores each new copy that capture keeps.
/// The contents are read only after the count changes, and never when the user has set Pilot's pasteboard
/// access to Always Deny, so macOS's pasteboard-privacy prompt fires for real copies only.
@MainActor
public final class ClipboardWatcher {
    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    /// Settings › Clipboard replaces it when the never-record list or Save images changes.
    public var capture: ClipboardCapture
    /// After each copy stored: the app has ClipboardOCR read any new image (card agent-bo-95423070).
    public var onStore: (() -> Void)?
    private let sourceApp: @MainActor () -> String?
    private var timer: Timer?
    private var changeCount = 0
    private var paused = false
    /// How often the change count is read: a copy lands within this and its tolerance, while the main run loop is free.
    static let interval: TimeInterval = 0.5
    /// How late a poll may come, so macOS fires it with other wake-ups rather than waking the Mac twice a second on its own.
    static let tolerance: TimeInterval = 0.2

    public init(pasteboard: NSPasteboard = .general, store: ClipboardStore, capture: ClipboardCapture = ClipboardCapture(),
                sourceApp: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.pasteboard = pasteboard
        self.store = store
        self.capture = capture
        self.sourceApp = sourceApp
    }

    /// Starts from what is on the pasteboard now, without recording it.
    public func start() {
        stop()
        changeCount = pasteboard.changeCount
        schedule()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        paused = false
    }

    /// The screen locked or its displays slept (card agent-bo-95422839): no polling until `resume`.
    public func pause() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        paused = true
    }

    /// Looks at once, so a copy made while locked is kept, then polls again. A watcher stopped meanwhile stays stopped.
    public func resume() {
        guard paused else { return }
        paused = false
        poll()
        schedule()
    }

    private func schedule() {
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = Self.tolerance
        // Common modes: a default-mode timer stops while a menu is open (Pilot's dropdown, any app's menu-bar
        // menu) or a modal panel runs, and copies made meanwhile merge into the last one.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard pasteboard.accessBehavior != .alwaysDeny, let item = capture.capture(pasteboard, sourceApp: sourceApp()) else { return }
        do {
            let id = try store.add(item)
            clipLog.info("clipboard stored \(item.kind.rawValue, privacy: .public) id=\(id, privacy: .public)")
            onStore?()
        } catch {
            clipLog.error("clipboard store failed: \(String(describing: error), privacy: .public)")
        }
    }
}
