import AppKit
import CoreAudio
import OSLog
import PilotCore

let slog = Logger(subsystem: "dev.banozz.pilot", category: "system")

/// The System branch's actions, dark mode, volume, media and the settings panes (stories 22 to 24, 80).
@MainActor
enum SystemModule {
    static func register(into registry: inout ActionRegistry) {
        // The menu's System branch (story 80; MenuLayout lists its rows).
        add(&registry, "menu", "System menu", Key("space", .shift), .system) { PilotMenu.shared.toggle(branch: .system) }
        // Activity's and Stats' screens in the menu (Q399, Q400), bindable with no default key; the Ring's Pilot ring runs
        // them for their extra rows (RingMenuSource).
        add(&registry, "activityMenu", "Activity menu", nil, .system) { PilotMenu.shared.toggle(branch: .activity) }
        add(&registry, "statsMenu", "Stats menu", nil, .system) { PilotMenu.shared.toggle(branch: .stats) }
        add(&registry, "lock", "Lock screen", Key("escape"), .system) { lock() }
        add(&registry, "sleep", "Sleep", nil, .system) { systemEvents("sleep") }
        add(&registry, "restart", "Restart", nil, .system) { systemEvents("restart") }
        add(&registry, "shutDown", "Shut down", nil, .system) { systemEvents("shut down") }
        add(&registry, "logOut", "Log out", nil, .system) { systemEvents("log out") }
        // Toolbox for Mac's Eject all (Q386): every external drive, SD card and disk image, in Power beside shut down.
        add(&registry, "ejectAll", "Eject all disks", nil, .system) { EjectDisks.run() }
        add(&registry, "darkMode", "Dark mode on or off", Key("d", shift: true), .system) {
            appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode", what: "dark mode")
        }
        // Finder's own desktop icons off and on (Sven, Q745), Finder started again so it applies; no key in either preset.
        add(&registry, "desktopIcons", "Desktop icons on or off", nil, .system, keywords: "finder hide desktop icons clean desktop") {
            FinderDesktopIcons.toggle()
        }
        // Omarchy's control panels open Pilot's own Setup page (card agent-bo-95422805, Sven's yes 2026-10-05); the ids stay,
        // so the binds and the Omarchy preset's Hyper+Ctrl+A, B and W keep working.
        add(&registry, "soundSettings", "Sound in Pilot", nil, .system) { AppWindowController.shared.open(.system, setup: .sound) }
        add(&registry, "bluetoothSettings", "Bluetooth in Pilot", nil, .system) { AppWindowController.shared.open(.system, setup: .bluetooth) }
        add(&registry, "wifiSettings", "Wi-Fi in Pilot", nil, .system) { AppWindowController.shared.open(.system, setup: .wifi) }
        // Hammerspoon's system chooser rows (card agent-bo-95422700). Wi-Fi and the sound output are real switches;
        // displays open Setup (card agent-bo-95422804); Focus has no public switch, so it opens its pane.
        add(&registry, "wifi", "Wi-Fi on or off", nil, .system) { toggleWiFi() }
        // Bluetooth's radio through a private call (T47, Sven Q833): it says why when Pilot cannot switch it.
        add(&registry, "bluetooth", "Bluetooth on or off", nil, .system) { toggleBluetooth() }
        add(&registry, "displaySettings", "Displays in Pilot", nil, .system) { AppWindowController.shared.open(.system, setup: .displays) }
        // Rotate a screen (Sven 2026-10-22): a picker of each screen's rotations, never a blind turn on a key; the pick
        // asks Keep and goes back by itself after 15 s.
        add(&registry, "rotateDisplay", "Rotate display", nil, .system) { pickRotation() }
        add(&registry, "focusSettings", "Focus settings", nil, .system) { pane("com.apple.Focus-Settings.extension") }
        // Setup's keep-awake (card agent-bo-95422801), bindable with no default key.
        add(&registry, "keepAwake", "Keep awake on or off", nil, .system) {
            KeepAwake.shared.toggle()
            HUD.tip(KeepAwake.shared.isOn ? "Keep awake on \(KeepAwake.shared.length.phrase)" : "Keep awake off", seconds: 2)
        }
        // Omarchy's nightlight and idle-lock switches (card agent-bo-95422972): Hyper+Ctrl+N and I in the Omarchy preset.
        add(&registry, "nightShift", "Night Shift on or off", nil, .system) {
            let tip = NightShift.toggle(nightShift)
            slog.notice("night shift: \(tip, privacy: .public)")
            HUD.tip(tip, seconds: 2)
        }
        add(&registry, "idleLock", "Lock when idle on or off", nil, .system) { HUD.tip(KeepAwake.shared.toggleIdleLock(), seconds: 3) }
        // Vicinae's Kill process, rebuilt (card agent-bo-95422771).
        add(&registry, "killProcess", "Kill a process", nil, .system) { pickProcess() }
        // Vicinae's Speedtest, rebuilt on macOS's own networkQuality (card agent-bo-95422772).
        add(&registry, "speedTest", "Test internet speed", nil, .system) { speedTest.start() }
        // Where macOS downloads translation languages (Translate, card agent-bo-95422773).
        add(&registry, "translationLanguages", "Translation languages", nil, .system) { pane("com.apple.Localization-Settings.extension") }
        // Omarchy's notification keys (card agent-bo-95422949): unbound here, since Hyper+comma is focus display left; the
        // Omarchy preset puts them on Hyper+comma, Shift and Alt.
        add(&registry, "clearNotification", "Clear latest notification", nil, .system) { NotificationKeys.clearLatest() }
        add(&registry, "clearAllNotifications", "Clear all notifications", nil, .system) { NotificationKeys.clearAll() }
        add(&registry, "openNotification", "Open latest notification", nil, .system) { NotificationKeys.openLatest() }
        // The drawer of Pilot's own notifications (spec notifications.html), bindable with no default key; the bell opens it too.
        add(&registry, "notificationDrawer", "Notification drawer", nil, .system, keywords: "bell notifications list") { PilotNotifications.shared.toggleDrawer() }
        // Omarchy's Exposé key, a default plain combo (story 106); Shortcut conflicts turns macOS's own Ctrl+Up off.
        add(&registry, "missionControl", "Mission Control", Key(keyCode: Key("up").keyCode, modifiers: .ctrl, hyper: false), .system) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"), configuration: .init())
        }
        // macOS's screen zoom (Sven, Q435) through its own Zoom shortcuts; a held key steps it.
        let zoomWords = DriveModule.AppZoom.keywords + " screen accessibility"
        add(&registry, "screenZoom", "Screen zoom on or off", nil, .system, keywords: zoomWords) { ScreenZoom.press(.toggle) }
        add(&registry, "screenZoomIn", "Screen zoom in", nil, .system, repeats: true, keywords: zoomWords) { ScreenZoom.press(.zoomIn) }
        add(&registry, "screenZoomOut", "Screen zoom out", nil, .system, repeats: true, keywords: zoomWords) { ScreenZoom.press(.zoomOut) }
        // Pointer speed (Sven, Q440): System › Mouse's three saved speeds, each with a tip; no default key.
        let pointerWords = "mouse tracking speed cursor"
        add(&registry, "pointerSpeedCycle", "Cycle pointer speeds", nil, .system, keywords: pointerWords) {
            PointerSpeed.shared.cycle()
            HUD.tip(PointerSpeed.shared.tip, seconds: 1.5)
        }
        for (index, name) in PointerSpeed.names.enumerated() {
            add(&registry, "pointerSpeed\(name)", "Pointer speed: \(name)", nil, .system, keywords: pointerWords) {
                PointerSpeed.shared.pick(index)
                HUD.tip(PointerSpeed.shared.tip, seconds: 1.5)
            }
        }

