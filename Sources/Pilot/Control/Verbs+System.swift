import CoreAudio
import CoreGraphics
import Foundation
import PilotCore

/// What `pilot system` reaches (CLI W7): System's Sound, Displays, Keep awake and Keyboard layout cards, through the
/// models the page itself drives, and dark mode's state. The tests hand in fakes, so no test reads or changes the Mac's
/// sound, screens, sleep or layouts.
@MainActor
final class ControlSystem {
    var audio: @MainActor () -> AudioSystem = { CoreAudioSystem() }
    /// The app's displays model, so a mode the command picks goes back after 15 s as the page's does, page open or not.
    var displays: @MainActor () -> SetupDisplays = { .shared }
    var brightness: @MainActor () -> Brightness? = { ScreenBrightness.engine }
    var awake: @MainActor () -> KeepAwake = { .shared }
    /// The enabled layouts as Look reads them, the one place Pilot switches them (story 111).
    var layouts: @MainActor () -> [InputSource] = {
        Look.shared.followLayouts()
        return Look.shared.layouts
    }
    /// Picks through Look as Setup does; the refusal Setup would show, nil when none.
    var pickLayout: @MainActor (String) -> String? = {
        Look.shared.pickLayout($0)
        return Look.shared.layoutError
    }
    var dark: @MainActor () -> Bool = { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    /// Whether Finder draws the desktop's icons (its CreateDesktop), only read here.
    var desktopIcons: @MainActor () -> Bool = { FinderDesktopIcons.shown }
    /// System › Mouse's pointer speed, only read here.
    var pointer: @MainActor () -> PointerSpeed = { .shared }
}

extension ControlVerbs {
    private static let systemParts: [(word: String, usage: String, text: String)] = [
        ("sound", "system sound [output|input <device>] | sound volume <0-100> [--input] | sound mute on|off [--input]",
         "the output and input devices, each with its volume (0-100) and mute; picks a device, sets a level or the mute as Setup › Sound does. A device is its id or its name. A volume macOS keeps fixed answers volumeSettable false and refuses a level."),
        ("displays", "system displays", "every screen's mode and brightness route, plus independently observed display connections and recovery readiness"),
        ("display", "system display <screen> [--name <text>] [--size <W>x<H>] [--hidpi] [--rate <Hz>] [--brightness <0-100>] [--rotate 0|90|180|270] [--connected on|off] [--test-connection] | display keep|revert|restore-all",
         "--name sets a personal Pilot label on an active screen; empty text clears it. Names persist by display UUID. Other flags change size, rate, brightness, rotation or native connection; a size or rate goes back after 15 s unless kept; a rotation stays unless reverted within 15 s. OFF needs attended `--test-connection` and refuses the last awake display. `restore-all` retries remembered OFF displays. Hardware names and connection identity stay unchanged."),
        ("awake", "system awake [on|off] [--for 1h|4h|until-off]",
         "keep awake: on or off, until when, and its length; --for sets the length the switch turns it on for, and while on counts from now, as the page's For picker does"),
        ("layout", "system layout [<layout>]", "the keyboard layouts macOS has enabled, the one in use marked; a layout (its id or name) selects it, as Setup › Keyboard layout does"),
        ("appearance", "system appearance", "dark mode on or off, and whether Finder shows the desktop icons; pilot run system.darkMode and system.desktopIcons flip them"),
        ("mouse", "system mouse", "the pointer speed macOS moves the mice at (0-3, System Settings' Tracking speed), the saved Slow, Normal and Fast with the one picked, and the mice connected; pilot run system.pointerSpeedCycle steps it"),
    ]

