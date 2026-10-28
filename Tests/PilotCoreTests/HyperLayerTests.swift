import Testing
@testable import PilotCore

private func bound(_ key: Key) -> Bool { key.keyCode == KeyCode.k }

@Suite("Hyper layer")
struct HyperLayerTests {
    @Test("Caps Lock (F18) keyDown turns the layer on, keyUp turns it off")
    func capsLockToggles() {
        var layer = HyperLayer(layerKey: .capsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound) == .layerOn)
        #expect(layer.isDown)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18), isBound: bound) == .layerOff(quickTap: false))
        #expect(!layer.isDown)
    }

    @Test("Each modifier layer key toggles through its device flag",
          arguments: [LayerKey.leftControl, .rightControl, .leftOption, .rightOption, .leftCommand, .rightCommand])
    func modifierToggles(key: LayerKey) {
        var layer = HyperLayer(layerKey: key)
        let flag = key.deviceFlag! | key.modifierMask!
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: key.keyCode, flags: flag), isBound: bound) == .layerOn)
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: key.keyCode, flags: 0), isBound: bound) == .layerOff(quickTap: false))
    }

    @Test("Left Option does not turn the right Option layer on")
    func leftOptionIgnored() {
        var layer = HyperLayer(layerKey: .rightOption)
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: 58, flags: 0x20), isBound: bound) == .pass)
    }

    @Test("A modifier layer key's other side is that modifier as before: no layer, its combos and typing pass (P68)")
    func otherSidePasses() {
        // Each picked side, then the other side's key code and device bit.
        let pairs: [(LayerKey, Int64, UInt64)] = [(.leftControl, KeyCode.rightControl, LayerKey.rightControl.deviceFlag!),
                                                  (.rightControl, KeyCode.leftControl, LayerKey.leftControl.deviceFlag!),
                                                  (.leftOption, KeyCode.rightOption, LayerKey.rightOption.deviceFlag!),
                                                  (.rightOption, KeyCode.leftOption, LayerKey.leftOption.deviceFlag!),
                                                  (.leftCommand, KeyCode.rightCommand, LayerKey.rightCommand.deviceFlag!),
                                                  (.rightCommand, KeyCode.leftCommand, LayerKey.leftCommand.deviceFlag!)]
        for (key, other, bit) in pairs {
            var layer = HyperLayer(layerKey: key)
            let held = key.modifierMask! | bit
            #expect(layer.handle(.init(kind: .flagsChanged, keyCode: other, flags: held), isBound: bound) == .pass, "\(key)")
            #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.c, flags: held), isBound: bound) == .pass, "\(key)")
            #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.c, flags: held), isBound: bound) == .pass, "\(key)")
            #expect(!layer.isDown, "\(key)")
        }
    }

    @Test("The same key code with the other side's device bit is no layer key: a release of one side while the other holds")
    func keyCodeAndBit() {
        var layer = HyperLayer(layerKey: .leftOption)
        let leftBit = LayerKey.leftOption.deviceFlag!, rightBit = LayerKey.rightOption.deviceFlag!
        let both = KeyEvent.altMask | leftBit | rightBit
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: KeyCode.leftOption, flags: both), isBound: bound) == .layerOn)
        // Left Option comes up while right Option stays down: the mask is still set, the left bit is not.
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: KeyCode.leftOption, flags: KeyEvent.altMask | rightBit), isBound: bound)
                == .layerOff(quickTap: false))
    }

    @Test("A bound key while held runs; an unbound key is swallowed; keyUp is swallowed")
    func keysWhileHeld() {
        var layer = HyperLayer(layerKey: .capsLock)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k), isBound: bound) == .run(Key(keyCode: KeyCode.k), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.k), isBound: bound) == .swallow)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 11), isBound: bound) == .unbound(Key(keyCode: 11)))
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, autorepeat: true), isBound: bound) == .run(Key(keyCode: KeyCode.k), autorepeat: true))
    }

    @Test("Shift while held passes through and marks the bind")
    func shiftMarksTheBind() {
        var layer = HyperLayer(layerKey: .capsLock)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound)
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: 56, flags: KeyEvent.shiftMask), isBound: bound) == .pass)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, flags: KeyEvent.shiftMask), isBound: { _ in false })
                == .unbound(Key(keyCode: KeyCode.k, shift: true)))
    }

    @Test("Shift+Caps Lock toggles the real Caps Lock and never turns the layer on")
    func shiftCapsLockTogglesCaps() {
        var layer = HyperLayer(layerKey: .capsLock, quickTapEscape: true)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, flags: KeyEvent.shiftMask), isBound: bound) == .toggleCapsLock)
        #expect(!layer.isDown)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, flags: KeyEvent.shiftMask), isBound: bound) == .swallow)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k), isBound: bound) == .pass)
    }

    @Test("Holding Shift+Caps Lock toggles once: repeats are swallowed, with or without Shift, and the layer stays off")
    func shiftCapsLockRepeat() {
        var layer = HyperLayer(layerKey: .capsLock, quickTapEscape: true)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, flags: KeyEvent.shiftMask, time: 1.0), isBound: bound) == .toggleCapsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, flags: KeyEvent.shiftMask, autorepeat: true, time: 1.3), isBound: bound) == .swallow)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, autorepeat: true, time: 1.4), isBound: bound) == .swallow)
        #expect(!layer.isDown)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 1.5), isBound: bound) == .swallow)
    }

    @Test("Shift pressed after Caps Lock is held is the Shift sublayer, not Caps Lock")
    func shiftAfterHoldIsSublayer() {
        var layer = HyperLayer(layerKey: .capsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound) == .layerOn)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, flags: KeyEvent.shiftMask, autorepeat: true), isBound: bound) == .swallow)
        #expect(layer.isDown)
    }

    @Test("Keys pass through when the layer is up")
    func passWhenUp() {
        var layer = HyperLayer(layerKey: .capsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k), isBound: bound) == .pass)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18), isBound: bound) == .swallow)
    }

    @Test("Autorepeat of the layer key while held is swallowed, not a second layerOn")
    func layerKeyRepeat() {
        var layer = HyperLayer(layerKey: .capsLock)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, autorepeat: true), isBound: bound) == .swallow)
        #expect(layer.isDown)
    }

    @Test("Quick tap sends Escape only when enabled, nothing pressed, and short")
    func quickTap() {
        var layer = HyperLayer(layerKey: .capsLock, quickTapEscape: true, quickTapWindow: 0.2)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 1.0), isBound: bound)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 1.1), isBound: bound) == .layerOff(quickTap: true))

        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 2.0), isBound: bound)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 2.5), isBound: bound) == .layerOff(quickTap: false))

        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 3.0), isBound: bound)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, time: 3.05), isBound: bound)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 3.1), isBound: bound) == .layerOff(quickTap: false))

        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 4.0), isBound: bound)
        _ = layer.handle(.init(kind: .keyDown, keyCode: 11, time: 4.05), isBound: bound)   // unbound key still counts
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 4.1), isBound: bound) == .layerOff(quickTap: false))

        var off = HyperLayer(layerKey: .capsLock, quickTapEscape: false)
        _ = off.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 1.0), isBound: bound)
        #expect(off.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 1.05), isBound: bound) == .layerOff(quickTap: false))
    }

    @Test("A hold long enough to show the overlay is no tap: no Escape once the overlay showed (card agent-bo-95422993, G10)")
    func noEscapeAfterOverlay() {
        var layer = HyperLayer(layerKey: .capsLock, quickTapEscape: true)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 1.0), isBound: bound)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 1.0 + HoldOverlay.delay * 0.75), isBound: bound) == .layerOff(quickTap: true))

        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 2.0), isBound: bound)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 2.0 + HoldOverlay.delay + 0.02), isBound: bound) == .layerOff(quickTap: false))
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 3.0), isBound: bound)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 3.6), isBound: bound) == .layerOff(quickTap: false))
    }
}

