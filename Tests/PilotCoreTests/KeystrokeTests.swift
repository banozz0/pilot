import Foundation
import Testing
@testable import PilotCore

/// A keystroke Pilot posts into the focused app (card agent-bo-95422753): pressed and released as a keyboard does, so
/// macOS's modifier state is clean afterwards. Posting only the key with the Cmd flag left Command held, and every Hyper
/// key after a drive chord read as Hyper+Cmd.
@Suite("Posted keystrokes")
struct KeystrokeTests {
    @Test("Cmd+V presses Command, the key, then releases Command, ending with no flags")
    func cmdV() {
        let cmd = KeyEvent.cmdMask | KeyEvent.leftCmdDeviceMask
        #expect(KeyEvent.keystroke(9, modifiers: .cmd) == [
            KeyEvent(kind: .flagsChanged, keyCode: 55, flags: cmd),
            KeyEvent(kind: .keyDown, keyCode: 9, flags: cmd),
            KeyEvent(kind: .keyUp, keyCode: 9, flags: cmd),
            KeyEvent(kind: .flagsChanged, keyCode: 55, flags: 0),
        ])
    }

    @Test("Several modifiers release in reverse order, each step carrying exactly what is still held")
    func ctrlCmdQ() {
        let ctrl = KeyEvent.ctrlMask | 0x1, both = ctrl | KeyEvent.cmdMask | KeyEvent.leftCmdDeviceMask
        #expect(KeyEvent.keystroke(12, modifiers: [.ctrl, .cmd]) == [
            KeyEvent(kind: .flagsChanged, keyCode: 59, flags: ctrl),
            KeyEvent(kind: .flagsChanged, keyCode: 55, flags: both),
            KeyEvent(kind: .keyDown, keyCode: 12, flags: both),
            KeyEvent(kind: .keyUp, keyCode: 12, flags: both),
            KeyEvent(kind: .flagsChanged, keyCode: 55, flags: ctrl),
            KeyEvent(kind: .flagsChanged, keyCode: 59, flags: 0),
        ])
    }

    @Test("A right-side modifier uses the right key; a bare key carries no flags at all, never the source's own")
    func sidesAndBare() {
        let rightAlt = KeyEvent.altMask | 0x40
        #expect(KeyEvent.keystroke(4, modifiers: .rightAlt).map(\.keyCode) == [61, 4, 4, 61])
        #expect(KeyEvent.keystroke(4, modifiers: .rightAlt).first?.flags == rightAlt)
        #expect(KeyEvent.keystroke(8, modifiers: []) == [KeyEvent(kind: .keyDown, keyCode: 8), KeyEvent(kind: .keyUp, keyCode: 8)])
    }

    @Test("Every keystroke ends with nothing held", arguments: [Modifiers.cmd, [.shift, .cmd], [.ctrl, .alt, .cmd], .leftAlt, []])
    func endsClean(_ modifiers: Modifiers) {
        #expect(KeyEvent.keystroke(9, modifiers: modifiers).last?.flags == 0)
    }
}
