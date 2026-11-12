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
///
/// On the pill-first bar (PillFirst, Q160 to Q165) it shows that bar's pages instead, Calendar and Stats among them, and a
/// recording or a running timer takes its compact face over (Q164); today's views stay saved as they were.
@MainActor @Observable
final class PillDrop {
    static let shared = PillDrop()

    @ObservationIgnored let layout: PillLayoutStore
    /// The bar's store, which keeps the pill-first bar's settings.
    @ObservationIgnored let bar: BarItemsStore
    @ObservationIgnored private var holds = 0
    @ObservationIgnored private var watch: Task<Void, Never>?
    /// What the watch is for; nil while nothing shows or the page showing reads nothing.
    @ObservationIgnored private var watching: Watch?
    /// The focused screen as Controls opened on it: its brightness is read from here, never an Accessibility read per draw.
    @ObservationIgnored private var screen: (screen: NSScreen, id: UInt32)?
    /// The drop is open: only then may Calendar ask for access (macOS's prompt), never for the compact face.
    @ObservationIgnored private var dropOpen = false
    /// The open drop's row the keys lit, its focus ring; nil while none is (a click opened it, or no key moved yet).
    private var highlight: Int?
    /// Opened on the live face: the drop shows the live Activity tab until another tab is picked or it closes.
    private var showingLive = false

    private struct Watch: Equatable {
        var page: PillValues.Page
        /// Calendar's read may ask for access.
        var ask = false
    }

    /// What shows now, on either pill: the tabs, the one showing, its kind and an extensions page's extensions.
    private struct Showing {
        var tabs: [PillValues.Tab]
        var index: Int
        var page: PillValues.Page
        var extensions: [String]
    }

    init(layout: PillLayoutStore = .shared, bar: BarItemsStore = .shared) {
        self.layout = layout
        self.bar = bar
        layout.changed = { [weak self] in self?.follow() }
        bar.pillFirstChanged = { [weak self] in self?.follow() }
    }

    /// The pill-first bar's settings while it draws; nil on today's pill.
    private var first: PillFirst.Settings? { bar.pillFirst.on ? bar.pillFirst : nil }
    /// The pill-first bar in Instrument draws the notch and the rail drop (Q170 B, Q171 C); Toybox keeps its capsule.
    var notched: Bool { bar.pillFirst.on && Look.shared.style == .instrument }
    /// The drop's size: the rail's on the pill-first bar.
    var dropSize: CGSize { notched ? PillPlacement.railSize : PillPlacement.size }

    private var showing: Showing { showing(live: live) }

    /// `showing` with the live row read once by the caller.
    private func showing(live: DropdownPanelValues.Running?) -> Showing {
        guard let first else {
            let saved = layout.layout, shown = saved.shown
            return Showing(tabs: shown.map { PillValues.Tab(.init($0)) }, index: shown.firstIndex(of: saved.current) ?? 0,
                           page: .init(saved.current), extensions: saved.extensions)
        }
        var tabs = first.pages.map { PillValues.Tab(.init($0.kind), title: $0.title) }
        // Something live and no Activity page: an Activity tab joins while it runs, so the live face's click lands on it.
        if live != nil, !first.pages.contains(where: { $0.kind == .activity }) {
            tabs.append(PillValues.Tab(.activity))
            if showingLive { return Showing(tabs: tabs, index: tabs.count - 1, page: .activity, extensions: []) }
        }
        let page = first.pages[first.current]
        return Showing(tabs: tabs, index: first.current, page: .init(page.kind), extensions: page.extensions)
    }

    /// The page the compact face and the drop show.
    var page: PillValues.Page { showing.page }

    /// The recording or running timer that takes the pill-first bar's compact face over (Q164); downloads never do, nor
    /// anything on today's pill.
    var live: DropdownPanelValues.Running? { bar.pillFirst.on ? DropdownNow.live : nil }

    /// What the faces draw now: the page showing, read alone.
    var values: PillValues {
        let live = live, showing = showing(live: live)
        var values = PillValues()
        values.page = showing.page
        values.tabs = showing.tabs
        values.tab = showing.index
        values.live = live
        let readings = Engine.shared?.barSources.readings
        switch showing.page {
        case .music: values.music = Self.music(NowPlaying.shared)
        case .extensions: values.extensions = Self.extensions(showing.extensions, bar: .shared)
        case .activity: values.running = DropdownNow.rows
        case .controls:
            guard let engine = Engine.shared else { break }
            values.controls = Self.controls(engine)
            values.sound = DropdownBlocks.sound(engine.barSources.readings)
            values.display = screen.flatMap(DropdownBlocks.display)
        case .calendar: values.calendar = readings.map { Self.calendar($0.calendar, now: $0.now, hours: bar.settings.clock.hoursAndMinutes) }
        case .stats: values.stats = readings.map { Self.stats($0) } ?? []
        }
        return values
    }

