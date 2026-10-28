import CoreGraphics
import PilotCore
import Testing
@testable import Pilot

/// The tap watches every Cmd+V go by, Pilot's own included, for a paste in sequence (card agent-bo-95423071), and lets
/// each one through. Events are made, never posted.
@MainActor
@Suite("Paste tap")
struct PasteTapTests {
    func event(_ key: Int64, flags: CGEventFlags, own: Bool = false, down: Bool = true) throws -> CGEvent {
        let e = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down))
        e.flags = flags
        if own { e.setIntegerValueField(.eventSourceUserData, value: HyperTap.ownEventMark) }
        return e
    }

    @Test("A Cmd+V, the user's or Pilot's own, is reported and passed through; Cmd+C and a keyUp are not reported")
    func reportsPastes() throws {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        var pastes = 0
        tap.onPaste = { pastes += 1 }
        for (e, type) in [(try event(KeyCode.v, flags: .maskCommand), CGEventType.keyDown),
                          (try event(KeyCode.v, flags: .maskCommand, own: true), .keyDown),
                          (try event(8, flags: .maskCommand), .keyDown),
                          (try event(KeyCode.v, flags: .maskCommand, down: false), .keyUp)] {
            #expect(tap.handle(type: type, event: e) != nil)
        }
        #expect(pastes == 2)
    }

    @Test("With right Command as the layer key, Hyper+V carries Command but the tap takes it: no paste is reported")
    func layerKeyCommandIsNoPaste() throws {
        let tap = HyperTap(layer: HyperLayer(layerKey: .rightCommand))
        var pastes = 0
        tap.onPaste = { pastes += 1 }
        let held = CGEventFlags(rawValue: KeyEvent.cmdMask | LayerKey.rightCommand.deviceFlag!)
        let down = try event(KeyCode.rightCommand, flags: held)
        _ = tap.handle(type: .flagsChanged, event: down)
        #expect(tap.handle(type: .keyDown, event: try event(KeyCode.v, flags: held)) == nil)
        #expect(pastes == 0)
    }
}