        // Brightness (story 144, card agent-bo-95423313): F1 and F2 as Apple's legends, on the focused window's screen,
        // Shift on every screen; held keys repeat.
        add(&registry, "brightnessDown", "Brightness down", Key("F1"), .system, tier: .v1_1, repeats: true) { ScreenBrightness.step(up: false, everyScreen: false) }
        add(&registry, "brightnessUp", "Brightness up", Key("F2"), .system, tier: .v1_1, repeats: true) { ScreenBrightness.step(up: true, everyScreen: false) }
        add(&registry, "brightnessDownAll", "Brightness down on every screen", Key("F1", shift: true), .system, tier: .v1_1, repeats: true) {
            ScreenBrightness.step(up: false, everyScreen: true)
        }
        add(&registry, "brightnessUpAll", "Brightness up on every screen", Key("F2", shift: true), .system, tier: .v1_1, repeats: true) {
            ScreenBrightness.step(up: true, everyScreen: true)
        }

        // Omarchy's background key (story 146, card agent-bo-95423316).
        add(&registry, "nextWallpaper", "Next wallpaper", Key("space", .ctrl), .system, tier: .v1_1) { WallpaperSwitch.step(forward: true) }
        add(&registry, "previousWallpaper", "Previous wallpaper", Key("space", [.shift, .ctrl]), .system, tier: .v1_1) {
            WallpaperSwitch.step(forward: false)
        }
        // Every screen at once, whatever Look › Wallpaper's Screens says (Sven 2026-10-17); no key until he binds one.
        add(&registry, "nextWallpaperAll", "Next wallpaper on every screen", nil, .system, tier: .v1_1) {
            WallpaperSwitch.step(forward: true, everyScreen: true)
        }
        add(&registry, "previousWallpaperAll", "Previous wallpaper on every screen", nil, .system, tier: .v1_1) {
            WallpaperSwitch.step(forward: false, everyScreen: true)
        }

