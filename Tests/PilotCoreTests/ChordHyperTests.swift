import Testing
@testable import PilotCore

/// A real cmd+ctrl+alt chord from the keyboard (the Keychron knob macros) counts as Hyper for keys Pilot binds.
@Suite("Chord Hyper")
struct ChordHyperTests {
    private let chord: UInt64 = 0x100000 | 0x40000 | 0x80000   // cmd, ctrl, alt
    private func bound(_ key: Key) -> Bool { key.keyCode == KeyCode.k && key.hyper }

    @Test("A bound chord runs its bind and its keyDown and keyUp are swallowed")
    func boundChordConsumed() {
        var layer = HyperLayer(layerKey: .capsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, flags: chord), isBound: bound) == .run(Key(keyCode: KeyCode.k), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.k, flags: chord), isBound: bound) == .swallow)
        #expect(!layer.isDown)
    }

    @Test("Shift in the chord marks the bind; its keyUp is swallowed even after the modifiers are let go")
    func shiftChord() {
        var layer = HyperLayer(layerKey: .capsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, flags: chord | KeyEvent.shiftMask), isBound: { $0 == Key(keyCode: KeyCode.k, shift: true) })
                == .run(Key(keyCode: KeyCode.k, shift: true), autorepeat: false))
        #expect(layer.handle(.init(kind: .keyUp, keyCode: KeyCode.k), isBound: bound) == .swallow)
    }

    @Test("An unbound chord passes through, keyDown and keyUp, so another app's hotkey still sees it")
    func unboundChordPasses() {
        var layer = HyperLayer(layerKey: .capsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 18, flags: chord), isBound: bound) == .pass)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: 18, flags: chord), isBound: bound) == .pass)
    }

    @Test("Two of the three modifiers is no chord")
    func partialChordPasses() {
        var layer = HyperLayer(layerKey: .capsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, flags: 0x100000 | 0x40000), isBound: bound) == .pass)
    }

    @Test("A press while the layer key is held is unaffected by the chord")
    func layerHeldUnaffected() {
        var layer = HyperLayer(layerKey: .capsLock)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.f18), isBound: bound)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: 18, flags: chord), isBound: bound) == .unbound(Key(keyCode: 18)))
        #expect(layer.handle(.init(kind: .keyUp, keyCode: 18, flags: chord), isBound: bound) == .swallow)
    }

    @Test("A bound chord's repeat is reported as a repeat")
    func chordRepeat() {
        var layer = HyperLayer(layerKey: .capsLock)
        _ = layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, flags: chord), isBound: bound)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: KeyCode.k, flags: chord, autorepeat: true), isBound: bound) == .run(Key(keyCode: KeyCode.k), autorepeat: true))
    }
}
