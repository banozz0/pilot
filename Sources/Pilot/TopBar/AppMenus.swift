import AppKit
import ApplicationServices
import Observation
import PilotCore

/// The front app's own menus for the top bar's App menus item (card agent-bo-95423015): with the bar over the menu bar,
/// the mouse cannot reach them there. Its AXMenuBar is read off the main thread, each ask waiting at most 0.5 s as
/// MenuApps' does, whenever an app comes forward (NSWorkspace's activation notification; no timer). A click reads that
/// one menu's items off the main thread and Pilot draws them as its own native menu under the clicked title (BarMenu),
/// wherever the title sits in the bar; a pick is AXPress on the item by its title path (AXMenu), never a keystroke. An
/// AXPress on the menu bar item itself (FelixKratz's menus helper) opened the menu where the hidden menu bar has the
/// title, at the screen's left edge (Sven on build 21). Pilot's own menus are never asked: Accessibility into its own
/// process ran AppKit's NSMenu on the reading thread, off the main one, and crashed Pilot (Sven on build 23).
@Observable @MainActor
final class AppMenus {
    /// The app's own menu first, as the menu bar shows it; never the Apple menu.
    private(set) var list: [MenuApps.Item] = []
    /// The app `list` is read from, whose items a pick presses.
    @ObservationIgnored private(set) var pid: pid_t?
    @ObservationIgnored private let reader: any MenuExtrasReading
    @ObservationIgnored private let front: @MainActor () -> pid_t?
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private let readMenu: @Sendable (MenuItemHandle) -> [MenuItemNode]
    @ObservationIgnored private let pressPath: @Sendable (pid_t, [String]) -> Bool
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// The read under way, for the tests.
    @ObservationIgnored private(set) var reading: Task<Void, Never>?

    init(reader: any MenuExtrasReading = AXMenuExtras(bar: kAXMenuBarAttribute, details: false),
         front: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         readMenu: @escaping @Sendable (MenuItemHandle) -> [MenuItemNode] = { AXMenuItems.read(menu: $0.element as! AXUIElement) },
         pressPath: @escaping @Sendable (pid_t, [String]) -> Bool = { AXMenu.press(pid: $0, path: $1) }) {
        self.reader = reader
        self.front = front
        self.center = center
        self.readMenu = readMenu
        self.pressPath = pressPath
    }

    /// The menu bar's titles less its first, the Apple menu; an untitled one is skipped.
    nonisolated static func menus(_ raws: [MenuExtrasRaw]) -> [MenuApps.Item] {
        raws.dropFirst().compactMap { raw in raw.title.flatMap { $0.isEmpty ? nil : MenuApps.Item(label: $0, handle: raw.handle) } }
    }

    /// Reads the front app's menus; one that does not answer in time, or has none, or Pilot itself, shows none rather
    /// than the last app's.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        let pid = front(), reader = reader
        let task = Task {
            var raws: [MenuExtrasRaw] = []
            if let pid, pid != getpid() { raws = await Task.detached(priority: .userInitiated) { (try? reader.items(of: pid)) ?? nil }.value ?? [] }
            // Another app came forward meanwhile: its own read follows.
            guard front() == pid else { return }
            let fresh = Self.menus(raws)
            self.pid = pid
            if fresh != list { list = fresh }
        }
        reading = task
        return task
    }

    /// `menu`'s items, read off the main thread: what the bar draws as the menu under its title.
    func items(of menu: MenuApps.Item) async -> [MenuItemNode] {
        let readMenu = readMenu, handle = menu.handle
        return await Task.detached(priority: .userInitiated) { readMenu(handle) }.value
    }

    /// Presses the item at `path` under `menu` ([Edit, Copy] for Edit's Copy) off the main thread; false when it did not
    /// take.
    @discardableResult
    func press(_ path: [String], in menu: MenuApps.Item) -> Task<Bool, Never> {
        let pressPath = pressPath, pid = pid, path = [menu.label] + path
        return Task.detached(priority: .userInitiated) { pid.map { pressPath($0, path) } ?? false }
    }

    /// The item shows: read now and on every app that comes forward.
    func start() {
        guard observer == nil else { return }
        refresh()
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
    }

    func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
    }

    /// Following app activations, for the tests.
    var isFollowing: Bool { observer != nil }
}
