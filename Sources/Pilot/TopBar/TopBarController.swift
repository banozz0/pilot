import AppKit
import Observation
import OSLog
import PilotCore
import SwiftUI

let tblog = Logger(subsystem: "dev.banozz.pilot", category: "topbar")

/// The bars on screen, behind a protocol so tests never show a window.
@MainActor
protocol TopBarPanels: AnyObject {
    /// One bar on each of these screens, none on any other.
    func show(on screens: [TopBarGeometry.Screen])
    func hideAll()
    func reservedHeight(on screen: TopBarGeometry.Screen, configuration: BarPresetConfiguration) -> Double
    /// Every bar's window level, the ones shown later too.
    var level: NSWindow.Level { get set }
    /// Keeps the bars on these screens out of sight, their room and geometry kept, and brings back the rest.
    func cover(_ screens: Set<String>)
}

extension TopBarPanels {
    func cover(_ screens: Set<String>) {}
    func reservedHeight(on screen: TopBarGeometry.Screen, configuration: BarPresetConfiguration) -> Double {
        configuration.height + configuration.topMargin
    }
}

/// Pilot's top bar (card agent-bo-95422850; spike vault note Projects/Pilot/Top bar spike.md): off by default, and
/// nothing changes until Sven switches it on. On measures each screen's menu bar strip, then TopBarSwitch hides the
/// menu bar through System Events and makes room in Pilot's block; off undoes both. Screens left out get no bar and
/// no room.
@Observable @MainActor
final class TopBarController {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let autohide: any MenuBarAutohide
    @ObservationIgnored private let writeBars: TopBarSwitch.WriteBars
    @ObservationIgnored private let screens: () -> [TopBarGeometry.Screen]
    @ObservationIgnored private let panels: any TopBarPanels

    /// Saved after each switch, so a relaunch shows the bars and off still puts back the autohide on found.
    private(set) var state: TopBarSwitch {
        didSet { defaults.set(try? JSONEncoder().encode(state), forKey: "topBar.switch") }
    }
    /// Screens by name that get no bar; a screen never seen before gets one.
    var leftOut: Set<String> {
        didSet {
            defaults.set(Array(leftOut).sorted(), forKey: "topBar.leftOut")
            follow()
        }
    }
    /// The screens connected now, for the page's list.
    private(set) var connected: [TopBarGeometry.Screen] = []
    private(set) var busy = false
    /// The last refusal, shown on the Menu bar page; nil after a clean switch.
    private(set) var problem: String?
    /// The bars last written while on, so a screen notification that changes nothing writes nothing.
    @ObservationIgnored private var written: [PilotBlock.BarInset]?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?
    /// Told after each switch that went through, on or off; Engine points it at the Menu bar page's placement.
    @ObservationIgnored var switched: @MainActor (Bool) -> Void = { _ in }

    init(defaults: UserDefaults = .pilot(), autohide: any MenuBarAutohide = SystemEventsAutohide(),
         writeBars: @escaping TopBarSwitch.WriteBars, screens: @escaping () -> [TopBarGeometry.Screen],
         panels: any TopBarPanels) {
        self.defaults = defaults
        self.autohide = autohide
        self.writeBars = writeBars
        self.screens = screens
        self.panels = panels
        state = defaults.data(forKey: "topBar.switch").flatMap { try? JSONDecoder().decode(TopBarSwitch.self, from: $0) } ?? .off
        leftOut = Set(defaults.stringArray(forKey: "topBar.leftOut") ?? [])
        connected = screens()
    }

    var isOn: Bool { state.isOn }

    /// The screens that get a bar now.
    private var picked: [TopBarGeometry.Screen] { connected.filter { !leftOut.contains($0.name) } }

    /// Same local bar.items source; changes reserve the floating bar's bottom edge, not just its painted height.
    private var reserved: [TopBarGeometry.Screen] {
        let preset = defaults.data(forKey: BarItemsStore.key).flatMap { try? JSONDecoder().decode(BarSettings.self, from: $0) }?.preset
        return picked.map { screen in
            guard let preset else { return screen }
            return .init(name: screen.name, strip: panels.reservedHeight(on: screen, configuration: preset), displayUUID: screen.displayUUID)
        }
    }

