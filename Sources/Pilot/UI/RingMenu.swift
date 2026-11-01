import AppKit
import Observation
import os
import PilotCore
import SwiftUI

private let ringLog = Logger(subsystem: "dev.banozz.pilot", category: "rings")

/// The rings on disk (PilotCore's Rings): `~/Library/Application Support/Pilot/rings.json`, schema `Rings.version`, read
/// at launch and written whenever Settings › Rings, Binds › Mouse or `pilot` change them. A test run keeps its own file.
@Observable @MainActor
final class RingStore {
    static let url = PilotFolder.support.appending(path: "rings.json")
    let fileURL = isTestRun ? PilotFolder.support.appending(path: "rings-\(UUID().uuidString).json") : RingStore.url

    private(set) var rings = Rings.standard
    /// Why the file was not read; nil after a clean load. While set, nothing is written, so a hand edit is never lost.
    private(set) var lastError: String?
    /// After every load and change: Engine hands the tap the new Hold after.
    @ObservationIgnored var onChange: () -> Void = {}

    init() { load() }

    func load() {
        lastError = nil
        let file = try? Data(contentsOf: fileURL)
        do { rings = try file.map { data throws(Rings.LoadError) in try Rings(json: data) } ?? .standard }
        catch {
            rings = .standard
            lastError = "\(fileURL.path) not read: \(error)"
            ringLog.error("rings: \(self.lastError ?? "", privacy: .public); the defaults run")
        }
        save(over: file)
    }

