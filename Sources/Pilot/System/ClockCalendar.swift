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
}

/// The clock's popover's events (card agent-bo-95423011, SPEC story 168): the store is made, and access asked, only
/// once Show events is on in the popover, never at launch or on a plain open; nil events while access is refused.
@Observable @MainActor
final class ClockCalendar {
    /// The month grid's and the listed days' events; nil without access.
    private(set) var events: [ClockEvent]?
    /// Asked and refused: the popover says so and links Privacy & Security instead of listing events.
    private(set) var refused = false
    @ObservationIgnored private let make: @MainActor () -> CalendarStore
    /// Where a new event goes, by name, once access is given (never asked for it).
    private(set) var newEventsCalendar: String?
    @ObservationIgnored private var store: CalendarStore?
    /// The span last read, read again once an event is added.
    @ObservationIgnored private var read: DateInterval?
    /// Opens an event's link in Calendar, or Privacy & Security's Calendars pane.
    @ObservationIgnored let open: @MainActor (URL) -> Void

    init(store make: @escaping @MainActor () -> CalendarStore = { EventKitCalendar() },
         open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.make = make
        self.open = open
    }

    /// Show events is on and the popover shows `shown`'s month: asks for access if never asked, then reads the month's
    /// and the listed days' events.
    func load(showing shown: Date, now: Date, timeZone: TimeZone) async {
        let store = await granted()
        let read = ClockMonth.reading(showing: shown, now: now, timeZone: timeZone)
        self.read = read
        events = store?.events(in: read)
    }

    /// Adds `event` to the default calendar (Sven, 2026-10-23, Q420), asking for access first if never asked, as Show
    /// events does; the events shown are read again. Says what happened, for a tip.
    func add(_ event: QuickEvent) async -> String {
        guard let store = await granted() else { return "No Calendar access: give it in Privacy & Security › Calendars" }
        guard let calendar = newEventsCalendar else { return "No calendar to add to: pick a default one in Calendar's settings" }
        do { try store.add(event) } catch { return "“\(event.title)” not added: \(error.localizedDescription)" }
        if events != nil, let read { events = store.events(in: read) }
        return "Added “\(event.title)” to \(calendar), \(event.when())"
    }

    /// The store once access is given, asked for if never asked; nil when refused.
    private func granted() async -> CalendarStore? {
        let store = store ?? make()
        self.store = store
        var access = store.access
        if access == .undetermined { access = await store.requestAccess() ? .granted : .denied }
        refused = access == .denied
        guard access == .granted else { return nil }
        if newEventsCalendar == nil { newEventsCalendar = store.newEventsCalendar }
        return store
    }

    /// Privacy & Security's Calendars pane, where refused access is given.
    static let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
}

/// EventKit's events; needs NSCalendarsFullAccessUsageDescription in the bundle.
@MainActor final class EventKitCalendar: CalendarStore {
    private let store = EKEventStore()

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
            let rgb = event.calendar.flatMap { NSColor(cgColor: $0.cgColor)?.usingColorSpace(.sRGB) }
            let holiday = event.calendar.map { ClockEvent.isHolidays(calendar: $0.title, readOnly: !$0.allowsContentModifications, birthdays: $0.type == .birthday) }
            return ClockEvent(title: event.title ?? "", start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                              colour: rgb.map { Paint(UInt32($0.redComponent * 255) << 16 | UInt32($0.greenComponent * 255) << 8 | UInt32($0.blueComponent * 255)) },
                              url: event.eventIdentifier.flatMap { ClockEvent.calendarURL(id: $0, occurrence: event.hasRecurrenceRules ? event.startDate : nil) },
                              holiday: holiday ?? false)
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