    /// At launch: the bars come back if the switch was left on, and follow the screens from then on.
    func start() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // Only the workspace's centre posts Space changes: entering or leaving fullscreen, or a swipe to another Space.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.coverFullscreen() }
        }
        if state.isOn { panels.show(on: picked) }
        coverFullscreen()
    }

    /// The screens whose current Space is a fullscreen app's (or Split View's), read fresh: their bars stay out of sight
    /// while another screen keeps its own. `.fullScreenNone` keeps none off such a Space: it only stops the bar going
    /// fullscreen itself, and a non-activating panel on every Space shows over a fullscreen app.
    var fullscreen: Set<String> { TopBarGeometry.covered(connected, spaces: DisplaySpaces.layout()) }

    /// Hides the bars on fullscreen Spaces and brings back the others; purely visual, so the block and the tiler's room
    /// stay as they are.
    private func coverFullscreen() {
        guard state.isOn else { return }
        panels.cover(fullscreen)
    }

    func set(_ on: Bool) {
        guard on != state.isOn, !busy else { return }
        busy = true
        problem = nil
        connected = screens()
        let bars = TopBarGeometry.bars(reserved)
        Task {
            defer { busy = false }
            do {
                state = on ? try await state.switchedOn(bars, autohide: autohide, writeBars: writeBars)
                    : try await state.switchedOff(bars: bars, autohide: autohide, writeBars: writeBars)
            } catch {
                problem = String(describing: error)
                tblog.error("top bar \(on ? "on" : "off", privacy: .public): \(String(describing: error), privacy: .public)")
                return
            }
            written = on ? bars : nil
            // A screen left out while switching on is caught up here.
            if on { follow(); coverFullscreen() } else { panels.hideAll() }
            switched(on)
            tblog.notice("top bar \(on ? "on" : "off", privacy: .public), \(bars.map { "\($0.monitor) \($0.height)" }.joined(separator: ", "), privacy: .public)")
        }
    }

    /// The observers dump's line, so a live check reads the switch and its bars.
    var line: String {
        "top bar: \(state.isOn ? "on" : "off"), saved autohide \(state.savedAutohide.map(String.init) ?? "none"), bars "
            + (picked.map { "\($0.name) \(TopBarGeometry.inset($0.strip))" }.joined(separator: ", "))
    }

    /// A screen came, went or changed.
    func screensChanged() {
        connected = screens()
        follow()
        coverFullscreen()
    }

    /// Held, the bars drop under the menu bar, so an autohidden menu bar revealing at the top edge shows over them and
    /// its menus and other apps' items take the mouse (card agent-bo-95423008); let go, they rise above it again.
    func peek(_ held: Bool) {
        panels.level = held ? TopBarWindows.underMenuBar : TopBarWindows.aboveMenuBar
    }

    /// The bar's actions: its switch (no default key) and the peek on Hyper+Shift+M, since Sven's plain Hyper+M and +B
    /// open Spotify and Zen.
    static func register(into registry: inout ActionRegistry, bar: TopBarController) {
        do {
            try registry.register(Action(id: "engine.topBar", label: "Top bar on or off", module: .engine) { bar.set(!bar.isOn) })
            try registry.register(Action(id: "bar.peekMenuBar", label: "Show the menu bar while held", module: .system,
                                         defaultKey: Key("m", .shift), hold: bar.peek))
        } catch { tblog.error("top bar actions: \(String(describing: error), privacy: .public)") }
    }

    /// While on, the bars and their room follow the picked screens; the block is written only when they changed.
    private func follow() {
        guard state.isOn else { return }
        panels.show(on: picked)
        let bars = TopBarGeometry.bars(reserved)
        guard bars != written else { return }
        written = bars
        Task {
            do { try await writeBars(bars) } catch {
                written = nil
                problem = TopBarError.block(error).description
                tblog.error("top bar room: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// The real screens: each NSScreen by the tiler's monitor name, its strip measured while the menu bar shows and
/// remembered for when autohide leaves it 0, then held to the Full bar's least height (TopBarGeometry.fullBar).
@MainActor
enum TopBarScreens {
    private static let key = "topBar.strips"

    static func measure(_ defaults: UserDefaults) -> [TopBarGeometry.Screen] {
        var remembered = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let screens = NSScreen.screens.map { screen in
            let name = screen.localizedName
            let strip = TopBarGeometry.strip(frameMaxY: screen.frame.maxY, visibleMaxY: screen.visibleFrame.maxY,
                                             remembered: remembered[name], fallback: NSStatusBar.system.thickness)
            if screen.frame.maxY > screen.visibleFrame.maxY { remembered[name] = strip }
            return TopBarGeometry.Screen(name: name, strip: TopBarGeometry.fullBar(strip), displayUUID: WallpaperScreen.number(screen).flatMap(DisplayIdentity.uuid(for:)))
        }
        if remembered != defaults.dictionary(forKey: key) as? [String: Double] { defaults.set(remembered, forKey: key) }
        return screens
    }
}

/// The window server's Spaces layout, each display's current Space among them (CGSCopyManagedDisplaySpaces, private, as
/// the background blur's CGS calls are); `layout` is swapped for a file in the sandbox.
@MainActor
enum DisplaySpaces {
    static var layout: @MainActor () -> [[String: Any]] = live

    private typealias Connection = @convention(c) () -> Int32
    private typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let calls: (Connection, Copy)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let connection = dlsym(handle, "CGSMainConnectionID"), let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces") else {
            tblog.error("no CGSCopyManagedDisplaySpaces, so the top bar and the dock stay on fullscreen Spaces")
            return nil
        }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(copy, to: Copy.self))
    }()

    private static func live() -> [[String: Any]] {
        guard let (connection, copy) = calls else { return [] }
        return copy(connection())?.takeRetainedValue() as? [[String: Any]] ?? []
    }
}

/// One borderless, non-activating panel per screen at the status bar's level (25): over the menu bar (24), so an
/// autohidden menu bar revealing on hover slides out under the bar, never over it (card agent-bo-95423007; SketchyBar's
/// topmost=on), and over the Dock (20). On every Space but a fullscreen app's (`cover`), never key, never in Cmd+Tab.
/// Each panel tracks edit mode's drags and hands right-clicks and the wheel to the item under the pointer (TopBarPanel).
@MainActor
final class TopBarWindows: TopBarPanels {
    private struct Key: Hashable { let screen: String; var side: TopBarSide? = nil }
    private var panels: [Key: TopBarPanel] = [:]
    private let sources: BarSources
    private let store: BarItemsStore
    private var shown: [TopBarGeometry.Screen] = []
    /// Screens on a fullscreen Space: their panels stay made and placed, out of sight.
    private var covered: Set<String> = []

    init(sources: BarSources, store: BarItemsStore) {
        self.sources = sources
        self.store = store
        followLook()
    }

    /// Every bar follows its Background and Colour and Look's theme and style as they change: what applyLook reads,
    /// watched even with no bar shown yet.
    private func followLook() {
        let look = Look.shared, wallpapers = BarWallpapers.shared
        if !shown.isEmpty {
            show(on: shown)
            Engine.shared?.topBar.screensChanged()
        }
        panels.forEach { Self.applyLook(look, store: store, wallpaper: wallpapers.strips[$0.key.screen], to: $0.value) }
        withObservationTracking {
            _ = (look.appearance(for: .topBar), look.style, look.theme, look.transparency, look.glassBlur, store.background, store.colour,
                 wallpapers.strips, store.topBarConfiguration)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followLook() }
        }
    }

    /// A bar's window as its own Background and Colour say (BarItemsStore), never Look's Glass: on that the wallpaper
    /// drowned its text (Sven, 2026-10-10, build 29). Solid leaves the ground to the strip (TopBarStrip); Glass puts the
    /// glass behind it, tinted with the bar's colour at Look's Transparency, in Look's Blur, and Solid at Transparency 0 %; Clear puts nothing, the items straight on the
    /// wallpaper as on the macOS menu bar (Sven on build 60). Dark or light as the style, or as the bar's
    /// ink once its text was inked for its colour or for the `wallpaper` under it (StyleTokens.inked, BarTone),
    /// so the glass and system glyphs go with the text.
    static func applyLook(_ look: Look, store: BarItemsStore, wallpaper: WallpaperStrip.Grid? = nil, to panel: NSPanel) {
        let tokens = tokens(look)
        let background = store.background.shown(transparency: look.transparency)
        let inked = TopBarColour.ink(store.colour, style: tokens, background: background, wallpaper: wallpaper, look: look).tokens
        panel.appearance = inked.inked ? NSAppearance(named: inked.dark ? .darkAqua : .aqua) : look.appearance(for: .topBar)
        // An island's or a Pills side's window shows no glass of its own: each island and each pill draws its own Liquid
        // Glass in its outline (TopBarStrip), so the glass's edge follows the flares instead of a mask cutting it.
        let glass = background == .glass && store.topBarConfiguration?.preset.islands != true
        (panel.contentView as? MaterialBackdrop)?.show(glass ? .glass : .solid, tint: TopBarColour.tint(store.colour, style: tokens, look: look),
                                                         blur: TopBarColour.barBlur(look), tintsGlass: TopBarColour.tintsGlass(store.colour))
    }

    /// The tokens the bar draws in (the topBar surface's style).
    static func tokens(_ look: Look) -> StyleTokens { StyleTokens.of(look.style, theme: look.theme) }

    static let aboveMenuBar = NSWindow.Level.statusBar
    /// Where the menu bar peek puts them: one under the menu bar.
    static let underMenuBar = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)

    /// The bar drops hang one under it, so they follow it (BarDrops.level).
    var level: NSWindow.Level = TopBarWindows.aboveMenuBar {
        didSet {
            guard level != oldValue else { return }
            panels.values.forEach { $0.level = level }
            BarDrops.shared.barLevel = level
        }
    }

    func reservedHeight(on screen: TopBarGeometry.Screen, configuration: BarPresetConfiguration) -> Double {
        guard let ns = NSScreen.screens.first(where: { $0.localizedName == screen.name }) else { return configuration.height + configuration.topMargin }
        return ns.frame.maxY - BarPresetGeometry.frame(configuration, screen: ns.frame, strip: screen.strip, notch: ns.safeAreaInsets.top).minY
    }

    func show(on screens: [TopBarGeometry.Screen]) {
        shown = screens
        // These same panel frames define the hard edge for snapped windows and the existing item anchors.
        Screens.bars = Dictionary(screens.map { screen in
            let config = store.topBarConfiguration
            return (screen.name, config.map { reservedHeight(on: screen, configuration: $0) } ?? screen.strip)
        }, uniquingKeysWith: { first, _ in first })
        BarWallpapers.shared.follow(screens)
        let configuration = store.topBarConfiguration
        let islands = configuration?.preset.islands == true
        for key in panels.keys where !screens.contains(where: { $0.name == key.screen }) || (key.side != nil) != islands {
            panels.removeValue(forKey: key)?.orderOut(nil)
        }
        for screen in screens {
            guard let ns = NSScreen.screens.first(where: { $0.localizedName == screen.name }) else { continue }
            let frame = BarPresetGeometry.frame(configuration, screen: ns.frame, strip: screen.strip, notch: ns.safeAreaInsets.top)
            let keys = islands ? TopBarSide.allCases.map { Key(screen: screen.name, side: $0) } : [Key(screen: screen.name)]
            for key in keys {
                let panel = panels[key] ?? make(key)
                panels[key] = panel
                panel.contentView?.wantsLayer = true
                // A pill rounds itself inside its side's window (TopBarStrip), so that window keeps square corners. A
                // one-window bar's glass takes the same corners, so its own edge is drawn round them.
                let radius = configuration.map { $0.preset == .pills || $0.isAttached ? 0 : $0.radius } ?? 0
                panel.contentView?.layer?.cornerRadius = radius
                (panel.contentView as? MaterialBackdrop)?.cornerRadius = radius
                panel.contentView?.layer?.maskedCorners = BarIslandShape.corners(configuration)
                panel.contentView?.layer?.masksToBounds = true
                if let clip = (panel.contentView as? MaterialBackdrop)?.content as? TopBarIslandClip {
                    clip.canvas = frame
                    clip.needsLayout = true
                    clip.layoutSubtreeIfNeeded()
                    // The canvas moved (Attached or Floating, a screen change, the menu strip measured again): each island
                    // follows it now. Before, an island window moved only when its own row changed size, as the row's
                    // rect inside the canvas is the same either way, so Attached islands kept Floating's frame 8 pt below
                    // the top until an item changed width (Sven on build 2479; his log: middle and right islands kept
                    // y 1396 while the left one went to 1404 when its width changed).
                    if clip.crop.width > 0 { placeIsland(key, rect: clip.reported) }
                } else {
                    panel.pin(frame)
                    place(panel, of: key, wanted: true)
                }
            }
        }
    }

    func hideAll() {
        shown = []
        Screens.bars = [:]
        BarWallpapers.shared.follow([])   // no bar, no strips read
        panels.values.forEach { $0.orderOut(nil) }
        panels = [:]
    }

    private func make(_ key: Key) -> TopBarPanel {
        let content = NSHostingView(rootView: TopBarView(screen: key.screen, sources: sources, store: store,
            reportIsland: key.side.map { side in { [weak self] reported, rect in
                guard reported == side else { return }
                self?.placeIsland(key, rect: rect)
            } }))
        content.sizingOptions = []
        let body: NSView = key.side == nil ? content : TopBarIslandClip(content)
        let panel = Self.panel(MaterialBackdrop(content: body), level: level)
        // Set, so its clear pixels take the mouse too (as GapHandlePanels'). Left at AppKit's default, a clear window takes
        // a click only on a pixel it draws, and the glass draws none of its own: a click on an item's padding, between a
        // glyph's strokes or on a flare went through to the wallpaper, and macOS showed the desktop (Sven, 2026-11-15; 35 of
        // 630 points over his right island's end reached Pilot). The dock, which shares panel(_:level:), keeps the default.
        panel.ignoresMouseEvents = false
        // The outer windows reach for their screen's sides: the left island the left, the right island the right, a
        // one-window bar both (TopBarPanel.reaches).
        panel.reaches = switch key.side {
        case nil: [.left, .right]
        case .left: [.left]
        case .right: [.right]
        case .centre: []
        }
        // Drag to rearrange on the bar (spec drag-reorder), in the row's own space.
        BarDrag.shared.store = store
        panel.drag = BarPanelDrag(screen: key.screen, host: content)
        Self.applyLook(.shared, store: store, wallpaper: BarWallpapers.shared.strips[key.screen], to: panel)
        return panel
    }

    private func placeIsland(_ key: Key, rect: CGRect) {
        guard store.topBarConfiguration?.preset.islands == true, let panel = panels[key],
              let clip = (panel.contentView as? MaterialBackdrop)?.content as? TopBarIslandClip else { return }
        // The final row rectangle drives the crop, window bounds and input region together. No full-width window.
        // Attached: as wide again as the flares the island's ground reaches out by, which the row keeps room for.
        clip.reported = rect
        let flare = store.topBarConfiguration.map(BarIslandShape.flare) ?? 0
        let grown = rect.width > 0 ? rect.insetBy(dx: -flare, dy: 0) : rect
        guard let frame = BarPresetGeometry.islandFrame(grown, in: clip.canvas) else {
            place(panel, of: key, wanted: false)
            return
        }
        // A window already where it goes is left alone (TopBarPanel.put): no frame set from inside a layout pass for nothing.
        if clip.crop != grown { clip.crop = grown }
        panel.pin(frame)
        clipToOutline(panel)
        place(panel, of: key, wanted: true)
    }

    /// An attached island window clipped to its grown outline (BarIslandShape.mask), the same outline its glass draws in;
    /// Floating, its rounded corners alone.
    private func clipToOutline(_ panel: TopBarPanel) {
        guard let layer = panel.contentView?.layer else { return }
        let bounds = CGRect(origin: .zero, size: panel.frame.size)
        if let path = BarIslandShape.mask(store.topBarConfiguration, bounds: bounds) {
            let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame = bounds
            mask.path = path
            layer.mask = mask
        } else if layer.mask != nil {
            layer.mask = nil
        }
    }

    func cover(_ screens: Set<String>) {
        guard screens != covered else { return }
        covered = screens
        tblog.notice("top bar hidden on fullscreen Spaces: \(screens.isEmpty ? "none" : screens.sorted().joined(separator: ", "), privacy: .public)")
        panels.forEach { place($0.value, of: $0.key, wanted: $0.value.wanted) }
    }

    /// A bar's window on screen when Pilot wants it there and its screen is on no fullscreen Space; out of sight otherwise.
    private func place(_ panel: TopBarPanel, of key: Key, wanted: Bool) {
        panel.wanted = wanted
        if wanted, !covered.contains(key.screen) {
            if !panel.isVisible { panel.orderFrontRegardless() }
            panel.placeCatchers()
        } else if panel.isVisible { panel.orderOut(nil) }
    }

    /// A bar's window around its content, at `level`.
    static func panel(_ content: NSView, level: NSWindow.Level) -> TopBarPanel {
        let panel = TopBarPanel()
        panel.contentView = content
        panel.title = "Pilot top bar"   // what Accessibility and tiler list-windows read
        panel.appearance = Theme.appearance
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        // A window shows tooltips only while its app is active unless told otherwise, and Pilot sits in the background
        // (card agent-bo-95423028); the cost, work as the pointer crosses the bar, is a strip one item tall.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        return panel
    }
}

