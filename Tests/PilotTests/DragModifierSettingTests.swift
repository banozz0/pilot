import CoreGraphics
import Foundation
import Observation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422930: the Alt+drag modifier is a stored, observed setting that reaches the mouse tap at once.
@MainActor
@Suite("MouseDrag setting")
struct DragModifierSettingTests {
    @Test("Alt by default; a change notifies observers, reaches the engine's hook and is read back at the next launch")
    func stored() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let item = LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {}))
        let settings = PilotSettings(defaults: defaults, loginItem: item)
        #expect(settings.dragModifier == .alt)
        nonisolated(unsafe) var fired = 0
        var applied = 0
        settings.onDragModifierChange = { applied += 1 }
        withObservationTracking { _ = settings.dragModifier } onChange: { fired += 1 }
        settings.dragModifier = .cmd
        #expect(fired == 1 && applied == 1)
        #expect(PilotSettings(defaults: defaults, loginItem: item).dragModifier == .cmd)
    }

    /// SwiftUI builds no accessibility tree offscreen without an AX client, so the picker's rows are checked through the
    /// options the section draws from; the opt-in page renders (AppWindowRenders) draw it on the Tiling page.
    @Test("Tiling's Mouse section offers Off, Alt, Ctrl, Cmd, Fn and Hyper under its label, Fn and Hyper with a tip")
    func picker() {
        #expect(MouseDragSection.options.map(\.title) == ["Off", "Alt", "Ctrl", "Cmd", "Fn", "Hyper"])
        #expect(MouseDragSection.tips[.fn] == "Only keyboards that send Fn, like Apple's.")
        #expect(Set(MouseDragSection.tips.keys) == [.fn, .hyper])
        #expect(MouseDragSection.options.map(\.value) == DragModifier.allCases)
        #expect(MouseDragSection.label == "Drag windows holding")
    }

    /// The mouse tap asks the keyboard tap's layer; the keyboard tap never sees the mouse, so no bind runs.
    @Test("A drag with the layer held starts, fires no bind, and closes the hold overlay as a key would")
    func hyperDrag() throws {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        tap.isBound = { _ in true }
        var ran = 0, unbound = 0, keys = 0
        tap.onRun = { _, _ in ran += 1 }
        tap.onUnbound = { _, _ in unbound += 1 }
        tap.onKey = { keys += 1 }
        let window = (id: 7, frame: CGRect(x: 0, y: 0, width: 800, height: 600)), at = CGPoint(x: 100, y: 100)
        #expect(MouseDrag.begin(.left, flags: 0, hyper: tap.isHeldAlone(flags: 0), at: at, modifier: .hyper, window: window) == nil)
        #expect(tap.route(.init(kind: .keyDown, keyCode: KeyCode.f18)))
        let drag = try #require(MouseDrag.begin(.left, flags: 0, hyper: tap.isHeldAlone(flags: 0), at: at, modifier: .hyper, window: window))
        #expect(drag.kind == .move)
        tap.layerUsed()
        #expect(tap.route(.init(kind: .keyUp, keyCode: KeyCode.f18)))
        #expect(ran == 0 && unbound == 0 && keys == 1)
        tap.layerUsed()   // the layer is up: nothing
        #expect(keys == 1)
    }

    /// Card agent-bo-95423002: Translate's language pair, read by the menu on each translation.
    @Test("Translate's pair is English and Spanish by default; a change is observed and read back at the next launch")
    func translatePair() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let item = LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {}))
        let settings = PilotSettings(defaults: defaults, loginItem: item)
        #expect(settings.translatePair == .standard)
        nonisolated(unsafe) var fired = 0
        withObservationTracking { _ = settings.translatePair } onChange: { fired += 1 }
        settings.translatePair = try #require(TranslatePair(home: "en", other: "fr"))
        #expect(fired == 1)
        #expect(PilotSettings(defaults: defaults, loginItem: item).translatePair == TranslatePair(home: "en", other: "fr"))
    }
}
