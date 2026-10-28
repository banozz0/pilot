import Foundation
@testable import PilotCore
import Testing

/// Each workspace's Monitor pick (N7): saved in Pilot's defaults, started once from the old AeroSpace config's table, read as an import, and offered as
/// Any, Main and the displays macOS names.
@Suite struct WorkspaceMonitorsTests {
    static let file = """
        [workspace-to-monitor-force-assignment]
            1 = 'CU34G4Z'
            2 = 'main'
        """
    static let lg = ConnectedDisplay(name: "LG ULTRAFINE", id: "B")
    static let wide = ConnectedDisplay(name: "CU34G4Z", id: "A")

    @Test func firstReadCarriesAeroSpacesTableOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        #expect(WorkspaceMonitors.pins(in: defaults, carryingFrom: Self.file, displays: []) == ["1": .display(name: "CU34G4Z", id: nil), "2": .main])
        // Saved: the file is not read again, so a pin Sven sets sticks whatever the table says.
        #expect(WorkspaceMonitors.pins(in: defaults, carryingFrom: "", displays: []) == ["1": .display(name: "CU34G4Z", id: nil), "2": .main])
        WorkspaceMonitors.save(["3": Self.lg.pin, "4": Self.lg.pin], in: defaults)
        #expect(WorkspaceMonitors.pins(in: defaults, carryingFrom: Self.file, displays: []) == ["3": Self.lg.pin, "4": Self.lg.pin])
        // All back to Any is saved too, never carried over again.
        WorkspaceMonitors.save([:], in: defaults)
        #expect(WorkspaceMonitors.pins(in: defaults, carryingFrom: Self.file, displays: []) == [:])
    }

    @Test func nothingToCarrySavesNothing() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        #expect(WorkspaceMonitors.pins(in: defaults, carryingFrom: "", displays: []) == [:])
        #expect(defaults.data(forKey: WorkspaceMonitors.key) == nil)
    }

    /// A display is matched by its id, so its twin of the same name is not it; a carried-over pin has only a name.
    @Test func matchingByIdThenName() {
        let twin = ConnectedDisplay(name: "LG ULTRAFINE", id: "C")
        #expect(Self.lg.matches(Self.lg.pin))
        #expect(!twin.matches(Self.lg.pin))
        #expect(twin.matches(.display(name: "lg ultrafine", id: nil)))
        #expect(!Self.lg.matches(.main))
    }

    /// A carried name that is a connected display's becomes that display, id and all; the rest keep their name.
    @Test func carriedNamesBecomeConnectedDisplays() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let file = "[workspace-to-monitor-force-assignment]\n1 = 'CU34G4Z'\n4 = '24G1WG4'\n"
        #expect(WorkspaceMonitors.pins(in: defaults, carryingFrom: file, displays: [Self.wide, Self.lg])
            == ["1": Self.wide.pin, "4": .display(name: "24G1WG4", id: nil)])
    }

    @Test func choicesOfferAnyMainAndEachDisplay() {
        let pick = WorkspaceMonitors.choices(pinned: nil, displays: [Self.wide, Self.lg])
        #expect(pick.choices.map(\.title) == ["Any", "Main", "CU34G4Z", "LG ULTRAFINE"])
        #expect(pick.choices.map(\.value) == [nil, .main, Self.wide.pin, Self.lg.pin])
        #expect(pick.picked == nil)
    }

    /// Unplugged, the pinned display stays in the pick, so it still says where the workspace goes back to.
    @Test func unpluggedDisplayStaysInThePick() {
        let pick = WorkspaceMonitors.choices(pinned: Self.lg.pin, displays: [Self.wide])
        #expect(pick.choices.map(\.title) == ["Any", "Main", "CU34G4Z", "LG ULTRAFINE (unplugged)"])
        #expect(pick.choices.last?.value == Self.lg.pin)
        #expect(pick.picked == Self.lg.pin)
    }

    /// A name-only pin lights its connected display; unmatched it is picked as it is.
    @Test func nameOnlyPinLightsItsDisplay() {
        #expect(WorkspaceMonitors.choices(pinned: .display(name: "CU34G4Z", id: nil), displays: [Self.wide, Self.lg]).picked == Self.wide.pin)
        let gone = MonitorPin.display(name: "24G1WG4", id: nil)
        #expect(WorkspaceMonitors.choices(pinned: gone, displays: [Self.wide]).picked == gone)
        #expect(WorkspaceMonitors.choices(pinned: .main, displays: [Self.wide]).picked == .main)
    }
}