    /// Every edit goes through here: the tap hears it at once, the file a moment after the last one, so typing a name
    /// writes once.
    func change(_ edit: (inout Rings) -> Void) {
        var next = rings
        edit(&next)
        guard next != rings else { return }
        rings = next
        onChange()
        pending?.cancel()
        let write = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.write() } }
        pending = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: write)
    }
    @ObservationIgnored private var pending: DispatchWorkItem?

    private func save(over old: Data? = nil) {
        onChange()
        write(over: old)
    }

    private func write(over old: Data? = nil) {
        pending = nil
        let data = rings.json()
        guard data != old else { return }
        guard lastError == nil else { return ringLog.error("rings: not written, \(self.fileURL.path, privacy: .public) could not be read") }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            ringLog.error("rings: \(self.fileURL.path, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// What one wedge shows, read once as its ring comes up: its glyph or app icon, its name, its keys and a switch's state.
struct RingFace {
    var symbol: String
    var image: NSImage?
    var label: String
    /// The action's key, "Hyper+←"; nil when unbound.
    var keys: String?
    /// A switch's state; nil for any other wedge, or a switch Pilot cannot read.
    var isOn: Bool?
    var isGroup = false
}

/// The open ring as the view draws it: the session (which ring, the level entered, what is aimed) and each place's face.
@Observable @MainActor
final class RingModel {
    var session: RingSession
    /// The faces of the level showing, by place.
    var faces: [RingFace?] = []
    var hideNames: Bool
    var flickRuns: Bool
    /// The ring came in: the view scales and fades in once.
    var shown = false

    init(session: RingSession, hideNames: Bool, flickRuns: Bool) {
        self.session = session; self.hideNames = hideNames; self.flickRuns = flickRuns
    }
}

/// Opens, drives and closes the ring (P74). `rings.open:<id>` is a held action: its press (a key, or a mouse hold once Hold
/// after ran out) opens the ring at the pointer, its release runs the aimed wedge, keeps the ring open for a click, or
/// closes it. While closed nothing is drawn or kept but the rings: the panel is made on open and let go on close.
@MainActor
final class RingController {
    let store: RingStore
    /// Set by Engine: the open ring's scroll step (HyperScroll), its Esc (HyperTap), an action run, a key's label, the
    /// switches' states, the faces' sources.
    var scroll: (((Int) -> Void)?) -> Void = { _ in }
    /// The tap's Esc (up a level, or close) and its outright close (every hold let go), set while a ring is open.
    var escape: ((() -> Void)?, (() -> Void)?) -> Void = { _, _ in }
    /// Runs a wedge's action, with where the pointer stood as the ring opened (screen points, bottom-left origin): a
    /// window wedge acts on the window there (Q415).
    var run: (String, CGPoint) -> Void = { _, _ in }
    var label: (String) -> String? = { _ in nil }
    var keys: (String) -> String? = { _ in nil }
    var states: () -> [String: Bool] = { [:] }
    var roleApps: () -> [String: String] = { [:] }
    /// A fresh filler of groups from the Hyper+Space menu for each ring opened: it reads the menu once, on the first group
    /// filled, and is let go with the ring.
    var menu: () -> RingSession.Expand = { { _ in [] } }

    /// Everything alive while a ring is open, dropped as one on close.
    private final class Open {
        let panel: NSPanel
        let model: RingModel
        let centre: CGPoint
        /// The pointer as the ring opened, before `centre` moved it in to keep the disc on screen.
        let pointer: CGPoint
        let opened: TimeInterval
        var session: RingSession
        var stopTicking: (@MainActor () -> Void)?
        /// The clicks that close a ring left open: another app's (global) and Pilot's own windows' (local), the ring's own
        /// panel aside.
        var clickWatch: [Any] = []
        var sticky = false
        let states: [String: Bool]
        let roles: [String: String]
        let expand: RingSession.Expand
        init(panel: NSPanel, model: RingModel, centre: CGPoint, pointer: CGPoint, opened: TimeInterval, session: RingSession,
             states: [String: Bool], roles: [String: String], expand: @escaping RingSession.Expand) {
            self.panel = panel; self.model = model; self.centre = centre; self.pointer = pointer; self.opened = opened; self.session = session
            self.states = states; self.roles = roles; self.expand = expand
        }
    }
    private var open: Open?
    /// The press that closed a ring left open for a click: its release does nothing.
    private var swallowRelease = false

    init(store: RingStore) { self.store = store }

    /// The trigger of `rings.open:<id>` down or up, from inside a tap's callback: the panel is made and let go after it
    /// returned, as a window's round trip to the WindowServer must never stall the tap. The main queue keeps down and up
    /// in order.
    func hold(_ down: Bool, ring id: String) {
        DispatchQueue.main.async { [weak self] in self?.held(down, ring: id) }
    }

    private func held(_ down: Bool, ring id: String) {
        if down {
            if open != nil { swallowRelease = true; return close("pressed again") }
            show(ring: id)
        } else {
            if swallowRelease { swallowRelease = false; return }
            guard let open, !open.sticky else { return }
            let held = ProcessInfo.processInfo.systemUptime - open.opened
            finish(open.session.release(held: held, flickRuns: store.rings.flickRuns), how: "let go")
        }
    }

    // MARK: open and close

    private func show(ring id: String) {
        let rings = store.rings
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let wheel = rings.wheel(front: front)
        // A ring of the app in front opens first (per-app rings, Q366); else the one the trigger names.
        let index = wheel.first?.app != nil ? 0 : wheel.firstIndex { $0.id == id } ?? 0
        guard !wheel.isEmpty else { return ringLog.notice("rings: no ring to open") }
        let expand = menu()
        let session = RingSession(wheel: wheel, index: index, expand: expand)
        let model = RingModel(session: session, hideNames: rings.hideNames, flickRuns: rings.flickRuns)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let centre = Self.centre(at: mouse, in: screen?.frame ?? .zero)
        let side = RingGeometry.side
        let panel = Self.panel(frame: CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side), model: model) { [weak self] p in
            self?.click(at: p)
        }
        let open = Open(panel: panel, model: model, centre: centre, pointer: mouse, opened: ProcessInfo.processInfo.systemUptime, session: session,
                        states: states(), roles: roleApps(), expand: expand)
        self.open = open
        publish(open, reface: true)
        panel.orderFrontRegardless()
        model.shown = true
        open.stopTicking = DragFollower.displayTicker(rate: 60) { [weak self] in self?.tick() }
        scroll { [weak self] step in self?.step(step) }
        escape({ [weak self] in DispatchQueue.main.async { self?.escaped() } },
               { [weak self] in DispatchQueue.main.async { self?.close("every hold let go") } })
        ringLog.notice("rings: \(wheel[index].id, privacy: .public) open")
    }

    /// The ring's centre: the pointer, moved in just enough that the disc stays on the screen.
    static func centre(at p: CGPoint, in frame: CGRect) -> CGPoint {
        let r = RingGeometry.disc + 6
        guard frame.width > 2 * r, frame.height > 2 * r else { return p }
        return CGPoint(x: min(max(p.x, frame.minX + r), frame.maxX - r), y: min(max(p.y, frame.minY + r), frame.maxY - r))
    }

    private func close(_ why: String) {
        guard let open else { return }
        self.open = nil
        open.stopTicking?()
        open.clickWatch.forEach(NSEvent.removeMonitor)
        scroll(nil)
        escape(nil, nil)
        open.panel.orderOut(nil)
        open.panel.contentView = nil
        open.panel.close()
        ringLog.notice("rings: closed, \(why, privacy: .public)")
    }

    /// `how` the trigger let go or the click came, for the log line, with where the session stood.
    private func finish(_ outcome: RingSession.Outcome, how: String) {
        if let s = open?.session {
            let kind = switch outcome { case .run: "run"; case .cancel: "close"; case .stay: "stay" }
            ringLog.notice("rings: \(how, privacy: .public) at \(s.crumbs.joined(separator: " › "), privacy: .public), depth \(s.depth), aim \(s.aim.map(String.init) ?? "none", privacy: .public): \(kind, privacy: .public)")
        }
        switch outcome {
        case .run(let id):
            let pointer = open?.pointer ?? NSEvent.mouseLocation
            close("ran \(LinkToken.redact(id))")
            // After the panel is gone, so the action meets the app in front as a key would.
            DispatchQueue.main.async { [run] in run(id, pointer) }
        case .cancel:
            close("nothing run")
        case .stay:
            guard let open, !open.sticky else { return }
            open.sticky = true
            // A click anywhere else closes it, in another app or in Pilot's own window, and still reaches what it clicked.
            let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            let panel = open.panel
            if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.close("clicked outside") }
            }) { open.clickWatch.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
                MainActor.assumeIsolated { if event.window !== panel { self?.close("clicked in Pilot") } }
                return event
            }) { open.clickWatch.append(local) }
        }
    }

    // MARK: while open

    /// Esc: back up a level inside a group, else closed.
    private func escaped() {
        guard let open else { return }
        if open.session.up() { publish(open) } else { close("esc") }
    }

    /// Each display frame: where the pointer aims, drawn only when that changes.
    private func tick() {
        guard let open else { return }
        let p = NSEvent.mouseLocation
        if open.session.point(dx: p.x - open.centre.x, dy: p.y - open.centre.y, at: ProcessInfo.processInfo.systemUptime, expand: open.expand) {
            publish(open)
        }
    }

    private func step(_ step: Int) {
        guard let open else { return }
        open.session.scroll(step, expand: open.expand)
        publish(open)
        ringLog.notice("rings: scrolled to \(open.session.ring?.id ?? "-", privacy: .public), depth \(open.session.depth)")
    }

    /// A click on the ring's panel, at `p` in its own points (y up from the bottom left).
    private func click(at p: CGPoint) {
        guard let open else { return }
        let side = RingGeometry.side
        let outcome = open.session.click(dx: p.x - side / 2, dy: p.y - side / 2, at: ProcessInfo.processInfo.systemUptime, expand: open.expand)
        publish(open)
        finish(outcome, how: "click")
    }

    /// The session drawn as it stands; the faces read again only when the ring, the level or its page changed.
    private func publish(_ open: Open, reface: Bool = false) {
        let before = open.model.session
        if before.crumbs != open.session.crumbs { ringLog.notice("rings: at \(open.session.crumbs.joined(separator: " › "), privacy: .public)") }
        if reface || before.index != open.session.index || before.levels != open.session.levels {
            open.model.faces = faces(open.session.places, states: open.states, roles: open.roles)
        }
        open.model.session = open.session
    }

    func faces(_ places: [RingSession.Place?], states: [String: Bool], roles: [String: String]) -> [RingFace?] {
        places.map { place in
            switch place {
            case nil: nil
            case .more?: RingFace(symbol: "ellipsis", label: "More", isGroup: true)
            case .slice(let s)?: face(s, states: states, roles: roles)
            }
        }
    }

    /// `session` drawn as it stands, shown at once: Settings › Rings' preview and the renders.
    func model(_ session: RingSession, states: [String: Bool], roles: [String: String]) -> RingModel {
        let rings = store.rings
        let model = RingModel(session: session, hideNames: rings.hideNames, flickRuns: rings.flickRuns)
        model.faces = faces(session.places, states: states, roles: roles)
        model.shown = true
        return model
    }

    func face(_ slice: RingSlice, states: [String: Bool], roles: [String: String]) -> RingFace {
        guard let id = slice.action else {
            // A group from the menu wears its branch's glyph.
            let symbol = slice.branch.flatMap(MenuBranch.init(id:))?.look.symbol ?? "rectangle.split.3x1"
            return RingFace(symbol: symbol, label: slice.label ?? "Group", isGroup: true)
        }
        let bundle = roles[id] ?? AppsModule.bundle(in: id)
        return RingFace(symbol: RingLook.symbol(id), image: bundle.flatMap(AppsModule.icon(bundle:)),
                        label: slice.label ?? label(id) ?? id, keys: keys(id), isOn: slice.kind == .switch ? states[id] : nil)
    }

    // MARK: the panel

    /// Borderless and non-activating, no shadow, at the pop-up menus' level on every Space; its view takes a click
    /// without the app in front losing focus.
    static func panel(frame: CGRect, model: RingModel, look: Look = .shared, click: @escaping @MainActor (CGPoint) -> Void) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = look.appearance(for: .menu)
        let host = RingHostView(rootView: AnyView(RingView(model: model).styled(.menu, look: look).pilotTheme(look: look)))
        host.onClick = click
        host.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = host
        return panel
    }
}

