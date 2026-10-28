import Testing
@testable import PilotCore

/// Card agent-bo-95422775: Hyper went from Caps Lock to right Command on 2026-10-05 with no log line and no question.
@Suite("Layer key change")
struct LayerKeyChangeTests {
    @Test("Only turning Caps Lock off asks first; adding a key never does")
    func asks() {
        #expect(LayerKey.asksFirst(from: [.capsLock], to: [.rightCommand]))
        #expect(LayerKey.asksFirst(from: [.capsLock], to: [.rightOption]))
        #expect(LayerKey.asksFirst(from: [.capsLock, .rightCommand], to: [.rightCommand]))
        #expect(!LayerKey.asksFirst(from: [.rightCommand], to: [.capsLock]))
        #expect(!LayerKey.asksFirst(from: [.rightCommand], to: [.rightOption]))
        #expect(!LayerKey.asksFirst(from: [.capsLock], to: [.capsLock]))
        #expect(!LayerKey.asksFirst(from: [.capsLock], to: [.capsLock, .rightCommand]))
        #expect(!LayerKey.asksFirst(from: [.capsLock, .rightCommand], to: [.capsLock]))
    }

    @Test("A change logs old, new and where it came from")
    func line() {
        #expect(LayerKey.changeLine([.capsLock], [.capsLock, .rightCommand], .settings)
                == "layer keys capsLock -> capsLock,rightCommand (settings)")
        #expect(LayerKey.changeLine([.rightCommand], [.capsLock], .onboarding) == "layer keys rightCommand -> capsLock (onboarding)")
    }
}