/// Sublayers (story 50): Shift, Ctrl, Alt and Shift+Ctrl held with the layer key pick another bind.
@Suite("Hyper sublayers")
struct SublayerTests {
    private let shift = KeyEvent.shiftMask, ctrl = KeyEvent.ctrlMask, alt = KeyEvent.altMask

    @Test("Ctrl, Alt and Shift+Ctrl held with Caps Lock reach the bind as its sublayer")
    func capsLockSublayers() {
        var layer = HyperLayer(layerKey: .capsLock)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: { _ in true })
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: ctrl), isBound: { _ in true }) == .run(Key("t", .ctrl), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: alt), isBound: { _ in true }) == .run(Key("t", .alt), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: shift | ctrl), isBound: { _ in true }) == .run(Key("t", [.shift, .ctrl]), autorepeat: false))
    }

    @Test("Right Option as the layer key is not the Alt sublayer; left Option with it is")
    func rightOptionLayerAlt() {
        var layer = HyperLayer(layerKey: .rightOption)
        let held = alt | LayerKey.rightOption.deviceFlag!
        _ = layer.handle(.init(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: held), isBound: { _ in true })
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: held), isBound: { _ in true }) == .run(Key("t"), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: held | KeyEvent.leftAltDeviceMask), isBound: { _ in true }) == .run(Key("t", .alt), autorepeat: false))
    }

    @Test("Left Option as the layer key is not the Alt sublayer; right Option with it is")
    func leftOptionLayerAlt() {
        var layer = HyperLayer(layerKey: .leftOption)
        let held = alt | LayerKey.leftOption.deviceFlag!
        _ = layer.handle(.init(kind: .flagsChanged, keyCode: KeyCode.leftOption, flags: held), isBound: { _ in true })
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: held), isBound: { _ in true }) == .run(Key("t"), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: held | LayerKey.rightOption.deviceFlag!), isBound: { _ in true }) == .run(Key("t", .alt), autorepeat: false))
    }

    @Test("A Control layer key is no Ctrl sublayer; the other Control with it is; Option and Command still are", arguments: [
        (LayerKey.leftControl, LayerKey.rightControl), (.rightControl, .leftControl),
    ])
    func controlLayerCtrl(key: LayerKey, other: LayerKey) {
        let otherBit = other.deviceFlag!
        var layer = HyperLayer(layerKey: key)
        let held = ctrl | key.deviceFlag!
        _ = layer.handle(.init(kind: .flagsChanged, keyCode: key.keyCode, flags: held), isBound: { _ in true })
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: held), isBound: { _ in true }) == .run(Key("t"), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: held | otherBit), isBound: { _ in true }) == .run(Key("t", .ctrl), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: held | alt | KeyEvent.leftAltDeviceMask), isBound: { _ in true }) == .run(Key("t", .alt), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: held | shift), isBound: { _ in true }) == .run(Key("t", .shift), autorepeat: false))
    }

    @Test("Both Options as layer keys (an old store or a hand edit; the settings refuse it): Alt is never a sublayer; either one holds the layer")
    func bothOptions() {
        var layer = HyperLayer(layerKeys: [.leftOption, .rightOption])
        let left = alt | LayerKey.leftOption.deviceFlag!, both = left | LayerKey.rightOption.deviceFlag!
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: KeyCode.leftOption, flags: left), isBound: { _ in true }) == .layerOn)
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: both), isBound: { _ in true }) == .swallow)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: both), isBound: { _ in true }) == .run(Key("t"), autorepeat: false))
    }

    @Test("Left Command as the layer key: left Cmd+C is Hyper+C; right Command with it is the Cmd sublayer")
    func leftCommandLayer() {
        var layer = HyperLayer(layerKey: .leftCommand)
        let held = KeyEvent.cmdMask | LayerKey.leftCommand.deviceFlag!
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: KeyCode.leftCommand, flags: held), isBound: { _ in true }) == .layerOn)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.c, flags: held), isBound: { _ in true }) == .run(Key("c"), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.c, flags: held | LayerKey.rightCommand.deviceFlag!), isBound: { _ in true })
                == .run(Key("c", .cmd), autorepeat: false))
    }

    @Test("Right Command as the layer key is no Cmd modifier on the bind")
    func rightCommandLayerCmd() {
        var layer = HyperLayer(layerKey: .rightCommand)
        let held = KeyEvent.cmdMask | LayerKey.rightCommand.deviceFlag!
        _ = layer.handle(.init(kind: .flagsChanged, keyCode: KeyCode.rightCommand, flags: held), isBound: { _ in true })
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 17, flags: held | ctrl), isBound: { _ in true }) == .run(Key("t", .ctrl), autorepeat: false))
    }
}
