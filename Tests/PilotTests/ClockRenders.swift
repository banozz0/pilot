#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The clock (card agent-bo-95423011, SPEC story 168): the date bare and the time on its accent chip, and
/// its popover with events off, given (holidays red, Q418; the New event field, Q420), refused and a day's card (build 86) in each style, at Wed 7 Oct 2026 21:04. Opt-in like the other renders, in a
/// moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-3011 PILOT_RENDER_DIR=/tmp/pilot-renders-3011 swift test --filter ClockRenders`
@MainActor
@Suite("Clock renders")
struct ClockRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    typealias Store = ClockPopoverTests.FakeStore

    static func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static let now = at(7, 21, 4)

    static func dir(_ folder: String = "clock") throws -> URL {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to draw on Sven's data")
        let dir = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"])).appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `view` at `size` on the ground, written to `url`.
    static func write(_ view: some View, size: NSSize, settle: Double = 0.6, to url: URL) throws -> NSBitmapImageRep {
        testApp()
        let shot = try rendered(view.frame(width: size.width, height: size.height).background(Theme.background).environment(\.colorScheme, .dark), wait: settle)
        try #require(shot.representation(using: .png, properties: [:])).write(to: url)
        return shot
    }

    static func sources(_ store: Store) -> BarSources {
        MenuBarStatusItemsTests.sources(SystemSamplerTests.sampler(SystemSamplerTests.Counter()), clock: { now }, calendar: ClockCalendar { store })
    }

    /// The time's chip fill, the accent at a fifth over the ground, as device RGB components.
    static func chipFill() -> [CGFloat] {
        let ground = NSColor(Theme.background).usingColorSpace(.deviceRGB)!, accent = NSColor(Theme.accent).usingColorSpace(.deviceRGB)!
        let share = BarMetrics.chip
        return [ground.redComponent * (1 - share) + accent.redComponent * share, ground.greenComponent * (1 - share) + accent.greenComponent * share,
                ground.blueComponent * (1 - share) + accent.blueComponent * share]
    }

    /// Pixels the time's chip fills, the accent at a fifth over the ground, give or take a step of rounding.
    static func chipPixels(_ shot: NSBitmapImageRep) -> Int {
        let fill = chipFill()
        var count = 0
        for x in 0..<shot.pixelsWide { for y in 0..<shot.pixelsHigh {
            guard let c = shot.colorAt(x: x, y: y) else { continue }
            if zip([c.redComponent, c.greenComponent, c.blueComponent], fill).allSatisfy({ abs($0 - $1) < 4 / 255 }) { count += 1 }
        } }
        return count
    }

    @Test("The date bare and the time on its accent chip, and the bar",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let dir = try Self.dir()
        let given = Store()
        given.events = [ClockEvent(title: "Shippers Club call", start: Self.at(7, 21, 30), end: Self.at(7, 22, 15)),
                        ClockEvent(title: "Dentist", start: Self.at(8, 10, 0), end: Self.at(8, 11, 0)),
                        ClockEvent(title: "Ship Pilot v1", start: Self.at(12, 0, 0), end: Self.at(13, 0, 0), allDay: true)]
        // The chip is behind the time and not the date: the date's target alone draws none of its fill.
        let date = try Self.write(BarPartsView(items: [[.date("Wed 7 Oct")]]).padding(6).pilotTheme().background(Theme.background),
                                  size: NSSize(width: 90, height: 30), to: dir.appendingPathComponent("date.png"))
        let time = try Self.write(BarPartsView(items: [[.time("21:04")]]).padding(6).pilotTheme().background(Theme.background),
                                  size: NSSize(width: 70, height: 30), to: dir.appendingPathComponent("time.png"))
        #expect(Self.chipPixels(date) == 0 && Self.chipPixels(time) > 100, "date \(Self.chipPixels(date)), time \(Self.chipPixels(time))")

        let bar = BarItemsStore(defaults: UserDefaults(suiteName: testSuite())!) { [:] }
        bar.settings.clockZone = "America/New_York"
        let sources = Self.sources(given)
        sources.readings.hold(.clock)
        _ = try Self.write(TopBarView(screen: "CU34G4Z", sources: sources, store: bar), size: NSSize(width: 900, height: 30),
                           settle: 1.5, to: dir.appendingPathComponent("top-bar.png"))
        sources.readings.release(.clock)
    }

    /// Each style on a dark and a light theme.
    static let looks: [(PilotStyle, String, String)] = [(.instrument, "lagoon", "dark"), (.instrument, "workshop", "light"),
                                                        (.toybox, "toybox-night", "dark"), (.toybox, "toybox", "light")]

    @Test("SPEC story 168, omarchy-ideas T8: the clock's popover in Omarchy's look (hero date, year rail, today outlined) with events off, given (a second zone, coloured events over three days) and refused, in Instrument and Toybox, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func styles() async throws {
        let dir = try Self.dir("clock-168")
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }
        let given = Store(), refused = Store()
        refused.grants = false
        let blue = Paint(0x3380FF), green = Paint(0x4CCC66)
        given.events = [ClockEvent(title: "Shippers Club call", start: Self.at(7, 21, 30), end: Self.at(7, 22, 15), colour: blue),
                        ClockEvent(title: "Dentist", start: Self.at(8, 10, 0), end: Self.at(8, 11, 0), colour: green),
                        ClockEvent(title: "Spanish class", start: Self.at(8, 18, 0), end: Self.at(8, 19, 0)),
                        ClockEvent(title: "Ship Pilot v1", start: Self.at(9, 0, 0), end: Self.at(10, 0, 0), allDay: true, colour: blue),
                        ClockEvent(title: "Gym", start: Self.at(15, 8, 0), end: Self.at(15, 9, 0), colour: green),
                        // Q418: a holiday's day red and underlined, its title a red chip.
                        ClockEvent(title: "Immaculate Conception", start: Self.at(8, 0, 0), end: Self.at(9, 0, 0), allDay: true, holiday: true),
                        ClockEvent(title: "Sette Giugno", start: Self.at(21, 0, 0), end: Self.at(22, 0, 0), allDay: true, holiday: true)]
        for (style, theme, shade) in Self.looks {
            (look.themeID, look.style) = (theme, style)
            let tokens = StyleTokens.of(style, theme: look.theme)
            // Build 86: a day's card, the 8th's holiday chip and events; the 22nd's, nothing on it, and with events off.
            for (state, store, on, picked) in [("off", given, false, nil), ("given", given, true, nil), ("refused", refused, true, nil),
                                               ("day", given, true, Self.at(8, 0, 0)), ("day-empty", given, true, Self.at(22, 0, 0)),
                                               ("day-off", given, false, Self.at(22, 0, 0))] as [(String, Store, Bool, Date?)] {
                let bar = BarItemsStore(defaults: UserDefaults(suiteName: testSuite())!) { [:] }
                bar.settings.clockZone = state == "given" ? "America/New_York" : nil
                bar.settings.clockEvents = on
                let readings = Self.sources(store).readings
                try writeRender(ClockPopover(store: bar, readings: readings, picked: picked) {}.styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                    .background(Color(tokens.colors.canvas)), to: dir.appendingPathComponent("popover-\(state)-\(style.rawValue)-\(shade).png"), wait: 0.6)
            }
        }
    }
}
}
#endif
