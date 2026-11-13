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
            if settings.size != oldValue.size { follow() }
        }
    }
    private(set) var pins: [DockPin] = []
    private(set) var running: [DockRunning] = []
    private(set) var busy = false
    /// The last refusal, shown on the Menu bar page; nil after a clean switch.
    private(set) var problem: String?
    @ObservationIgnored private var written: [PilotBlock.BarInset]?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .pilot(), autohide: any DockAutohide = SystemEventsAutohide.dock, readPins: @escaping @MainActor () -> [DockPin] = DockPins.readLive,
         writeRoom: @escaping DockSwitch.WriteRoom, panels: any DockPanels) {
        self.defaults = defaults
        self.autohide = autohide
        self.readPins = readPins
        self.writeRoom = writeRoom
        self.panels = panels
        state = defaults.data(forKey: Self.switchKey).flatMap { try? JSONDecoder().decode(DockSwitch.self, from: $0) } ?? .off
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(DockSettings.self, from: $0) } ?? DockSettings()
    }

    var isOn: Bool { state.isOn }

    /// The room the tiler keeps at the foot of the dock's screen.
    var room: [PilotBlock.BarInset] { screen().map { [PilotBlock.BarInset(monitor: $0, height: settings.size.room)] } ?? [] }

    /// At launch with the switch left on: the Dock hides again and the pill shows. Off, the dock reads nothing.
    func start() {
        guard state.isOn else { return }
        busy = true
        Task {
            defer { busy = false }
            do { state = try await state.resumed(autohide: autohide) } catch {
                problem = String(describing: error)
                docklog.error("dock resume: \(String(describing: error), privacy: .public)")
            }
            shown()
            follow()
        }
    }

    /// On screen: the pins read, the running apps followed as apps launch and quit, the pill shown.
    private func shown() {
        pins = readPins()
        running = Self.runningApps()
        let centre = NSWorkspace.shared.notificationCenter
        tokens = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.running = Self.runningApps() } }
        }
        panels.show()
    }

    private func hidden() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens = []
        panels.hide()
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
                state = on ? try await state.switchedOn(room, autohide: autohide, writeRoom: writeRoom)
                    : try await state.switchedOff(room: room, autohide: autohide, writeRoom: writeRoom)
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
        do { try await state.restoredForQuit(autohide: autohide) } catch {
            docklog.error("dock quit: \(String(describing: error), privacy: .public)")
        }
    }

    /// The icons: pins, then the other running apps, each with its windows from Pilot's tiler (`byApp`, by bundle id).
    static func apps(pins: [DockPin], running: [DockRunning], byApp: [String: [AeroWindow]], front: String?) -> [DockApp] {
        DockApps.list(pins: pins, running: running, windows: byApp.mapValues(\.count), front: front)
    }

    /// The observers dump's line.
    var line: String {
        "dock: \(state.isOn ? "on" : "off"), saved autohide \(state.savedAutohide.map(String.init) ?? "none"), size \(settings.size.rawValue), room "
            + room.map { "\($0.monitor) \($0.height)" }.joined(separator: ", ") + ", widgets " + settings.widgets.joined(separator: " ")
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

    /// One above the Dock's own level, so its auto-hidden slide-up shows under the pill, not over it.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    func show() {
        let panel = self.panel ?? TopBarWindows.panel(MaterialBackdrop(content: make()), level: Self.level)
        if self.panel == nil {
            panel.title = "Pilot dock"
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = DockPill.radius
            panel.contentView?.layer?.masksToBounds = true
        }
        self.panel = panel
        panel.appearance = Look.shared.appearance(for: .topBar)
        (panel.contentView as? MaterialBackdrop)?.show(.glass, tint: TopBarColour.tint(.theme, style: TopBarWindows.tokens(.shared), look: .shared),
                                                         blur: Look.shared.glassBlur)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        fitted = nil
    }

    private var fitted: NSRect?

    /// The pill reports its size as its icons and widgets change; the window follows, centred at the foot of the screen.
    func fit(_ size: CGSize) {
        guard let panel, let screen = NSScreen.screens.first, size.width > 0 else { return }
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.minY + DockSize.margin,
                           width: size.width.rounded(.up), height: size.height.rounded(.up))
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