    /// `pilot system`: Sound, Displays, Keep awake, Keyboard layout and dark mode, read and changed as System's cards do.
    func registerSystem(_ system: ControlSystem) {
        let parts = Self.systemParts, words = parts.map(\.word)
        register(ControlVerb("system", help: "Reads and sets the Mac's sound, displays, brightness, keep awake and keyboard layout, and reads the pointer speed, as System's cards do.",
                             usage: "pilot system [\(words.joined(separator: "|"))] …",
                             flags: [.init("input", help: "sound volume and mute: the input side, not the output", takesValue: false),
                                     .init("size", help: "display: a size it offers, <W>x<H> in points"),
                                     .init("hidpi", help: "display: the HiDPI one of a size listed both ways", takesValue: false),
                                     .init("rate", help: "display: a refresh rate it offers, in Hz"),
                                     .init("brightness", help: "display: its brightness, 0 to 100"),
                                     .init("rotate", help: "display: its rotation, 0, 90, 180 or 270 degrees"),
                                     .init("name", help: "display: personal Pilot name; empty text restores the system name; runs alone"),
                                     .init("connected", help: "display: native connection on or off"),
                                     .init("test-connection", help: "display: attended OFF then ON connection validation", takesValue: false),
                                     .init("for", help: "awake: 1h, 4h or until-off")],
                             schema: { .object(["subcommands": .array(parts.map { .object(["name": .string($0.word), "usage": .string("pilot " + $0.usage), "help": .string($0.text)]) })]) },
                             index: { .object(["subcommands": .array(words.map(JSONValue.string))]) },
                             detail: { word throws(ControlError) in parts.first { $0.word == word }.map { "pilot \($0.usage)\n\($0.text)" } }) { call throws(ControlError) in
            let args = call.arguments()
            guard let part = args.positional.first else {
                try Self.only([], args, "pilot system")
                return .object(["sound": Self.soundRead(system.audio()), "displays": await Self.displaysRead(system),
                                "awake": Self.awakeRead(system.awake()), "layouts": Self.layoutsRead(system.layouts()),
                                "dark": .bool(system.dark()), "desktopIcons": .bool(system.desktopIcons()), "mouse": Self.mouseRead(system.pointer())])
            }
            switch part {
            case "sound": return try Self.sound(args, system)
            case "displays":
                try Self.only([], args, "pilot system displays")
                return await Self.displaysRead(system)
            case "display": return try await Self.display(args, system)
            case "awake": return try Self.awake(args, system.awake())
            case "layout": return try Self.layout(args, system)
            case "appearance":
                try Self.only([], args, "pilot system appearance")
                return .object(["dark": .bool(system.dark()), "desktopIcons": .bool(system.desktopIcons())])
            case "mouse":
                try Self.only([], args, "pilot system mouse")
                return Self.mouseRead(system.pointer())
            case let other: throw ControlError(.badValue, "no system \(other); pilot system \(words.joined(separator: "|"))")
            }
        })
    }

    /// Unknown-flag for a flag the verb takes but not this subcommand.
    private static func only(_ known: [String], _ args: ControlArguments, _ place: String) throws(ControlError) {
        if let refusal = ControlVerb.unknownFlag(args.flags, known: known, in: place) { throw refusal }
    }

    /// System › Mouse as it shows, read now.
    private static func mouseRead(_ pointer: PointerSpeed) -> JSONValue {
        pointer.refresh()
        var answer: [String: JSONValue] = [
            "picked": .string(PointerSpeed.names[pointer.picked]),
            "saved": .object(Dictionary(uniqueKeysWithValues: zip(PointerSpeed.names, pointer.saved.map(JSONValue.number)))),
            "mice": .array(pointer.mice.map(JSONValue.string)),
        ]
        answer["speed"] = pointer.current.map(JSONValue.number)
        return .object(answer)
    }

    private static func percent(_ value: Double) -> JSONValue { .number((value * 100).rounded()) }

    /// A 0-100 level, or out-of-range.
    private static func level(_ word: String, _ what: String) throws(ControlError) -> Double {
        guard let value = Double(word), value.isFinite else { throw ControlError(.badValue, "\(what) is a number from 0 to 100, not \(word)") }
        guard (0...100).contains(value) else { throw ControlError(.outOfRange, "\(what) runs from 0 to 100, not \(word)") }
        return value / 100
    }

    // MARK: Sound

    /// Both sides as Setup › Sound reads them, read now.
    private static func soundRead(_ audio: AudioSystem) -> JSONValue {
        let sound = SetupSound(audio: audio)
        sound.start()
        defer { sound.stop() }
        return .object(Dictionary(uniqueKeysWithValues: AudioDirection.allCases.map { ($0.rawValue, side(sound.side($0))) }))
    }

    private static func side(_ side: SetupSound.Side) -> JSONValue {
        var entry: [String: JSONValue] = [
            "devices": .array(side.devices.map { .object(["id": .number(Double($0.id)), "name": .string($0.name), "inUse": .bool($0.id == side.current)]) }),
        ]
        entry["inUse"] = side.devices.first { $0.id == side.current }.map { .string($0.name) }
        if let volume = side.volume {
            entry["volume"] = percent(Double(volume.value))
            entry["volumeSettable"] = .bool(volume.settable)
        }
        entry["muted"] = side.muted.map(JSONValue.bool)
        return .object(entry)
    }

