import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The clock's popover in the app (card agent-bo-95423011, SPEC story 168): Calendar access is asked only once Show
/// events is on, never at launch or on a plain open, and with access denied the popover shows the month and the second
/// zone, no events and where to give access. A fake event store; EventKit is never touched.
@MainActor
@Suite("Clock popover")
struct ClockPopoverTests {
    @MainActor final class FakeStore: CalendarStore {
        var access: CalendarAccess = .undetermined
        var grants = true
        var requests = 0
        var events: [ClockEvent] = []

        func requestAccess() async -> Bool {
            requests += 1
            access = grants ? .granted : .denied
            return grants
        }

        func events(in range: DateInterval) -> [ClockEvent] { events.filter { $0.overlaps(range) } }
        var newEventsCalendar: String? { nil }
        func add(_ event: QuickEvent) throws {}
    }

    static func readings(_ calendar: ClockCalendar) -> BarReadings {
        MenuBarStatusItemsTests.sources(SystemSamplerTests.sampler(SystemSamplerTests.Counter()), calendar: calendar).readings
    }

    /// Shows the popover in an offscreen window until its first read is done. SwiftUI builds no accessibility tree for
    /// an offscreen host, so the tests check what the popover read; the renders show what it draws.
    static func show(_ readings: BarReadings, events: Bool = true) throws {
        let store = BarItemsStore(defaults: UserDefaults(suiteName: testSuite())!) { [:] }
        store.settings.clockEvents = events
        testApp()
        _ = try rendered(ClockPopover(store: store, readings: readings) {}.frame(width: ClockPopover.width), wait: 0.3)
    }

    @Test("No access request at launch or on opens with Show events off; exactly one once it is on, none after")
    func asksOnlyWithShowEvents() throws {
        let fake = FakeStore()
        fake.events = [Self.call]
        var made = 0
        let readings = Self.readings(ClockCalendar { made += 1; return fake })
        // Launch: the bar draws its clock; nothing asks EventKit for anything.
        readings.hold(.clock)
        defer { readings.release(.clock) }
        #expect(made == 0 && fake.requests == 0)
        // The popover opened, Show events off: still no store, no ask, no events.
        try Self.show(readings, events: false)
        try Self.show(readings, events: false)
        #expect(made == 0 && fake.requests == 0 && readings.calendar.events == nil && !readings.calendar.refused)
        try Self.show(readings)
        #expect(fake.requests == 1 && readings.calendar.events == [Self.call])
        try Self.show(readings)
        #expect(fake.requests == 1)
    }

    @Test("Access given before but Show events off: the popover reads nothing")
    func grantedButOff() throws {
        let fake = FakeStore()
        fake.access = .granted
        var made = 0
        let readings = Self.readings(ClockCalendar { made += 1; return fake })
        try Self.show(readings, events: false)
        #expect(made == 0 && readings.calendar.events == nil)
    }

    static let call = ClockEvent(title: "Shippers Club call", start: Date().addingTimeInterval(60), end: Date().addingTimeInterval(120))

    @Test("With Show events on and access granted the popover reads the month's and the next days' events")
    func granted() throws {
        let fake = FakeStore()
        fake.events = [Self.call]
        let readings = Self.readings(ClockCalendar { fake })
        try Self.show(readings)
        #expect(readings.calendar.events == [Self.call])
    }

    @Test("With access denied the popover reads no events: no events row, only that access is off")
    func denied() throws {
        let fake = FakeStore()
        fake.grants = false
        fake.events = [Self.call]
        let readings = Self.readings(ClockCalendar { fake })
        try Self.show(readings)
        #expect(fake.requests == 1 && readings.calendar.events == nil && readings.calendar.refused)
        // Refused before: never asked again, still no events.
        try Self.show(readings)
        #expect(fake.requests == 1 && readings.calendar.events == nil && readings.calendar.refused)
    }

    @Test("The second-zone menu offers None, then every zone by city, and keeps a zone set outside the list")
    func zoneChoices() {
        let plain = ClockPopover.zoneChoices(nil)
        #expect(plain.first?.id == nil && plain.first?.title == "None")
        #expect(plain.count == ClockPopover.zones.count + 1)
        #expect(plain.contains { $0.id == "America/Bogota" && $0.title == "Bogota" })
        let odd = ClockPopover.zoneChoices("Pacific/Auckland")
        #expect(odd.count == ClockPopover.zones.count + 2 && odd.contains { $0.id == "Pacific/Auckland" })
        #expect(ClockPopover.zoneChoices("Europe/Malta").count == plain.count)
    }
}
