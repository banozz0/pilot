import AppKit
import Observation
import PilotCore

/// The tall Pilot menu's saved arrangement (spec desktop-controls T4): block order, hidden and pinned, Instrument only;
/// Toybox keeps today's Dropdown. Its own store, as WallpaperSettings is, so `pilot set dropdown.*` works without an
/// engine. A saved value that no longer decodes (a block renamed or gone) falls back to the standard arrangement.
@Observable @MainActor
final class DropdownLayoutStore {
    static let shared = DropdownLayoutStore()
    /// What `pilot set dropdown.*` writes: the menu's own store, and in an isolated test run a store of its own, so a
    /// settings test's arrangement never reaches a panel another test draws (as `UserDefaults.pilot()` keeps defaults apart).
    static var forSettings: DropdownLayoutStore { isIsolatedTestRun ? DropdownLayoutStore() : .shared }

    private(set) var layout: Dropdown.Layout { didSet { save() } }
    @ObservationIgnored private let defaults: UserDefaults
    static let key = "dropdown.layout"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Dropdown.Layout.self, from: $0) }
        // A block added since the save joins at its first place in the order, hidden if it is optional.
        layout = saved.flatMap { saved in
            (try? Dropdown.Layout.order(saved.order)).map { order in
                let added = Set(order).subtracting(saved.order)
                return Dropdown.Layout(order: order, hidden: saved.hidden.union(added.intersection(Dropdown.Layout.optional)), pinned: saved.pinned,
                                       extensions: saved.extensions)
            }
        } ?? .standard
    }

    /// `pilot set dropdown.order`: the named blocks first, the rest after in their first order.
    func setOrder(_ blocks: [Dropdown.Block]) throws(ControlError) { layout.order = try Dropdown.Layout.order(blocks) }
    func setHidden(_ blocks: Set<Dropdown.Block>) throws(ControlError) { layout.hidden = try Dropdown.Layout.hide(blocks) }
    func setPinned(_ blocks: Set<Dropdown.Block>) throws(ControlError) { layout.pinned = try Dropdown.Layout.pin(blocks) }
    func setExtensions(_ ids: [String]) throws(ControlError) { layout.extensions = try Pill.Layout.extensions(ids) }

    /// The edit list's switch for one extension in the Extensions card.
    func hold(extension id: String, _ on: Bool) {
        if !on { layout.extensions.removeAll { $0 == id } } else if !layout.extensions.contains(id) { layout.extensions.append(id) }
    }

    /// The edit list's moves: a block to a place, shown or hidden, pinned or not.
    func move(_ block: Dropdown.Block, to index: Int) { layout.move(block, to: index) }

    func show(_ block: Dropdown.Block, _ on: Bool) {
        guard block != .status else { return }
        if on { layout.hidden.remove(block) } else { layout.hidden.insert(block) }
    }

    func pin(_ block: Dropdown.Block, _ on: Bool) {
        if on { layout.pinned.insert(block) } else { layout.pinned.remove(block) }
    }

    func reset() { layout = .standard }

    private func save() {
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: Self.key) }
    }
}

extension Dropdown.Block {
    /// The block's name as the edit list and `pilot help` show it.
    var title: String {
        switch self {
        case .status: "Status"
        case .workspaces: "Workspaces"
        case .quickSwitches: "Switches"
        case .extensions: "Extensions"
        case .now: "Running now"
        case .sound: "Sound"
        case .connections: "Wi-Fi and Bluetooth"
        case .display: "Brightness"
        case .media: "Now playing"
        case .stats: "Battery, CPU and memory"
        case .rows: "Commands"
        case .developer: "Developer"
        case .footer: "Footer"
        }
    }

    var symbol: String {
        switch self {
        case .status: "checkmark.circle"
        case .workspaces: "square.grid.3x1.below.line.grid.1x2"
        case .quickSwitches: "switch.2"
        case .extensions: "puzzlepiece.extension"
        case .now: "dot.radiowaves.left.and.right"
        case .sound: "speaker.wave.2"
        case .connections: "wifi"
        case .display: "sun.max"
        case .media: "music.note"
        case .stats: "cpu"
        case .rows: "list.bullet"
        case .developer: "hammer"
        case .footer: "rectangle.bottomthird.inset.filled"
        }
    }
}

/// The optional blocks' readings (spec desktop-controls T4), read only while the panel shows and the block is shown: the
/// bar's own readers held for sound, Wi-Fi, battery and the stats, Now playing's watcher for media, brightness read on
/// open. `hold` starts them and gives back what releases them.
@MainActor
enum DropdownBlocks {
    /// The bar readers each shown optional block needs.
    static func kinds(_ shown: Set<Dropdown.Block>) -> Set<BarKind> {
        var kinds: Set<BarKind> = []
        if shown.contains(.sound) { kinds.insert(.volume) }
        if shown.contains(.connections) { kinds.insert(.wifi) }
        if shown.contains(.stats) { kinds.formUnion([.cpu, .memory, .battery]) }
        if shown.contains(.extensions) { kinds.insert(.extensions) }
        return kinds
    }