    private static func sound(_ args: ControlArguments, _ system: ControlSystem) throws(ControlError) -> JSONValue {
        let audio = system.audio()
        guard args.positional.count > 1 else {
            try only([], args, "pilot system sound")
            return soundRead(audio)
        }
        let what = args.positional[1]
        let direction: AudioDirection = args.has("input") ? .input : .output
        let sound = SetupSound(audio: audio)
        sound.start()
        defer { sound.stop() }
        switch what {
        case "output", "input":
            try only([], args, "pilot system sound \(what)")
            let direction = AudioDirection(rawValue: what)!
            let name = try args.word(2, "\(what) device: its id or name; pilot system sound lists them")
            let devices = sound.side(direction).devices
            guard let device = devices.first(where: { String($0.id) == name }) ?? devices.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw ControlError(.badValue, "no \(what) device \(name); \(what)s: \(devices.map { "\($0.id) \($0.name)" }.joined(separator: ", "))")
            }
            sound.pick(device.id, direction)
        case "volume":
            try only(["input"], args, "pilot system sound volume")
            let value = try level(try args.word(2, "volume, 0 to 100"), "volume")
            let side = sound.side(direction)
            guard let volume = side.volume else { throw ControlError(.badValue, "the \(direction.rawValue) device has no volume to set") }
            guard volume.settable else { throw ControlError(.badValue, "macOS keeps the \(direction.rawValue) device's volume fixed, so no app can change it") }
            sound.setVolume(Float(value), direction)
        case "mute":
            try only(["input"], args, "pilot system sound mute")
            let word = try args.word(2, "on or off")
            guard let muted = ["on": true, "off": false][word] else { throw ControlError(.badValue, "mute is on or off, not \(word)") }
            guard sound.side(direction).muted != nil else { throw ControlError(.badValue, "the \(direction.rawValue) device has no mute Pilot can set") }
            sound.setMuted(muted, direction)
        case let other:
            throw ControlError(.badValue, "no system sound \(other); pilot system sound [output|input <device>] | volume <0-100> | mute on|off")
        }
        if let problem = sound.problem { throw ControlError(.badValue, problem) }
        return soundRead(audio)
    }

    // MARK: Displays

    /// Every screen as Setup › Displays shows it, read now.
    private static func displaysRead(_ system: ControlSystem) async -> JSONValue {
        let displays = system.displays(), brightness = system.brightness()
        displays.start()
        var answer: [String: JSONValue] = ["screens": .array(displays.displays.map { info in
            var screen: [String: JSONValue] = [
                "id": .number(Double(info.id)), "name": .string(info.name), "main": .bool(info.main), "rotation": .number(Double(info.rotation)),
                "canRotate": .bool(displays.canRotate(info.id)),
                "frame": .object(["x": .number(info.frame.minX), "y": .number(info.frame.minY), "width": .number(info.frame.width), "height": .number(info.frame.height)]),
                "mode": .string(info.mode.label),
                "sizes": .array(displays.sizes(for: info.id).map { .string(size($0)) }),
                "rates": .array(displays.rates(for: info.id).compactMap { m -> JSONValue? in m.refresh > 0 ? .number(m.refresh.rounded()) : nil }),
            ]
            screen["displayUUID"] = info.displayUUID.map(JSONValue.string)
            let uuid = displays.displays.filter { $0.displayUUID == info.displayUUID }.count == 1 ? info.displayUUID : nil
            screen["nickname"] = displays.nicknames.nickname(for: uuid).map(JSONValue.string)
            screen["label"] = .string(displays.nicknames.label(systemName: info.name, displayUUID: uuid))
            if let brightness {
                let read = brightness.screens[info.id]
                var entry: [String: JSONValue] = ["route": .string(read?.route.rawValue ?? "reading")]
                entry["level"] = read?.level.map(percent)
                screen["brightness"] = .object(entry)
            }
            return .object(screen)
        })]
        if let connections = displays.connections {
            await connections.refresh()
            answer["connections"] = .array(connections.screens.map { connectionRead($0, connections, displays.nicknames) })
            answer["connectionProblem"] = connections.problem.map(JSONValue.string)
        }
        if let pending = displays.pending {
            let name = displays.displays.first { $0.id == pending.display }?.name ?? String(pending.display)
            answer["pending"] = .object(["screen": .string(name), "from": .string(pending.old.label), "to": .string(pending.new.label),
                                         "secondsLeft": .number(Double(pending.secondsLeft(at: Date()))),
                                         "next": .string("pilot system display keep, or it goes back by itself")])
        }
        if let turning = displays.turning {
            let name = displays.displays.first { $0.id == turning.display }?.name ?? String(turning.display)
            answer["pending"] = .object(["screen": .string(name), "from": .string("\(turning.old)°"), "to": .string("\(turning.new)°"),
                                         "secondsLeft": .number(Double(turning.secondsLeft(at: Date()))),
                                         "next": .string("pilot system display revert, or it stays")])
        }
        answer["problem"] = displays.problem.map(JSONValue.string)
        return .object(answer)
    }