/// A bar's window. The right button and the wheel go straight to the item under the pointer (its ScreenAnchor; card
/// agent-bo-95423027): SwiftUI's hit test stops at the item's button, never the anchor behind it, and a plain button
/// takes a right-click as a click. Every other event, and these where no item takes them, go on to SwiftUI. (The bar's
/// on-bar edit mode, its Command-drag and shelf, is parked on branch parked/bar-edit-on-bar since Q185.)
final class TopBarPanel: NSPanel {
    /// Where Pilot put the bar: a move or resize by anyone else goes back here (card agent-bo-95423038; the tiler's unpark
    /// moved the bars mid-screen, and nothing put them back until Pilot restarted).
    private var pinned: NSRect?
    /// Whether Pilot wants it on screen, a fullscreen Space aside (TopBarWindows.place).
    var wanted = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(snapBack), name: name, object: self)
        }
    }

    func pin(_ frame: NSRect) {
        pinned = frame
        refused = nil
        pushedTo = nil
        pushes = 0
        put(frame)
    }

    /// Inside its own put-back: the resize that putting back makes comes here again and is left alone.
    private var snapping = false
    /// The pinned frame AppKit would not take (its constraints held the window to another size): kept as AppKit has it
    /// until the next pin, never put back again.
    private var refused: NSRect?
    /// Where something else last moved it since the last pin, and how many times in a row.
    private var pushedTo: NSRect?
    private var pushes = 0

    /// A move or resize by anyone else. Put back, unless it is AppKit holding the window to its own frame: a frame within
    /// a point of Pilot's (its Auto Layout rounding a hosting view's fractional subviews), or the same frame a third time
    /// in a row. Putting back against that from inside AppKit's constraint pass marks the window for another pass each
    /// time until AppKit throws (build 2480 at launch on Sven's Mac, 2026-11-14: the dock pinned 1739 wide, AppKit
    /// holding it at 1738, "put back at 1739" 106 times in 70 ms, then NSGenericException from
    /// _postWindowNeedsUpdateConstraints). Kept as AppKit has it until the next pin.
    @objc private func snapBack() {
        guard let pinned, frame != pinned, !snapping, refused != pinned else { return }
        if frame == pushedTo { pushes += 1 } else { (pushedTo, pushes) = (frame, 1) }
        let near = abs(frame.minX - pinned.minX) <= 1 && abs(frame.minY - pinned.minY) <= 1
            && abs(frame.width - pinned.width) <= 1 && abs(frame.height - pinned.height) <= 1
        if near || pushes > 2 {
            refused = pinned
            tblog.error("top bar kept at \(String(describing: self.frame), privacy: .public): AppKit holds it there, not at \(String(describing: pinned), privacy: .public)")
            return
        }
        put(pinned)
    }

    /// Puts it at `pinned`, once.
    private func put(_ pinned: NSRect) {
        guard frame != pinned, !snapping else { return }
        // Logged, so whatever moves a bar shows in the log rather than being quietly undone.
        tblog.notice("top bar moved to \(String(describing: self.frame), privacy: .public), put back at \(String(describing: pinned), privacy: .public)")
        snapping = true
        defer { snapping = false }
        setFrame(pinned, display: true)
        // A frame AppKit refuses (a Pills island 30 wide that its constraints held at 242, Sven on build 2433): putting it
        // back again from its own resize notification recursed inside layout until the stack ran out. Keep AppKit's.
        if frame != pinned {
            refused = pinned
            tblog.error("top bar kept at \(String(describing: self.frame), privacy: .public): AppKit refused \(String(describing: pinned), privacy: .public)")
        }
    }

    /// The bar sits in the menu bar's strip, where AppKit's constraint would push it below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override var level: NSWindow.Level {
        didSet { catchers.values.forEach { $0.level = level } }
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        catchers.values.forEach { $0.orderOut(nil) }
    }

    /// The screen sides its outermost item reaches to (Sven, 2026-11-15: a flick into the top-right corner hit the 12 pt
    /// margin past the bell and macOS showed the desktop). A press past that item, on its padding, a flare, or in the
    /// margin beyond the window (BarEdgeCatcher), goes to it, so the corner is the item's as on the macOS menu bar.
    enum Reach: CaseIterable { case left, right }
    var reaches: Set<Reach> = []
    private var catchers: [Reach: BarEdgeCatcher] = [:]
    /// The point the press now down goes to instead of where it is, for its drags and its release too; nil for none.
    private var redirected: CGPoint?

    /// A clear window over the room between this one and each side of its screen it reaches, from its foot to the
    /// screen's top; none where it touches that side, or while it is out of sight.
    func placeCatchers() {
        for reach in Reach.allCases {
            guard isVisible, reaches.contains(reach), let screen = screen?.frame, let room = Self.room(reach, of: frame, on: screen) else {
                catchers[reach]?.orderOut(nil)
                continue
            }
            let catcher = catchers[reach] ?? BarEdgeCatcher(bar: self)
            catchers[reach] = catcher
            if catcher.frame != room { catcher.setFrame(room, display: false) }
            if !catcher.isVisible { catcher.orderFrontRegardless() }
        }
    }

    /// The room between a bar window and its screen's `reach` side, from the window's foot to the screen's top edge.
    static func room(_ reach: Reach, of bar: CGRect, on screen: CGRect) -> CGRect? {
        let x = reach == .left ? screen.minX : bar.maxX
        let width = reach == .left ? bar.minX - screen.minX : screen.maxX - bar.maxX
        guard width >= 0.5, bar.minY < screen.maxY else { return nil }
        return CGRect(x: x, y: bar.minY, width: width, height: screen.maxY - bar.minY)
    }

    /// The window point a press at `point` goes to: the centre of the outermost item it lies past, toward a side this
    /// window reaches; nil on an item or between two.
    func reached(_ point: CGPoint) -> CGPoint? {
        guard !reaches.isEmpty else { return nil }
        let inside = CGRect(origin: .zero, size: frame.size)
        var items: [CGRect] = []
        func walk(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                if let anchor = sub as? ScreenAnchor.AnchorView, anchor.rightClick != nil {
                    // The island's clip holds the whole row: only the items inside this window count.
                    let rect = anchor.convert(anchor.bounds, to: nil)
                    if rect.width > 0, rect.intersects(inside) { items.append(rect) }
                }
                walk(sub)
            }
        }
        if let contentView { walk(contentView) }
        guard !items.contains(where: { $0.contains(point) }) else { return nil }
        if reaches.contains(.right), let last = items.max(by: { $0.maxX < $1.maxX }), point.x >= last.maxX {
            return CGPoint(x: last.midX, y: last.midY)
        }
        if reaches.contains(.left), let first = items.min(by: { $0.minX < $1.minX }), point.x <= first.minX {
            return CGPoint(x: first.midX, y: first.midY)
        }
        return nil
    }

    /// `event` as it lands: a press past the outermost item, and its drags and release, moved onto that item.
    private func redirect(_ event: NSEvent) -> NSEvent {
        guard NSEvent.buttons.contains(event.type) else { return event }
        if event.type == .leftMouseDown || event.type == .rightMouseDown { redirected = reached(event.locationInWindow) }
        guard let point = redirected else { return event }
        if event.type == .leftMouseUp || event.type == .rightMouseUp { redirected = nil }
        return event.moved(to: point, in: self) ?? event
    }

    override func sendEvent(_ event: NSEvent) {
        let event = redirect(event)
        if let anchor = ScreenAnchor.AnchorView.taking(event, in: contentView) { return anchor.take(event) }
        if let drag, dragged(event, drag) { return }
        super.sendEvent(event)
    }

    /// Drag to rearrange (spec drag-reorder): the dock's or the bar's pieces, read off the left button here rather than
    /// by a SwiftUI gesture, which would fight each item's button for the press. Nil takes no drag.
    var drag: (any PanelDrag)?
    /// The press while the left button is down over a piece: where it began, and whether it has become a drag.
    private var press: (start: CGPoint, dragging: Bool)?

    /// A press goes on to SwiftUI until it moves MouseDragTap.clickSlop, so a click stays a click. Past it the item's button
    /// is let go with a release far outside it (a button does nothing for a release off itself), and the drag owns the
    /// moves and the release. True when the event was the drag's.
    private func dragged(_ event: NSEvent, _ drag: any PanelDrag) -> Bool {
        guard [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type), let host = drag.host else { return false }
        let local = host.convert(event.locationInWindow, from: nil)
        let point = host.isFlipped ? local : CGPoint(x: local.x, y: host.bounds.height - local.y)
        switch event.type {
        case .leftMouseDown:
            press = drag.pressed(at: point) ? (point, false) : nil
            return false
        case .leftMouseDragged:
            guard let press else { return false }
            if !press.dragging {
                guard hypot(point.x - press.start.x, point.y - press.start.y) > MouseDragTap.clickSlop else { return false }
                self.press = (press.start, true)
                if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -100_000, y: -100_000), modifierFlags: [],
                                               timestamp: event.timestamp, windowNumber: windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 0) { super.sendEvent(up) }
            }
            drag.moved(to: point)
            return true
        case .leftMouseUp:
            defer { press = nil }
            guard press?.dragging == true else { return false }
            drag.released(at: point)
            return true
        default:
            return false
        }
    }
}

