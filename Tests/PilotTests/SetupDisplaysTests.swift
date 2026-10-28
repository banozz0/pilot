import CoreGraphics
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Setup › Displays (card agent-bo-95422804): every screen with its resolution, refresh rate, rotation and place, and a
/// resolution change that goes back by itself after 15 s unless kept. Every case runs on a fake; no test changes a real
/// display mode.
@MainActor
@Suite("Setup displays")
struct SetupDisplaysTests {
    static let wide = DisplayMode(id: 1, width: 3440, height: 1440, pixelWidth: 3440, refresh: 100)
    static let wideLow = DisplayMode(id: 2, width: 2560, height: 1080, pixelWidth: 2560, refresh: 60)
    static let portrait = DisplayMode(id: 7, width: 1440, height: 2560, pixelWidth: 1440, refresh: 60)

    final class FakeDisplays: DisplaySystem {
        var screens = [
            DisplayInfo(id: 1, name: "CU34G4Z", main: true, frame: CGRect(x: 0, y: 0, width: 3440, height: 1440), mode: wide, rotation: 0),
            DisplayInfo(id: 2, name: "24G1WG4", main: false, frame: CGRect(x: 3440, y: -560, width: 1440, height: 2560), mode: portrait, rotation: 90),
        ]
        var modesByDisplay: [UInt32: [DisplayMode]] = [1: [wide, wideLow], 2: [portrait]]
        var applied: [(mode: DisplayMode, display: UInt32, permanently: Bool)] = []

        func displays() -> [DisplayInfo] { screens }
        func modes(_ display: UInt32) -> [DisplayMode] { modesByDisplay[display] ?? [] }
        func apply(_ mode: DisplayMode, to display: UInt32, permanently: Bool) throws {
            applied.append((mode, display, permanently))
            if let i = screens.firstIndex(where: { $0.id == display }) { screens[i].mode = mode }
        }
    }

    typealias FakeTime = SetupKeepAwakeTests.FakeTime

    /// A section on a fake with two screens, started, and the clock its timers run on.
    static func started(_ fake: FakeDisplays = FakeDisplays()) -> (FakeDisplays, FakeTime, SetupDisplays) {
        let time = FakeTime(), section = SetupDisplays(system: fake, after: time.after)
        section.start()
        return (fake, time, section)
    }

    @Test("Both screens listed with resolution, refresh rate, rotation and the main one marked")
    func lists() {
        let (fake, _, section) = Self.started()
        #expect(section.displays.map(\.name) == ["CU34G4Z", "24G1WG4"])
        #expect(section.displays.map(\.main) == [true, false])
        #expect(section.displays[0].mode.label == "3440 × 1440 · 100 Hz")
        #expect(section.displays[1].rotation == 90)
        #expect(fake.applied.isEmpty)
    }

    @Test("Picking a mode applies it for the session once; 15 s without Keep puts the old one back")
    func revertsByItself() {
        let (fake, time, section) = Self.started()
        section.pick(Self.wideLow, for: 1)
        #expect(fake.applied.count == 1 && fake.applied[0].mode == Self.wideLow && !fake.applied[0].permanently)
        #expect(section.pending?.display == 1 && time.timers.count == 1)
        time.pass(14.9)
        #expect(fake.applied.count == 1)
        time.pass(0.1)
        #expect(fake.applied.count == 2 && fake.applied[1].mode == Self.wide && !fake.applied[1].permanently)
        #expect(section.pending == nil && section.displays[0].mode == Self.wide)
    }

    @Test("Keep makes the new mode permanent once, and nothing goes back after")
    func keep() {
        let (fake, time, section) = Self.started()
        section.pick(Self.wideLow, for: 1)
        section.keep()
        #expect(fake.applied.count == 2 && fake.applied[1].mode == Self.wideLow && fake.applied[1].permanently)
        #expect(section.pending == nil && time.timers.isEmpty)
        time.pass(60)
        #expect(fake.applied.count == 2)
    }

    @Test("Revert puts the old mode back at once; picking the mode in use changes nothing")
    func revert() {
        let (fake, time, section) = Self.started()
        section.pick(Self.wide, for: 1)
        #expect(fake.applied.isEmpty && section.pending == nil)
        section.pick(Self.wideLow, for: 1)
        section.revert()
        #expect(fake.applied.map(\.mode) == [Self.wideLow, Self.wide] && time.timers.isEmpty && section.pending == nil)
    }

    @Test("A screen with one mode offers no picker")
    func oneMode() {
        let (fake, _, section) = Self.started()
        #expect(section.modes(for: 1).count == 2 && section.modes(for: 2).count == 1)
        #expect(section.offersPicker(1) && !section.offersPicker(2))
    }

    @Test("The size picker shows each size once, at the rate in use; the rate picker shows the size in use's rates")
    func sizesAndRates() {
        let fake = FakeDisplays()
        let wide60 = DisplayMode(id: 3, width: 3440, height: 1440, pixelWidth: 3440, refresh: 60)
        let low100 = DisplayMode(id: 4, width: 2560, height: 1080, pixelWidth: 2560, refresh: 100)
        fake.modesByDisplay[1] = [Self.wide, wide60, low100, Self.wideLow]
        let (_, _, section) = Self.started(fake)
        #expect(section.sizes(for: 1) == [Self.wide, low100])
        #expect(section.rates(for: 1) == [Self.wide, wide60])
        // The mode in use under another encoding id than the one the list kept still selects its rate.
        let sameRateOtherID = DisplayMode(id: 99, width: 3440, height: 1440, pixelWidth: 3440, refresh: 100)
        fake.screens[0].mode = sameRateOtherID
        section.start()
        #expect(section.selectedRate(for: 1) == Self.wide)
        fake.screens[0].mode = Self.wide
        section.start()
        section.pick(wide60, for: 1)
        #expect(section.sizes(for: 1) == [wide60, Self.wideLow] && section.selectedSize(for: 1) == wide60)
    }

    @Test("A HiDPI mode says so: points, then the pixels behind them")
    func hiDPI() {
        let retina = DisplayMode(id: 9, width: 1920, height: 1080, pixelWidth: 3840, refresh: 60)
        #expect(retina.label == "1920 × 1080 · 60 Hz · HiDPI" && retina.sizeLabel == "1920 × 1080 · HiDPI")
    }

    /// The real screens on this Mac, read-only: opt-in like every live test. Lists; never applies a mode.
    @Test("CoreGraphics lists this Mac's displays and their modes", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func live() {
        let system = CoreGraphicsDisplays()
        let screens = system.displays()
        #expect(!screens.isEmpty && screens.filter(\.main).count == 1)
        for s in screens { print("live: \(s.name) \(s.mode.label) rotation \(s.rotation) at \(s.frame) · \(system.modes(s.id).count) modes") }
    }
}
