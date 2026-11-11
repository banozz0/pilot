import AppKit
import PilotCore
import SwiftUI

/// The pill's saved views (spec desktop-controls T7): order, hidden, the selected one and the extensions it holds, as
/// Menu bar › Pill edits them and `pilot set pill.*` writes them. Its own store, as the Pilot menu's is, so a theme's
/// Restore of the bar never takes it back.
@Observable @MainActor
final class PillLayoutStore {
    static let shared = PillLayoutStore()
    /// What `pilot set pill.*` writes: the pill's own store, and in an isolated test run a store of its own.
    static var forSettings: PillLayoutStore { isIsolatedTestRun ? PillLayoutStore() : .shared }
    static let key = "pill.layout"

    private(set) var layout: Pill.Layout { didSet { save(); changed?() } }
    /// Told after each change: the pill follows its watchers to the view that now shows.
    @ObservationIgnored var changed: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        layout = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Pill.Layout.self, from: $0) } ?? .standard
    }

    func setOrder(_ views: [Pill.View]) throws(ControlError) { layout.order = try Pill.Layout.order(views) }
    func setHidden(_ views: Set<Pill.View>) throws(ControlError) { layout.hidden = try Pill.Layout.hide(views) }
    func select(_ view: Pill.View) throws(ControlError) { layout.selected = try layout.select(view) }
    func setExtensions(_ ids: [String]) throws(ControlError) { layout.extensions = try Pill.Layout.extensions(ids) }

    /// The edit list's moves and switches; hiding the last view shown is refused, as `pill.hidden` refuses it.
    func move(_ view: Pill.View, to index: Int) { layout.move(view, to: index) }
    func show(_ view: Pill.View, _ on: Bool) { try? setHidden(on ? layout.hidden.subtracting([view]) : layout.hidden.union([view])) }
    func hold(extension id: String, _ on: Bool) {
        if !on { layout.extensions.removeAll { $0 == id } } else if !layout.extensions.contains(id) { layout.extensions.append(id) }
    }
    func reset() { layout = .standard }

    private func save() {
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: Self.key) }
    }
}

/// The pill (spec desktop-controls T5, Sven's pick A, shoulders): its compact face on the top bar and its drop, one of
/// BarDrops' drops, hung under the item that was clicked (PillPlacement) and alone: opening it closes the other drops and
/// the Pilot menu, and theirs close it (DropKeys). Four views (T7): Music, Extensions, Activity and Controls, switched by
/// the drop's tabs or on Menu bar › Pill. Only the view showing reads, and only while a face shows it (a pill on a bar or
/// the open drop): Music NowPlaying's watcher, Extensions the pill's extensions' bar items, Controls sound and brightness.
@MainActor @Observable
final class PillDrop {
    static let shared = PillDrop()

    @ObservationIgnored let layout: PillLayoutStore
    @ObservationIgnored private var holds = 0
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// The view the watch is for; nil while nothing shows or the view showing reads nothing.
    @ObservationIgnored private var watching: Pill.View?
    /// The focused screen as Controls opened on it: its brightness is read from here, never an Accessibility read per draw.
    @ObservationIgnored private var screen: (screen: NSScreen, id: UInt32)?

    init(layout: PillLayoutStore = .shared) {
        self.layout = layout
        layout.changed = { [weak self] in self?.follow() }
    }

    /// The view the compact face and the drop show.
    var page: PillValues.Page { .init(layout.layout.current) }
    /// The views offered, in order: the drop's tabs.
    var pages: [PillValues.Page] { layout.layout.shown.map(PillValues.Page.init) }

    /// What the faces draw now: the view showing, read alone.
    var values: PillValues {
        let current = layout.layout.current
        var values = PillValues()
        values.page = .init(current)
        values.pages = pages
        switch current {
        case .music: values.music = Self.music(NowPlaying.shared)
        case .extensions: values.extensions = Self.extensions(layout.layout.extensions, bar: .shared)
        case .activity: values.running = DropdownNow.rows
        case .controls:
            guard let engine = Engine.shared else { break }
            values.controls = Self.controls(engine)
            values.sound = DropdownBlocks.sound(engine.barSources.readings)
            values.display = screen.flatMap(DropdownBlocks.display)
        }
        return values
    }

