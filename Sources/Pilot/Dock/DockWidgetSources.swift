import AppKit
import Observation
import PilotCore

/// What each dock widget reads (design round 3, Q215), turned into faces by DockFaces: the extensions' bar answers
/// (ExtensionBar, held for the dock so they are asked even when no bar places them), Pilot's timer, the sampler's CPU
/// and memory, the battery readings, and today's Calendar events (DockCalendar). Nothing here asks for a permission.
@MainActor
struct DockWidgetSources {
    let sources: BarSources
    var extensionBar: ExtensionBar = .shared
    var calendar: DockCalendar = .shared
    /// Whether the pomodoro extension, which starts the focus timer, is installed; read from its folder.
    var installed: (String) -> Bool = { DockWidgetSources.isInstalled($0) }

    /// The System stats widget's picks (DockWidgetOptions.stats).
    var stats: [MenuBarStats.Stat] = DockWidgetOptions.defaultStats

    /// The readers `widgets` hold while the dock shows them: System stats' the stats it shows (the sampler reads only
    /// those), an extension slot the extensions' loop.
    static func kinds(_ widgets: [DockSlot], stats: [MenuBarStats.Stat] = DockWidgetOptions.defaultStats) -> Set<BarKind> {
        Set(widgets.flatMap { slot -> [BarKind] in
            guard case .widget(let widget) = slot else { return [.extensions] }
            switch widget {
            case .aiUsage, .nowPlaying, .weather, .todo, .github, .markets: return [.extensions]
            case .system: return stats.map(BarKind.init)
            case .battery: return [.battery, .bluetoothBatteries]
            case .nextEvent, .timeline: return [.clock]
            case .focus: return [.timer]
            }
        })
    }

    /// The extensions whose bar answers `widgets` read: asked for the dock (ExtensionBar.hold).
    static func extensions(_ widgets: [DockSlot]) -> Set<String> {
        Set(widgets.compactMap(\.extensionID))
    }

    /// What `slot` draws now.
    func body(_ slot: DockSlot) -> DockWidgetBody {
        switch slot {
        case .widget(let widget): body(widget)
        // Drawn from its answer alone: its faces, gauges or text (answered).
        case .extensionItem(let id): answered(id, waiting: DockFace(glyph: .symbol(slot.symbol), label: id, value: "…")) { Self.generic($0, $1) }
        }
    }

    /// What `widget` draws now.
    func body(_ widget: DockWidget) -> DockWidgetBody {
        switch widget {
        case .aiUsage: return answered(widget) { .faces(DockFaces.aiUsage($0)) }
        case .nowPlaying:
            return answered(widget) { answer in
                .faces([DockFaces.nowPlaying(answer) ?? DockFace(glyph: .symbol("music.note"), label: "Now playing", value: "Nothing")])
            }
        case .weather:
            return answered(widget) { answer in
                // Its warn dash: no place found or set (its own Location), so Set up.
                answer.tone == .warn && DockFaces.plain(answer.text) == "–" ? .setUp(.settings(widget.rawValue)) : .faces([DockFaces.weather(answer)])
            }
        case .todo: return answered(widget) { .faces([DockFaces.todo($0)]) }
        case .github: return answered(widget) { .faces([DockFaces.github($0)]) }
        case .markets: return answered(widget) { answer in DockFaces.markets(answer).map(DockWidgetBody.faces) ?? .setUp(.settings(widget.rawValue)) }
        case .focus:
            let timer = sources.timer
            if timer.countdown == nil, let id = widget.extensionID, !installed(id) { return .setUp(.install(id)) }
            return .faces([DockFaces.focus(countdown: timer.countdown, left: timer.left, title: timer.title, paused: timer.isPaused)])
        case .system: return .faces(DockFaces.system(stats, values: sources.sampler.latestValues, raw: sources.sampler.latest))
        case .battery:
            let readings = sources.readings
            // Nothing read yet: no Set up before the battery, the draw or the sampler was looked at.
            if readings.battery == nil, readings.watts == nil, sources.sampler.latest == nil { return .faces([waiting(widget)]) }
            return DockFaces.battery(readings.battery, watts: readings.watts, bluetooth: sources.sampler.latest?.slow.bluetooth ?? []).map(DockWidgetBody.faces)
                ?? .setUp(.bluetooth)
        case .nextEvent, .timeline:
            switch calendar.access {
            case .undetermined: return .setUp(.askCalendar)
            case .denied: return .setUp(.calendarPrivacy)
            case .granted:
                let now = sources.readings.now
                return widget == .nextEvent ? .faces([DockFaces.nextEvent(calendar.events, now: now)]) : .timeline(DockFaces.timeline(calendar.events, now: now))
            }
        }
    }