/// A clear window over the margin between a bar's outer window and its screen's side (TopBarPanel.placeCatchers): it draws
/// nothing, takes the mouse in all of it, and hands its button events on to the bar, which moves a press there onto its
/// outermost item (TopBarPanel.reached). Before, the margin was the wallpaper's, and a click there showed the desktop.
final class BarEdgeCatcher: NSPanel {
    private weak var bar: TopBarPanel?

    init(bar: TopBarPanel) {
        self.bar = bar
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Pilot top bar edge"
        level = bar.level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = bar.collectionBehavior
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        guard let bar, NSEvent.buttons.contains(event.type) else { return super.sendEvent(event) }
        if let moved = event.moved(to: bar.convertPoint(fromScreen: convertPoint(toScreen: event.locationInWindow)), in: bar) {
            bar.sendEvent(moved)
        }
    }
}

private extension NSEvent {
    /// The left and right buttons' presses, drags and releases: what the bar's edges hand on (TopBarPanel.redirect).
    static let buttons: Set<EventType> = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp]

    /// This button event at `point` in `window`, everything else kept.
    func moved(to point: CGPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifierFlags, timestamp: timestamp, windowNumber: window.windowNumber,
                           context: nil, eventNumber: eventNumber, clickCount: clickCount, pressure: pressure)
    }
}