    /// "3440x1440", "1920x1080 HiDPI": how --size and --hidpi name a size.
    private static func size(_ mode: DisplayMode) -> String { "\(mode.width)x\(mode.height)" + (mode.hiDPI ? " HiDPI" : "") }

    private static func connectionRead(_ screen: ConnectionScreen, _ connections: DisplayConnections, _ nicknames: DisplayNicknames) -> JSONValue {
        var read: [String: JSONValue] = [
            "id": .number(Double(screen.id)), "name": .string(screen.name), "identity": .string(screen.identity),
            "state": .string(screen.state.rawValue), "main": .bool(screen.main), "asleep": .bool(screen.asleep),
            "supported": .bool(screen.supported), "verified": .bool(screen.verified),
            "canDisconnect": .bool(connections.canDisconnect(screen)), "busy": .bool(connections.busy),
        ]
        read["displayUUID"] = screen.displayUUID.map(JSONValue.string)
        let uuid = connections.screens.filter { $0.displayUUID == screen.displayUUID }.count == 1 ? screen.displayUUID : nil
        read["nickname"] = nicknames.nickname(for: uuid).map(JSONValue.string)
        read["label"] = .string(nicknames.label(systemName: screen.name, displayUUID: uuid))
        read["problems"] = .array(connections.problem.map { [.string($0)] } ?? [])
        return .object(read)
    }

