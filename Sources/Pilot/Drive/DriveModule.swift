import AppKit
import OSLog
import PilotCore

let dlog = Logger(subsystem: "dev.banozz.pilot", category: "drive")

/// Drive actions (GLOSSARY.md; stories 45, 47 and 91). Keystrokes into the focused app (ADR 0001 allows them, since they
/// aim at the app in front and never at another app's global hotkey): Omarchy's Hyper+C, V, X, A, Z and Shift+Z send the
/// Cmd chord, so Caps+C copies on both machines, and Hyper+Q quits like Cmd+Q. No key in the shipped presets; Sven's
/// Omarchy import binds them. The rest are PilotCore's DriveRoute ids the Binds screen makes (card agent-bo-95422444): another app's
/// URL, its menu item, a keystroke, a Shortcuts shortcut or a shell command.
@MainActor
enum DriveModule {
    static func register(into registry: inout ActionRegistry) {
        let chords: [(id: String, label: String, key: Key)] = [
            ("copy", "Copy", Key("c", .cmd, hyper: false)), ("paste", "Paste", Key("v", .cmd, hyper: false)),
            ("cut", "Cut", Key("x", .cmd, hyper: false)), ("selectAll", "Select all", Key("a", .cmd, hyper: false)),
            ("undo", "Undo", Key("z", .cmd, hyper: false)), ("redo", "Redo", Key("z", [.shift, .cmd], hyper: false)),
            ("quitApp", "Quit app", Key("q", .cmd, hyper: false)),
        ]
        for c in chords {
            do { try registry.register(Action(id: "drive.\(c.id)", label: c.label, module: .drive, defaultKey: nil) { run(.keystroke(c.key)) }) }
            catch { dlog.error("drive.\(c.id, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
        // The front app's next and previous tab (Pilot default, story 149): its own menu item, pressed, never a keystroke.
        for (id, label, next) in [("nextTab", "Next tab", true), ("previousTab", "Previous tab", false)] {
            do { try registry.register(Action(id: "drive.\(id)", label: label, module: .drive, defaultKey: nil) { Task { @MainActor in pressTab(next: next) } }) }
            catch { dlog.error("drive.\(id, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
        for (id, label, left) in [("moveTabLeft", "Move tab left", true), ("moveTabRight", "Move tab right", false)] {
            do { try registry.register(Action(id: "drive.\(id)", label: label, module: .drive, defaultKey: nil) { Task { @MainActor in moveTab(left: left) } }) }
            catch { dlog.error("drive.\(id, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
        for zoom in AppZoom.allCases {
            do {
                try registry.register(Action(id: "drive.\(zoom.rawValue)", label: zoom.label, module: .drive, defaultKey: nil,
                                             keywords: AppZoom.keywords) { Task { @MainActor in pressZoom(zoom) } })
            } catch { dlog.error("drive.\(zoom.rawValue, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
    }

    /// Zoom in, out and back to actual size in the front app (Sven, Q435): its own menu item, pressed, never a posted ⌘+
    /// (ADR 0001). By what apps call it (Safari, Chrome and Preview "Zoom In", Ghostty "Increase Font Size"), else the item
    /// on Command plus +, = or −; Command+0 only beside one of those, since Mail's and Xcode's Command+0 is no zoom.
    /// English titles only (Sven's Mac is English (UK)); the shortcut finds another language's item.
    enum AppZoom: String, CaseIterable {
        case zoomIn, zoomOut, actualSize

        /// What `pilot actions --find` and the menu's search match besides the label; screen zoom's too.
        static let keywords = "zoom magnify bigger smaller enlarge"
        /// The keys an Actual Size on Command+0 must sit beside.
        static let steps = zoomIn.keys + zoomOut.keys

        var label: String {
            switch self { case .zoomIn: "Zoom in"; case .zoomOut: "Zoom out"; case .actualSize: "Actual size" }
        }
        /// Never TextEdit's Format › Font › Bigger, which grows the selected text, not the view.
        var titles: Set<String> {
            switch self {
            case .zoomIn: ["Zoom In", "Make Text Bigger", "Increase Font Size"]
            case .zoomOut: ["Zoom Out", "Make Text Smaller", "Decrease Font Size"]
            case .actualSize: ["Actual Size", "Reset Zoom", "Reset Font Size", "Default Font Size", "Make Text Normal Size"]
            }
        }
        /// Accessibility's shortcut character and modifier mask: 0 is Command alone, 1 Command+Shift (+ typed as Shift+=).
        var keys: [(char: String, modifiers: Int)] {
            switch self {
            case .zoomIn: [("+", 0), ("=", 0), ("=", 1)]
            case .zoomOut: [("-", 0), ("−", 0)]
            case .actualSize: [("0", 0)]
            }
        }
    }

    private static func pressZoom(_ zoom: AppZoom) {
        let keys = zoom.keys
        pressFront(zoom.label, titles: zoom.titles, missing: { "\($0) has no zoom in its menus." }) { e in
            AXMenu.on(e, keys) && (zoom != .actualSize || AXMenu.beside(e) { AXMenu.on($0, AppZoom.steps) })
        }
    }

    /// What apps call next and previous tab in their menus (Safari and Finder "Show Next Tab", Chrome "Select Next Tab"),
    /// then the shortcut most of them give it, Shift+Command+] or [.
    static let tabTitles = (next: Set(["Show Next Tab", "Select Next Tab", "Next Tab"]),
                            previous: Set(["Show Previous Tab", "Select Previous Tab", "Previous Tab"]))

    private static func pressTab(next: Bool) {
        let label = next ? "Next Tab" : "Previous Tab", key = next ? "]" : "["
        pressFront(label, titles: next ? tabTitles.next : tabTitles.previous, missing: { "\($0) has no \(label) in its menus." }) {
            AXMenu.on($0, [(key, 1)])
        }
    }

    /// Moves the front app's tab one place (Arrows preset, Sven's Q439) by its own menu item only, never a shortcut: apps
    /// put other items on the keys some apps move tabs with. Ghostty's and Ghostex's binaries carry these titles; Safari and
    /// Chrome have no such item and say so.
    static let moveTabTitles = (left: Set(["Move Tab Left"]), right: Set(["Move Tab Right"]))

    private static func moveTab(left: Bool) {
        let label = left ? "Move Tab Left" : "Move Tab Right"
        pressFront(label, titles: left ? moveTabTitles.left : moveTabTitles.right, missing: { "\($0) has no \(label) in its menus." }) { _ in false }
    }

    /// The front app's menu item by title, else by `onShortcut`. The walk runs off the main thread, at most a second, so
    /// the tap never waits on a big menu bar; a greyed-out item says so, a missing one `missing(app name)`.
    private static func pressFront(_ label: String, titles: Set<String>, missing: @escaping @MainActor (String) -> String,
                                   orShortcut onShortcut: @escaping @Sendable (AXUIElement) -> Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier, bundle = app.bundleIdentifier ?? "?", name = app.localizedName ?? "This app"
        Task {
            let found = await Task.detached(priority: .userInitiated) { AXMenu.press(pid: pid, titles: titles, orShortcut: onShortcut) }.value
            dlog.notice("\(label, privacy: .public) in \(bundle, privacy: .public): \(String(describing: found), privacy: .public)")
            switch found {
            case .pressed: break
            case .disabled: HUD.tip("\(name)'s \(label) is greyed out right now.")
            case .missing: HUD.tip(missing(name))
            }
        }
    }

    /// The drive catalogue in Pilot.app's Resources (card agent-bo-95422445); empty, with a log line, outside the bundle.
    static let catalogue = BundledJSON.load("drive-catalogue", log: dlog, empty: DriveCatalogue()) { try DriveCatalogue(json: $0) }

    /// The action a DriveRoute id names, nil for any other id. Not in the registry, like AppsModule's app links.
    static func dynamic(_ id: String) -> Action? {
        guard let route = DriveRoute(id: id) else { return nil }
        let appName = if case .menu(let bundle, _) = route { AppsModule.appName(bundle) } else { String?.none }
        // An app command whose result shows in its app (the catalogue's `opens`, P38) brings that app forward first.
        let opens = catalogue.app(for: id).flatMap { $0.entry.opens == true ? $0.app.bundle : nil }
        return Action(id: id, label: route.label(appName: appName), module: .drive) {
            if let opens { open(opens, then: route) } else { run(route) }
        }
    }

    /// The app comes forward, launched when it was not running, then the route runs; a menu item is waited for up to 3 s
    /// while a launching app builds its menus (press: its menu bar first, up to 10 s).
    static func open(_ bundle: String, then route: DriveRoute) {
        let name = AppsModule.displayName(bundle)
        guard let url = AppsModule.url(forBundle: bundle) else { return HUD.tip("\(name) is not on this Mac.") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            let pid = app?.processIdentifier, problem = error?.localizedDescription
            Task { @MainActor in
                guard let pid else {
                    dlog.error("open \(bundle, privacy: .public): \(problem ?? "no app", privacy: .public)")
                    return HUD.tip("\(name) did not open.")
                }
                if case .menu(_, let path) = route { press(path, pid: pid, bundle: bundle, name: name, wait: 3) } else { perform(route) }
            }
        }
    }

    /// After the tap callback returns: a menu walk or a LaunchServices lookup inside it would stall the keyboard. A task,
    /// not a dispatch, so a picker run from a menu row still knows where the menu stood (PilotMenu.origin).
    static func run(_ route: DriveRoute) {
        Task { @MainActor in perform(route) }
    }

    private static func perform(_ route: DriveRoute) {
        switch route {
        case .url(let raw): open(raw)
        case .menu(let bundle, let path): pressMenu(bundle, path)
        case .keystroke(let key):
            Post.key(key.keyCode, key.modifiers)
            dlog.notice("keystroke \(key.label, privacy: .public) into \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", privacy: .public)")
        case .shortcut, .shell:
            guard let command = route.command(loginShell: loginShell) else { return }
            Task { await runChild(command, route.id) }
        case .picker(let title, _, _): pick(route, title: title)
        }
    }

    static let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    /// A shell route's command run to its end: its output, nil when it failed (logged).
    static func shell(_ command: String) async -> String? {
        let route = DriveRoute.shell(command)
        guard let child = route.command(loginShell: loginShell) else { return nil }
        return await runChild(child, route.id)
    }

    /// The bind editor's Run once (spec bind-editor T5): a shell route's command now, as its bind runs it, in a child
    /// started off the main thread (ChildProcess); nil when it ran, else why it failed. The command stays out of the log.
    /// `run` runs the child: a test's in its place.
    static func runOnce(_ command: String, run: @escaping @Sendable (DriveRoute.Command) async throws -> String = {
        try await ChildProcess.run($0.path, $0.arguments)
    }) async -> String? {
        guard let child = DriveRoute.shell(command).command(loginShell: loginShell) else { return "nothing to run." }
        do { _ = try await runLogged(child, "shell run once", run: run); return nil } catch { return String(describing: error) }
    }

    /// A running app's menu items for the bind editor's Menu item form (a10), read off the main thread as the menu's
    /// search reads them (AXMenuItems); nil while the app is not running. `read` walks the menu bar: a test's in its place.
    static func menuItems(of bundle: String, read: @escaping @Sendable (pid_t) -> [MenuItemNode] = { AXMenuItems.read(pid: $0) }) async -> [MenuEntry]? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else { return nil }
        let pid = app.processIdentifier
        return await Task.detached(priority: .userInitiated) { MenuItemSearch.entries(read(pid), bundle: bundle) }.value
    }

    /// The Shortcuts app's shortcut names for the bind editor's Shortcut search: `shortcuts list` in a child, 10 s at most;
    /// none when it fails (logged).
    static func shortcutNames() async -> [String] {
        await runChild(.init(path: "/usr/bin/shortcuts", arguments: ["list"]), "shortcuts list", timeout: .seconds(10)).map(DriveRoute.rows) ?? []
    }

    @discardableResult
    private static func runChild(_ command: DriveRoute.Command, _ what: String, timeout: Duration? = nil) async -> String? {
        try? await runLogged(command, what) { try await ChildProcess.run($0.path, $0.arguments, timeout: timeout) }
    }

    /// A child run to its end, its outcome logged as `what`: its output, or the error thrown.
    private static func runLogged(_ command: DriveRoute.Command, _ what: String,
                                  run: @Sendable (DriveRoute.Command) async throws -> String) async throws -> String {
        do {
            let out = try await run(command)
            dlog.notice("\(what, privacy: .public) ran")
            return out
        } catch {
            dlog.error("\(what, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// A picker (story 48): the list command's lines in the menu's picker, then the second command with the pick as $1.
    /// The list command gets 10 s, so a wedged one never leaves a bind silent for good.
    private static func pick(_ route: DriveRoute, title: String?) {
        guard let list = route.command(loginShell: loginShell) else { return }
        Task {
            guard let out = await runChild(list, "picker list", timeout: .seconds(10)) else {
                return HUD.tip("The picker's list command failed.")
            }
            let rows = DriveRoute.rows(out)
            guard !rows.isEmpty else { return HUD.tip("The picker's list is empty.") }
            PilotMenu.shared.pick(rows.map { MenuEntry(title: $0, target: .action($0)) }, title: title) { row in
                dlog.notice("picker: \(row.title, privacy: .public) picked")
                guard let run = route.pickCommand(loginShell: loginShell, pick: row.title) else { return }
                Task { await runChild(run, "picker run") }
            }
        }
    }

    /// Without activating the app that takes the link, where its scheme allows. Checked first: a link nothing handles puts
    /// up Finder's "no application set" dialog.
    static func open(_ raw: String) {
        guard let url = URL(string: raw) else { return dlog.error("url \(LinkToken.redact(raw), privacy: .public): not a URL") }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            dlog.notice("url \(LinkToken.redact(raw), privacy: .public): no app opens it")
            return HUD.tip("No app opens \(url.scheme ?? raw) links.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error { dlog.error("url \(LinkToken.redact(raw), privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        dlog.notice("url \(LinkToken.redact(raw), privacy: .public)")
    }

    /// A running app's menu item by title path, through Accessibility; the app stays where it is.
    /// Presses a running app's menu item; an app that is not running is said so in a tip unless `quietWhenNotRunning`.
    static func pressMenu(_ bundle: String, _ path: [String], quietWhenNotRunning: Bool = false) {
        let title = DriveRoute.title(path)
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else {
            dlog.notice("menu \(bundle, privacy: .public) \(title, privacy: .private): not running")
            if !quietWhenNotRunning { HUD.tip("\(AppsModule.appName(bundle) ?? bundle) is not running.") }
            return
        }
        press(path, pid: app.processIdentifier, bundle: bundle, name: app.localizedName ?? bundle)
    }

    /// Presses the item at `path` off the main thread, the walk at most a second, so the tap never waits on it; `wait`
    /// gives a launching app that long to build its menus once its menu bar answers, and with any wait the menu bar itself
    /// gets up to 10 s (a closed app's saved menu item, T41, launches it cold). A found item is pressed once and counts as
    /// pressed: one that opens a dialog (Empty Bin…) answers AX with a timeout. A menu bar that never answered says so.
    /// macOS's own menu bar apps are refused here, so every way in (pressMenu, open(_:then:)) meets it (DriveRoute.pressesMenus).
    private static func press(_ path: [String], pid: pid_t, bundle: String, name: String, wait: TimeInterval = 0) {
        let title = DriveRoute.title(path)
        guard DriveRoute.pressesMenus(of: bundle, regular: NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular) else {
            dlog.error("menu \(bundle, privacy: .public) \(title, privacy: .private): refused, macOS's own menus")
            HUD.tip("Pilot doesn't press macOS's own menus.")
            return
        }
        enum Outcome: String { case pressed, missing = "no such enabled item", slow = "no menu bar in time" }
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                let start = Date.now
                var answered: Date?
                while true {
                    if let item = AXMenu.item(pid: pid, path: path) { _ = AXMenu.press(item); return .pressed }
                    if answered == nil, AXMenu.hasMenuBar(pid: pid) { answered = .now }
                    guard Date.now < answered.map({ $0 + wait }) ?? start + (wait > 0 ? 10 : 0) else { return answered == nil ? .slow : .missing }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }.value
            dlog.notice("menu \(bundle, privacy: .public) \(title, privacy: .private): \(outcome.rawValue, privacy: .public)")
            switch outcome {
            case .pressed: break
            case .missing: HUD.tip("\(name) has no enabled \(title).")
            case .slow: HUD.tip("\(name)'s menus didn't answer in time.")
            }
        }
    }
}