/// The ring's view in its panel: every click on it is the ring's, the first one too.
final class RingHostView: NSHostingView<AnyView> {
    var onClick: (@MainActor (CGPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onClick?(CGPoint(x: p.x, y: isFlipped ? bounds.height - p.y : p.y))
    }
}

/// `rings.open:<ring>` (P74): a held action per ring, bindable to a key in Binds › Keyboard and to a mouse button's hold in
/// Binds › Mouse. Its press opens the ring, its release runs what is aimed; run any other way (the menu, `pilot run`) its
/// press and release come at once, so the ring opens and stays for a click.
@MainActor
enum RingsModule {
    /// One per ring at launch, so each lists in Binds; a ring made later is found by `dynamic`.
    static func register(into registry: inout ActionRegistry, rings: RingController) {
        for ring in rings.store.rings.rings { try? registry.register(action(ring, rings)) }
    }

    static func dynamic(_ id: String, rings: RingController) -> Action? {
        guard let ringID = Rings.ringID(inAction: id), let ring = rings.store.rings.ring(id: ringID) else { return nil }
        return action(ring, rings)
    }

    private static func action(_ ring: Ring, _ rings: RingController) -> Action {
        let id = ring.id
        return Action(id: ring.openID, label: "Open ring: \(ring.name)", module: .rings) { [weak rings] down in rings?.hold(down, ring: id) }
    }
}

/// The Pilot ring's filler (Sven, 2026-10-20): the Hyper+Space menu read once, on the first group filled while one ring
/// is open, and each branch turned into wedges as the menu lists it: an action that asks for no typing (a switch where
/// the menu shows one on or off), an app, and a sub-branch that holds any, entered as its own ring. A search, an answer, a
/// file, a package, a Remove, Update or Clean pick and the like are left out, and a branch left with none with them. The
/// root is the menu's root as Sven arranged it (MenuRoot.shownRows): its branches and the extra rows he switched on, in
/// his order, hidden ones left out; an extra is a group of its branch, its action (none that asks for typing), or a page
/// of Pilot's window, and Files, which searches, is left out.
@MainActor
final class RingMenuSource {
    /// The menu's rows, and the action ids of the scripts that ask for a password, which no wedge holds.
    typealias Read = () -> (entries: [MenuEntry], passwords: Set<String>)
    private let read: Read
    private let root: () -> [MenuRoot.Row]
    private var menu: (entries: [MenuEntry], passwords: Set<String>)?
    private var filled: [MenuBranch: [RingSlice?]] = [:]

