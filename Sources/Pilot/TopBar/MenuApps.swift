import AppKit
import ApplicationServices
import Observation
import PilotCore

/// A running app that may own menu bar items.
struct MenuExtrasApp: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let bundleId: String?
}

/// One menu bar item as Accessibility gives it, with the element a press acts on.
struct MenuExtrasRaw: Sendable {
    let title: String?
    let description: String?
    let help: String?
    let handle: MenuItemHandle
    /// Where the item sits in the macOS menu bar, in global points from the top left (the drawer's pictures and its
    /// clicks); nil when the app did not say.
    var frame: CGRect? = nil
    /// Its AXIdentifier ("com.apple.menuextra.clock"); nil when the app gives none.
    var identifier: String? = nil
}

/// An Accessibility element (any CF object in tests), equal when CoreFoundation says so; AXUIElement is thread-safe
/// to pass around, only slow to ask.
struct MenuItemHandle: Hashable, @unchecked Sendable {
    let element: AnyObject
    init(_ element: AnyObject) { self.element = element }
    static func == (a: Self, b: Self) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

struct MenuExtrasTimeout: Error {}

extension MenuExtrasReading {
    /// Off the main thread, since a busy app can take its timeout to answer; the task says whether it took.
    func pressOffMain(_ item: MenuApps.Item) -> Task<Bool, Never> {
        Task.detached(priority: .userInitiated) { press(item.handle) }
    }
}

/// Other apps' menu bar items through Accessibility, behind a protocol so tests use a fake tree.
protocol MenuExtrasReading: Sendable {
    /// Called on the main thread: NSWorkspace updates its running apps there, and a read off it raced that update into
    /// a freed app (card agent-bo-95423303).
    func running() -> [MenuExtrasApp]
    /// The app's items, nil when it has no menu bar items; throws when the app did not answer in time.
    func items(of pid: pid_t) throws -> [MenuExtrasRaw]?
    func press(_ handle: MenuItemHandle) -> Bool
    /// The item's frame now, as `MenuExtrasRaw.frame`, read again while MenuItemOpener moves it.
    func frame(of handle: MenuItemHandle) -> CGRect?
    /// The item's own menu as Accessibility shows it closed, for Pilot to draw (MenuApps.press); empty when it shows none.
    func menu(of handle: MenuItemHandle) -> [MenuItemNode]
    /// Presses the item at `path` inside the item's menu, never the item itself.
    func press(_ path: [String], in handle: MenuItemHandle) -> Bool
}

extension MenuExtrasReading {
    func frame(of handle: MenuItemHandle) -> CGRect? { nil }
    func menu(of handle: MenuItemHandle) -> [MenuItemNode] { [] }
    func press(_ path: [String], in handle: MenuItemHandle) -> Bool { false }
}

/// The real tree: each app's AXExtrasMenuBar (top bar spike, vault note Projects/Pilot/Top bar spike.md). Pilot never
/// moves or hides another app's item; it pictures one only with Show exact menu bar items on (MenuItemPictures, ADR
/// 0012); a press is AXPress on the item, never a synthesized click or keystroke (ADR 0001).
struct AXMenuExtras: MenuExtrasReading {
    /// Which bar it reads: other apps' items (AXExtrasMenuBar), or an app's own menus (AXMenuBar, AppMenus).
    var bar = "AXExtrasMenuBar"
    /// Description and help read too; an app's own menus are named by their title alone, one ask each.
    var details = true

    /// Each app's activation policy, asked once per app rather than at every scan.
    let policies = PolicyCache()

    /// Background daemons (activation policy prohibited) own no menu bar items and are never asked.
    func running() -> [MenuExtrasApp] {
        policies.allowed(NSWorkspace.shared.runningApplications, pid: \.processIdentifier, ask: \.activationPolicy).map {
            MenuExtrasApp(pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "?", bundleId: $0.bundleIdentifier)
        }
    }

