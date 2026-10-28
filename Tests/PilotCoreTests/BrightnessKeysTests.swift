import Testing
@testable import PilotCore

/// Card agent-bo-95423314 (story 144): the keyboard's own brightness keys as system-defined events, and when the tap
/// takes them. Pure decoding; no event is made or posted.
@Suite("Brightness keys")
struct BrightnessKeysTests {
    /// data1 as macOS packs it: the key type in the high 16 bits, the state in bits 8 to 15, a repeat in bit 0.
    func data1(_ key: Int, down: Bool, repeats: Bool = false) -> Int { key << 16 | (down ? 0x0A : 0x0B) << 8 | (repeats ? 1 : 0) }

    @Test("Brightness up and down, pressed, released and held, decode from subtype 8")
    func decodes() {
        #expect(BrightnessKeys.press(subtype: 8, data1: data1(2, down: true)) == .init(up: true, isDown: true, isRepeat: false))
        #expect(BrightnessKeys.press(subtype: 8, data1: data1(3, down: true)) == .init(up: false, isDown: true, isRepeat: false))
        #expect(BrightnessKeys.press(subtype: 8, data1: data1(2, down: false)) == .init(up: true, isDown: false, isRepeat: false))
        #expect(BrightnessKeys.press(subtype: 8, data1: data1(3, down: true, repeats: true)) == .init(up: false, isDown: true, isRepeat: true))
    }

    @Test("Every other system-defined event is none: volume, mute, play, the keyboard light, another subtype")
    func othersAreNone() {
        // NX_KEYTYPE_SOUND_UP 0, SOUND_DOWN 1, MUTE 7, PLAY 16, ILLUMINATION_UP 21.
        for key in [0, 1, 7, 16, 21] { #expect(BrightnessKeys.press(subtype: 8, data1: data1(key, down: true)) == nil) }
        // Subtype 7 carries mouse buttons; the same bits there are no key.
        #expect(BrightnessKeys.press(subtype: 7, data1: data1(2, down: true)) == nil)
        // A state that is neither down nor up.
        #expect(BrightnessKeys.press(subtype: 8, data1: 2 << 16) == nil)
    }

    func press(up: Bool = true, down: Bool = true, repeats: Bool = false) -> BrightnessKeys.Press {
        .init(up: up, isDown: down, isRepeat: repeats)
    }

    @Test("Taken only with the switch on and a route to the screen; off, no control or not read yet pass to macOS")
    func routing() {
        for (switchOn, route, taken) in [(true, BrightnessRoute.ddc, true), (true, .apple, true), (false, .ddc, false),
                                         (true, BrightnessRoute.none, false), (true, nil, false)] as [(Bool, BrightnessRoute?, Bool)] {
            var router = BrightnessKeys.Router<String>()
            let answer = router.route(press(), switchOn: switchOn) { ("CU34G4Z", route) }
            #expect(answer.taken == taken && answer.step == (taken ? "CU34G4Z" : nil))
        }
        var router = BrightnessKeys.Router<String>()
        #expect(router.route(press(), switchOn: true) { nil } == (false, nil), "no focused screen")
    }

    @Test("The first press decides: its repeats step the same screen without asking, its key up is taken and ends it")
    func heldKey() {
        var router = BrightnessKeys.Router<String>()
        var asked = 0
        let target = { () -> (screen: String, route: BrightnessRoute?)? in asked += 1; return ("CU34G4Z", .ddc) }
        #expect(router.route(press(), switchOn: true, target: target) == (true, "CU34G4Z"))
        #expect(router.route(press(repeats: true), switchOn: true, target: target) == (true, "CU34G4Z"))
        #expect(router.route(press(down: false), switchOn: true, target: target) == (true, nil))
        #expect(asked == 1)
        // After the key up, a stray repeat or up is macOS's.
        #expect(router.route(press(repeats: true), switchOn: true, target: target) == (false, nil))
        #expect(router.route(press(down: false), switchOn: true, target: target) == (false, nil))
    }

    @Test("With the switch off the screen is never asked for, and a passed press's repeats and up pass too")
    func offAsksNothing() {
        var router = BrightnessKeys.Router<String>()
        var asked = 0
        let target = { () -> (screen: String, route: BrightnessRoute?)? in asked += 1; return ("CU34G4Z", .ddc) }
        #expect(router.route(press(), switchOn: false, target: target) == (false, nil))
        #expect(router.route(press(repeats: true), switchOn: true, target: target) == (false, nil))
        #expect(router.route(press(down: false), switchOn: true, target: target) == (false, nil))
        #expect(asked == 0)
    }
}