    init(read: @escaping Read, root: @escaping () -> [MenuRoot.Row]) { self.read = read; self.root = root }

    /// The menu as Hyper+Space reads it as it opens.
    convenience init(engine: Engine) {
        self.init(read: {
            let scripts = ScriptCommand.find()
            return (PilotMenu.entries(engine, scripts: scripts, extensions: Extension.find().extensions),
                    Set(scripts.filter(\.takesPassword).map(\.actionID)))
        }, root: { MenuRootSettings.shared.root.listed.shownRows() })
    }

    /// The wedges of the branch `id` names, or of the root for nil.
    func wedges(_ id: String?) -> [RingSlice?] {
        guard let id else { return root().compactMap(wedge) }
        return MenuBranch(id: id).map(children) ?? []
    }

    /// The menu's screens an extra row opens, and the action that opens the menu on each (SystemModule).
    static let screens: [MenuBranch: String] = [.activity: "system.activityMenu", .stats: "system.statsMenu"]

    private func wedge(_ row: MenuRoot.Row) -> RingSlice? {
        switch row {
        case .branch(let b): return group(b)
        case .extra(let e):
            switch e.target {
            // Activity and Stats are screens, not rows a ring could hold: their wedge opens the menu on them (Q399, Q400).
            case .branch(let b): return Self.screens[b].map { RingSlice($0, label: e.title) } ?? group(b, label: e.title)
            case .action(let id): return Rings.needsTyping(id) ? nil : RingSlice(id, label: e.title)
            case .openPage(let place): return RingSlice(SettingsSearch.actionID(place), label: e.title)
            default: return nil   // Files searches
            }
        }
    }

