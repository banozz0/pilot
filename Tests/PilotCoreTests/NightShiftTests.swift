import Testing
@testable import PilotCore

/// Card agent-bo-95422972: Night Shift's switch on a fake client; no test changes the real Night Shift.
@Suite("Night Shift")
struct NightShiftTests {
    final class Fake: NightShiftClient {
        var on: Bool?
        var refuses = false
        var sets: [Bool] = []
        init(_ on: Bool?) { self.on = on }
        func isOn() -> Bool? { on }
        func set(_ on: Bool) -> Bool {
            sets.append(on)
            if !refuses { self.on = on }
            return !refuses
        }
    }

    @Test("From off it turns on, from on it turns off, each saying so")
    func toggles() {
        let c = Fake(false)
        #expect(NightShift.toggle(c) == "Night Shift on")
        #expect(c.on == true)
        #expect(NightShift.toggle(c) == "Night Shift off")
        #expect(c.sets == [true, false])
    }

    @Test("Not available sets nothing; a refused set says macOS refused")
    func problems() {
        let gone = Fake(nil)
        #expect(NightShift.toggle(gone) == "Night Shift is not available on this Mac")
        #expect(gone.sets.isEmpty)
        let stuck = Fake(false)
        stuck.refuses = true
        #expect(NightShift.toggle(stuck) == "macOS refused to change Night Shift")
    }

    @Test("Night Shift and lock when idle sit in the menu's Display and Power")
    func omarchyKeys() {
        #expect(MenuLayout.rows[MenuLayout.system("Display")]?.contains(.action("system.nightShift")) == true)
        #expect(MenuLayout.rows[MenuLayout.system("Power")]?.contains(.action("system.idleLock")) == true)
    }
}