    /// The timeout is per element (AXUIElementSetMessagingTimeout), so the bar and each item get it too: a hung app
    /// costs half a second per ask, never the default 6 s.
    func items(of pid: pid_t) throws -> [MenuExtrasRaw]? {
        // Never Pilot's own, as AXMenu.menuBar.
        guard pid != getpid(), let bar = try Self.copy(AXUIElementCreateApplication(pid), bar),
              let items = try Self.copy(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement], !items.isEmpty else { return nil }
        return try items.map { item in
            MenuExtrasRaw(title: try Self.copy(item, kAXTitleAttribute) as? String,
                          description: details ? try Self.copy(item, kAXDescriptionAttribute) as? String : nil,
                          help: details ? try Self.copy(item, kAXHelpAttribute) as? String : nil, handle: MenuItemHandle(item),
                          frame: details ? try Self.frame(item) : nil,
                          identifier: details ? try Self.copy(item, kAXIdentifierAttribute) as? String : nil)
        }
    }

    func frame(of handle: MenuItemHandle) -> CGRect? { try? Self.frame(handle.element as! AXUIElement) }

    /// The element's position and size, two asks.
    private static func frame(_ element: AXUIElement) throws -> CGRect? {
        guard let position = try copy(element, kAXPositionAttribute), let size = try copy(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// One attribute within 0.5 s: nil when the element lacks it, a throw when the app did not answer in time.
    private static func copy(_ element: AXUIElement, _ attribute: String) throws -> AnyObject? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: AnyObject?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .success: return value
        case .cannotComplete: throw MenuExtrasTimeout()
        default: return nil
        }
    }

    func press(_ handle: MenuItemHandle) -> Bool {
        let item = handle.element as! AXUIElement
        AXUIElementSetMessagingTimeout(item, 1)
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    func menu(of handle: MenuItemHandle) -> [MenuItemNode] { AXMenuItems.read(menu: handle.element as! AXUIElement) }

    func press(_ path: [String], in handle: MenuItemHandle) -> Bool {
        let item = handle.element as! AXUIElement
        var pid: pid_t = 0
        // The whole app's timeout, so the walk's menu items wait 1 s too, never AX's default 6 s.
        if AXUIElementGetPid(item, &pid) == .success { AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(pid), 1) }
        AXUIElementSetMessagingTimeout(item, 1)
        return AXMenu.press(path, under: item)
    }
}

/// Which running apps are background daemons, by pid (2026-10-10, idle CPU): each activation policy ask is a round trip
/// to LaunchServices, and asking every running app held the main thread 25 to 50 ms at each scan, at each launch or
/// quit. Answers are kept while their app runs and all asked afresh every `life`, so an app that changes its
/// policy is followed. Used on the main thread only, as `running` is.
final class PolicyCache: @unchecked Sendable {
    nonisolated static let life: TimeInterval = 300
    private var prohibited: [pid_t: Bool] = [:]
    private var since: Date
    private let now: () -> Date
    init(now: @escaping () -> Date = Date.init) { self.now = now; since = now() }

    /// `apps` less the daemons, asking only the apps not seen before; a gone app's pid, reused, is asked afresh.
    func allowed<App>(_ apps: [App], pid: (App) -> pid_t, ask: (App) -> NSApplication.ActivationPolicy) -> [App] {
        if now().timeIntervalSince(since) >= Self.life { prohibited = [:]; since = now() }
        var kept: [pid_t: Bool] = [:]
        let allowed = apps.filter { app in
            let id = pid(app), daemon = prohibited[id] ?? (ask(app) == .prohibited)
            kept[id] = daemon
            return !daemon
        }
        prohibited = kept
        return allowed
    }
}

/// The menu bar apps module (card agent-bo-95422853): every other app's menu bar items, by the app's icon and name,
/// read off the main thread, several apps at once, while the module shows, again when an app launches or quits (KVO on
/// runningApplications, since NSWorkspace's notifications never arrive for menu-bar-only apps, AppWatcher) and when the
/// pointer comes over them, at most once per `hoverGap`, and when the drawer opens; one scan at a time. No poll (Sven, 2026-10-10: a 30 s scan of every app was idle CPU), so an
/// item a running app adds shows at the next hover. Each scan ends by picturing the items afresh, with Show exact menu bar
/// items on (MenuItemPictures). A click presses the item itself; from the drawer its menu opens under the drawer's item
/// (`press(_:under:)`). An app that does not answer in time keeps what it last listed.
@Observable @MainActor
final class MenuApps {
    struct Item: Equatable {
        let label: String
        let handle: MenuItemHandle
        /// Where it sits in the macOS menu bar (MenuExtrasRaw.frame).
        var frame: CGRect? = nil
    }
    struct Entry: Equatable {
        let app: MenuExtrasApp
        let items: [Item]
    }

