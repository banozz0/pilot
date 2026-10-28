import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Setup › Keep awake (card agent-bo-95422801). Every case runs on fakes: no test holds a real power assertion.
@MainActor
@Suite("Setup keep-awake")
struct SetupKeepAwakeTests {
    final class FakePower: PowerAssertions {
        var held: [UInt32: String] = [:]
        var types: [String] = []
        var created = 0
        func hold(_ type: String, _ name: String) -> UInt32? {
            created += 1
            types.append(type)
            held[UInt32(created)] = name
            return UInt32(created)
        }
        func release(_ id: UInt32) { held[id] = nil }
    }

    /// A clock the test moves, and the timers the model asked for, fired when it passes them; a cancelled one never fires.
    @MainActor
    final class FakeTime {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var timers: [(id: Int, at: Date, fire: @MainActor () -> Void)] = []
        private var made = 0
        func after(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Watch {
            made += 1
            let id = made
            timers.append((id, now + seconds, fire))
            return Watch { [weak self] in self?.timers.removeAll { $0.id == id } }
        }
        func pass(_ seconds: TimeInterval) {
            now += seconds
            let due = timers.filter { $0.at <= now }
            timers.removeAll { $0.at <= now }
            for timer in due { timer.fire() }
        }
    }

    static func model(_ power: FakePower, _ time: FakeTime) -> KeepAwake {
        KeepAwake(power: power, now: { time.now }, after: time.after)
    }

    @Test("On for an hour holds one display-sleep assertion, and the hour passing lets it go")
    func hour() {
        let power = FakePower(), time = FakeTime(), awake = Self.model(power, time)
        awake.turnOn(.hour)
        #expect(power.held.count == 1 && power.held.values.first == KeepAwake.assertionName)
        #expect(power.types == ["PreventUserIdleDisplaySleep"])
        #expect(awake.until == time.now + 3600)
        time.pass(3599)
        #expect(power.held.count == 1 && awake.isOn)
        time.pass(1)
        #expect(power.held.isEmpty && !awake.isOn && awake.until == nil)
    }

    @Test("Off lets the assertion go; on twice still holds one; an earlier run's timer is cancelled, never ends a newer run")
    func onOff() {
        let power = FakePower(), time = FakeTime(), awake = Self.model(power, time)
        awake.turnOn(.hour)
        awake.select(.fourHours)
        #expect(power.held.count == 1 && awake.until == time.now + 4 * 3600 && time.timers.count == 1)
        time.pass(3600)
        #expect(awake.isOn)
        awake.turnOff()
        #expect(time.timers.isEmpty)
        #expect(power.held.isEmpty && !awake.isOn)
        awake.turnOn(.untilOff)
        #expect(power.held.count == 1 && awake.isOn && awake.until == nil)
        // The 4-hour run's timer went with it.
        #expect(time.timers.isEmpty)
        time.pass(5 * 3600)
        #expect(power.held.count == 1 && awake.isOn)
        awake.turnOff()
        #expect(power.held.isEmpty)
    }

    @Test("A fresh model holds nothing: keep-awake never starts by itself")
    func neverAtLaunch() {
        let power = FakePower(), awake = Self.model(power, FakeTime())
        #expect(!awake.isOn && power.created == 0)
        // Picking a length while off turns nothing on.
        awake.select(.fourHours)
        #expect(!awake.isOn && power.created == 0 && awake.length == .fourHours)
    }

    @Test("Keep awake is an action in the System menu, bindable, with no default key")
    func action() {
        var registry = ActionRegistry()
        SystemModule.register(into: &registry)
        let action = registry.actions["system.keepAwake"]
        #expect(action?.label == "Keep awake on or off" && action?.defaultKey == nil)
        #expect(MenuLayout.rows[MenuLayout.system("Power")]?.contains(.action("system.keepAwake")) == true)
    }

    /// Two enabled layouts for the renders, which read nothing of the Mac's.
    final class FakeSources: InputSourceSystem {
        func all() -> [InputSource] {
            [InputSource(id: "com.apple.keylayout.British-PC", name: "British – PC", isKeyboard: true, isEnabled: true, isSelectable: true, isCurrent: true),
             InputSource(id: "com.apple.keylayout.ABC", name: "ABC", isKeyboard: true, isEnabled: true, isSelectable: true, isCurrent: false)]
        }
        func select(_ id: String) throws {}
    }
}
