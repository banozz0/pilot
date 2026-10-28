import Foundation
import Testing
@testable import PilotCore

/// Mouse button binds (Q184): a mouse's buttons and the media keys it sends as triggers, how the tap routes them, and
/// their place in binds.json, which stays version 3.
@Suite("Mouse keys")
struct MouseKeysTests {
    func data1(_ key: Int, down: Bool, repeats: Bool = false) -> Int { key << 16 | (down ? 0x0A : 0x0B) << 8 | (repeats ? 1 : 0) }

    @Test("Each trigger has a name that reads back, apart from every keyboard key")
    func names() {
        for (key, name) in [(MouseKeys.button(3), "Mouse 4"), (MouseKeys.button(2), "Mouse 3"), (MouseKeys.media(17), "Mouse Next"),
                            (MouseKeys.media(16), "Mouse Play"), (MouseKeys.media(9), "Mouse Media 9")] {
            #expect(key.label == name && !key.hyper)
            #expect(KeyNames.code(for: name) == key.keyCode && KeyNames.code(for: name.lowercased()) == key.keyCode)
            #expect(KeyNames.names[key.keyCode] == nil, "the keyboard's key list never gains a mouse trigger")
        }
        #expect(MouseKeys.isButton(MouseKeys.button(4).keyCode) && MouseKeys.isMedia(MouseKeys.media(18).keyCode))
        #expect(!MouseKeys.isMouse(Key("F9").keyCode) && KeyNames.code(for: "Mouse") == nil)
    }

    @Test("A media key decodes from subtype 8 only, with its state and repeat")
    func decodes() {
        #expect(MouseKeys.MediaPress(subtype: 8, data1: data1(17, down: true)) == .init(keyType: 17, isDown: true, isRepeat: false))
        #expect(MouseKeys.MediaPress(subtype: 8, data1: data1(16, down: false)) == .init(keyType: 16, isDown: false, isRepeat: false))
        #expect(MouseKeys.MediaPress(subtype: 8, data1: data1(16, down: true, repeats: true))?.isRepeat == true)
        #expect(MouseKeys.MediaPress(subtype: 7, data1: data1(16, down: true)) == nil)
        #expect(MouseKeys.MediaPress(subtype: 8, data1: 16 << 16) == nil)
    }

    @Test("Media: an unbound or keyboard press passes without asking the HID side; a bound mouse press runs, repeats and releases")
    func mediaRouting() {
        var router = MouseKeys.Router()
        var asked = 0
        let next = MouseKeys.media(17)
        func route(down: Bool = true, repeats: Bool = false, bound: Bool, mouse: Bool = true, learning: Bool = false) -> MouseKeys.Decision {
            router.route(next, isDown: down, isRepeat: repeats, learning: learning, isBound: { _ in bound }) { _ in asked += 1; return mouse }
        }
        #expect(route(bound: false) == .pass && asked == 0, "unbound: never asked, passes untouched")
        #expect(route(down: false, bound: false) == .pass)
        #expect(route(bound: true, mouse: false) == .pass && asked == 1, "the keyboard's Next passes")
        #expect(route(down: false, bound: true) == .pass, "its key up too")
        #expect(route(bound: true) == .run(next))
        #expect(route(repeats: true, bound: true) == .swallow)
        #expect(route(down: false, bound: true) == .release(next))
        #expect(route(bound: false, learning: true) == .learn(next))
        #expect(route(down: false, bound: false) == .swallow, "a learnt press's key up is taken")
    }

    @Test("Buttons: unbound passes; bound runs and releases; Learn takes the press and its release")
    func buttonRouting() {
        var router = MouseKeys.Router()
        let four = MouseKeys.button(3), five = MouseKeys.button(4)
        #expect(router.route(four, isDown: true, learning: false, isBound: { _ in false }) == .pass)
        #expect(router.route(four, isDown: false, learning: false, isBound: { _ in false }) == .pass)
        #expect(router.route(four, isDown: true, learning: false, isBound: { $0 == four }) == .run(four))
        #expect(router.route(four, isDown: false, learning: false, isBound: { _ in true }) == .release(four))
        #expect(router.route(five, isDown: true, learning: true, isBound: { _ in false }) == .learn(five))
        #expect(router.route(five, isDown: false, learning: false, isBound: { _ in false }) == .swallow)
    }