    private static func display(_ args: ControlArguments, _ system: ControlSystem) async throws(ControlError) -> JSONValue {
        let displays = system.displays()
        displays.start()
        let word = try args.word(1, "screen: its id or name, or keep or revert; pilot system displays lists them")
        if args.has("name") {
            try only(["name"], args, "pilot system display name")
            guard let name = args.value("name"), args.positional.count == 2 else { throw ControlError(.badRequest, "--name needs one text value (empty clears)") }
            let matches = displays.displays.filter {
                String($0.id) == word || $0.name.localizedCaseInsensitiveCompare(word) == .orderedSame ||
                $0.displayUUID?.localizedCaseInsensitiveCompare(word) == .orderedSame ||
                displays.nicknames.nickname(for: $0.displayUUID)?.localizedCaseInsensitiveCompare(word) == .orderedSame
            }
            guard matches.count == 1, let info = matches.first else { throw ControlError(.badValue, "\(matches.isEmpty ? "No screen" : "More than one screen matches") \(word); pilot system displays lists them") }
            guard let uuid = info.displayUUID, displays.displays.filter({ $0.displayUUID == uuid }).count == 1 else {
                throw ControlError(.notReady, "That display has no unique stable identity for a personal name")
            }
            do { try displays.nicknames.set(name, for: uuid) }
            catch { throw ControlError(.badValue, error.localizedDescription) }
            return await displaysRead(system)
        }
        if word == "keep" || word == "revert" {
            try only([], args, "pilot system display \(word)")
            guard displays.pending != nil || displays.turning != nil else { throw ControlError(.badValue, "no display change is waiting for keep or revert") }
            if word == "keep" { displays.keep() } else { displays.revert() }
            if let problem = displays.problem { throw ControlError(.badValue, problem) }
            return await displaysRead(system)
        }
        if word == "restore-all" {
            try only([], args, "pilot system display restore-all")
            guard let connections = displays.connections else { throw ControlError(.notReady, "display connections are unavailable") }
            await connections.restoreAll()
            try connectionSucceeded(connections)
            return await displaysRead(system)
        }
        if args.has("connected") || args.has("test-connection") {
            try only(["connected", "test-connection"], args, "pilot system display connection")
            guard let connections = displays.connections else { throw ControlError(.notReady, "display connections are unavailable") }
            await connections.refresh()
            let screen = try connection(word, in: connections)
            if args.has("test-connection") {
                guard !args.has("connected") else { throw ControlError(.badRequest, "--test-connection runs alone; run --connected off after it succeeds") }
                await connections.validateConnection(id: screen.id, binding: screen.binding)
            } else {
                guard let value = args.value("connected") else { throw ControlError(.badRequest, "--connected needs on or off") }
                guard let connected = ["on": true, "off": false][value] else { throw ControlError(.badValue, "--connected is on or off, not \(value)") }
                await connections.setConnected(connected, id: screen.id, binding: screen.binding)
            }
            try connectionSucceeded(connections)
            return await displaysRead(system)
        }
        try only(["size", "hidpi", "rate", "brightness", "rotate"], args, "pilot system display")
        let screens = displays.displays
        guard let info = screens.first(where: { String($0.id) == word }) ?? screens.first(where: { $0.name.localizedCaseInsensitiveCompare(word) == .orderedSame }) else {
            throw ControlError(.badValue, "no screen \(word); screens: \(screens.map { "\($0.id) \($0.name)" }.joined(separator: ", "))")
        }
        let level = try args.value("brightness").map { v throws(ControlError) in try Self.level(v, "brightness") }
        let mode = try pickMode(args, info, displays)
        let degrees = try args.value("rotate").map { v throws(ControlError) -> Int in
            guard let d = Int(v), DisplayRotation.degrees.contains(d) else { throw ControlError(.badValue, "--rotate is 0, 90, 180 or 270, not \(v)") }
            return d
        }
        guard level != nil || mode != nil || degrees != nil else {
            throw ControlError(.badRequest, "pilot system display \(word) needs --size, --rate, --brightness or --rotate")
        }
        guard degrees == nil || mode == nil else { throw ControlError(.badRequest, "--rotate runs without --size or --rate: one change waits at a time") }
        if degrees != nil, !displays.canRotate(info.id) { throw ControlError(.notReady, "macOS does not let Pilot rotate \(info.name)") }
        if let level {
            guard let brightness = system.brightness(), let read = brightness.screens[info.id] else {
                throw ControlError(.notReady, "\(info.name)'s brightness is not read yet; ask again in a moment")
            }
            guard read.route != .none, brightness.set(info.id, level) != nil else {
                throw ControlError(.badValue, "\(info.name) answers neither Apple's brightness call nor DDC/CI, so Pilot cannot set its brightness")
            }
        }
        if let mode, mode != info.mode {
            displays.pick(mode, for: info.id)
            if displays.pending == nil, let problem = displays.problem { throw ControlError(.badValue, problem) }
        }
        if let degrees, degrees != info.rotation {
            displays.rotate(info.id, to: degrees)
            if displays.turning == nil, let problem = displays.problem { throw ControlError(.badValue, problem) }
        }
        return await displaysRead(system)
    }

    private static func connectionSucceeded(_ connections: DisplayConnections) throws(ControlError) {
        if let problem = connections.problem { throw ControlError(.badValue, problem) }
    }

    private static func connection(_ word: String, in connections: DisplayConnections) throws(ControlError) -> ConnectionScreen {
        let matches = connections.screens.filter {
            String($0.id) == word || $0.name.localizedCaseInsensitiveCompare(word) == .orderedSame || $0.identity.localizedCaseInsensitiveCompare(word) == .orderedSame
        }
        guard matches.count == 1, let screen = matches.first else {
            let choices = connections.screens.map { "\($0.id) \($0.name) [\($0.identity)]" }.joined(separator: ", ")
            let cause = matches.isEmpty ? "no display" : "more than one display matches"
            throw ControlError(.badValue, "\(cause) \(word); displays: \(choices)")
        }
        return screen
    }