    private(set) var list: [Entry] = []
    /// The top bar's drawer of these items (card agent-bo-95423018), one for every screen's bar.
    @ObservationIgnored let drawer: MenuAppsDrawer
    /// The items as macOS draws them, with Show exact menu bar items on.
    @ObservationIgnored let pictures: MenuItemPictures
    /// Opens an item's menu under the drawer's item.
    @ObservationIgnored let opener: MenuItemOpener
    /// Draws an item's menu under the drawer's item and returns once it closes; a pick hands back its title path.
    typealias ShowMenu = @MainActor ([MenuItemNode], NSView, @escaping ([String]) -> Void) -> Void
    @ObservationIgnored private let showMenu: ShowMenu
    @ObservationIgnored private let reader: any MenuExtrasReading
    @ObservationIgnored private let ownPid: pid_t
    @ObservationIgnored private var launches: AnyObject?
    /// Calls back at each launch or quit for as long as what it returns is kept; the tests' never calls.
    @ObservationIgnored private let watchLaunches: (@escaping @Sendable () -> Void) -> AnyObject
    @ObservationIgnored private var scanning = false
    /// When the last scan ended, so a pointer passing to and fro scans once per `hoverGap`.
    @ObservationIgnored private var scanned = Date.distantPast
    @ObservationIgnored private let now: () -> Date
    nonisolated static let hoverGap: TimeInterval = 10
    /// A refresh asked for during a scan, run once that scan ends, so a launch or a hover is never missed.
    @ObservationIgnored private var again = false

    init(reader: any MenuExtrasReading = AXMenuExtras(), ownPid: pid_t = ProcessInfo.processInfo.processIdentifier,
         drawer: MenuAppsDrawer = MenuAppsDrawer(), pictures: MenuItemPictures = MenuItemPictures(),
         opener: MenuItemOpener? = nil, now: @escaping () -> Date = Date.init,
         showMenu: @escaping ShowMenu = { BarMenu.show(appMenu: $0, under: $1, pick: $2) },
         watchLaunches: @escaping (@escaping @Sendable () -> Void) -> AnyObject = { changed in
             NSWorkspace.shared.observe(\.runningApplications) { _, _ in changed() }
         }) {
        self.reader = reader
        self.now = now
        self.watchLaunches = watchLaunches
        self.drawer = drawer
        self.pictures = pictures
        self.opener = opener ?? MenuItemOpener(reader: reader)
        self.showMenu = showMenu
        self.ownPid = ownPid
    }

    /// macOS's own items that do nothing from Pilot's bar, left out of the list (Sven on build 60: "essentially useless as
    /// theyre like menubar only items"): Control Centre's own button and its clock, which Pilot's Clock item is instead.
    nonisolated static let menuBarOnly: Set<String> = ["com.apple.menuextra.controlcenter", "com.apple.menuextra.clock"]
    /// macOS 27 moved that button and the clock to MenuBarAgent, which gives them no name and none of those identifiers:
    /// Sven's clicks on both on build 66 logged "other apps: MenuBarAgent pid 35024" (P44).
    nonisolated static let menuBarAgent = "com.apple.MenuBarAgent"

    /// The app's items Pilot's bar lists: never a `menuBarOnly` one, nor a MenuBarAgent item with no name to show.
    nonisolated static func shown(_ raws: [MenuExtrasRaw], of app: MenuExtrasApp) -> [MenuExtrasRaw] {
        raws.filter { raw in
            !menuBarOnly.contains(raw.identifier ?? "")
                && !(app.bundleId == menuBarAgent && name(raw) == nil)
        }
    }

    /// Description first (Control Centre's items carry their name there), then title, help; else the app's name.
    nonisolated static func label(_ raw: MenuExtrasRaw, app: String) -> String { name(raw) ?? app }

