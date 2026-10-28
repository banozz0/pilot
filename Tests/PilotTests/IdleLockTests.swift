import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422972: lock when idle on keep-awake with a fake power assertion, and the two actions' registration.
/// No action that changes Night Shift is run.
@MainActor
@Suite("Lock when idle")
struct IdleLockTests {
    @Test("Off holds keep-awake until turned off, on releases it, and keep-awake's own length is left alone")
    func toggles() {
        let power = SetupKeepAwakeTests.FakePower()
        let awake = KeepAwake(power: power)
        awake.select(.fourHours)
        #expect(awake.toggleIdleLock() == "Lock when idle off: the screen stays awake until you turn it back on")
        #expect(awake.isOn && awake.until == nil)
        #expect(awake.state(at: .now) == "On until you turn it off")
        #expect(power.held.values.contains(KeepAwake.assertionName))
        #expect(awake.toggleIdleLock() == "Lock when idle on")
        #expect(!awake.isOn && power.held.isEmpty)
        #expect(awake.length == .fourHours)
    }

    @Test("Night Shift and lock when idle are registered System actions with no default key")
    func registered() throws {
        var registry = ActionRegistry()
        SystemModule.register(into: &registry)
        for (id, label) in [("system.nightShift", "Night Shift on or off"), ("system.idleLock", "Lock when idle on or off")] {
            let action = try #require(registry.actions[id])
            #expect(action.label == label)
            #expect(action.defaultKey == nil)
        }
    }
}