    /// Whether the view showing moves once a second on its own: a playing track's clock, a recording's time. A timer's
    /// countdown and a download's share are observed, so they redraw without a tick.
    var ticks: Bool {
        switch layout.layout.current {
        case .music: NowPlaying.shared.track?.playing == true
        case .activity: Recorder.shared.isActive
        case .extensions, .controls: false
        }
    }

    /// The playing track as Music shows it; nil draws Music's empty state.
    static func music(_ now: NowPlaying) -> PillValues.Music? {
        guard let track = now.track else { return nil }
        let at = track.position(at: .now), length = track.duration
        return .init(title: track.title, artist: track.artist, album: track.album.isEmpty ? nil : track.album, art: now.art,
                     playing: track.playing, elapsed: clock(at), length: length.map(clock) ?? "",
                     progress: length.map { $0 > 0 ? min(max(at / $0, 0), 1) : 0 } ?? 0, source: track.app)
    }

    /// The pill's extensions' bar items in its order, as they last answered; one uninstalled since is left out.
    static func extensions(_ ids: [String], bar: ExtensionBar) -> [PillValues.Extension] {
        bar.items(ids).map { item in
            .init(symbol: "puzzlepiece.extension", name: item.title, value: item.answer.map { $0.text.isEmpty ? "–" : $0.text } ?? "…",
                  detail: item.problem ?? (item.answer == nil ? "Asking…" : ""))
        }
    }

