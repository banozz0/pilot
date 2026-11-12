import AppKit
import PilotCore
import SwiftUI

/// Gathers the readings bar items draw from (card agent-bo-95422911), for the macOS menu bar and the top bar alike. It
/// reads only what the given items need in their styles, so an observer tracking it wakes only for those readings: a
/// CPU tick never redraws the clock, a new minute never redraws the readings.
@MainActor
struct BarSources {
    let readings: BarReadings
    let observers: EngineObservers
    let sampler: SystemSampler
    let keepAwake: KeepAwake
    let timer: ExtensionTimer
    /// The extensions' bar items (story 161).
    var extensionBar: ExtensionBar = .shared
    /// The Pilot icon's number, or off, or ! for secure input (Engine.menuBarTitle).
    let pilotTitle: @MainActor () -> String
    /// Accessibility is missing: Pilot's icon warns.
    var pilotAlert: @MainActor () -> Bool = { false }
    /// Pilot's dropdown (card agent-bo-95422912), hung from Pilot's item in either bar.
    var dropdown: @MainActor () -> AnyView = { AnyView(EmptyView()) }
    /// Opens an app by bundle id: the clock's date opens Calendar (card agent-bo-95423011); a fake in tests.
    var openApp: @MainActor (String) -> Void = { _ = AppsModule.open(bundle: $0) }
    /// Runs the Power item's lock, sleep, restart, shut down and log out; a fake in tests.
    var power: any PowerRunning = SystemPower()
    /// The Displays item's screens and brightness, the app's own as System's Displays card's: a mode picked waits for Keep
    /// there too.
    var displays: @MainActor () -> SetupDisplays = { .shared }
    var brightness: @MainActor () -> Brightness? = { ScreenBrightness.engine }
    /// Takes the shown popover down (Power's, once its action ran); a fake in tests.
    var closePopover: @MainActor () -> Void = { BarPanel.shared.close() }
    /// The registered actions among these ids, each with its key as the dropdown signs it (Capture's menu); a fake in tests.
    var registered: @MainActor ([String]) -> [String: String?] = { BarSources.registered($0) }
    /// Every registered capture action's label by id, so Capture's menu lists a capture it does not name; a fake in tests.
    var captureLabels: @MainActor () -> [String: String] = {
        Engine.shared?.registry.actions.values.filter { $0.module == .captures }.reduce(into: [:]) { $0[$1.id] = $1.label } ?? [:]
    }
    /// Bluetooth's switch as its item's menu opens, nil to hide it, and the switch itself (T47); fakes in tests.
    var bluetoothOn: @MainActor () -> Bool? = { BluetoothPower.state(SystemModule.bluetooth) }
    var setBluetooth: @MainActor (Bool) -> Void = { SystemModule.setBluetooth($0) }
    /// Runs a registered action by its id, as the menu's rows do; a fake in tests.
    var runAction: @MainActor (String) -> Void = { Engine.shared?.action($0)?.run() }

    func inputs(for entries: [BarEntry]) -> BarInputs {
        var i = BarInputs()
        for entry in entries {
            switch entry.kind {
            case .pilot:
                i.pilotTitle = pilotTitle()
                i.pilotAlert = pilotAlert()
                i.pilotDownload = ExtrasDownloads.shared.share
            case .workspaces:
                let tiler = observers.tiler
                i.workspaces = tiler.occupied.map(\.name)
                i.focusedWorkspace = tiler.focused
                // Each workspace's apps only in the style that shows them, so a window opening redraws no other style.
                if entry.style == .withApp {
                    i.firstApp = Dictionary(tiler.occupied.compactMap { w in w.apps.first.map { (w.name, $0) } }, uniquingKeysWith: { a, _ in a })
                }
            case .focusedApp: i.focusedApp = observers.focusedApp?.localizedName
            case .cpu, .memory, .network, .graphics, .storage, .heat, .bluetoothBatteries:
                i.latest = sampler.latest
                i.values = sampler.latestValues
                if entry.style == .graph { i.history = sampler.history }
                i.bluetooth = sampler.latest?.slow.bluetooth ?? []
            case .battery:
                i.battery = readings.battery
                i.watts = readings.watts
            case .keepAwake:
                i.keepAwake = keepAwake.isOn
                i.keepAwakeLeft = keepAwake.until.map { $0.timeIntervalSince(readings.now) }
            case .volume:
                let output = readings.sound.side(.output)
                i.volume = output.volume?.value
                i.muted = output.muted
                i.output = output.devices.first { $0.id == output.current }?.name
            case .keyboardLayout: i.keyboardLayout = readings.look.currentLayout?.name
            case .wifi:
                i.wifiOn = readings.wifi?.on
                i.wifiSignal = readings.wifi?.signal
            case .clock: i.now = readings.now
            case .timer:
                i.timerCountdown = timer.countdown
                i.timerLeft = timer.left
                i.timerTitle = timer.title
            case .extensions: i.extensionBars = extensionBar.faces(in: .topBar)
            case .modes: i.statusLights = readings.statusLights.lights
            case .capture: i.recording = readings.recording
            case .notifications: i.notifications = NotificationSettings.shared.inBar ? NotificationCardsModel.shared.unread : nil
            // The pill reads NowPlaying itself, held while its Music shows (PillDrop).
            case .otherApps, .appMenus, .power, .displays, .terminal, .askAI, .pill, .spacer, .divider, .group: break
            }
        }
        return i
    }