        // The Carousel's Wallpapers mode (spec desktop-controls T8): the current theme's wallpapers, or the cycling folders,
        // browsed by key on the focused screen; no key until Sven binds one.
        add(&registry, "wallpaperCarousel", "Browse wallpapers", nil, .system, keywords: "carousel wallpaper picker favourites") {
            WallpaperCarouselPanel.shared.toggle(.wallpapers, on: Screens.focusedScreen)
        }
        // Its Themes mode (T9): every theme pack the style takes, drawn as a desktop; Return applies one after its Allow.
        // Either bind switches the open Carousel to its mode.
        add(&registry, "themeCarousel", "Browse themes", nil, .system, keywords: "carousel theme picker look colours") {
            WallpaperCarouselPanel.shared.toggle(.themes, on: Screens.focusedScreen)
        }

        // The pill's drop (spec desktop-controls T5) on the focused display, by key; works with the top bar off too. Opened
        // by key it lights its first row, and the arrows, Tab and Return work it (the pill from the keyboard, 2026-11-12).
        // Both only once the pill ships (PillFeature): no bind or search entry for it before.
        if PillFeature.released {
            add(&registry, "pill", "Open the pill", nil, .system, keywords: "pill music now playing top bar drop") { PillDrop.shared.toggle(byKey: true) }
            // The compact pill's next view, without opening it; no key until Sven binds one.
            add(&registry, "nextPillView", "Next pill view", nil, .system, keywords: "pill view music extensions activity controls cycle") {
                PillDrop.shared.layout.next()
            }
        }

        // Omarchy's Super+Ctrl+Alt+T, which flashes the time (story 188): the time, date, battery and weather, read on the press.
        add(&registry, "infoHUD", "Show time, battery and weather", Key("t", [.ctrl, .alt]), .system, tier: .v1_1) { InfoHUD.show() }
        // Sven, 2026-10-23 (Q420): the menu with `event ` typed, whose answer adds the event without opening Calendar.
        add(&registry, "newEvent", "New calendar event", nil, .system) { PilotMenu.shared.open(typing: "event ") }

