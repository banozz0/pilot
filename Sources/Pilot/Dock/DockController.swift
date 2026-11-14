import AppKit
import Observation
import OSLog
import PilotCore

let docklog = Logger(subsystem: "dev.banozz.pilot", category: "dock")

/// The dock's window on screen, behind a protocol so tests and the sandbox never draw on the screen.
@MainActor
protocol DockPanels: AnyObject {
    func show()
    func hide()
}

/// Pilot's dock (spec Projects/Pilot/specs/pilot-dock.html; look A, Sven 2026-11-13, Q199, Q200): off by default. On saves
/// the macOS Dock's auto-hide, makes the tiler keep the dock's room at the foot of the main screen, turns the Dock's
/// auto-hide on and shows the pill; off undoes each. Quitting puts Sven's auto-hide back (PilotApp); the next launch hides
/// the Dock again while the switch is on.
@Observable @MainActor
final class DockController {
    static let switchKey = "dock.switch", settingsKey = "dock.settings"

    @ObservationIgnored private let defaults: UserDefaults
    /// The Dock's auto-hide; the sandbox puts a file in its place (DockFixture).
    @ObservationIgnored var autohide: any DockAutohide
    /// The Dock's reveal delay, so it never rises at the screen's foot under the pill; the sandbox puts a file in its place.
    @ObservationIgnored var delay: any DockRevealDelay = DefaultsDockDelay()
    /// The Dock's pins; the sandbox reads a copy of its preferences.
    @ObservationIgnored var readPins: @MainActor () -> [DockPin]
    @ObservationIgnored var writeRoom: DockSwitch.WriteRoom
    @ObservationIgnored var panels: any DockPanels
    /// The tiler's name for the dock's screen, the main one (spec: main screen only in v1).
    @ObservationIgnored var screen: @MainActor () -> String? = { NSScreen.screens.first?.localizedName }

    /// Saved after each switch, so a relaunch shows the dock and off still puts back the auto-hide it found.
    private(set) var state: DockSwitch {
        didSet { defaults.set(try? JSONEncoder().encode(state), forKey: Self.switchKey) }
    }
    var settings: DockSettings {
        didSet {
            guard settings != oldValue else { return }
            defaults.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if settings.size != oldValue.size || settings.placement != oldValue.placement { follow() }
            if settings.size != oldValue.size || settings.visualizer != oldValue.visualizer { listen() }
        }
    }
    /// The visualizer (rice round): on while the dock shows and its switch is on.
    let visualizer: DockVisualizer
    /// The macOS Dock's own pins, as last read.
    private(set) var dockPins: [DockPin] = []
    /// The dock's pins: the Dock's, less the ones taken out, then the ones kept (DockSettings.pinned).
    var pins: [DockPin] { settings.pinned(dockPins) }
    private(set) var running: [DockRunning] = []
    private(set) var busy = false
    /// The last refusal, shown on the Menu bar page; nil after a clean switch.
    private(set) var problem: String?
    @ObservationIgnored private var written: [PilotBlock.BarInset]?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    /// NSWorkspace's own list of running apps, followed while the dock shows.
    @ObservationIgnored private var runningWatch: NSKeyValueObservation?
    /// The running apps as the dock reads them; the sandbox's stays the real Mac's.
    @ObservationIgnored var readRunning: @MainActor () -> [DockRunning] = { DockController.runningApps() }