    static let hyperX = MouseKeys.Device(vendor: 2385, product: 5899, name: "HyperX Pulsefire Haste")
    /// Sven's keyboard, which also shows a mouse, so the HID side notes its media keys too.
    static let keychron = MouseKeys.Device(vendor: 13364, product: 2355, name: "Keychron V3 Max")

    @Test("A composite keyboard+mouse's Next passes while the mouse's Next is bound; only the bound device and the key's own usage claim it")
    func claims() {
        let ms: UInt64 = 1_000_000, t: UInt64 = 10_000 * ms
        var presses = MouseKeys.Presses()
        presses.note(time: t, usage: 0xB5, device: Self.keychron)   // the Keychron's Next
        #expect(presses.claim(keyType: 17, from: .device(Self.hyperX), now: t + 2 * ms) == nil, "the keyboard's Next is not the HyperX's")
        presses.note(time: t + 5 * ms, usage: 0xCD, device: Self.hyperX)   // the mouse's Play
        #expect(presses.claim(keyType: 17, from: .device(Self.hyperX), now: t + 6 * ms) == nil, "Play is no Next")
        presses.note(time: t + 7 * ms, usage: 0xB5, device: Self.hyperX)
        #expect(presses.claim(keyType: 17, from: .device(Self.hyperX), now: t + 300 * ms) == nil, "too old")
        presses.note(time: t + 400 * ms, usage: 0xB5, device: Self.hyperX)
        let renamed = MouseKeys.Device(vendor: 2385, product: 5899, name: "HyperX (renamed)")
        #expect(presses.claim(keyType: 17, from: .device(renamed), now: t + 401 * ms) == Self.hyperX, "the same vendor and product")
        #expect(presses.claim(keyType: 17, from: .device(Self.hyperX), now: t + 402 * ms) == nil, "claimed once")
        presses.note(time: t + 500 * ms, usage: 0xB5, device: Self.keychron)
        #expect(presses.claim(keyType: 17, from: .anyMouse, now: t + 501 * ms) == Self.keychron, "Learn names whichever device sent it")
        #expect(MouseKeys.usages(keyType: 16) == [0xCD, 0xB0, 0xB1] && MouseKeys.usages(keyType: 9) == nil)
    }