/// What a bar or dock window's drag drives (spec drag-reorder): points in `host`'s own space, top left at its corner,
/// the space its SwiftUI view reports its pieces' frames in.
@MainActor
protocol PanelDrag: AnyObject {
    var host: NSView? { get }
    /// The left button went down here: whether a piece is under it, so a drag may start.
    func pressed(at point: CGPoint) -> Bool
    /// The pointer moved past the threshold, then each move after.
    func moved(to point: CGPoint)
    /// The drop.
    func released(at point: CGPoint)
}

/// Each island window holds the existing full row at its original coordinates, cropped to that final group.
/// Keeping the row's coordinate space intact also keeps overflow indices and every item's existing anchor intact.
final class TopBarIslandClip: NSView {
    let content: NSView
    var canvas = CGRect.zero { didSet { place() } }
    var crop = CGRect.zero { didSet { place() } }
    /// The island's row as last reported, before its flares: placed again whenever the canvas moves.
    var reported = CGRect.zero
    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }
    private func place() {
        content.frame = CGRect(x: -crop.minX, y: crop.maxY - canvas.height, width: canvas.width, height: canvas.height)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard BarPresetGeometry.hit(local, in: bounds),
              BarPresetGeometry.hit(CGPoint(x: local.x + crop.minX, y: local.y + crop.minY), in: crop) else { return nil }
        return super.hitTest(point)
    }
}