    init(defaults: UserDefaults = .pilot(), autohide: any DockAutohide = SystemEventsAutohide.dock, readPins: @escaping @MainActor () -> [DockPin] = DockPins.readLive,
         writeRoom: @escaping DockSwitch.WriteRoom, panels: any DockPanels, visualizer: DockVisualizer = DockVisualizer()) {
        self.defaults = defaults
        self.visualizer = visualizer
        self.autohide = autohide
        self.readPins = readPins
        self.writeRoom = writeRoom
        self.panels = panels
        state = defaults.data(forKey: Self.switchKey).flatMap { try? JSONDecoder().decode(DockSwitch.self, from: $0) } ?? .off
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(DockSettings.self, from: $0) } ?? DockSettings()
    }

    var isOn: Bool { state.isOn }

    /// The room the tiler keeps at the foot of the dock's screen.
    var room: [PilotBlock.BarInset] { screen().map { [PilotBlock.BarInset(monitor: $0, height: settings.room)] } ?? [] }

    /// At launch with the switch left on: the Dock hides again and the pill shows. Off, the dock reads nothing.
    func start() {
        guard state.isOn else { return }
        busy = true
        Task {
            defer { busy = false }
            do { state = try await state.resumed(autohide: autohide, delay: delay) } catch {
                problem = String(describing: error)
                docklog.error("dock resume: \(String(describing: error), privacy: .public)")
            }
            shown()
            follow()
        }
    }

    /// On screen: the pins read, the running apps followed as apps launch and quit, the pill shown.
    private func shown() {
        dockPins = readPins()
        followRunning()
        panels.show()
        listen()
    }

    /// The visualizer on while the dock shows and its switch is on, its bars as tall as the size makes them.
    private func listen() {
        let tallest = CGFloat(settings.size.tallestBar)
        if tallest != visualizer.tallest {
            visualizer.set(false)
            visualizer.tallest = tallest
        }
        visualizer.set(state.isOn && settings.visualizer)
    }

    /// The visualizer's switch: on asks macOS for System Audio Recording Only now, on this press, by starting a tap for
    /// a moment (the first start asks); never at launch.
    func setVisualizer(_ on: Bool) async {
        settings.visualizer = on
        if on { await visualizer.ask() }
    }

    /// The running apps, followed through NSWorkspace's own list (KVO, as Apple documents it), not read inside the launch
    /// and quit notifications: those can come before the list has the new app, so an app opened that is not kept never
    /// showed until the next launch or quit (Sven on build 2459). An app coming forward reads it again too, for an app
    /// that turns into a regular one after it launched.
    private func followRunning() {
        refreshRunning()
        runningWatch = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshRunning() } }
        }
        let centre = NSWorkspace.shared.notificationCenter
        tokens = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification].map { name in
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refreshRunning() } }
        }
    }

    /// The running apps read again; set only when they changed, so a steady list redraws nothing.
    func refreshRunning() {
        let now = readRunning()
        if now != running { running = now }
    }

    private func hidden() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens = []
        runningWatch?.invalidate()
        runningWatch = nil
        panels.hide()
        visualizer.set(false)
    }

    static func runningApps() -> [DockRunning] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }.map {
            DockRunning(bundleID: $0.bundleIdentifier, url: $0.bundleURL, name: $0.localizedName ?? $0.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                        pid: $0.processIdentifier)
        }
    }

    func set(_ on: Bool) {
        guard on != state.isOn, !busy else { return }
        busy = true
        problem = nil
        let room = room
        Task {
            defer { busy = false }
            do {
                state = on ? try await state.switchedOn(room, autohide: autohide, delay: delay, writeRoom: writeRoom)
                    : try await state.switchedOff(room: room, autohide: autohide, delay: delay, writeRoom: writeRoom)
            } catch {
                problem = String(describing: error)
                docklog.error("dock \(on ? "on" : "off", privacy: .public): \(String(describing: error), privacy: .public)")
                return
            }
            written = on ? room : nil
            if on { shown() } else { hidden() }
            docklog.notice("dock \(on ? "on" : "off", privacy: .public), room \(room.map { "\($0.monitor) \($0.height)" }.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Quitting: Sven's auto-hide goes back, the switch stays on for the next launch. Never throws: quit goes on.
    func restoreForQuit() async {
        do { try await state.restoredForQuit(autohide: autohide, delay: delay) } catch {
            docklog.error("dock quit: \(String(describing: error), privacy: .public)")
        }
    }

    /// Keep in Dock: the app joins Pilot's own pins (never the macOS Dock's list).
    func keep(_ app: DockApp, dock: [DockPin]? = nil) {
        guard let url = app.url else { return }
        settings.keep(DockPin(bundleID: app.bundleID, url: url, name: app.name), dock: dock ?? current)
    }

    /// Remove from Dock: out of Pilot's dock alone; the macOS Dock's list is never written.
    func unpin(_ app: DockApp, dock: [DockPin]? = nil) {
        settings.unpin(app.key, dock: dock ?? current)
    }

    /// The Dock's pins as last read, or read now while the dock is off.
    private var current: [DockPin] { dockPins.isEmpty ? readPins() : dockPins }

    /// The icons: pins, then the other running apps, each with its windows from Pilot's tiler (`byApp`, by bundle id).
    static func apps(pins: [DockPin], running: [DockRunning], byApp: [String: [AeroWindow]], front: String?) -> [DockApp] {
        DockApps.list(pins: pins, running: running, windows: byApp.mapValues(\.count), front: front)
    }

    /// The observers dump's line.
    var line: String {
        "dock: \(state.isOn ? "on" : "off"), saved autohide \(state.savedAutohide.map(String.init) ?? "none"), saved delay "
            + (state.delaySaved == true ? state.savedDelay.map { String($0) } ?? "absent" : "none") + ", size \(settings.size.rawValue), room "
            + room.map { "\($0.monitor) \($0.height)" }.joined(separator: ", ") + ", widgets " + settings.widgets.map(\.name).joined(separator: " ")
            + ", \(settings.placement.rawValue), tint \(settings.tint.rawValue), visualizer \(settings.visualizer ? "on" : "off")"
    }

    /// While on, the room follows the size; the block is written only when it changed.
    private func follow() {
        guard state.isOn else { return }
        let room = room
        guard room != written else { return }
        written = room
        Task {
            do { try await writeRoom(room) } catch {
                written = nil
                problem = DockError.room(error).description
                docklog.error("dock room: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// The dock's one window: a borderless, non-activating panel at the foot of the main screen, centred, as wide as the pill.
@MainActor
final class DockWindow: DockPanels {
    private var panel: TopBarPanel?
    /// The pill's view; set once the controller it draws exists (Engine).
    var make: () -> NSView = { NSView() }
    /// Where the pill stands: on the screen's bottom edge, or over it (rice round).
    var placement: () -> DockPlacement = { .attached }

    /// One above the Dock's own level, so its auto-hidden slide-up shows under the pill, not over it.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    func show() {
        if panel == nil {
            // Its first frame from the box's own size, as BarPanel.keyPanel's: a host left at zero would wait on a
            // geometry report from inside a zero-size window. The window is clear: the pill draws its own glass or solid
            // ground (DockBacking), so the box can grow above it for magnified icons.
            let host = make()
            host.frame.size = host.fittingSize
            let panel = TopBarWindows.panel(host, level: Self.level)
            panel.title = "Pilot dock"
            self.panel = panel
            fit(host.frame.size)
        }
        guard let panel else { return }
        panel.appearance = Look.shared.appearance(for: .topBar)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The widest the pill may be: the dock's screen less DockPill.sideMargin each side.
    static func widest() -> CGFloat { (NSScreen.screens.first?.frame.width ?? 1440) - 2 * DockPill.sideMargin }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        fitted = nil
    }

    private var fitted: NSRect?

    /// The box reports its size as its icons and widgets change and as a hover grows it; the window follows, centred at
    /// the foot of the screen, its bottom edge where the pill's is, so a taller box grows upward only.
    func fit(_ size: CGSize) {
        guard let panel, let screen = NSScreen.screens.first, size.width > 0 else { return }
        // The pill is held to DockWindow.widest(); only a hover's box at the widest can reach past the screen: held to it.
        let width = min(size.width.rounded(.up), screen.frame.width)
        let frame = NSRect(x: (screen.frame.midX - width / 2).rounded(), y: screen.frame.minY + DockSize.margin(placement()),
                           width: width, height: size.height.rounded(.up))
        guard frame != fitted else { return }
        fitted = frame
        panel.pin(frame)
    }
}

/// The sandbox's window: nothing on screen.
@MainActor
final class DockNoWindow: DockPanels {
    func show() {}
    func hide() {}
}
