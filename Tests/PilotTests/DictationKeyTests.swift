import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The dictation key (Q224): Right Control tapped alone toggles dictation, held with anything else it stays plain
/// Control. Driven through the tap's route with made events; the key is never taken.
@MainActor
@Suite("Dictation key")
struct DictationKeyTests {
    static let ctrl = KeyEvent.ctrlMask, rightBit = KeyEvent.rightCtrlDeviceMask, leftBit: UInt64 = 0x1

    final class Box { var decisions: [DictationKeyWatch.Decision] = []; var clicked = false; var arms = 0 }

    private func tap(_ key: DictationKey = .rightControl, _ mode: DictationKeyMode = .toggle, layer: LayerKey = .capsLock) -> (HyperTap, Box) {
        let tap = HyperTap(layer: HyperLayer(layerKey: layer))
        let box = Box()
        tap.onDictationKey = { box.decisions.append($0) }
        tap.clickedWithin = { _ in box.clicked }
        tap.armDictationHold = { _ in box.arms += 1 }
        tap.update(dictationKey: key, mode: mode)
        return (tap, box)
    }

    private func right(_ down: Bool, at time: TimeInterval, also: UInt64 = 0) -> KeyEvent {
        KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightControl, flags: (down ? Self.ctrl | Self.rightBit : 0) | also, time: time)
    }

    /// Feeds the events and expects every one to pass to the app.
    private func pass(_ tap: HyperTap, _ events: [KeyEvent]) {
        for e in events { #expect(!tap.route(e), "taken: \(e)") }
    }

    @Test("Right Control pressed and released alone under 300 ms toggles, each tap once; the key still reaches the app")
    func tapToggles() {
        let (tap, box) = tap()
        pass(tap, [right(true, at: 0), right(false, at: 0.1), right(true, at: 1), right(false, at: 1.2)])
        #expect(box.decisions == [.toggle, .toggle])
    }

    @Test("Right Control with a key between is a Ctrl shortcut: no toggle, and the key passes untouched")
    func chordIsControl() {
        let (tap, box) = tap()
        let held = Self.ctrl | Self.rightBit
        pass(tap, [right(true, at: 0), KeyEvent(kind: .keyDown, keyCode: KeyCode.c, flags: held, time: 0.05),
                   KeyEvent(kind: .keyUp, keyCode: KeyCode.c, flags: held, time: 0.08), right(false, at: 0.1)])
        #expect(box.decisions.isEmpty)
    }

    @Test("Held 300 ms or longer is no tap")
    func heldTooLong() {
        let (tap, box) = tap()
        pass(tap, [right(true, at: 0), right(false, at: DictationKeyWatch.window)])
        pass(tap, [right(true, at: 1), right(false, at: 1.29)])
        #expect(box.decisions == [.toggle])
    }

    @Test("Left Control tapped alone does nothing; Right Control pressed with Left Control or Shift held is a chord")
    func leftControlAndOtherModifiers() {
        let (tap, box) = tap()
        pass(tap, [KeyEvent(kind: .flagsChanged, keyCode: 59, flags: Self.ctrl | Self.leftBit, time: 0),
                   KeyEvent(kind: .flagsChanged, keyCode: 59, flags: 0, time: 0.1)])
        pass(tap, [right(true, at: 1, also: Self.leftBit), right(false, at: 1.1, also: Self.ctrl | Self.leftBit)])
        pass(tap, [right(true, at: 2, also: KeyEvent.shiftMask | 0x2), right(false, at: 2.1, also: KeyEvent.shiftMask | 0x2)])
        #expect(box.decisions.isEmpty)
    }

    @Test("Another modifier pressed and let go while Right Control is down: no toggle")
    func modifierBetween() {
        let (tap, box) = tap()
        let held = Self.ctrl | Self.rightBit
        pass(tap, [right(true, at: 0), KeyEvent(kind: .flagsChanged, keyCode: 56, flags: held | KeyEvent.shiftMask | 0x2, time: 0.03),
                   KeyEvent(kind: .flagsChanged, keyCode: 56, flags: held, time: 0.06), right(false, at: 0.1)])
        #expect(box.decisions.isEmpty)
    }

    @Test("A click while Right Control was down (a Ctrl+click) is no tap")
    func clickBetween() {
        let (tap, box) = tap()
        box.clicked = true
        pass(tap, [right(true, at: 0), right(false, at: 0.1)])
        #expect(box.decisions.isEmpty)
    }

    @Test("Right Control under a held Hyper is a sublayer, never dictation")
    func underHyper() {
        let (tap, box) = tap()
        #expect(tap.route(KeyEvent(kind: .keyDown, keyCode: KeyCode.f18, time: 0)))
        pass(tap, [right(true, at: 0.05), right(false, at: 0.1)])
        #expect(box.decisions.isEmpty)
    }

    @Test("Off, nothing happens; a dictation key that is a layer key is Hyper alone, and comes back once it is not")
    func offAndLayerKey() {
        let (offTap, offBox) = tap(.off)
        pass(offTap, [right(true, at: 0), right(false, at: 0.1)])
        #expect(offBox.decisions.isEmpty)

        let (tap, box) = tap(.rightOption, layer: .rightOption)
        let option = KeyEvent.altMask | LayerKey.rightOption.deviceFlag!
        #expect(tap.route(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: option, time: 0)))
        _ = tap.route(KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: 0, time: 0.1))
        #expect(box.decisions.isEmpty)
        tap.update(layerKeys: [.capsLock], quickTapEscape: false)
        pass(tap, [KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: option, time: 1),
                   KeyEvent(kind: .flagsChanged, keyCode: KeyCode.rightOption, flags: 0, time: 1.1)])
        #expect(box.decisions == [.toggle])
        #expect(DictationKey.offered(layerKeys: [.capsLock, .rightOption]) == [.off, .rightControl, .rightCommand])
        #expect(DictationKey.offered(layerKeys: [.capsLock, .rightControl]) == [.off, .rightOption, .rightCommand])
        #expect(DictationKey.offered(layerKeys: [.leftControl, .leftOption]) == DictationKey.allCases, "a left key leaves every right one free")
    }

    @Test("Hold mode: held alone past the tap window, talks until the release; a press shorter than the window does nothing")
    func holdMode() {
        let (tap, box) = tap(.rightControl, .hold)
        pass(tap, [right(true, at: 0)])
        #expect(box.arms == 1 && box.decisions.isEmpty)
        tap.dictationKeyHeld(at: DictationKeyWatch.window)
        pass(tap, [right(false, at: 2)])
        #expect(box.decisions == [.hold(true), .hold(false)])
        box.decisions = []
        pass(tap, [right(true, at: 3), right(false, at: 3.1)])
        tap.dictationKeyHeld(at: 3.3)
        #expect(box.decisions.isEmpty)
    }

    @Test("Hold mode: Right Ctrl+C, another modifier or a click before the window is plain Control: no decision at all")
    func holdChordIsControl() {
        let (tap, box) = tap(.rightControl, .hold)
        pass(tap, [right(true, at: 0), KeyEvent(kind: .keyDown, keyCode: KeyCode.c, flags: Self.ctrl | Self.rightBit, time: 0.05)])
        tap.dictationKeyHeld(at: 0.3)
        pass(tap, [right(false, at: 0.4)])
        pass(tap, [right(true, at: 1), KeyEvent(kind: .flagsChanged, keyCode: 56, flags: Self.ctrl | Self.rightBit | KeyEvent.shiftMask | 0x2, time: 1.1)])
        tap.dictationKeyHeld(at: 1.3)
        pass(tap, [right(false, at: 1.4, also: KeyEvent.shiftMask | 0x2)])
        box.clicked = true
        pass(tap, [right(true, at: 2)])
        tap.dictationKeyHeld(at: 2.3)
        pass(tap, [right(false, at: 2.5)])
        #expect(box.decisions.isEmpty)
    }

    @Test("Hold mode: a take that is running ends only at the release, whatever is pressed meanwhile")
    func takeEndsAtRelease() {
        let (tap, box) = tap(.rightControl, .hold)
        let held = Self.ctrl | Self.rightBit
        pass(tap, [right(true, at: 0)])
        tap.dictationKeyHeld(at: 0.3)
        pass(tap, [KeyEvent(kind: .flagsChanged, keyCode: 56, flags: held | KeyEvent.shiftMask | 0x2, time: 0.5),
                   KeyEvent(kind: .keyDown, keyCode: KeyCode.c, flags: held | KeyEvent.shiftMask | 0x2, time: 0.6),
                   KeyEvent(kind: .keyUp, keyCode: KeyCode.c, flags: held, time: 0.7),
                   KeyEvent(kind: .flagsChanged, keyCode: 59, flags: held | Self.leftBit, time: 0.8)])
        #expect(box.decisions == [.hold(true)])
        pass(tap, [right(false, at: 1, also: Self.ctrl | Self.leftBit)])
        #expect(box.decisions == [.hold(true), .hold(false)])
    }

    @Test("Hold mode: a timer left from an earlier press finds a fresh press too young")
    func staleTimer() {
        let (tap, box) = tap(.rightControl, .hold)
        pass(tap, [right(true, at: 0), right(false, at: 0.1), right(true, at: 0.2)])
        tap.dictationKeyHeld(at: 0.3)
        #expect(box.decisions.isEmpty)
        tap.dictationKeyHeld(at: 0.5)
        #expect(box.decisions == [.hold(true)])
    }

    @Test("A release the tap never sees (macOS turned it off) or a key change mid-hold stops the talk")
    func lostRelease() {
        let (tap, box) = tap(.rightControl, .hold)
        pass(tap, [right(true, at: 0)])
        tap.dictationKeyHeld(at: 0.3)
        tap.tapDisabled("timeout")
        #expect(box.decisions == [.hold(true), .hold(false)])
        pass(tap, [right(false, at: 1)])
        pass(tap, [right(true, at: 2)])
        tap.dictationKeyHeld(at: 2.3)
        tap.update(dictationKey: .off, mode: .hold)
        #expect(box.decisions == [.hold(true), .hold(false), .hold(true), .hold(false)])
    }

    @Test("Secure input on (a password field): a held talk stops and the key is ignored until it is off")
    func secureInput() {
        let (tap, box) = tap(.rightControl, .hold)
        pass(tap, [right(true, at: 0)])
        tap.dictationKeyHeld(at: 0.3)
        tap.setSecureInput(true)
        pass(tap, [right(false, at: 1), right(true, at: 2)])
        tap.dictationKeyHeld(at: 2.3)
        #expect(box.decisions == [.hold(true), .hold(false)] && box.arms == 1)
        tap.setSecureInput(false)
        pass(tap, [right(false, at: 3), right(true, at: 4)])
        tap.dictationKeyHeld(at: 4.3)
        #expect(box.decisions == [.hold(true), .hold(false), .hold(true)])
    }
}
