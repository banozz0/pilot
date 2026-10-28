import Foundation
import Testing
@testable import PilotCore

/// The paste the tap watches for (card agent-bo-95423071): a Cmd+V keyDown advances a paste in sequence.
@Suite("Paste key")
struct PasteKeyTests {
    @Test("Cmd+V and Cmd+Shift+V are a paste; Ctrl+Cmd+V, plain V, Cmd+C, a repeat and a keyUp are not")
    func isPaste() {
        let cmd = KeyEvent.cmdMask | KeyEvent.leftCmdDeviceMask
        #expect(KeyEvent(kind: .keyDown, keyCode: KeyCode.v, flags: cmd).isPaste)
        #expect(KeyEvent(kind: .keyDown, keyCode: KeyCode.v, flags: cmd | KeyEvent.shiftMask).isPaste)
        #expect(!KeyEvent(kind: .keyDown, keyCode: KeyCode.v, flags: cmd | KeyEvent.ctrlMask).isPaste)
        #expect(!KeyEvent(kind: .keyDown, keyCode: KeyCode.v).isPaste)
        #expect(!KeyEvent(kind: .keyDown, keyCode: 8, flags: cmd).isPaste)
        #expect(!KeyEvent(kind: .keyDown, keyCode: KeyCode.v, flags: cmd, autorepeat: true).isPaste)
        #expect(!KeyEvent(kind: .keyUp, keyCode: KeyCode.v, flags: cmd).isPaste)
    }
}
