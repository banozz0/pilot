import Testing
@testable import PilotCore

/// Hyper+K is bound; no plain combo is, so a plain Cmd+K passes.
private func bound(_ key: Key) -> Bool { key.hyper && key.keyCode == KeyCode.k }

/// More than one layer key at once (Sven 2026-10-12): each alone is Hyper, all binds the same; right-hand keys only, so
/// left Command and Option stay plain.
@Suite("Layer keys")
struct LayerKeysTests {
    private let rightCmd = KeyCode.rightCommand, rightCmdDown = KeyEvent.cmdMask | 0x10

    @Test("Caps Lock and right Command: each alone turns the layer on and fires the bind")
    func eachAloneFires() {
        var layer = HyperLayer(layerKeys: [.rightCommand, .capsLock])
        #expect(layer.layerKeys == [.capsLock, .rightCommand])
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound) == .layerOn)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k), isBound: bound) == .run(Key(keyCode: KeyCode.k), autorepeat: false))
        _ = layer.handle(.init(kind: .keyUp, keyCode: KeyCode.k), isBound: bound)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18), isBound: bound) == .layerOff(quickTap: false))

        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: rightCmd, flags: rightCmdDown), isBound: bound) == .layerOn)
        // Right Command is the layer key, so its Cmd flag on the keyDown is no Cmd sublayer: the same bind runs.
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, flags: rightCmdDown), isBound: bound)
                == .run(Key(keyCode: KeyCode.k), autorepeat: false))
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: rightCmd, flags: 0), isBound: bound) == .layerOff(quickTap: false))
        #expect(!layer.isDown)
    }

    @Test("Only Caps Lock on: a right Command shortcut stays a normal shortcut")
    func rightCommandPlainWhenOff() {
        var layer = HyperLayer(layerKeys: [.capsLock])
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: rightCmd, flags: rightCmdDown), isBound: bound) == .pass)
        #expect(!layer.isDown)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, flags: rightCmdDown), isBound: bound) == .pass)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.k, flags: rightCmdDown), isBound: bound) == .pass)
    }

    @Test("Left Command never counts as a layer key, and with the layer held it is the Cmd sublayer")
    func leftCommandNeverCounts() {
        var layer = HyperLayer(layerKeys: [.capsLock, .rightCommand])
        let leftCmdDown = KeyEvent.cmdMask | KeyEvent.leftCmdDeviceMask
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: 55, flags: leftCmdDown), isBound: bound) == .pass)
        #expect(!layer.isDown)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.c, flags: leftCmdDown), isBound: bound) == .pass, "Cmd+C still copies")
        _ = layer.handle(.init(kind: .keyUp, keyCode: KeyCode.c, flags: leftCmdDown), isBound: bound)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound)
        #expect(layer.sublayer(flags: leftCmdDown) == .cmd)
        #expect(layer.sublayer(flags: rightCmdDown).isEmpty)
    }

    @Test("A second layer key while the first holds is swallowed; the first's release ends the layer, never as a tap")
    func secondKeyWhileHeld() {
        var layer = HyperLayer(layerKeys: [.capsLock, .rightCommand], quickTapEscape: true)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18, time: 0), isBound: bound) == .layerOn)
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: rightCmd, flags: rightCmdDown, time: 0.05), isBound: bound) == .swallow)
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: rightCmd, flags: 0, time: 0.1), isBound: bound) == .swallow)
        #expect(layer.isDown)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.f18, time: 0.15), isBound: bound) == .layerOff(quickTap: false))
    }

    @Test("Hyper off: Caps Lock flips Caps Lock, right Command passes")
    func off() {
        var layer = HyperLayer(layerKeys: [.capsLock, .rightCommand], isOn: false)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound) == .toggleCapsLock)
        #expect(layer.handle(.init(kind: .flagsChanged, keyCode: rightCmd, flags: rightCmdDown), isBound: bound) == .pass)
    }

    @Test("Labels name every key, Caps Lock first; a key cap shows the first's sign")
    func labels() {
        #expect([LayerKey.capsLock, .rightCommand].label == "Caps Lock or right Command")
        #expect([LayerKey.capsLock, .rightOption, .rightCommand].label == "Caps Lock, right Option or right Command")
        #expect([LayerKey.rightCommand].label == "Right Command")
        #expect([LayerKey.capsLock, .rightCommand].symbol == "⇪")
        #expect(LayerKey.parse(["rightCommand", "fn", "capsLock"]) == [.capsLock, .rightCommand])
        #expect(LayerKey.parse(["fn"]) == nil && LayerKey.ordered([]) == nil)
        // P68: both sides of Control, Option and Command; Caps Lock still first.
        #expect(LayerKey.allCases == [.capsLock, .leftControl, .rightControl, .leftOption, .rightOption, .leftCommand, .rightCommand])
        #expect(LayerKey.parse(["rightCommand", "leftOption", "rightControl", "fn"]) == [.rightControl, .leftOption, .rightCommand])
        #expect([LayerKey.capsLock, .leftCommand].label == "Caps Lock or left Command" && LayerKey.leftCommand.note.contains("right Command"))
        #expect([LayerKey.capsLock, .leftControl, .leftOption].label == "Caps Lock, left Control or left Option")
        #expect(LayerKey.ordered([.leftControl, .capsLock])?.symbol == "⇪" && [LayerKey.rightControl].symbol == "⌃")
        #expect(LayerKey.allCases.allSatisfy { ($0.deviceFlag == nil) == ($0.modifierMask == nil) && !$0.note.isEmpty })
        #expect(Set(LayerKey.allCases.map(\.pressWord)).count == LayerKey.allCases.count)
        #expect(LayerKey.hasTwins([.leftControl, .rightControl]) && !LayerKey.hasTwins([.leftControl, .rightOption, .rightCommand]))
        #expect(LayerKey.hasTwins([.leftCommand, .rightCommand]))
        // General's switches: the last key and a twin's other side are greyed; both twins stored, neither is.
        #expect(LayerKey.isLocked(.capsLock, in: [.capsLock]) && LayerKey.isLocked(.rightOption, in: [.capsLock, .leftOption]))
        #expect(!LayerKey.isLocked(.leftOption, in: [.capsLock, .leftOption]) && !LayerKey.isLocked(.rightControl, in: [.capsLock]))
        #expect(!LayerKey.isLocked(.leftOption, in: [.leftOption, .rightOption]) && !LayerKey.isLocked(.rightOption, in: [.leftOption, .rightOption]))
    }
}
