import CoreGraphics
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// `pilot system` (CLI W7): Sound, Displays, brightness, Keep awake, Keyboard layout and dark mode, asked through the
/// registry the socket answers from. Every model runs on the Setup tests' fakes, so nothing reads or changes the Mac's
/// sound, screens, sleep or layouts.
@MainActor
@Suite("Control system")
struct ControlSystemVerbTests {
    /// Screen 1 answers Apple's brightness call at 0.5, screen 2 nothing.
    final class FakeHardware: BrightnessHardware, @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [(UInt32, Double)] = []
        var writes: [(UInt32, Double)] { lock.withLock { _writes } }
        func readApple(_ display: UInt32) -> Double? { display == 1 ? 0.5 : nil }
        func readDDC(_ display: UInt32) -> Double? { nil }
        func write(_ level: Double, to display: UInt32, over route: BrightnessRoute) -> Bool {
            lock.withLock { _writes.append((display, level)) }
            return true
        }
    }

    @MainActor final class Rig {
        let audio = SetupSoundTests.FakeAudio()
        let screens = SetupDisplaysTests.FakeDisplays()
        let time = SetupKeepAwakeTests.FakeTime()
        let power = SetupKeepAwakeTests.FakePower()
        let hardware = FakeHardware()
        let displays: SetupDisplays
        let brightness: Brightness
        let awake: KeepAwake
        var layouts = SetupKeepAwakeTests.FakeSources().all()
        var picked: [String] = []
        var layoutRefusal: String?
        let system = ControlSystem()
        let verbs = ControlVerbs()

        init() {
            displays = SetupDisplays(system: screens, after: time.after)
            brightness = Brightness(hardware: hardware)
            awake = SetupKeepAwakeTests.model(power, time)
            let audio = audio, displays = displays, brightness = brightness, awake = awake
            system.audio = { audio }
            system.displays = { displays }
            system.brightness = { brightness }
            system.awake = { awake }
            system.layouts = { [unowned self] in layouts }
            system.pickLayout = { [unowned self] id in
                picked.append(id)
                if layoutRefusal == nil { layouts = layouts.map { .init(id: $0.id, name: $0.name, isKeyboard: true, isEnabled: true, isSelectable: true, isCurrent: $0.id == id) } }
                return layoutRefusal
            }
            system.dark = { true }
            system.desktopIcons = { false }
            let pointer = PointerSpeed(system: SharedLook.PointerSpeedRenders.FakePointer())
            system.pointer = { pointer }
            verbs.registerSystem(system)
        }

        func ask(_ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: "system", args: args), peer: nil) }
    }

    static func path(_ value: JSONValue?, _ keys: String...) -> JSONValue? {
        keys.reduce(value) { value, key in
            switch value {
            case .object(let o)?: o[key]
            case .array(let a)?: Int(key).flatMap { a.indices.contains($0) ? a[$0] : nil }
            default: nil
            }
        }
    }

    @Test("Sound reads each side's devices with the one in use, its volume 0-100, whether macOS lets it change, and mute")
    func soundRead() async {
        let rig = Rig()
        let answer = await rig.ask("sound")
        #expect(Self.path(answer.result, "output", "inUse") == .string("MacBook Speakers"))
        #expect(Self.path(answer.result, "output", "volume") == .number(50) && Self.path(answer.result, "output", "volumeSettable") == .bool(true))
        #expect(Self.path(answer.result, "output", "muted") == .bool(false))
        #expect(Self.path(answer.result, "output", "devices", "1", "name") == .string("LG HDR 4K"))
        #expect(Self.path(answer.result, "output", "devices", "1", "inUse") == .bool(false))
        #expect(Self.path(answer.result, "input", "inUse") == .string("MacBook Microphone"))
        #expect(Self.path(answer.result, "input", "volume") == .number(70) && Self.path(answer.result, "input", "muted") == nil)
        #expect(rig.audio.watched.isEmpty, "the read stops following once answered")
    }

    @Test("A device picked by name or id becomes the default and the answer reads it back; an unknown one names the choices")
    func soundPick() async {
        let rig = Rig()
        let tv = await rig.ask("sound", "output", "tv")
        #expect(rig.audio.setDefaultCalls.map(\.0) == [12])
        #expect(Self.path(tv.result, "output", "inUse") == .string("TV"))
        #expect(Self.path(tv.result, "output", "volumeSettable") == .bool(false), "the TV keeps its volume fixed")
        let mic = await rig.ask("sound", "input", "21")
        #expect(Self.path(mic.result, "input", "inUse") == .string("AirPods"))
        let none = await rig.ask("sound", "output", "Sonos")
        #expect(none.error?.code == .badValue && none.error?.message.contains("10 MacBook Speakers") == true)
    }

    @Test("Volume sets an exact level on either side, refuses past 100 and a fixed volume; mute is on or off")
    func soundLevels() async {
        let rig = Rig()
        let set = await rig.ask("sound", "volume", "30")
        #expect(rig.audio.volumes[10] == 0.3 && Self.path(set.result, "output", "volume") == .number(30))
        let input = await rig.ask("sound", "volume", "45", "--input")
        #expect(rig.audio.volumes[20] == 0.45 && Self.path(input.result, "input", "volume") == .number(45))
        #expect(await rig.ask("sound", "volume", "150").error?.code == .outOfRange)
        #expect(await rig.ask("sound", "volume", "loud").error?.code == .badValue)
        let muted = await rig.ask("sound", "mute", "on")
        #expect(rig.audio.mutes[10] == true && Self.path(muted.result, "output", "muted") == .bool(true))
        #expect(await rig.ask("sound", "mute", "on", "--input").error?.message.contains("no mute") == true)
        rig.audio.defaults[.output] = 12
        #expect(await rig.ask("sound", "volume", "20").error?.message.contains("fixed") == true)
        #expect(rig.audio.volumes[12] == 0.6)
        #expect(await rig.ask("sound", "--size", "1x1").error?.code == .unknownFlag)
    }

    @Test("Displays read each screen with its mode, sizes, rates and brightness; a size waits 15 s for keep, revert goes back")
    func displays() async {
        let rig = Rig()
        await rig.brightness.refresh([.init(id: 1, appleAllowed: true), .init(id: 2, appleAllowed: true)])
        let read = await rig.ask("displays")
        #expect(Self.path(read.result, "screens", "0", "name") == .string("CU34G4Z"))
        #expect(Self.path(read.result, "screens", "0", "mode") == .string("3440 × 1440 · 100 Hz"))
        #expect(Self.path(read.result, "screens", "0", "sizes") == .array([.string("3440x1440"), .string("2560x1080")]))
        #expect(Self.path(read.result, "screens", "1", "rotation") == .number(90))
        #expect(Self.path(read.result, "screens", "0", "brightness") == .object(["route": .string("apple"), "level": .number(50)]))
        #expect(Self.path(read.result, "screens", "1", "brightness", "route") == .string("none"))

        let picked = await rig.ask("display", "CU34G4Z", "--size", "2560x1080")
        #expect(rig.screens.applied.map(\.permanently) == [false] && rig.screens.applied.first?.mode == SetupDisplaysTests.wideLow)
        #expect(Self.path(picked.result, "pending", "to") == .string("2560 × 1080 · 60 Hz"))
        #expect(Self.path(picked.result, "pending", "secondsLeft").map { [.number(14), .number(15)].contains($0) } == true)
        _ = await rig.ask("display", "keep")
        #expect(rig.screens.applied.last?.permanently == true && rig.displays.pending == nil)

        _ = await rig.ask("display", "1", "--size", "3440x1440", "--rate", "100")
        #expect(rig.displays.pending != nil)
        let back = await rig.ask("display", "revert")
        #expect(Self.path(back.result, "pending") == nil && rig.screens.applied.last?.mode == SetupDisplaysTests.wideLow)
        #expect(await rig.ask("display", "keep").error?.code == .badValue, "nothing waits")

        #expect(await rig.ask("display", "1", "--size", "800x600").error?.message.contains("sizes: 3440x1440, 2560x1080") == true)
        #expect(await rig.ask("display", "1", "--rate", "144").error?.code == .badValue)
        #expect(await rig.ask("display", "Nope", "--size", "1x1").error?.code == .badValue)
        #expect(await rig.ask("display", "1").error?.code == .badRequest)
    }

    @Test("Brightness sets a screen's level as the slider does; a screen with no control or not read yet refuses")
    func brightness() async {
        let rig = Rig()
        #expect(await rig.ask("display", "1", "--brightness", "40").error?.code == .notReady)
        await rig.brightness.refresh([.init(id: 1, appleAllowed: true), .init(id: 2, appleAllowed: true)])
        let set = await rig.ask("display", "1", "--brightness", "40")
        #expect(Self.path(set.result, "screens", "0", "brightness", "level") == .number(40))
        #expect(await rig.ask("display", "24G1WG4", "--brightness", "40").error?.code == .badValue)
        #expect(await rig.ask("display", "1", "--brightness", "101").error?.code == .outOfRange)
        #expect(rig.screens.applied.isEmpty, "brightness alone changes no mode")
    }

    @Test("Keep awake turns on for a length, reads until when, and off lets the assertion go")
    func awake() async {
        let rig = Rig()
        let on = await rig.ask("awake", "on", "--for", "4h")
        #expect(Self.path(on.result, "on") == .bool(true) && Self.path(on.result, "for") == .string("4h"))
        #expect(rig.power.held.count == 1 && Self.path(on.result, "until") != nil)
        let off = await rig.ask("awake", "off")
        #expect(Self.path(off.result, "on") == .bool(false) && rig.power.held.isEmpty)
        let length = await rig.ask("awake", "--for", "until-off")
        #expect(Self.path(length.result, "for") == .string("until-off") && Self.path(length.result, "on") == .bool(false))
        #expect(await rig.ask("awake", "maybe").error?.code == .badValue)
        #expect(await rig.ask("awake", "--for", "2h").error?.code == .badValue)
    }

    @Test("Layouts list with the one in use; a pick by name selects it through Look, a refusal answers its line")
    func layouts() async {
        let rig = Rig()
        let picked = await rig.ask("layout", "abc")
        #expect(rig.picked == ["com.apple.keylayout.ABC"])
        #expect(Self.path(picked.result, "0", "inUse") == .bool(false) && Self.path(picked.result, "1", "inUse") == .bool(true))
        _ = await rig.ask("layout", "ABC")
        #expect(rig.picked.count == 1, "the layout in use is not picked again")
        rig.layoutRefusal = "keyboard layout not changed: refused"
        #expect(await rig.ask("layout", "com.apple.keylayout.British-PC").error?.message == "keyboard layout not changed: refused")
        #expect(await rig.ask("layout", "Dvorak").error?.code == .badValue)
    }

    @Test("pilot system alone reads every card and dark mode; an unknown part or flag is refused")
    func overview() async {
        let rig = Rig()
        let all = await rig.ask()
        guard case .object(let o)? = all.result else { Issue.record("not an object: \(all)"); return }
        #expect(Set(o.keys) == ["sound", "displays", "awake", "layouts", "dark", "desktopIcons", "mouse"] && o["dark"] == .bool(true))
        // Finder's desktop icons on the fake: read, never written.
        let appearance = await rig.ask("appearance").result
        #expect(o["desktopIcons"] == .bool(false) && Self.path(appearance, "desktopIcons") == .bool(false))
        // The pointer speed on the fake: read, never set.
        #expect(Self.path(o["mouse"], "speed") == .number(1.5) && Self.path(o["mouse"], "picked") == .string("Normal"))
        #expect(Self.path(await rig.ask("appearance").result, "dark") == .bool(true))
        #expect(await rig.ask("wifi").error?.code == .badValue)
        #expect(await rig.ask("sound", "--nope").error?.code == .unknownFlag)
        #expect(rig.verbs.verbs["system"]?.detail.map { (try? $0("display")) ?? nil }??.contains("keep") == true)
    }
}
