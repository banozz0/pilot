import Foundation
import PilotCore
import Testing
@testable import Pilot

/// A Hyper release the tap never saw (macOS turned it off, a password field had the keyboard) must not leave the layer
/// down: the tap reads the layer key's real state and lets go (Moody 2026-10-15). The key-state read is injected.
@MainActor
@Suite("Hyper release")
struct HyperReleaseTests {
    private func heldTap(_ key: LayerKey = .capsLock) -> (HyperTap, Box) {
        let tap = HyperTap(layer: HyperLayer(layerKey: key))
        let box = Box()
        tap.onLayerChange = { box.changes.append($0) }
        tap.isLayerKeyDown = { _ in box.physicallyDown }
        _ = key.deviceFlag.map { tap.route(KeyEvent(kind: .flagsChanged, keyCode: key.keyCode, flags: $0)) }
            ?? tap.route(KeyEvent(kind: .keyDown, keyCode: key.keyCode))
        #expect(tap.layer.isDown && box.changes == [true])
        return (tap, box)
    }

    final class Box { var changes: [Bool] = []; var physicallyDown = true }

    @Test("Re-enabled with the layer key up: the layer goes up, reported once")
    func releasesOnReenable() {
        let (tap, box) = heldTap()
        box.physicallyDown = false
        tap.tapDisabled("timeout")
        #expect(!tap.layer.isDown && box.changes == [true, false])
        tap.tapDisabled("user input")
        #expect(box.changes == [true, false], "nothing more to report")
        #expect(!tap.route(KeyEvent(kind: .keyDown, keyCode: 0)), "plain typing reaches the app again")
    }

    @Test("Re-enabled with the layer key still held: the layer stays down")
    func keepsHeldLayer() {
        let (tap, box) = heldTap()
        tap.tapDisabled("timeout")
        #expect(tap.layer.isDown && box.changes == [true])
        #expect(tap.route(KeyEvent(kind: .keyDown, keyCode: 0)), "still Hyper")
    }

    @Test("A key under Hyper with no lost release in sight keeps the layer, whatever Caps Lock reads now (a stalled tap)")
    func stalledKeyKeepsLayer() {
        let (tap, box) = heldTap()
        box.physicallyDown = false
        #expect(tap.route(KeyEvent(kind: .keyDown, keyCode: 0)), "still Hyper")
        #expect(tap.layer.isDown && box.changes == [true])
    }

    @Test("Once a release may be lost (lock, secure input), a key under a stuck layer with Caps Lock up lets it go")
    func keyDropsStuckLayer() {
        let (tap, box) = heldTap()
        box.physicallyDown = false
        tap.mayHaveLostRelease()
        #expect(!tap.route(KeyEvent(kind: .keyDown, keyCode: 0)))
        #expect(!tap.layer.isDown && box.changes == [true, false])
        #expect(tap.route(KeyEvent(kind: .keyUp, keyCode: KeyCode.f18)), "the late release, if it comes, is swallowed quietly")
        #expect(box.changes == [true, false])
    }

    @Test("Caps Lock read down after a possible loss: the layer stays and the next check trusts the event again")
    func heldReadClearsFlag() {
        let (tap, box) = heldTap()
        tap.mayHaveLostRelease()
        #expect(tap.route(KeyEvent(kind: .keyDown, keyCode: 0)) && !tap.releaseMayBeLost)
        box.physicallyDown = false
        #expect(tap.route(KeyEvent(kind: .keyDown, keyCode: 1)) && tap.layer.isDown)
    }

    @Test("Stopping with Hyper held lets the layer go: reported off once, never again on the next key")
    func stopDropsLayer() {
        let (tap, box) = heldTap()
        tap.stop()
        #expect(!tap.layer.isDown && box.changes == [true, false])
        _ = tap.route(KeyEvent(kind: .keyDown, keyCode: 0))
        _ = tap.route(KeyEvent(kind: .keyUp, keyCode: KeyCode.f18))
        #expect(box.changes == [true, false])
    }

    @Test("Right Command answers from the key's own device bit, not the HID read")
    func deviceBitAnswers() {
        let (tap, box) = heldTap(.rightCommand)
        box.physicallyDown = false
        #expect(tap.route(KeyEvent(kind: .keyDown, keyCode: 0, flags: KeyEvent.cmdMask | 0x10)), "bit set: still Hyper")
        #expect(tap.layer.isDown)
        #expect(!tap.route(KeyEvent(kind: .keyDown, keyCode: 0)), "bit gone: the release was lost")
        #expect(!tap.layer.isDown && box.changes == [true, false])
    }
}