    /// The Pilot menu's six switches as the Controls view's tiles.
    static func controls(_ engine: Engine) -> [PillValues.Control] {
        let switches = engine.quickSwitches, layerKeys = engine.settings.layerKeys, tiler = engine.observers.tiler.tilerName
        return Dropdown.Switch.allCases.map { which in
            let on = switches[which].isOn
            return .init(symbol: which.symbol(layerKeys: layerKeys), title: which.title, detail: which.state(on, layerKeys: layerKeys, tiler: tiler), on: on)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A face showing the pill came or went: the first hold starts the showing view's reader, the last stops it.
    func hold() {
        holds += 1
        if holds == 1 { follow() }
    }

    func release() {
        holds = max(0, holds - 1)
        if holds == 0 { follow() }
    }

    /// Points the readers at the view showing now, or stops them while no face shows the pill. The extensions asked on
    /// the pill's account follow at once; a view's reader restarts only when the view changed.
    private func follow() {
        let asked = holds > 0 ? layout.layout.asked : []
        ExtensionBar.shared.hold(Set(asked), for: "pill")
        // Extensions with none held reads nothing: no extension round scans the folder for it.
        let view: Pill.View? = holds == 0 || layout.layout.current == .extensions && asked.isEmpty ? nil : layout.layout.current
        guard view != watching else { return }
        watch?.cancel()
        watching = view
        screen = view == .controls ? DropdownBlocks.focused : nil
        let readings = Engine.shared?.barSources.readings
        watch = switch view {
        case .music: Task { await NowPlaying.shared.watch() }
        case .extensions: readings.map { readings in Task { await Self.holding([.extensions], readings) } }
        case .controls: readings.map { readings in Task { await DropdownBlocks.hold([.sound, .display], readings: readings) } }
        case .activity, nil: nil
        }
    }

    /// Holds the bar's `kinds` readers until cancelled.
    private static func holding(_ kinds: Set<BarKind>, _ readings: BarReadings) async {
        var held: Set<BarKind> = []
        readings.hold(kinds, replacing: &held)
        defer { readings.hold([], replacing: &held) }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// The pill's click or its key: closes the drop when open, else opens it under the item clicked (`spot`), or on the
    /// focused display.
    func toggle(at spot: BarDrops.Spot? = nil, drops: BarDrops = .shared) {
        if drops.isOpen(.pill) { return drops.close(.pill) }
        // One open at a time: the Pilot menu goes too.
        BarPanel.shared.close()
        hold()
        drops.open(.pill, face: face(), at: spot)
    }

    private func face() -> BarDropFace {
        let look = Look.shared
        return BarDropFace(panel: { size in
            let host = NSHostingView(rootView: PillDropHost(pill: self).styled(.barPopovers, look: look).pilotTheme(look: look))
            host.sizingOptions = []   // the drop's frame is BarDrops', from PillPlacement
            host.frame.size = size
            return BarDrops.panel(host, title: "Pill", appearance: look.appearance(for: .barPopovers))
        }, keepsField: false, closed: { [weak self] in self?.release() })
    }

    /// A press in the drop.
    func act(_ action: PillDropFace.Action) {
        switch action {
        case .select(let page): try? layout.select(page.view)
        case .transport(.previous): NowPlaying.shared.send(.previous)
        case .transport(.playPause): NowPlaying.shared.send(.toggle)
        case .transport(.next): NowPlaying.shared.send(.next)
        case .toggle(let title):
            guard let engine = Engine.shared, let which = Dropdown.Switch.allCases.first(where: { $0.title == title }) else { return }
            engine.quickSwitches[which].toggle()
        case .level(.display, let level):
            // The screen the view reads, so the slider and its reading stay on one display.
            guard let id = screen?.id else { return }
            _ = ScreenBrightness.engine.set(id, level)
        case .level(let kind, let level):
            guard let readings = Engine.shared?.barSources.readings else { return }
            DropdownBlocks.act(.level(kind, level), readings: readings)
        case .pause(let i): DropdownNow.press(i, pause: true)
        case .stop(let i): DropdownNow.press(i, pause: false)
        case .empty(.music): NSWorkspace.shared.open(URL(filePath: "/System/Applications/Music.app"))
        // Choosing views and the pill's extensions is Menu bar › Pill.
        case .choosePages, .empty:
            BarDrops.shared.close(.pill)
            AppWindowController.shared.open(AppPlace(.menuBar))
        }
    }
}

extension PillValues.Page {
    init(_ view: Pill.View) { self = Self.allCases.first { $0.view == view }! }

    var view: Pill.View {
        switch self {
        case .music: .music
        case .extensions: .extensions
        case .activity: .activity
        case .controls: .controls
        }
    }
}

/// The open drop's face, fed from the pill as it changes; a playing track's clock or a running timer moves once a second.
private struct PillDropHost: View {
    let pill: PillDrop

    var body: some View {
        Ticking(pill.ticks) { face }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var face: some View {
        PillDropFace(values: pill.values, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { pill.act($0) }
    }
}

/// The pill's item on the top bar: its compact face, the chevron turned while its drop is open; a click toggles the
/// drop under this item, on this item's screen.
struct TopBarPillItem: View {
    var pill = PillDrop.shared
    var lights = BarDropLights.shared
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        Button { pill.toggle(at: lights.spot(of: .pill, from: anchor)) } label: {
            // A recording's time moves on the bar too; Music's compact face has no clock.
            Ticking(pill.ticks && pill.page == .activity) { PillCompactFace(values: pill.values, open: lights.open.contains(.pill)) }
        }
        .buttonStyle(.kitPress)
        .accessibilityLabel("Pill, \(pill.page.title)")
        .frame(maxHeight: .infinity)
        .toyIsland(.pill)
        .onAppear { lights.register(anchor, for: .pill); pill.hold() }
        .onDisappear { lights.unregister(anchor, for: .pill); pill.release() }
        .background { ScreenAnchor(box: anchor) }
    }
}

/// `content` redrawn once a second while `on`, else drawn as it is.
private struct Ticking<Content: View>: View {
    let on: Bool
    @ViewBuilder let content: () -> Content

    init(_ on: Bool, @ViewBuilder content: @escaping () -> Content) { self.on = on; self.content = content }

    var body: some View {
        if on { TimelineView(.periodic(from: .now, by: 1)) { _ in content() } } else { content() }
    }
}