    @Test("A media bind with no device recorded is never the mouse's outside Learn: the Keychron's Next passes")
    func deviceless() throws {
        #expect(MouseKeys.Presses.Source.of(learning: false, bound: nil) == nil, "nothing to claim from: the tap passes it")
        #expect(MouseKeys.Presses.Source.of(learning: false, bound: Self.hyperX) == .device(Self.hyperX))
        #expect(MouseKeys.Presses.Source.of(learning: true, bound: nil) == .anyMouse)
        #expect(MouseKeys.Presses.Source.of(learning: true, bound: Self.hyperX) == .anyMouse, "Learn hears whichever button is pressed")
        // A hand-edited file: Mouse Next bound with no device.
        let json = Data(#"{"version": 3, "preset": "myBinds", "binds": [], "mouse": [{"action": "media.next", "trigger": {"hyper": false, "key": "Mouse Next", "modifiers": []}}]}"#.utf8)
        let store = try BindStore(json: json, presets: [.myBinds: Self.defaults])
        #expect(store.action(for: MouseKeys.media(17)) == "media.next" && store.mouseBinds.first?.bind.device == nil)
    }

    static let defaults: [String: Key] = ["media.next": Key("F9"), "media.playPause": Key("F8")]

    @Test("A mouse bind runs its action without taking the action's key, survives a preset switch, and round-trips at version 3")
    func store() throws {
        var store = BindStore(presets: [.pilot: Self.defaults, .myBinds: Self.defaults])
        let plain = store.json()
        #expect(String(decoding: plain, as: UTF8.self).contains("\"mouse\"") == false, "no mouse bind: the file is as before")
        store.setMouse(MouseKeys.button(3), to: "media.next")
        store.setMouse(MouseKeys.media(16), to: "media.next", device: Self.hyperX)
        store.setMouse(Key("F1"), to: "media.next")   // not a mouse trigger: refused
        #expect(store.action(for: MouseKeys.button(3)) == "media.next" && store.action(for: MouseKeys.media(16)) == "media.next")
        #expect(store.trigger(for: "media.next") == Key("F9"), "Hyper+F9 still runs Next")
        #expect(store.action(for: Key("F1")) == nil && store.mouseBinds.count == 2)
        store.use(.myBinds)
        #expect(store.action(for: MouseKeys.button(3)) == "media.next", "kept across presets, as the mouse is")

        let json = store.json()
        let file = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(file["version"] as? Int == 3)
        let rows = try #require(file["mouse"] as? [[String: Any]])
        #expect((rows.first?["trigger"] as? [String: Any])?["key"] as? String == "Mouse 4")
        let back = try BindStore(json: json, presets: [.pilot: Self.defaults, .myBinds: Self.defaults])
        #expect(back.fileVersion == 3 && back.mouseBinds.map(\.trigger) == store.mouseBinds.map(\.trigger))
        #expect(back.action(for: MouseKeys.media(16)) == "media.next")
        #expect(back.mouseBinds.map(\.bind.device) == [nil, Self.hyperX], "a media key keeps its device; a button has none")
        #expect(back.json() == json)

        var freed = back
        freed.setMouse(MouseKeys.button(3), to: nil)
        #expect(freed.action(for: MouseKeys.button(3)) == nil && freed.mouseBinds.count == 1)
    }

    @Test("A mouse bind set on a version 2 file changes what is written, so it is saved at once")
    func olderFile() throws {
        let v2 = BindStore(presets: [.myBinds: Self.defaults]).json(version: 2)
        var store = try BindStore(json: v2, presets: [.myBinds: Self.defaults])
        #expect(store.fileVersion == 2 && store.json(version: 2) == v2)
        store.setMouse(MouseKeys.button(3), to: "media.next")
        #expect(store.json(version: 2) != v2)
        #expect(try BindStore(json: store.json(), presets: [.myBinds: Self.defaults]).action(for: MouseKeys.button(3)) == "media.next")
    }

    static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }
    }

    @Test("A mouse's buttons are read from its HID report descriptor, its mouse collection only")
    func buttonCount() {
        // Sven's HyperX Pulsefire Core (1008:3471), from ioreg: its mouse interface has buttons 1 to 5, its keyboard
        // interface (keys, system and consumer controls, vendor reports) none.
        let pulsefire = Self.bytes("05010902a10185010901a10005091901290515002501750195058102750195038101050109381581257f750895018106"
            + "0501093009313700c0f900470040060016018026ff7f55046513751095028106c0c0")
        let pulsefireKeys = Self.bytes("05010906a10185017501950805071" + "9e029e715002501810295017508810195057501050819012905910295017503"
            + "910195057508150026ff00050719002aff008100c005010980a10185021981298315002501750195038102750595018101c0050c0901a10185"
            + "0319002aff02150026ff7f751095038100750895018101c00600ff0901a1018506150026ff000930950375088102c00601ff0901a10185071500"
            + "26ff0009207508960701b102c0")
        // Keychron Link's mouse part, and a joystick's 16 buttons, which are no mouse's.
        let keychron = Self.bytes("05010902a10185030901a1000509190129051500250175019505810275039501810105010930093116018026ff7f"
            + "75109502810609381581257f750895018106050c0a38021581257f750895018106c0c0")
        let joystick = Self.bytes("05010904a1018504a10a0501093009310932093309340935158125" + "7f95067508810205091901291015002501951075018102c0c0")
        #expect(MouseKeys.buttonCount(descriptor: pulsefire) == 5)
        #expect(MouseKeys.buttonCount(descriptor: pulsefireKeys) == 0)
        #expect(MouseKeys.buttonCount(descriptor: keychron) == 5)
        #expect(MouseKeys.buttonCount(descriptor: joystick) == 0)
        #expect(MouseKeys.buttonCount(descriptor: Array(pulsefire.prefix(20))) == 0, "a cut descriptor reads, short of its input")
        #expect(MouseKeys.buttonCount(descriptor: []) == 0)
        // A descriptor declaring buttons up to 255 or 65535 lists the 32 a CGEvent numbers, never a media key's code.
        for max in ["29ff", "2affff"] {
            let wide = Self.bytes("05010902a1010901a10005091901" + max + "150025017501950581020501093009311581257f750895028106c0c0")
            #expect(MouseKeys.buttonCount(descriptor: wide) == 32)
            #expect(MouseKeys.isButton(MouseKeys.button(Int64(MouseKeys.buttonCount(descriptor: wide) - 1)).keyCode))
        }
    }

    @Test("Learn names a key press by its chord, and says what to do when a mouse button sends a key or nothing")
    func learnNotes() {
        #expect(MouseKeys.keyLabel(keyCode: 33, flags: KeyEvent.cmdMask) == "Cmd+[")
        #expect(MouseKeys.keyLabel(keyCode: 33, flags: KeyEvent.cmdMask | KeyEvent.shiftMask | 0x100) == "Shift+Cmd+[")
        #expect(MouseKeys.keyLabel(keyCode: 49, flags: 0) == KeyNames.name(for: 49))
        #expect(MouseKeys.keyNote("Cmd+[", from: "HyperX Pulsefire Core", isMouse: true)
                == "This button sends Cmd+[, not a mouse button: reset it in NGenuity or bind that key.")
        #expect(MouseKeys.keyNote("Cmd+[", from: "MX Master 3S", isMouse: true).contains("the mouse's own app"))
        #expect(MouseKeys.keyNote("A", from: "Keychron V3 Max", isMouse: false, press: "Back") == "That was your keyboard. Press Back on the mouse.")
        #expect(MouseKeys.keyNote("A", from: nil, isMouse: nil).hasPrefix("That was A, a key"))
    }

    @Test("The catch's lines are the mockup's words, and a trigger is named as the page shows it")
    func catchWords() {
        typealias C = MouseKeys.Catch
        #expect(C.quiet(seconds: 8) == "Nothing arrived in 8 seconds.")
        #expect(C.quietWhy.hasPrefix("That button sends nothing to the Mac"), "P51: said plainly, a DPI button the likely one")
        #expect(C.sends("Back", MouseKeys.media(16), from: "HyperX Pulsefire Core") == "Back sends the Play key, from HyperX Pulsefire Core.")
        #expect(C.sends("Back", MouseKeys.button(3), from: nil) == "Back sends Button 4.")
        #expect(C.sends(nil, MouseKeys.media(17), from: nil) == "The button sends the Next key.")
        #expect(C.otherMouse("Logitech MX Master 3S", not: ["HyperX Pulsefire Core"]) == "That came from Logitech MX Master 3S, not HyperX Pulsefire Core.")
        #expect(C.keyboard(press: "Back") == "That was your keyboard. Press Back on the mouse.")
        #expect(C.locked("Play key") == "A Play key arrived, but Pilot can't tell your mouse from your keyboard until you allow Input Monitoring.")
        #expect(C.removed("Back") == "Remove: Back does its own job again.")
        #expect((3...6).map(MouseKeys.buttonName) == ["Wheel click", "Back", "Forward", "Button 6"])
        #expect(MouseKeys.sends(MouseKeys.button(2)) == "Button 3" && MouseKeys.sends(MouseKeys.media(9)) == "Media 9 key")
        #expect(MouseKeys.number(MouseKeys.button(3)) == 4 && MouseKeys.number(MouseKeys.media(16)) == nil)
        #expect(MouseKeys.button(3).label == "Mouse 4" && MouseKeys.media(16).label == "Mouse Play", "the file's names stay")
        #expect(MouseKeys.sends(MouseKeys.key(53)) == "Esc key" && MouseKeys.sends(MouseKeys.key(33, flags: KeyEvent.cmdMask)) == "Cmd+[ key")
        #expect(C.sends("Back", MouseKeys.key(53), from: "HyperX Pulsefire Core") == "Back sends the Esc key, from HyperX Pulsefire Core.")
    }

    @Test("A key the mouse sends is a mouse trigger of its own, named and read back, tied to its device and button")
    func keyTrigger() throws {
        let esc = MouseKeys.key(53), cmdBracket = MouseKeys.key(33, flags: KeyEvent.cmdMask)
        #expect(MouseKeys.isMouse(esc.keyCode) && MouseKeys.isKey(esc.keyCode) && MouseKeys.isSent(esc.keyCode) && !MouseKeys.isMedia(esc.keyCode))
        #expect(MouseKeys.name(for: esc.keyCode) == "Mouse Key Escape" && MouseKeys.code(for: "mouse key escape") == esc.keyCode)
        #expect(MouseKeys.keyCode(of: esc) == 53 && MouseKeys.keyCode(of: MouseKeys.media(16)) == nil)
        #expect(MouseKeys.code(for: "Mouse Media 99") == MouseKeys.media(99).keyCode && MouseKeys.code(for: "Mouse Media 100") == nil,
                "a media name never lands in the key range")
        #expect(cmdBracket.modifiers == .cmd && MouseKeys.isSent(MouseKeys.media(16).keyCode))
        var store = BindStore(presets: [.pilot: Self.defaults, .myBinds: Self.defaults])
        store.setMouse(esc, to: "media.next", device: Self.hyperX, button: 4)
        store.setMouse(cmdBracket, to: "media.playPause", device: Self.hyperX)
        #expect(store.action(for: esc) == "media.next" && store.action(for: MouseKeys.key(53, flags: KeyEvent.cmdMask)) == nil)
        #expect(store.mouseBinds.first { $0.trigger == esc }?.bind == .init(action: "media.next", device: Self.hyperX, button: 4))
        let json = store.json()
        let back = try BindStore(json: json, presets: [.pilot: Self.defaults, .myBinds: Self.defaults])
        #expect(back.mouseBinds.map(\.trigger) == store.mouseBinds.map(\.trigger) && back.json() == json)
    }

    @Test("A button holds one bind: binding on it frees its plain trigger and a media key tied to it, nothing else")
    func oneBindPerButton() {
        var store = BindStore(presets: [.pilot: Self.defaults, .myBinds: Self.defaults])
        store.setMouse(MouseKeys.button(3), to: "media.playPause")                                  // Back as a plain button
        store.setMouse(MouseKeys.media(17), to: "media.next", device: Self.hyperX, button: 4)       // a media key on Back
        store.setMouse(MouseKeys.media(18), to: "media.previous", device: Self.hyperX, button: 3)   // Wheel click's
        store.setMouse(MouseKeys.media(19), to: "media.next", device: Self.hyperX)                  // on no button
        #expect(store.mouseBinds.map(\.trigger) == [MouseKeys.media(17), MouseKeys.media(18), MouseKeys.media(19)],
                "the media key on Back freed Back's plain trigger")
        store.setMouse(MouseKeys.media(16), to: "media.playPause", device: Self.hyperX, button: 4)
        #expect(store.mouseBinds.map(\.trigger) == [MouseKeys.media(16), MouseKeys.media(18), MouseKeys.media(19)])
        store.setMouse(MouseKeys.button(2), to: "media.next")                                       // Wheel click, plain now
        #expect(store.mouseBinds.map(\.trigger) == [MouseKeys.button(2), MouseKeys.media(16), MouseKeys.media(19)])
        store.setMouse(MouseKeys.button(2), to: nil)
        #expect(store.mouseBinds.map(\.trigger) == [MouseKeys.media(16), MouseKeys.media(19)], "freeing frees only itself")
    }

    @Test("A media bind keeps the drawn button that sends it; a plain button or an out-of-range one never has one")
    func mediaOnButton() throws {
        var store = BindStore(presets: [.pilot: Self.defaults, .myBinds: Self.defaults])
        store.setMouse(MouseKeys.media(16), to: "media.next", device: Self.hyperX, button: 3)
        store.setMouse(MouseKeys.button(3), to: "media.playPause", button: 5)   // a plain button is its own
        store.setMouse(MouseKeys.media(17), to: "media.previous", device: Self.hyperX, button: 40)
        let bound = Dictionary(uniqueKeysWithValues: store.mouseBinds.map { ($0.trigger, $0.bind.button) })
        #expect(bound[MouseKeys.media(16)] == 3 && bound[MouseKeys.button(3)] == .some(nil) && bound[MouseKeys.media(17)] == .some(nil))

        let json = store.json()
        let rows = try #require((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["mouse"] as? [[String: Any]])
        #expect(rows.compactMap { $0["button"] as? Int } == [3], "only the placed media key writes a button")
        let back = try BindStore(json: json, presets: [.pilot: Self.defaults, .myBinds: Self.defaults])
        #expect(back.mouseBinds.first { $0.trigger == MouseKeys.media(16) }?.bind == .init(action: "media.next", device: Self.hyperX, button: 3))
        #expect(back.json() == json)
    }
}