        // Media: the F key with that legend on a Mac keyboard. Held volume keys repeat.
        add(&registry, "volumeUp", "Volume up", Key("F12"), .media, repeats: true) { Post.media(.volumeUp) }
        add(&registry, "volumeDown", "Volume down", Key("F11"), .media, repeats: true) { Post.media(.volumeDown) }
        add(&registry, "mute", "Mute", Key("F10"), .media) { Post.media(.mute) }
        add(&registry, "playPause", "Play or pause", Key("F8"), .media) { Post.media(.playPause) }
        add(&registry, "next", "Next track", Key("F9"), .media) { Post.media(.next) }
        add(&registry, "previous", "Previous track", Key("F7"), .media) { Post.media(.previous) }
    }

    /// One "Play through …" row per other sound output, read as the menu opens; `dynamic` builds the action. Keyed on
    /// the device's UID, which a bind keeps across reconnects; CoreAudio's numeric id changes when the device comes back.
    /// `excluding` holds the UIDs of outputs to leave out: the menu's, those hidden in Sound (spec hide-rows).
    static func outputRows(excluding: Set<String> = []) -> [BindsPage.ActionInfo] {
        let current = audio.defaultDevice(.output)
        return audio.devices(.output).filter { $0.id != current && !excluding.contains($0.uid ?? "") }.map {
            .init(id: outputPrefix + $0.key, label: playThrough($0.name), module: Module.system.rawValue)
        }
    }

    /// System's switches as the menu opens, by action id (card agent-bo-95422981): each read is quick and asks for no
    /// permission; Night Shift, Wi-Fi and Bluetooth are left out when this Mac cannot say, Bluetooth also until it is
    /// allowed or when Pilot cannot switch it.
    static func switchStates() -> [String: Bool] {
        var on = ["system.darkMode": MacAppearance.isDark(),
                  "system.keepAwake": KeepAwake.shared.isOn, "system.idleLock": !KeepAwake.shared.isOn]
        on["system.nightShift"] = nightShift.isOn()
        on["system.wifi"] = wifi.isOn()
        on["system.bluetooth"] = BluetoothPower.state(bluetooth)
        return on
    }

    private static let outputPrefix = "system.output:"
    private static let audio = CoreAudioSystem()
    private static let nightShift = CoreBrightnessNightShift()
    private static let wifi = CoreWLANSystem()
    static let bluetooth = IOBluetoothSystem()
    private static func playThrough(_ name: String) -> String { "Play through \(name)" }

    /// `system.output:<device UID>`, or an older bind's `<CoreAudio device id>`: switches the sound output to the device
    /// holding it when the key is pressed, as the System branch's rows do.
    static func dynamic(_ id: String) -> Action? {
        guard id.hasPrefix(outputPrefix) else { return nil }
        let key = String(id.dropFirst(outputPrefix.count))
        guard !key.isEmpty else { return nil }
        let name = output(key)?.name ?? key
        return Action(id: id, label: playThrough(name), module: .system) {
            guard let device = output(key) else { return slog.notice("sound output \(name, privacy: .public) is not connected") }
            slog.notice("sound output \(name, privacy: .public) \(audio.setDefault(device.id, .output) ? "set" : "refused", privacy: .public)")
        }
    }

    /// The output an action's key names: by UID, else by the numeric id an older bind holds.
    private static func output(_ key: String) -> AudioDevice? {
        let devices = audio.devices(.output)
        return devices.first { $0.uid == key } ?? AudioDeviceID(key).flatMap { id in devices.first { $0.id == id } }
    }

    private static func add(_ registry: inout ActionRegistry, _ id: String, _ label: String, _ key: Key?, _ module: Module,
                            tier: Tier = .v1, repeats: Bool = false, keywords: String? = nil, run: @escaping @Sendable @MainActor () -> Void) {
        do {
            try registry.register(Action(id: "\(module.rawValue).\(id)", label: label, module: module, defaultKey: key, tier: tier, repeats: repeats,
                                         keywords: keywords, run: run))
        }
        catch { slog.error("\(module.rawValue, privacy: .public).\(id, privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    /// One networkQuality run at a time, the last 30 results kept; the result stays up long enough to read. The menu's
    /// Speed test view (P41) shows this one's run.
    static let speedTest = SpeedTest(history: DayFile("speedtest-runs")) { line in
        slog.notice("speed test: \(line, privacy: .public)")
        HUD.tip(line, seconds: 8)
    }

    /// The second pick of one pid within 30 s forces it (KillProcess.Kills).
    private static var kills = KillProcess.Kills()

    /// Activity's list (task N3): the apps with their helpers and your background processes Pilot may quit, busiest CPU
    /// first. A pick quits through Activity's own quit; the same one picked again within 30 s is forced where it may be.
    static func pickProcess() {
        Task {
            let monitor = ActivityMonitor.shared
            guard await monitor.refresh() else { return HUD.tip("The process list could not be read") }
            let entries = Activity.entries(monitor.snapshot)
            guard !entries.isEmpty else { return HUD.tip("Nothing of yours to quit") }
            PilotMenu.shared.pick(entries, title: "Kill a process") { picked in
                guard case .action(let id) = picked.target, let row = monitor.snapshot.row(id) else {
                    return HUD.tip("\(picked.title) is gone")
                }
                let force = kills.signal(for: row.pid, now: .now) == SIGKILL && row.rights.canForce
                guard monitor.quit(row, force: force) else { return HUD.tip("\(row.name) is gone or not yours to quit") }
                HUD.tip(force ? "\(row.name) forced to quit"
                        : row.rights.canForce ? "Asked \(row.name) to quit; pick it again to force it" : "Asked \(row.name) to quit")
            }
        }
    }

    /// Every screen macOS lets Pilot turn, each rotation it is not at now, labelled by its Pilot name.
    static func pickRotation() {
        let displays = SetupDisplays.shared
        displays.start()
        let screens = displays.displays.filter { displays.canRotate($0.id) }
        guard !screens.isEmpty else { return HUD.tip("macOS does not let Pilot rotate these screens") }
        let turns = screens.flatMap { screen in DisplayRotation.degrees.filter { $0 != screen.rotation }.map { (screen, $0) } }
        let rows = turns.enumerated().map { i, turn in
            MenuEntry(title: "\(displays.label(turn.0)) to \(turn.1)°", target: .action(String(i)), detail: "now \(turn.0.rotation)°")
        }
        PilotMenu.shared.pick(rows, title: "Rotate display") { picked in
            guard case .action(let id) = picked.target, let i = Int(id), turns.indices.contains(i) else { return }
            displays.rotate(turns[i].0.id, to: turns[i].1)
            if let problem = displays.problem { HUD.tip(problem) }
        }
    }

    /// Locks the screen through SACLockScreenImmediate, the login framework's call behind macOS's own Lock Screen; no
    /// posted key (it was ctrl+cmd+Q). macOS has no public lock call.
    static func lock() {
        slog.notice("lock")
        guard let call = lockCall else { return slog.error("lock: no lock call in the login framework") }
        let result = call()
        if result != 0 { slog.error("lock returned \(result)") }
    }

    static let lockCall: (@convention(c) () -> Int32)? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(framework, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()

    /// Sleep, restart, shut down, log out: System Events, the one automation target Pilot talks to. The first call
    /// raises macOS's Automation prompt once; restart, shut down and log out then show Apple's own confirmation.
    static func systemEvents(_ verb: String) {
        appleScript("tell application \"System Events\" to \(verb)", what: verb)
    }

    /// osascript in a child process, so a pending Automation prompt never blocks the main thread the tap runs on.
    private static func appleScript(_ source: String, what: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let err = Pipe()
        p.standardError = err
        p.terminationHandler = { proc in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                if proc.terminationStatus == 0 { slog.notice("\(what, privacy: .public) done") }
                else {
                    slog.error("\(what, privacy: .public): \(msg, privacy: .public)")
                    HUD.tip("\(what.capitalized) needs Pilot allowed under Privacy & Security → Automation → System Events.")
                }
            }
        }
        do { try p.run() } catch { slog.error("\(what, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }

    /// Flips Wi-Fi through CoreWLAN, the same calls as Setup's Wi-Fi switch (card agent-bo-95422803).
    static func toggleWiFi() {
        Task {
            guard let on = wifi.status()?.on else { return slog.error("wi-fi: this Mac has no Wi-Fi") }
            do {
                try await wifi.setPower(!on)
                slog.notice("wi-fi \(on ? "off" : "on", privacy: .public)")
            } catch {
                slog.error("wi-fi: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Flips Bluetooth's radio (BluetoothPower).
    static func toggleBluetooth() {
        guard let on = BluetoothPower.state(bluetooth) else { return cannotSwitchBluetooth() }
        setBluetooth(!on)
    }

    /// Turns Bluetooth on, or off once Pilot's menu has asked, when Bluetooth keyboards and mice are the only input.
    static func setBluetooth(_ on: Bool) {
        guard BluetoothPower.state(bluetooth) != nil else { return cannotSwitchBluetooth() }
        guard !on, let warning = BluetoothPower.warning(bluetooth.inputs()) else { return powerBluetooth(on) }
        let off = MenuEntry(title: "Turn Bluetooth off", target: .action("bluetooth.off"), detail: "disconnects them")
        slog.notice("bluetooth off: asking, only Bluetooth input")
        PilotMenu.shared.pick([MenuEntry(title: "Cancel", target: .action("bluetooth.cancel")), off], title: warning) { row in
            guard row == off else { return slog.notice("bluetooth off: cancelled") }
            powerBluetooth(false)
        }
    }

    private static func powerBluetooth(_ on: Bool) {
        guard BluetoothPower.begin() else {
            slog.notice("bluetooth: a switch is under way, press ignored")
            return HUD.tip("Bluetooth is still switching", seconds: 2)
        }
        Task {
            defer { BluetoothPower.end() }
            let after = await bluetooth.setPower(on)
            NotificationCenter.default.post(name: BluetoothPower.changed, object: nil)
            slog.notice("bluetooth \(on ? "on" : "off", privacy: .public): \(after == on ? "done" : "failed", privacy: .public)")
            HUD.tip(after == on ? "Bluetooth \(on ? "on" : "off")" : "macOS did not turn Bluetooth \(on ? "on" : "off")", seconds: 2)
        }
    }

    /// Why there is no switch: the private call is gone, Bluetooth is not allowed yet (System › Bluetooth asks), or no radio.
    private static func cannotSwitchBluetooth() {
        guard bluetooth.canSetPower else { return HUD.tip("This macOS no longer lets Pilot switch Bluetooth; use Control Centre", seconds: 3) }
        guard bluetooth.authorization() == .allowed else {
            AppWindowController.shared.open(.system, setup: .bluetooth)
            return HUD.tip("Allow Bluetooth first: Show paired devices", seconds: 3)
        }
        HUD.tip("This Mac has no Bluetooth", seconds: 2)
    }

    /// Text on the pasteboard, said in Pilot's alert.
    static func copy(_ text: String, tip: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        HUD.tip(tip)
    }

    /// Full Disk Access has no prompt: Sven switches Pilot on in this pane (onboarding, the menu's Files view).
    static func openFullDiskAccess() { pane("com.apple.preference.security?Privacy_AllFiles") }

    static func pane(_ id: String) {
        slog.notice("settings pane \(id, privacy: .public)")
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(id)")!)
    }
}