    /// An extension widget: Set up while its extension is missing or answers with a problem; a quiet face while it is
    /// asked for the first time; else `faces` of its answer.
    private func answered(_ widget: DockWidget, _ faces: (Extension.BarAnswer) -> DockWidgetBody) -> DockWidgetBody {
        answered(widget.extensionID ?? widget.rawValue, waiting: waiting(widget)) { answer, _ in faces(answer) }
    }

    /// An answer carrying faces for the dock (ADR 0010, 2026-11-13) draws them, whichever widget reads it; one without
    /// goes through the widget's own mapping (`faces`), and an extension slot's through its gauges or text.
    private func answered(_ id: String, waiting: DockFace, _ faces: (Extension.BarAnswer, ExtensionBar.Item) -> DockWidgetBody) -> DockWidgetBody {
        guard let item = extensionBar.items.first(where: { $0.id == id }) else {
            return extensionBar.listed ? .setUp(.install(id)) : .faces([waiting])
        }
        if item.problem != nil { return .setUp(.settings(id)) }
        guard let answer = item.answer else { return .faces([waiting]) }
        return answer.faces.isEmpty ? faces(answer, item) : Self.generic(answer, item)
    }

    private static func generic(_ answer: Extension.BarAnswer, _ item: ExtensionBar.Item) -> DockWidgetBody {
        .faces(DockFaces.extensionItem(answer, title: item.title, icon: item.icon))
    }

    private func waiting(_ widget: DockWidget) -> DockFace { DockFace(glyph: .symbol(widget.symbol), label: widget.title, value: "…") }

    /// The installed extensions with a top bar item that no built-in widget reads: the Dock page's From extensions, and
    /// what `pilot add dock-widgets --item extension:<id>` takes. Read from the manifests, so an extension no bar shows
    /// is offered too.
    nonisolated static func barExtensions(in folder: URL = Extension.folder) -> [Extension] {
        Extension.find(in: folder).extensions.filter { $0.bar != nil && !DockWidget.extensionIDs.contains($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Whether extension `id` is installed: its folder holds a manifest.
    nonisolated static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: Extension.folder.appending(path: id).appending(path: "extension.json").path(percentEncoded: false))
    }
}

/// Today's Calendar events for the next event and day timeline widgets, read the way the clock reads them (EventKit,
/// ClockCalendar's store) but never asking: access is only read here, and asked for only by a click on Set up. Followed
/// while a widget shows them: Calendar's changes and the day's turn read again.
@Observable @MainActor
final class DockCalendar {
    static let shared = DockCalendar()

    private(set) var access: CalendarAccess = .undetermined
    /// Today's events, all-day ones and holidays among them (the faces leave those out).
    private(set) var events: [ClockEvent] = []
    @ObservationIgnored private let make: @MainActor () -> CalendarStore
    @ObservationIgnored private var store: CalendarStore?
    @ObservationIgnored private var day: Date?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var following = false

    init(store make: @escaping @MainActor () -> CalendarStore = { EventKitCalendar() }) { self.make = make }

    /// A widget shows: access read (never asked); with it, today's events read, and Calendar's changes followed.
    func follow(now: Date, calendar: Calendar = .autoupdatingCurrent) {
        following = true
        let store = store ?? make()
        self.store = store
        if access != store.access { access = store.access }
        guard access == .granted else { return }
        let today = calendar.startOfDay(for: now)
        guard today != day else { return }
        day = today
        read(store, today)
        if !observing {
            observing = true
            store.observe { [weak self] in
                guard let self, self.following, let store = self.store, let day = self.day else { return }
                self.read(store, day)
            }
        }
    }

    /// No widget shows: changes are no longer read.
    func stop() {
        following = false
        day = nil
    }

    /// Set up's click: macOS's prompt the first time, then today's events.
    func ask() async {
        let store = store ?? make()
        self.store = store
        if store.access == .undetermined { _ = await store.requestAccess() }
        access = store.access
        day = nil
        follow(now: Date())
    }

    private func read(_ store: CalendarStore, _ day: Date) {
        let found = store.events(in: DateInterval(start: day, duration: 86_400))
        if found != events { events = found }
    }
}
