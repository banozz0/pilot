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

    /// The readers `widgets` hold while the dock shows them.
    static func kinds(_ widgets: [DockWidget]) -> Set<BarKind> {
        Set(widgets.flatMap { widget -> [BarKind] in
            switch widget {
            case .aiUsage, .nowPlaying, .weather, .todo, .github, .markets: [.extensions]
            case .system: [.cpu, .memory]
            case .battery: [.battery, .bluetoothBatteries]
            case .nextEvent, .timeline: [.clock]
            case .focus: [.timer]
            }
        })
    }

    /// The extensions whose bar answers `widgets` read: asked for the dock (ExtensionBar.hold).
    static func extensions(_ widgets: [DockWidget]) -> Set<String> {
        Set(widgets.filter { $0 != .focus }.compactMap(\.extensionID))
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
        case .system: return .faces(DockFaces.system(sources.sampler.latestValues, raw: sources.sampler.latest))
        case .battery:
            // Nothing read yet: no Set up before the sampler has looked.
            if sources.readings.battery == nil, sources.sampler.latest == nil { return .faces([waiting(widget)]) }
            return DockFaces.battery(sources.readings.battery, bluetooth: sources.sampler.latest?.slow.bluetooth ?? []).map(DockWidgetBody.faces) ?? .setUp(.bluetooth)
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
        let id = widget.extensionID ?? widget.rawValue
        guard let item = extensionBar.items.first(where: { $0.id == id }) else {
            return extensionBar.listed ? .setUp(.install(id)) : .faces([waiting(widget)])
        }
        if item.problem != nil { return .setUp(.settings(id)) }
        guard let answer = item.answer else { return .faces([waiting(widget)]) }
        return faces(answer)
    }

    private func waiting(_ widget: DockWidget) -> DockFace { DockFace(glyph: .symbol(widget.symbol), label: widget.title, value: "…") }

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
