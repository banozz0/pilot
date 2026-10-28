import Testing
@testable import PilotCore

private let h = Key("h").keyCode
private let rightOptionDown = KeyEvent.altMask | 0x40

/// Hyper off (card agent-bo-95422986): the layer key and chord Hyper stop, every key does what macOS says; plain combos
/// are not Hyper and still run, so a plain-combo bind of the Hyper switch turns it back on.
@Suite("Hyper off")
struct HyperOffTests {
    @Test("Caps Lock with Hyper off is Caps Lock again: its press flips Caps Lock, never the layer, and Hyper+H passes")
    func capsLockIsCapsLock() {
        var layer = HyperLayer(layerKey: .capsLock)
        layer.isOn = false
        let f18 = LayerKey.capsLock.keyCode
        #expect(layer.handle(.init(kind: .keyDown, keyCode: f18), isBound: { _ in true }) == .toggleCapsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: f18, autorepeat: true), isBound: { _ in true }) == .swallow)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: h), isBound: { _ in true }) == .pass)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: f18), isBound: { _ in true }) == .swallow)
        #expect(!layer.isDown)
    }

    @Test("Right Option with Hyper off passes as plain Option, and the key after it passes too")
    func rightOptionPasses() {
        var layer = HyperLayer(layerKey: .rightOption)
        layer.isOn = false
        let ropt = LayerKey.rightOption.keyCode
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: ropt, flags: rightOptionDown), isBound: { _ in true }) == .pass)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: h, flags: KeyEvent.altMask), isBound: { $0.hyper }) == .pass)
        #expect(!layer.isDown)
    }

    @Test("A bound chord passes with Hyper off, so the app in front gets cmd+ctrl+alt")
    func chordPasses() {
        var layer = HyperLayer(layerKey: .capsLock)
        layer.isOn = false
        #expect(layer.handle(.init(kind: .keyDown, keyCode: h, flags: KeyEvent.chordMask), isBound: { _ in true }) == .pass)
    }

    @Test("A plain-combo bind still runs with Hyper off")
    func plainComboRuns() {
        let bind = Key(keyCode: h, modifiers: .ctrl, hyper: false)
        var layer = HyperLayer(layerKey: .capsLock)
        layer.isOn = false
        #expect(layer.handle(.init(kind: .keyDown, keyCode: h, flags: KeyEvent.ctrlMask), isBound: { $0 == bind }) == .run(bind, autorepeat: false))
    }

    @Test("Switched off while held, the layer lets go: the next key passes, and on again Hyper works as before")
    func offWhileHeldThenOn() {
        var layer = HyperLayer(layerKey: .capsLock)
        let f18 = LayerKey.capsLock.keyCode
        #expect(layer.handle(.init(kind: .keyDown, keyCode: f18), isBound: { _ in true }) == .layerOn)
        layer.isOn = false
        #expect(!layer.isDown)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: h), isBound: { _ in true }) == .pass)
        layer.isOn = true
        #expect(layer.handle(.init(kind: .keyDown, keyCode: f18), isBound: { _ in true }) == .layerOn)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: h), isBound: { _ in true }) == .run(Key(keyCode: h, modifiers: []), autorepeat: false))
    }
}
