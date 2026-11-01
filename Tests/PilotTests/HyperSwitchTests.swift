import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The Hyper key's own switch (card agent-bo-95422986), over a fake of the tap: no test stops the real one.
@MainActor
@Suite("Hyper switch")
struct HyperSwitchTests {
    @Test("Off and on reach the tap, and the dropdown's Hyper switch is that switch")
    func togglesTheTap() {
        var applied: [Bool] = []
        let hyper = SessionSwitch { applied.append($0) }
        #expect(hyper.isOn)
        hyper.toggle()
        #expect(!hyper.isOn && applied == [false])
        hyper.toggle()
        #expect(hyper.isOn && applied == [false, true])
        let switches = QuickSwitches(hyper: hyper, tiling: DropdownQuickSwitchesTests.Fake(true), topBar: DropdownQuickSwitchesTests.Fake(false),
                                     keepAwake: DropdownQuickSwitchesTests.Fake(false), clipboard: DropdownQuickSwitchesTests.Fake(true), dictation: DropdownQuickSwitchesTests.Fake(true))
        switches[.hyper].toggle()
        #expect(!hyper.isOn && applied == [false, true, false])
    }

    @Test("Hyper comes back on at every launch: a new switch is on, whatever the last one was left at")
    func onAtLaunch() {
        let last = SessionSwitch { _ in }
        last.toggle()
        #expect(!last.isOn)
        #expect(SessionSwitch { _ in }.isOn)
    }

    @Test("The tap's Hyper off holds over a new layer key, and nothing reports a layer change while it was up")
    func tapKeepsOff() {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        var changes: [Bool] = []
        tap.onLayerChange = { changes.append($0) }
        tap.setHyper(true)
        tap.setHyper(false)
        #expect(changes.isEmpty && !tap.layer.isOn)
        tap.update(layerKeys: [.rightOption], quickTapEscape: false)
        #expect(!tap.layer.isOn, "a new layer key keeps Hyper off")
        tap.setHyper(true)
        #expect(tap.layer.isOn)
    }
}