    /// The item's own name: its first non-empty description, title or help; nil when it gives none.
    nonisolated static func name(_ raw: MenuExtrasRaw) -> String? {
        [raw.description, raw.title, raw.help].compactMap { $0 }.first { !$0.isEmpty }
    }

    func refresh() async {
        guard !scanning else { again = true; return }
        scanning = true
        defer {
            scanning = false
            scanned = now()
            if again { again = false; refreshSoon() }
        }
        let reader = reader, previous = list
        let apps = reader.running().filter { $0.pid != ownPid }
        let fresh = await Task.detached(priority: .utility) {
            let entries = Entries(count: apps.count)
            DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                let app = apps[i]
                do {
                    entries.set(i, try reader.items(of: app.pid).flatMap { raws in
                        let shown = MenuApps.shown(raws, of: app)
                        return shown.isEmpty ? nil
                            : Entry(app: app, items: shown.map { Item(label: MenuApps.label($0, app: app.name), handle: $0.handle, frame: $0.frame) })
                    })
                } catch {
                    entries.set(i, previous.first { $0.app.pid == app.pid })
                }
            }
            return entries.all
        }.value
        if fresh != list { list = fresh }
        // Pictured only for the open drawer, the one place they are drawn.
        if drawer.isOpen { await pictures.refresh(list.flatMap(\.items)) }
    }

    /// The concurrent reads' results, each in its app's slot.
    private final class Entries: @unchecked Sendable {
        private var slots: [Entry?]
        private let lock = NSLock()
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ entry: Entry?) { lock.withLock { slots[i] = entry } }
        var all: [Entry] { lock.withLock { slots.compactMap { $0 } } }
    }

    /// Presses the item where it sits; with `under`, its app's pid and the drawer's item clicked, its menu opens under
    /// that: Pilot's own native menu of the item's items as Accessibility shows them closed, a pick AXPress on the item
    /// by its title path, as App menus draw the front app's (build 21). macOS hangs an app's own menu only under where the
    /// item sits in its own bar, and Pilot cannot put its room right of the other apps' items there to move one (Sven on
    /// build 43: an app's menu still opened at the screen's right edge), so only an item with no menu to read (a popover,
    /// a menu made as it opens) goes to MenuItemOpener.
    @discardableResult
    func press(_ item: Item, under target: (pid: pid_t, view: NSView)? = nil) -> Task<Bool, Never> {
        guard let target, let x = target.view.screenFrame?.minX else { return reader.pressOffMain(item) }
        let reader = reader, handle = item.handle, label = item.label
        return Task {
            let nodes = await Task.detached(priority: .userInitiated) { reader.menu(of: handle) }.value
            tblog.notice("other apps: \(label, privacy: .public) pid \(target.pid): \(nodes.count) menu items read closed")
            guard !nodes.isEmpty else { return await opener.open(item, of: target.pid, under: x).value }
            showMenu(nodes, target.view) { path in
                Task.detached(priority: .userInitiated) {
                    let took = reader.press(path, in: handle)
                    // Never the item's title: an app's menu may name an account.
                    tblog.notice("other apps: \(label, privacy: .public) picked an item \(path.count) deep, took \(took)")
                }
            }
            return true
        }
    }

    /// The module shows: list now and follow launches and quits.
    func start() {
        guard launches == nil else { return }
        refreshSoon()
        launches = watchLaunches { [weak self] in Task { @MainActor in self?.refreshSoon() } }
    }

    func stop() { launches = nil }

    /// The pointer came over the apps: list them afresh while followed, unless a scan is under way or just ended.
    func hovered() {
        guard launches != nil, !scanning, now().timeIntervalSince(scanned) >= Self.hoverGap else { return }
        refreshSoon()
    }

    /// The drawer opened: list and picture the items afresh, whatever the hover gap, as a click asked for them. A scan
    /// under way pictures them as it ends; one just ended (the hover before the click) leaves only the picturing.
    func opened() {
        guard launches != nil, !scanning else { return }
        if now().timeIntervalSince(scanned) < 1 { Task { await pictures.refresh(list.flatMap(\.items)) } } else { refreshSoon() }
    }

    /// Following launches, for the tests.
    var isFollowing: Bool { launches != nil }

    private func refreshSoon() { Task { await refresh() } }
}