    private func group(_ branch: MenuBranch, label: String? = nil) -> RingSlice? {
        children(branch).isEmpty ? nil : .menu(label ?? branch.title, branch: branch.rawValue)
    }

    private func children(_ branch: MenuBranch) -> [RingSlice?] {
        if let done = filled[branch] { return done }
        filled[branch] = []   // a branch listing itself, however far down, ends there
        if menu == nil { menu = read() }
        let passwords = menu?.passwords ?? []
        let wedges: [RingSlice?] = (menu?.entries ?? []).filter { $0.home == branch }.compactMap { entry -> RingSlice? in
            switch entry.target {
            // A script that asks for its arguments (`fills`) or a password needs typing too.
            case .action(let id): Rings.needsTyping(id) || entry.fills != nil || passwords.contains(id) ? nil
                : RingSlice(id, kind: entry.isOn == nil ? .action : .switch, label: entry.title)
            case .app(let bundle): RingSlice(AppsModule.openID(bundle: bundle), label: entry.title)
            case .branch(let sub): group(sub)
            default: nil
            }
        }
        filled[branch] = wedges
        return wedges
    }
}

/// A wedge's glyph: the Hyper+Space menu's own for that action, else its module's.
enum RingLook {
    static func symbol(_ id: String) -> String { own[id] ?? MenuEntry.symbol(forAction: id) }

    /// The window places and Read aloud, which the menu leaves to their module's glyph, apart on a ring where they sit side
    /// by side (Halo's).
    static let own = [
        "speech.readAloud": "text.bubble",
        "windows.maximise": "viewfinder", "windows.snapLeft": "rectangle.lefthalf.inset.filled", "windows.snapRight": "rectangle.righthalf.inset.filled",
        "windows.centre": "rectangle.center.inset.filled", "windows.middleThird": "rectangle.center.inset.filled",
        "windows.firstThird": "rectangle.leftthird.inset.filled", "windows.lastThird": "rectangle.rightthird.inset.filled",
        "windows.firstTwoThirds": "rectangle.lefthalf.inset.filled", "windows.lastTwoThirds": "rectangle.righthalf.inset.filled",
        "windows.firstThreeQuarters": "rectangle.lefthalf.inset.filled", "windows.lastQuarter": "rectangle.rightthird.inset.filled",
        "windows.sendToNextWorkspace": "arrow.up.forward.square", "windows.sendToPreviousWorkspace": "arrow.up.backward.square",
    ]
}
