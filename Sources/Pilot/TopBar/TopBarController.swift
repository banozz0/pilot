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
    /// Every bar's window level, the ones shown later too.
    var level: NSWindow.Level { get set }
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

    /// At launch: the bars come back if the switch was left on, and follow the screens from then on.
    func start() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        if state.isOn { panels.show(on: picked) }
    }

    func set(_ on: Bool) {
        guard on != state.isOn, !busy else { return }
        busy = true
        problem = nil
        connected = screens()
        let bars = TopBarGeometry.bars(picked)
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
            if on { follow() } else { panels.hideAll() }
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
        let bars = TopBarGeometry.bars(picked)
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
/// remembered for when autohide leaves it 0.
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
            return TopBarGeometry.Screen(name: name, strip: strip, displayUUID: WallpaperScreen.number(screen).flatMap(DisplayIdentity.uuid(for:)))
        }
        if remembered != defaults.dictionary(forKey: key) as? [String: Double] { defaults.set(remembered, forKey: key) }
        return screens
    }
}

/// One borderless, non-activating panel per screen at the status bar's level (25): over the menu bar (24), so an
/// autohidden menu bar revealing on hover slides out under the bar, never over it (card agent-bo-95423007; SketchyBar's
/// topmost=on), and over the Dock (20). On every Space, never key, never in Cmd+Tab. Each panel tracks edit mode's drags
/// and hands right-clicks and the wheel to the item under the pointer (TopBarPanel).
@MainActor
final class TopBarWindows: TopBarPanels {
    private var panels: [String: TopBarPanel] = [:]
    private let sources: BarSources
    private let store: BarItemsStore

    init(sources: BarSources, store: BarItemsStore) {
        self.sources = sources
        self.store = store
        followLook()
    }

    /// Every bar follows its Background and Colour and Look's theme and style as they change: what applyLook reads,
    /// watched even with no bar shown yet.
    private func followLook() {
        let look = Look.shared, wallpapers = BarWallpapers.shared
        panels.forEach { Self.applyLook(look, store: store, wallpaper: wallpapers.strips[$0.key], to: $0.value) }
        withObservationTracking {
            _ = (look.appearance(for: .topBar), look.style, look.theme, look.transparency, look.glassBlur, store.background, store.colour,
                 wallpapers.strips)
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
        (panel.contentView as? MaterialBackdrop)?.show(background == .glass ? .glass : .solid,
                                                         tint: TopBarColour.tint(store.colour, style: tokens, look: look), blur: look.glassBlur)
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

    func show(on screens: [TopBarGeometry.Screen]) {
        // The bars are a hard edge for the windows Pilot places.
        Screens.bars = Dictionary(screens.map { ($0.name, $0.strip) }, uniquingKeysWith: { first, _ in first })
        BarWallpapers.shared.follow(screens)
        for name in panels.keys where !screens.contains(where: { $0.name == name }) { panels.removeValue(forKey: name)?.orderOut(nil) }
        for screen in screens {
            guard let ns = NSScreen.screens.first(where: { $0.localizedName == screen.name }) else { continue }
            let panel = panels[screen.name] ?? make(screen.name)
            panels[screen.name] = panel
            panel.pin(TopBarGeometry.frame(screen: ns.frame, strip: screen.strip))
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    func hideAll() {
        Screens.bars = [:]
        BarWallpapers.shared.follow([])   // no bar, no strips read
        panels.values.forEach { $0.orderOut(nil) }
        panels = [:]
    }

    private func make(_ name: String) -> TopBarPanel {
        let content = NSHostingView(rootView: TopBarView(screen: name, sources: sources, store: store))
        content.sizingOptions = []   // the bar's frame is Pilot's alone (pin), never its content's size
        let panel = Self.panel(MaterialBackdrop(content: content), level: level)
        Self.applyLook(.shared, store: store, wallpaper: BarWallpapers.shared.strips[name], to: panel)
        return panel
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

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(snapBack), name: name, object: self)
        }
    }

    func pin(_ frame: NSRect) {
        pinned = frame
        snapBack()
    }

    @objc private func snapBack() {
        guard let pinned, frame != pinned else { return }
        // Logged, so whatever moves a bar shows in the log rather than being quietly undone.
        tblog.notice("top bar moved to \(String(describing: self.frame), privacy: .public), put back at \(String(describing: pinned), privacy: .public)")
        setFrame(pinned, display: true)
    }

    /// The bar sits in the menu bar's strip, where AppKit's constraint would push it below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if let anchor = ScreenAnchor.AnchorView.taking(event, in: contentView) { return anchor.take(event) }
        super.sendEvent(event)
    }
}