    /// What the open drop draws: `values` with the lit row, read here alone so the compact face never redraws for a key.
    /// A row gone since it was lit (a timer ended) moves the ring to the last one left.
    var dropValues: PillValues {
        var values = values
        values.highlight = values.rows == 0 ? nil : highlight.map { min($0, values.rows - 1) }
        return values
    }

    /// Whether the page showing moves once a second on its own: a playing track's clock, a recording's time. A timer's
    /// countdown and a download's share are observed, so they redraw without a tick. The open drop's.
    var ticks: Bool { Self.ticks(page) }

    static func ticks(_ page: PillValues.Page) -> Bool {
        switch page {
        case .music: return NowPlaying.shared.track?.playing == true
        case .activity: return Recorder.shared.isActive
        case .extensions, .controls, .calendar, .stats: return false
        }
    }

    /// Whether the compact face `values` draws moves once a second: a recording's time, on its page or the live face.
    /// Music's compact face has no clock.
    static func compactTicks(_ values: PillValues) -> Bool {
        Recorder.shared.isActive && (values.live?.symbol == "video" || values.live == nil && values.page == .activity)
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

    /// The Calendar page from the clock's own events and listing (ClockMonth.upcoming): what is left of today, then the
    /// next day that has any; times in the clock's own 12 or 24 hours. Asking until access is given or refused.
    static func calendar(_ source: ClockCalendar, now: Date, hours: TopBarClockFormat, timeZone: TimeZone = .autoupdatingCurrent,
                         locale: Locale = .autoupdatingCurrent) -> PillValues.Calendar {
        let access: PillValues.Calendar.Access = source.refused ? .refused : source.events == nil ? .asking : .granted
        let days = ClockMonth.upcoming(source.events ?? [], now: now, timeZone: timeZone).prefix(2)
        let events = days.enumerated().flatMap { offset, listed in
            listed.events.map { event in
                PillValues.Calendar.Event(time: event.allDay ? "All day" : "\(hours.text(event.start, timeZone: timeZone, locale: locale)) – \(hours.text(event.end, timeZone: timeZone, locale: locale))",
                                          title: event.title, colour: event.colour.map { Color($0) },
                                          day: offset == 0 ? nil : ClockMonth.dayName(listed.date, now: now, timeZone: timeZone, locale: locale),
                                          now: offset == 0 && !event.allDay && event.start <= now, url: event.url)
            }
        }
        func date(_ template: String) -> String { ClockMonth.formatted(now, template, timeZone: timeZone, locale: locale) }
        return .init(access: access, weekday: date("EEEE"), day: date("d"), month: date("MMMMyyyy"), short: date("EEEdMMM"), events: events)
    }

    /// The Stats page: the Pilot menu's Stats card's readings (DropdownBlocks.stats), then the free disk and, on a Mac
    /// with one, the battery, else the temperature.
    static func stats(_ readings: BarReadings, sampler: SystemSampler = .shared) -> [PillValues.Stat] {
        guard let base = DropdownBlocks.stats(readings, sampler: sampler) else { return [] }
        var stats: [PillValues.Stat] = [
            .init(symbol: "cpu", title: "CPU", number: "\(base.cpu)", unit: "%", detail: "In use", share: Double(base.cpu) / 100),
            .init(symbol: "memorychip", title: "Memory", number: String(format: "%.1f", base.memoryUsed), unit: "GB",
                  detail: "of \(Int(base.memoryTotal)) GB", share: base.memoryTotal > 0 ? base.memoryUsed / base.memoryTotal : nil),
        ]
        if let disk = sampler.latest?.slow.disk, disk.total > 0 {
            let (number, unit) = StatsStrip.split(StatsFormat.bytes(Double(disk.available)))
            stats.append(.init(symbol: "internaldrive", title: "Disk", number: number, unit: unit,
                               detail: "free of \(StatsFormat.bytes(Double(disk.total)))", share: 1 - Double(disk.available) / Double(disk.total)))
        }
        if let battery = base.battery {
            stats.append(.init(symbol: base.charging ? "battery.100.bolt" : "battery.75", title: "Battery", number: "\(battery)", unit: "%",
                               detail: base.charging ? "Charging" : "On battery", share: Double(battery) / 100))
        } else if let heat = sampler.latestValues?.heat {
            stats.append(.init(symbol: "thermometer.medium", title: "Temperature", number: StatsFormat.whole(heat), unit: "°C", detail: "Hottest sensor"))
        }
        return stats
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

    /// Points the readers at the page showing now, or stops them while no face shows the pill. The extensions asked on
    /// the pill's account follow at once; a page's reader restarts only when the page changed, or Calendar may now ask.
    private func follow() {
        let showing = showing
        let asked = holds > 0 && showing.page == .extensions ? showing.extensions : []
        ExtensionBar.shared.hold(Set(asked), for: "pill")
        // Extensions with none held reads nothing: no extension round scans the folder for it.
        let next: Watch? = holds == 0 || showing.page == .extensions && asked.isEmpty ? nil
            : Watch(page: showing.page, ask: showing.page == .calendar && dropOpen)
        guard next != watching else { return }
        watch?.cancel()
        watching = next
        screen = next?.page == .controls ? DropdownBlocks.focused : nil
        let readings = Engine.shared?.barSources.readings
        watch = switch next?.page {
        case .music: Task { await NowPlaying.shared.watch() }
        case .extensions: readings.map { readings in Task { await Self.holding([.extensions], readings) } }
        case .controls: readings.map { readings in Task { await DropdownBlocks.hold([.sound, .display], readings: readings) } }
        // The clock's own read, asking for access only once the drop is open on Calendar; it follows changes itself.
        case .calendar: readings.map { readings in
            Task { [ask = next?.ask ?? false] in await readings.calendar.load(showing: readings.now, now: readings.now, timeZone: .current, ask: ask) }
        }
        // The battery on a Mac with one, else the temperature: the page shows one of them.
        case .stats: readings.map { readings in Task { await Self.holding([.cpu, .memory, .storage, readings.battery == nil ? .heat : .battery], readings) } }
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
    /// focused display. Opened `byKey`, its first row is lit, so Return works at once; a click lights none. `page` opens
    /// the pill-first bar's page at that place (the clock's click opens Calendar), or picks it when the drop is open on
    /// another. Opened on the live face, it shows the live Activity tab.
    func toggle(at spot: BarDrops.Spot? = nil, byKey: Bool = false, page: Int? = nil, drops: BarDrops = .shared) {
        if drops.isOpen(.pill) {
            if let page, first != nil, page != showing.index { return select(page) }
            return drops.close(.pill)
        }
        // One open at a time: the Pilot menu goes too.
        BarPanel.shared.close()
        showingLive = page == nil && live != nil
        if let page, first != nil { select(page) }
        dropOpen = true
        hold()
        // The compact face already holds the pill, so this hold starts nothing: follow again, so Calendar may now ask.
        follow()
        highlight = byKey ? 0 : nil
        drops.open(.pill, face: face(), at: spot)
    }

    /// A tab picked by its place: today's view, or the pill-first bar's page, saved either way. The live Activity tab is
    /// not a page: picking it keeps it showing while something runs.
    func select(_ i: Int) {
        guard let first else {
            let shown = layout.layout.shown
            if shown.indices.contains(i) { try? layout.select(shown[i]) }
            return
        }
        showingLive = i >= first.pages.count && live != nil
        if first.pages.indices.contains(i) { bar.pillFirst.selected = i } else { follow() }
    }

    /// The next tab, wrapping: the Next pill view key.
    func next() {
        let showing = showing
        select(Pill.Press.wrap(showing.index + 1, showing.tabs.count))
    }

    private func face() -> BarDropFace {
        let look = Look.shared
        return BarDropFace(panel: { size in
            let host = NSHostingView(rootView: PillDropHost(pill: self).styled(.barPopovers, look: look).pilotTheme(look: look))
            host.sizingOptions = []   // the drop's frame is BarDrops', from PillPlacement
            host.frame.size = size
            return BarDrops.panel(host, title: "Pill", appearance: look.appearance(for: .barPopovers))
        }, keys: { [weak self] code, flags, chars in self?.key(code, flags, chars) ?? false },
           keepsField: false, closed: { [weak self] in
            self?.dropOpen = false
            self?.showingLive = false
            self?.release()
            self?.follow()
        })
    }

    /// A key in the open drop (Pill.Press): true when taken. A view picked by key is saved as `pill.view` (or the
    /// pill-first bar's page), as a click's is, and lights its first row.
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String?) -> Bool {
        let values = dropValues, showing = showing
        guard let what = Pill.Press.of(code: code, shift: flags.contains(.shift), chord: !flags.isDisjoint(with: [.control, .option, .command]),
                                        chars: chars, tabs: showing.tabs.count, current: showing.index, music: showing.page == .music,
                                        activity: showing.page == .activity, rows: values.rows, highlight: values.highlight)
        else { return false }
        switch what {
        case .page(let i):
            select(i)
            highlight = 0
        case .row(let row): highlight = row
        case .act(let row): press(row, in: values)
        case .stop(let row): act(.stop(row))
        case .playPause: act(.transport(.playPause))
        case .previous: act(.transport(.previous))
        case .next: act(.transport(.next))
        }
        return true
    }

    /// Return on the lit row: what a click on it does; an extension's item opens its page, as the Pilot menu's card does.
    private func press(_ row: Int, in values: PillValues) {
        switch values.page {
        case .music: act(.empty(.music))
        case .extensions: act(values.extensions.isEmpty ? .empty(.extensions) : .extensionPage(row))
        case .activity:
            let item = values.running[row]
            if item.canPause { act(.pause(row)) } else if item.canStop { act(.stop(row)) }
        case .controls: act(.toggle(values.controls[row].title))
        case .calendar: act(values.calendar?.access == .granted ? .event(row) : .empty(.calendar))
        case .stats: act(.stats)
        }
    }

    /// A press in the drop.
    func act(_ action: PillDropFace.Action) {
        switch action {
        case .select(let i): select(i)
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
        case .extensionPage(let i):
            BarDrops.shared.close(.pill)
            DropdownBlocks.openPage(showing.extensions, at: i)
        case .pause(let i): DropdownNow.press(i, pause: true)
        case .stop(let i): DropdownNow.press(i, pause: false)
        case .event(let i):
            // The row as drawn, so a click opens what it showed; one with no link opens Calendar, as the clock's does.
            guard let sources = Engine.shared?.barSources, let events = dropValues.calendar?.events, events.indices.contains(i) else { return }
            BarDrops.shared.close(.pill)
            if let url = events[i].url { sources.readings.calendar.open(url) } else { sources.openApp("com.apple.iCal") }
        case .stats:
            BarDrops.shared.close(.pill)
            AppWindowController.shared.open(AppPlace(.stats))
        case .empty(.calendar):
            guard let readings = Engine.shared?.barSources.readings else { return }
            if readings.calendar.refused { return readings.calendar.open(ClockCalendar.privacy) }
            Task { await readings.calendar.load(showing: readings.now, now: readings.now, timeZone: .current, ask: true) }
        case .empty(.music): NSWorkspace.shared.open(URL(filePath: "/System/Applications/Music.app"))
        // Choosing views and the pill's extensions is Menu bar › Pill.
        case .choosePages, .empty:
            BarDrops.shared.close(.pill)
            AppWindowController.shared.open(AppPlace(.menuBar))
        }
    }
}

extension PillValues.Page {
    init(_ view: Pill.View) {
        switch view {
        case .music: self = .music
        case .extensions: self = .extensions
        case .activity: self = .activity
        case .controls: self = .controls
        }
    }

    init(_ kind: PillFirst.Kind) {
        switch kind {
        case .media: self = .music
        case .calendar: self = .calendar
        case .stats: self = .stats
        case .controls: self = .controls
        case .activity: self = .activity
        case .extensions: self = .extensions
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
        PillDropFace(values: pill.dropValues, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, rail: pill.notched) { pill.act($0) }
            .modifier(Notched(on: pill.notched))
    }
}

/// The pill's item on the top bar: its compact face, the chevron turned while its drop is open; a click toggles the
/// drop under this item, on this item's screen.
struct TopBarPillItem: View {
    var pill = PillDrop.shared
    var lights = BarDropLights.shared
    @State private var anchor = ScreenAnchor.Box()

    var body: some View {
        // Read once a draw: the face, its tick and its label.
        let values = pill.values
        Button { pill.toggle(at: lights.spot(of: .pill, from: anchor)) } label: {
            Ticking(PillDrop.compactTicks(values)) { PillCompactFace(values: pill.values, open: lights.open.contains(.pill), notch: pill.notched) }
        }
        .buttonStyle(.kitPress)
        .accessibilityLabel("Pill, \(values.live?.title ?? values.title)")
        .frame(maxHeight: .infinity)
        .toyIsland(.pill)
        .onAppear { lights.register(anchor, for: .pill); pill.hold() }
        .onDisappear { lights.unregister(anchor, for: .pill); pill.release() }
        .background { ScreenAnchor(box: anchor) }
    }
}

/// The notch's tokens on the pill-first bar's drop (PillNotched); as it is elsewhere.
private struct Notched: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.modifier(PillNotched()) } else { content }
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
