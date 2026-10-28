import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The dropdown's quick switches (card agent-bo-95422912): each reaches its own switch, on fakes, so no test pauses
/// the tiler, hides the menu bar, keeps the Mac awake or stops the clipboard.
@MainActor
@Suite("Dropdown quick switches")
struct DropdownQuickSwitchesTests {
    final class Fake: QuickSwitchable {
        var isOn: Bool
        var toggles = 0
        init(_ on: Bool) { isOn = on }
        func toggle() { toggles += 1; isOn.toggle() }
    }

    @Test("Each switch toggles its own: Tiling, the top bar, Keep awake and the clipboard's recording")
    func eachItsOwn() async throws {
        // Tiling over a fake tiler: it sends enable off, then enable on; clipboard over a fake watcher.
        var sent: [Bool] = [], recorded: [Bool] = []
        let tiling = TilingSwitch(answering: { true }, enable: { sent.append($0) })
        let clipboard = SessionSwitch { recorded.append($0) }
        let power = SetupKeepAwakeTests.FakePower()
        let keepAwake = KeepAwake(power: power)
        let panels = TopBarControllerTests.FakePanels()
        let topBar = TopBarControllerTests.make(TopBarControllerTests.defaults(), panels: panels)
        let switches = QuickSwitches(hyper: Fake(true), tiling: tiling, topBar: topBar, keepAwake: keepAwake, clipboard: clipboard)
        #expect(Dropdown.Switch.allCases.map { switches[$0].isOn } == [true, true, false, false, true])
        switches[.tiling].toggle()
        #expect(try await SystemSamplerTests.wait { sent == [false] && !tiling.isOn })
        switches[.tiling].toggle()
        #expect(try await SystemSamplerTests.wait { sent == [false, true] && tiling.isOn })
        switches[.clipboard].toggle()
        switches[.clipboard].toggle()
        #expect(recorded == [false, true] && clipboard.isOn)
        switches[.keepAwake].toggle()
        #expect(keepAwake.isOn && power.held.count == 1)
        switches[.keepAwake].toggle()
        #expect(!keepAwake.isOn && power.held.isEmpty)
        // The top bar's switch goes through its own controller: the fake autohide and panels, never the real menu bar.
        switches[.topBar].toggle()
        await TopBarControllerTests.settle(topBar)
        #expect(topBar.isOn && !panels.shown.isEmpty)
        switches[.topBar].toggle()
        await TopBarControllerTests.settle(topBar)
        #expect(!topBar.isOn && panels.shown.isEmpty)
    }

    @Test("Tiling is off while the tiler does not answer, and a refused enable changes nothing")
    func tilingRefused() async throws {
        struct Refused: Error {}
        var tries = 0
        let silent = TilingSwitch(answering: { false }, enable: { _ in })
        #expect(!silent.isOn)
        let refusing = TilingSwitch(answering: { true }, enable: { _ in tries += 1; throw Refused() })
        refusing.toggle()
        #expect(try await SystemSamplerTests.wait { tries == 1 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(refusing.isOn)
    }
}