    /// Holds the readers for `shown` until the calling task is cancelled (the panel closes or the blocks change), and the
    /// Extensions card's `extensions` with the extension bar. The first Wi-Fi hold reads Wi-Fi at once.
    static func hold(_ shown: Set<Dropdown.Block>, extensions: [String] = [], readings: BarReadings) async {
        var held: Set<BarKind> = []
        let asked = shown.contains(.extensions) ? Set(extensions) : []
        readings.hold(kinds(shown.subtracting(asked.isEmpty ? [.extensions] : [])), replacing: &held)
        ExtensionBar.shared.hold(asked, for: "dropdown")
        defer {
            readings.hold([], replacing: &held)
            ExtensionBar.shared.hold([], for: "dropdown")
        }
        if shown.contains(.display) { await ScreenBrightness.engine.refresh(ScreenBrightness.displays()) }
        if shown.contains(.media) { await NowPlaying.shared.watch() }
        else { while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) } }
    }

    static func sound(_ readings: BarReadings) -> DropdownPanelValues.Sound? {
        let output = readings.sound.side(.output)
        guard let volume = output.volume?.value else { return nil }
        return .init(device: output.devices.first { $0.id == output.current }?.name ?? "Output", level: Double(volume), muted: output.muted ?? false)
    }

    static func connections(_ readings: BarReadings) -> DropdownPanelValues.Connections {
        let wifi = readings.wifi
        // CoreWLAN's RSSI in dBm: -60 or better is strong, -70 good, -80 weak.
        // The bar's own cutoffs, as the face draws three bars at most.
        let bars = wifi.flatMap(\.signal).map { min(BarParts.wifiBars($0), 3) } ?? 0
        let bluetooth = BluetoothPower.power() ?? false
        return .init(wifiOn: wifi?.on ?? false, wifiBars: bars, bluetoothOn: bluetooth, bluetoothDetail: bluetooth ? "On" : "Off")
    }

    /// The focused screen and its display id, whose brightness the block shows and sets.
    static var focused: (screen: NSScreen, id: UInt32)? {
        guard let screen = Screens.focusedScreen ?? NSScreen.main, let id = WallpaperScreen.number(screen) else { return nil }
        return (screen, id)
    }

    /// The focused screen's brightness, nil while it has no control or is not read yet.
    static func display() -> DropdownPanelValues.Display? { focused.flatMap(display) }

    /// `screen`'s brightness: for a face that redraws often and reads the focused screen once (the pill's Controls).
    static func display(_ screen: (screen: NSScreen, id: UInt32)) -> DropdownPanelValues.Display? {
        ScreenBrightness.engine.screens[screen.id]?.level.map { .init(name: screen.screen.localizedName, level: $0) }
    }

    static func media() -> DropdownPanelValues.Media? {
        guard let track = NowPlaying.shared.track else { return nil }
        return .init(title: track.title, artist: track.artist, art: NowPlaying.shared.art, playing: track.playing)
    }

    static func stats(_ readings: BarReadings, sampler: SystemSampler) -> DropdownPanelValues.Stats? {
        guard let values = sampler.latestValues else { return nil }
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return .init(cpu: Int(((values.cpu ?? 0) * 100).rounded()), memoryUsed: values.ram * total, memoryTotal: total.rounded(),
                     battery: readings.battery.map(\.percent), charging: readings.battery?.charging ?? false)
    }

    /// The Extensions card's rows: the picked extensions' bar items as they last answered.
    static func extensions(_ ids: [String], bar: ExtensionBar = .shared) -> [DropdownPanelValues.Extension] {
        bar.items(ids).map { item in
            .init(emoji: item.icon ?? "🧩", title: item.title, text: item.answer.map { $0.text.isEmpty ? "–" : $0.text } ?? "…",
                  detail: item.answer == nil && item.problem == nil ? "Asking…" : nil, problem: item.problem)
        }
    }

    /// A row of the Extensions card: the extension's page in Pilot's window (Q76), or its place on Extensions when it
    /// has no page.
    static func openPage(_ ids: [String], at i: Int, bar: ExtensionBar = .shared) {
        let items = bar.items(ids)
        guard items.indices.contains(i) else { return }
        BarPanel.shared.close()
        if items[i].hasPage { AppWindowController.shared.openExtensionPage(items[i].id) }
        else { AppWindowController.shared.open(AppPlace(.extensions), extension: items[i].id) }
    }

    /// A press on an optional block's control.
    static func act(_ action: DropdownPanelFace.Action, readings: BarReadings) {
        switch action {
        case .level(.sound, let level): readings.sound.setVolume(Float(level), .output)
        case .level(.display, let level):
            guard let id = focused?.id else { return }
            _ = ScreenBrightness.engine.set(id, level)
        case .connection(.wifi): Task { await readings.setWiFi(!(readings.wifi?.on ?? false)) }
        case .connection(.bluetooth):
            guard let on = BluetoothPower.power() else { return }
            Task { _ = await BluetoothPower.set(!on) }
        case .media(.previous): NowPlaying.shared.send(.previous)
        case .media(.playPause): NowPlaying.shared.send(.toggle)
        case .media(.next): NowPlaying.shared.send(.next)
        default: break
        }
    }
}
