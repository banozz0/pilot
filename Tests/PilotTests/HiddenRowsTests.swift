import Foundation
import Testing
@testable import Pilot

/// Hidden rows (spec hide-rows): what a list folds under Hidden (N), and that a hide outlives the store, on a throwaway
/// defaults suite.
@MainActor
@Suite("Hidden rows")
struct HiddenRowsTests {
    private let speakers = AudioDevice(id: 10, name: "Mac mini Speakers", uid: "BuiltInSpeakerDevice")
    private let monitor = AudioDevice(id: 11, name: "24G1WG4", uid: "monitor-a")
    private let other = AudioDevice(id: 12, name: "CU34G4Z", uid: "monitor-b")
    private let noUID = AudioDevice(id: 13, name: "AB13X USB Audio")

    private func split(_ store: HiddenRows, current: UInt32 = 10) -> (shown: [String], hidden: [String]) {
        let parts = store.split([speakers, monitor, other, noUID], in: .soundOutput, id: { $0.uid }, inUse: { $0.id == current })
        return (parts.shown.map(\.name), parts.hidden.map(\.name))
    }

    @Test("A hidden row folds, keeps the list's order, and Show brings it back")
    func hideAndShow() {
        let store = HiddenRows(defaults: UserDefaults(suiteName: testSuite())!)
        store.set("monitor-b", hidden: true, in: .soundOutput)
        store.set("monitor-a", hidden: true, in: .soundOutput)
        #expect(split(store) == (["Mac mini Speakers", "AB13X USB Audio"], ["24G1WG4", "CU34G4Z"]))
        store.set("monitor-a", hidden: false, in: .soundOutput)
        #expect(split(store) == (["Mac mini Speakers", "24G1WG4", "AB13X USB Audio"], ["CU34G4Z"]))
    }

    @Test("The device in use shows even when hidden, and folds again once it is not")
    func inUseShows() {
        let store = HiddenRows(defaults: UserDefaults(suiteName: testSuite())!)
        store.set("monitor-a", hidden: true, in: .soundOutput)
        #expect(split(store, current: 11).hidden.isEmpty)
        #expect(split(store, current: 10).hidden == ["24G1WG4"])
    }

    @Test("Each list hides on its own, and a new store reads what the last one saved")
    func persists() {
        let defaults = UserDefaults(suiteName: testSuite())!
        HiddenRows(defaults: defaults).set("monitor-a", hidden: true, in: .soundOutput)
        let again = HiddenRows(defaults: defaults)
        #expect(again.isHidden("monitor-a", in: .soundOutput))
        #expect(!again.isHidden("monitor-a", in: .soundInput))
        #expect(defaults.stringArray(forKey: "hidden.soundOutput") == ["monitor-a"])
    }
}