    /// The mode --size, --hidpi and --rate name among what the pickers offer, nil when neither size nor rate is given.
    private static func pickMode(_ args: ControlArguments, _ info: DisplayInfo, _ displays: SetupDisplays) throws(ControlError) -> DisplayMode? {
        let sizeWord = args.value("size"), rateWord = args.value("rate")
        if args.has("size"), sizeWord == nil { throw ControlError(.badRequest, "--size needs a value") }
        if args.has("rate"), rateWord == nil { throw ControlError(.badRequest, "--rate needs a value") }
        if args.has("hidpi"), sizeWord == nil { throw ControlError(.badRequest, "--hidpi goes with --size") }
        guard sizeWord != nil || rateWord != nil else { return nil }
        let sizes = displays.sizes(for: info.id)
        var target = info.mode.size
        if let sizeWord {
            let wh = sizeWord.lowercased().split(separator: "x").compactMap { Int($0) }
            guard wh.count == 2 else { throw ControlError(.badValue, "--size is <W>x<H>, as pilot system displays lists them, not \(sizeWord)") }
            let matching = sizes.filter { $0.width == wh[0] && $0.height == wh[1] }
            guard let picked = matching.first(where: { $0.hiDPI == args.has("hidpi") }) ?? (args.has("hidpi") ? nil : matching.first) else {
                throw ControlError(.badValue, "\(info.name) offers no \(sizeWord)\(args.has("hidpi") ? " HiDPI" : ""); sizes: \(sizes.map(size).joined(separator: ", "))")
            }
            target = picked.size
        }
        let ofSize = displays.modes(for: info.id).filter { $0.size == target }
        guard let rateWord else {
            // The size picker's pick: the size at the rate in use when it has it, else its highest.
            return sizes.first { $0.size == target }
        }
        guard let hz = Double(rateWord), let mode = ofSize.first(where: { $0.refresh.rounded() == hz.rounded() }) else {
            throw ControlError(.badValue, "\(info.name) offers no \(rateWord) Hz at that size; rates: \(ofSize.compactMap(\.rate).joined(separator: ", "))")
        }
        return mode
    }

    // MARK: Keep awake

    private static let lengths: [(word: String, length: KeepAwake.Length)] = [("1h", .hour), ("4h", .fourHours), ("until-off", .untilOff)]

    private static func awakeRead(_ awake: KeepAwake) -> JSONValue {
        var entry: [String: JSONValue] = ["on": .bool(awake.isOn), "state": .string(awake.state(at: Date())),
                                          "for": .string(lengths.first { $0.length == awake.length }?.word ?? "")]
        entry["until"] = awake.until.map { .string($0.ISO8601Format()) }
        entry["problem"] = awake.problem.map(JSONValue.string)
        return .object(entry)
    }

    private static func awake(_ args: ControlArguments, _ awake: KeepAwake) throws(ControlError) -> JSONValue {
        try only(["for"], args, "pilot system awake")
        let switchWord = args.positional.count > 1 ? args.positional[1] : nil
        if let switchWord, switchWord != "on", switchWord != "off" { throw ControlError(.badValue, "awake is on or off, not \(switchWord)") }
        if let word = args.value("for") {
            guard let length = lengths.first(where: { $0.word == word })?.length else {
                throw ControlError(.badValue, "--for is \(lengths.map(\.word).joined(separator: ", ")), not \(word)")
            }
            guard switchWord != "off" else { throw ControlError(.badRequest, "--for goes with on, or alone; off has no length") }
            awake.select(length)
        } else if args.has("for") {
            throw ControlError(.badRequest, "--for needs a value")
        }
        switch switchWord {
        case "on" where !awake.isOn: awake.turnOn(awake.length)
        case "off": awake.turnOff()
        default: break
        }
        if switchWord == "on", !awake.isOn { throw ControlError(.badValue, awake.problem ?? "macOS refused to keep the Mac awake") }
        return awakeRead(awake)
    }

    // MARK: Keyboard layout

    private static func layoutsRead(_ layouts: [InputSource]) -> JSONValue {
        .array(layouts.map { .object(["id": .string($0.id), "name": .string($0.name), "inUse": .bool($0.isCurrent)]) })
    }

    private static func layout(_ args: ControlArguments, _ system: ControlSystem) throws(ControlError) -> JSONValue {
        try only([], args, "pilot system layout")
        let layouts = system.layouts()
        guard args.positional.count > 1 else { return layoutsRead(layouts) }
        let word = args.positional[1]
        guard let layout = layouts.first(where: { $0.id == word }) ?? layouts.first(where: { $0.name.localizedCaseInsensitiveCompare(word) == .orderedSame }) else {
            throw ControlError(.badValue, "no keyboard layout \(word); layouts: \(layouts.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")); add one in System Settings › Keyboard › Text Input")
        }
        if !layout.isCurrent, let error = system.pickLayout(layout.id) { throw ControlError(.badValue, error) }
        return layoutsRead(system.layouts())
    }
}
