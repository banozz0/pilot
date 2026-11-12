import AppKit
import EventKit
import Observation
import PilotCore

/// Calendar access as the clock's popover needs it: not asked yet, given, or refused (or limited to adding events).
enum CalendarAccess { case undetermined, granted, denied }

/// The events the clock's popover reads; EventKit in the app, a fake in tests.
@MainActor protocol CalendarStore: AnyObject {
    var access: CalendarAccess { get }
    /// Asks for full access, macOS's prompt the first time; true when given.
    func requestAccess() async -> Bool
    func events(in range: DateInterval) -> [ClockEvent]
    /// Where a new event goes: Calendar's default calendar for new events; nil when there is none.
    var newEventsCalendar: String? { get }
    /// Saves `event` to that calendar.
    func add(_ event: QuickEvent) throws
    /// Asks for Reminders, macOS's prompt the first time, alongside Calendar's (T65); refused leaves events alone.
    func requestRemindersAccess() async
    /// The reminders not done yet that are due in `range`, as events; none without Reminders access.
    func reminders(in range: DateInterval) async -> [ClockEvent]
    /// Calls `changed` whenever Calendar or Reminders change, in Pilot or anywhere else.
    func observe(_ changed: @escaping @MainActor () -> Void)
}

extension CalendarStore {
    func requestRemindersAccess() async {}
    func reminders(in range: DateInterval) async -> [ClockEvent] { [] }
    func observe(_ changed: @escaping @MainActor () -> Void) {}
}

/// The clock's popover's events (card agent-bo-95423011, SPEC story 168): the store is made, and access asked, only
/// once Show events is on in the popover, never at launch or on a plain open; nil events while access is refused.
@Observable @MainActor
final class ClockCalendar {
    /// The month grid's and the listed days' events, reminders with a due day among them (T65); nil without access.
    private(set) var events: [ClockEvent]?
    /// Asked and refused: the popover says so and links Privacy & Security instead of listing events.
    private(set) var refused = false
    @ObservationIgnored private let make: @MainActor () -> CalendarStore
    /// Where a new event goes, by name, once access is given (never asked for it).
    private(set) var newEventsCalendar: String?
    @ObservationIgnored private var store: CalendarStore?
    /// The span last read, read again once an event is added.
    @ObservationIgnored private var read: DateInterval?
    /// Reminders asked for and changes followed, once Show events read with access given.
    @ObservationIgnored private var observing = false
    /// A read again is due for a burst of changes.
    @ObservationIgnored private var pending = false
    /// Opens an event's link in Calendar, or Privacy & Security's Calendars pane.
    @ObservationIgnored let open: @MainActor (URL) -> Void

    init(store make: @escaping @MainActor () -> CalendarStore = { EventKitCalendar() },
         open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.make = make
        self.open = open
    }

    /// Show events is on and the popover shows `shown`'s month: asks for access if never asked, then reads the month's
    /// and the listed days' events. Without `ask` (the pill-first bar's compact face) access never asked reads nothing.
    func load(showing shown: Date, now: Date, timeZone: TimeZone, ask: Bool = true) async {
        let store = await granted(ask: ask)
        let read = ClockMonth.reading(showing: shown, now: now, timeZone: timeZone)
        self.read = read
        guard let store else { events = nil; return }
        if !observing {
            observing = true
            store.observe { [weak self] in self?.changed() }
            // Reminders' own prompt comes after the events show; their reminders join once it is answered.
            Task { await store.requestRemindersAccess(); await refresh() }
        }
        await reread(store, read)
    }

    /// Calendar or Reminders changed, here or anywhere: one read again for a burst of changes.
    private func changed() {
        guard !pending else { return }
        pending = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            pending = false
            await refresh()
        }
    }

    /// The span last read, read again once events were read.
    private func refresh() async {
        guard events != nil, let store, let read else { return }
        await reread(store, read)
    }

    /// Reads `span`'s events and reminders, unless a later read replaced it while Reminders answered.
    private func reread(_ store: CalendarStore, _ span: DateInterval) async {
        let reminders = await store.reminders(in: span)
        guard span == read else { return }
        events = store.events(in: span) + reminders
    }

    /// Adds `event` to the default calendar (Sven, 2026-10-23, Q420), asking for access first if never asked, as Show
    /// events does; the events shown are read again. Says what happened, for a tip.
    func add(_ event: QuickEvent) async -> String {
        guard let store = await granted() else { return "No Calendar access: give it in Privacy & Security › Calendars" }
        guard let calendar = newEventsCalendar else { return "No calendar to add to: pick a default one in Calendar's settings" }
        do { try store.add(event) } catch { return "“\(event.title)” not added: \(error.localizedDescription)" }
        await refresh()
        return "Added “\(event.title)” to \(calendar), \(event.when())"
    }

    /// The store once access is given, asked for if never asked and `ask`; nil when refused or not asked.
    private func granted(ask: Bool = true) async -> CalendarStore? {
        let store = store ?? make()
        self.store = store
        var access = store.access
        if access == .undetermined, !ask { return nil }
        if access == .undetermined { access = await store.requestAccess() ? .granted : .denied }
        refused = access == .denied
        guard access == .granted else { return nil }
        if newEventsCalendar == nil { newEventsCalendar = store.newEventsCalendar }
        return store
    }

    /// Privacy & Security's Calendars pane, where refused access is given.
    static let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
    /// Privacy & Security's Reminders pane.
    static let remindersPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
}

