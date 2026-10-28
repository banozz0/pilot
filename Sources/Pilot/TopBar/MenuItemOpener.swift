import AppKit

/// Pilot's own room in the macOS menu bar, behind a protocol so tests never touch the real bar.
@MainActor
protocol MenuBarSpacing: AnyObject {
    /// Pilot's own status item, empty, `length` wide, right of every other app's item.
    func show(length: CGFloat)
    func hide()
}

/// Opens another app's menu bar item under the drawer's item (Sven's yes, 2026-10-10): macOS hangs an item's menu under
/// where the item sits in its own bar, far right, while the drawer sits further left. Pilot never drags or clicks
/// another app's item (ADR 0001; Ice's Cmd-drag of the real item is a synthesized drag into another app); it widens an
/// empty status item of its own, right of the others, by as much as the item must move left, so macOS lays the item out
/// over the drawer's. Once the item's own frame says it is there, AXPress opens it; the room goes at the next click
/// outside that app's windows (its menu or popover closing), or after `keep`. An item that did not get there (macOS's own
/// items right of Pilot's room, no room left of it) is pressed where it sits, as before. macOS 27 seldom lets it: a probe's
/// room at saved position 0 sat left of an item made before it, and a room grows leftward, so it moves only the items
/// left of it (2026-10-12). MenuApps.press draws the item's menu itself first and comes here only for an item
/// with no menu to read; each step is logged (category topbar).
@MainActor
final class MenuItemOpener {
    /// How close the item's left edge must come to the drawer's item's, in points.
    nonisolated static let near: CGFloat = 4
    /// How long macOS gets to lay the bar out afresh, read every `step`.
    nonisolated static let settle: Duration = .milliseconds(400), step: Duration = .milliseconds(40)
    /// The longest the room stays with no click.
    nonisolated static let keep: Duration = .seconds(60)

    private let reader: any MenuExtrasReading
    private let spacer: any MenuBarSpacing
    private let sleep: (Duration) async -> Void
    /// Whose windows a click may land in without taking the room away.
    private var opened: pid_t?
    private var monitors: [Any] = []
    private var expiry: Task<Void, Never>?

    init(reader: any MenuExtrasReading, spacer: (any MenuBarSpacing)? = nil,
         sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.reader = reader
        self.spacer = spacer ?? StatusItemSpacer()
        self.sleep = sleep
    }

    /// Whether Pilot's room is in the bar now, for the tests.
    var isMoved: Bool { opened != nil }

    /// Opens `item` of `pid`'s with its left edge at `x`, global points; the task says whether the press took.
    @discardableResult
    func open(_ item: MenuApps.Item, of pid: pid_t, under x: CGFloat) -> Task<Bool, Never> {
        Task {
            putBack()
            let reader = reader, handle = item.handle, label = item.label
            // Read afresh: the scan's frame is as old as the last hover.
            let before = await Task.detached(operation: { reader.frame(of: handle) }).value ?? item.frame
            let shift = (before?.minX).map { $0 - x } ?? 0
            tblog.notice("opener: \(label, privacy: .public) pid \(pid): item at \(Self.describe(before), privacy: .public), drawer's at x \(x), room \(shift)")
            if shift > Self.near {
                spacer.show(length: shift)
                let after = await landed(handle, at: x), moved = after.map { abs($0.minX - x) <= Self.near } ?? false
                if moved { hold(for: pid) } else { spacer.hide() }
                tblog.notice("opener: \(label, privacy: .public) landed \(moved), item now at \(Self.describe(after), privacy: .public)")
            }
            let took = await Task.detached(priority: .userInitiated) { reader.press(handle) }.value
            tblog.notice("opener: \(label, privacy: .public) pressed, took \(took)")
            return took
        }
    }

    nonisolated private static func describe(_ frame: CGRect?) -> String {
        frame.map { "x \(Int($0.minX))…\(Int($0.maxX)) y \(Int($0.minY))" } ?? "an unknown frame"
    }

    /// The item's frame once its left edge comes to `x`, else the last read when `settle` runs out; read off the main
    /// thread every `step`.
    private func landed(_ handle: MenuItemHandle, at x: CGFloat) async -> CGRect? {
        let reader = reader
        var now: CGRect?
        for _ in 0..<Int(Self.settle / Self.step) {
            await sleep(Self.step)
            now = await Task.detached(operation: { reader.frame(of: handle) }).value
            if let now, abs(now.minX - x) <= Self.near { break }
        }
        return now
    }

    /// Takes Pilot's room out of the bar: the item goes back where it was.
    func putBack() {
        guard opened != nil else { return }
        opened = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        expiry?.cancel()
        expiry = nil
        spacer.hide()
    }

    /// A click on the screen outside `pid`'s windows, or at Pilot's own, puts the item back.
    func clicked(ownerPid: pid_t?) {
        guard let opened, ownerPid != opened else { return }
        putBack()
    }

    private func hold(for pid: pid_t) {
        opened = pid
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.clicked(ownerPid: Self.owner(at: point)) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.putBack()
            return event
        } as Any)
        expiry = Task { [weak self, sleep] in
            await sleep(Self.keep)
            guard !Task.isCancelled else { return }
            self?.putBack()
        }
    }

    /// The pid owning the frontmost on-screen window under `point` (Cocoa's global points), read on a click only.
    static func owner(at point: CGPoint) -> pid_t? {
        let flipped = CGPoint(x: point.x, y: Screens.primaryHeight - point.y)
        return EngineObservers.onScreen().first { $0.info.frame.contains(flipped) }?.info.pid
    }
}

/// Pilot's room: an empty NSStatusItem made when needed and removed after. macOS orders status items by each one's
/// saved preferred position, 0 the rightmost, so Pilot saves 0 under the item's name before making it.
@MainActor
final class StatusItemSpacer: MenuBarSpacing {
    static let name = "PilotMenuRoom"
    private var item: NSStatusItem?

    func show(length: CGFloat) {
        if item == nil {
            // The app's own defaults, where macOS reads the position; a test run's throwaway suite.
            let defaults = UserDefaults.pilot()
            defaults.set(0, forKey: "NSStatusItem Preferred Position \(Self.name)")
            defaults.removeObject(forKey: "NSStatusItem Visible \(Self.name)")
            let made = NSStatusBar.system.statusItem(withLength: length)
            made.autosaveName = Self.name
            made.button?.isEnabled = false
            item = made
        }
        item?.length = length
    }

    func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }
}
