import Foundation
import Observation
import PilotCore
import Testing
@testable import Pilot

/// Where the bars drew their slots (BarFrames), for the overflow item, and the bar's items saved whole; read through
/// BarItemsStore on a scratch defaults suite. The on-bar edit mode these tests drove is parked (Q185).
@MainActor
@Suite("Bar frames")
struct BarFramesTests {
    /// The mockup's set: left Pilot, Workspaces and the focused app; centre the clock; right other apps, CPU (846 to 886),
    /// Memory, Network and the timer, each its own item; each slot reported 40 wide, 6 apart, the left from 6, the centre
    /// from 500, the right from 800.
    static func fixture() throws -> (BarFrames, BarItemsStore) {
        let store = BarItemsStore(defaults: try MenuBarStatusItemsTests.defaults()) { [:] }
        store.settings.set(.group, on: false)
        for kind in [BarKind.focusedApp, .cpu, .memory] { store.settings.set(kind, on: true) }
        let frames = BarFrames()
        for side in TopBarSide.allCases {
            let start: CGFloat = [.left: 6, .centre: 500, .right: 800][side]!
            for i in store.settings.slots(in: .topBar, topBarOn: true, side: side).indices {
                frames.report(CGRect(x: start + CGFloat(i) * 46, y: 3, width: 40, height: 24), side: side, index: i, on: "Main")
            }
        }
        return (frames, store)
    }

    @Test("The overflow lists the slots the row put off the bar for room, in the bar's order; one drawing nothing is not gone")
    func gone() throws {
        let (frames, store) = try Self.fixture()
        let sides = store.settings.preview(.topBar).top ?? [:]
        #expect(frames.gone(on: "Main", in: sides).isEmpty)
        let right = try #require(sides[.right])
        frames.report(CGRect(x: -10_040, y: 3, width: 40, height: 24), side: .right, index: 0, on: "Main")
        frames.report(CGRect(x: -10_000, y: 3, width: 0, height: 24), side: .right, index: 1, on: "Main")
        frames.report(CGRect(x: -10_080, y: 3, width: 40, height: 24), side: .right, index: 2, on: "Main")
        #expect(frames.gone(on: "Main", in: sides) == [right[0], right[2]])
        #expect(frames.gone(on: "Other", in: sides).isEmpty)
    }

    @Test("Every item and 30 extensions' items on the top bar, far more than one bar draws, are saved and read back whole (Sven on build 52: no limit)")
    func manyItemsPersist() throws {
        let defaults = try MenuBarStatusItemsTests.defaults()
        let store = BarItemsStore(defaults: defaults) { [:] }
        for kind in BarKind.allCases {
            store.settings.set(kind, on: true)
            store.settings.set(kind, placement: .topBar)
        }
        // Each reading its own slot, not gathered by the Group.
        store.settings.set(.group, on: false)
        let ids = (1...30).map { "ext-\($0)" }
        for id in ids { store.settings.set(extension: id, on: true, placement: .topBar) }
        let slots = store.settings.slots(in: .topBar, topBarOn: true)
        #expect(slots.count == BarKind.allCases.count - 1, "every item but the Group, each its own slot")

        let read = BarItemsStore(defaults: defaults) { [:] }
        #expect(read.settings == store.settings)
        #expect(read.settings.slots(in: .topBar, topBarOn: true) == slots)
        #expect(ids.allSatisfy { read.settings.shows(extension: $0, in: .topBar, topBarOn: true) })
    }
}