/// EventKit's events and reminders; needs NSCalendarsFullAccessUsageDescription and NSRemindersFullAccessUsageDescription
/// in the bundle.
@MainActor final class EventKitCalendar: CalendarStore {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .undetermined
        case .fullAccess: .granted
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func events(in range: DateInterval) -> [ClockEvent] {
        store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)).map { event in
            let holiday = event.calendar.map { ClockEvent.isHolidays(calendar: $0.title, readOnly: !$0.allowsContentModifications, birthdays: $0.type == .birthday) }
            return ClockEvent(title: event.title ?? "", start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                              colour: Self.paint(event.calendar),
                              url: event.eventIdentifier.flatMap { ClockEvent.calendarURL(id: $0, occurrence: event.hasRecurrenceRules ? event.startDate : nil) },
                              holiday: holiday ?? false)
        }
    }

    /// A calendar's or a Reminders list's colour.
    nonisolated private static func paint(_ calendar: EKCalendar?) -> Paint? {
        calendar.flatMap { NSColor(cgColor: $0.cgColor)?.usingColorSpace(.sRGB) }
            .map { Paint(UInt32($0.redComponent * 255) << 16 | UInt32($0.greenComponent * 255) << 8 | UInt32($0.blueComponent * 255)) }
    }

    func requestRemindersAccess() async {
        guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined else { return }
        _ = try? await store.requestFullAccessToReminders()
    }

    /// Read only; a reminder due on a day with no time is that whole day, else a moment at its due time. A click opens
    /// Calendar, which lists reminders too.
    func reminders(in range: DateInterval) async -> [ClockEvent] {
        guard await Self.hasFullAccess(to: .reminder) else { return [] }
        let due = store.predicateForIncompleteReminders(withDueDateStarting: range.start, ending: range.end, calendars: nil)
        return await withCheckedContinuation { done in
            store.fetchReminders(matching: due, completion: Self.reply(done))
        }
    }

    /// Whether full access to `entity` was given, read off the main thread: `authorizationStatus` is a synchronous call to
    /// the calendar daemon, and every calendar widget's refresh asks (lean audit 2026-11-05: 15 of the main thread's 44
    /// busy samples with widgets shown). Never asks.
    nonisolated static func hasFullAccess(to entity: EKEntityType) async -> Bool {
        await Task.detached { EKEventStore.authorizationStatus(for: entity) == .fullAccess }.value
    }

    /// EventKit calls this on its own reminders queue (com.apple.eventkit.reminders.search), so it is built outside the
    /// main actor: a closure written in `reminders(in:)` would inherit @MainActor and trap Swift's isolation check there
    /// (build 2045's crash on opening the clock drop).
    nonisolated private static func reply(_ done: CheckedContinuation<[ClockEvent], Never>) -> @Sendable ([EKReminder]?) -> Void {
        { found in
            let calendar = Calendar.autoupdatingCurrent
            done.resume(returning: (found ?? []).compactMap { reminder in
                guard let parts = reminder.dueDateComponents, let start = calendar.date(from: parts) else { return nil }
                let allDay = parts.hour == nil, day = calendar.startOfDay(for: start)
                return allDay
                    ? ClockEvent(title: reminder.title ?? "", start: day, end: calendar.date(byAdding: .day, value: 1, to: day) ?? day,
                                 allDay: true, colour: paint(reminder.calendar))
                    : ClockEvent(title: reminder.title ?? "", start: start, end: start, colour: paint(reminder.calendar))
            })
        }
    }

    func observe(_ changed: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { changed() }
        }
    }

    var newEventsCalendar: String? { store.defaultCalendarForNewEvents?.title }

    func add(_ quick: QuickEvent) throws {
        let event = EKEvent(eventStore: store)
        event.title = quick.title
        event.startDate = quick.start
        event.endDate = quick.end
        event.isAllDay = quick.allDay
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
    }
}