    /// Whether this Mac gives `kind`'s reading (no battery on a Mac mini): MenuBarStats' text for it, the rule the items
    /// follow; everything counts until the first reading says.
    func gives(_ kind: BarKind) -> Bool {
        guard let raw = sampler.latest, let stat = kind.stat else { return true }
        return MenuBarStats.text(stat, values: sampler.latestValues, raw: raw) != nil
    }

    /// The readings this Mac lacks, for Stats' chips and Menu bar's count.
    var lacking: Set<BarKind> { Set(BarSettings.readingKinds.filter { !gives($0) }) }

    /// A click's one action, the same from either bar; a popover is shown by the bar it hangs from.
    func perform(_ click: BarClick) {
        switch click {
        case .cycleLayout: readings.look.pickNextLayout()
        case .toggleKeepAwake: keepAwake.toggle()
        case .toggleMute: readings.sound.toggleMute(.output)
        // A menu is hung by the bar it hangs from, as a popover is.
        case .popover, .none, .extension, .menu: break
        }
    }

    static func registered(_ ids: [String]) -> [String: String?] {
        guard let engine = Engine.shared else { return [:] }
        return Dictionary(uniqueKeysWithValues: ids.filter { engine.action($0) != nil }.map { ($0, engine.keyLabel($0)) })
    }

    /// An item's right-click menu in `place` (card agent-bo-95423010), from its readings and, for Volume, the outputs.
    func menu(_ kind: BarKind, in place: BarPlace, store: BarItemsStore) -> [BarMenuRow] { menu(.kind(kind), in: place, store: store) }

    /// The same for any slot's item, an extension's own in the top bar included (spec pilot-1.1 T50).
    func menu(_ item: BarTrayItem, in place: BarPlace, store: BarItemsStore) -> [BarMenuRow] {
        guard let entry = store.settings.entries.first(where: { $0.item == item }) else { return [] }
        return entry.menu(menuInputs(entry), in: place)
    }

    /// The menu Capture's click opens: its own actions alone.
    func clickMenu(_ kind: BarKind, store: BarItemsStore) -> [BarMenuRow] {
        kind.actions(menuInputs(store.settings.entry(kind)), scrolls: false)
    }

    /// An item's readings, and what only its menu reads: Volume's outputs, the actions Capture's rows run, Wi-Fi read
    /// now and Bluetooth's switch.
    private func menuInputs(_ entry: BarEntry) -> BarInputs {
        if entry.kind == .wifi { readings.refreshWiFi() }
        var i = inputs(for: [entry])
        if entry.kind == .bluetoothBatteries { i.bluetoothOn = bluetoothOn() }
        if entry.kind == .volume { i.outputs = readings.sound.side(.output).devices.map(\.name) }
        if entry.kind == .capture {
            i.actionLabels = captureLabels()
            // One id once: `registered` builds a dictionary, and the labels hold the named actions too.
            i.actions = registered(Set(BarKind.captureActions).union(i.actionLabels.keys).sorted())
        }
        return i
    }

    /// A pick from an item's right-click menu: the bar's own changes go to `store`, the rest run here; `popover` shows
    /// the item's popover from the bar it hangs from.
    func perform(_ action: BarAction, on kind: BarKind, store: BarItemsStore, popover: () -> Void) {
        perform(action, on: .kind(kind), store: store, popover: popover)
    }

    func perform(_ action: BarAction, on item: BarTrayItem, store: BarItemsStore, popover: () -> Void) {
        switch action {
        case .click(.popover): popover()
        case .click(let click): perform(click)
        case .workspace(let next): BarScroll.perform(.workspaces, steps: next ? -1 : 1, on: self)
        case .output(let name):
            if let device = readings.sound.side(.output).devices.first(where: { $0.name == name }) { readings.sound.pick(device.id, .output) }
        case .settings(let pane): SystemModule.pane(pane)
        case .activityMonitor: AppsModule.open(bundle: AppsModule.resolved(.activityMonitor))
        // The Menu bar page, where the bar is dragged (Q185).
        case .edit(let edit): store.settings.apply(edit, on: item)
        case .run(let id): runAction(id)
        // Edit bar's the Menu bar page, where the bar is dragged (Q185).
        case .page(let page): AppWindowController.shared.open(page)
        case .radio(.wifi, let on): Task { await readings.setWiFi(on) }
        case .radio(.bluetooth, let on): setBluetooth(on)
        }
    }
}

/// Scroll on Volume and Workspaces: the output's level, and a workspace step through TilerService, which sends it to
/// Pilot's tiler.
extension BarSources: BarScrollTarget {
    var volume: Float? { readings.sound.side(.output).volume?.value }

    func setVolume(_ level: Float) { readings.sound.setVolume(level, .output) }

    func run(_ command: AeroCommand) {
        let tiler = observers.tiler
        Task { await tiler.perform("bar.\(command.arguments.joined(separator: " "))") { try await $0.run(command) } }
    }
}
