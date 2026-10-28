import Foundation

/// A mouse's extra buttons as triggers (Q184): a plain button press (CGEvent's button number, 2 the wheel click), a
/// media key the mouse itself sends, as a HyperX mouse's onboard memory does, or a keyboard key it sends (NGenuity's
/// Esc on a side button, Build 62). Each is a plain `Key` on a code no keyboard has, so the bind store keeps them as any
/// other bind, schema 3 unchanged: `{"hyper": false, "key": "Mouse 4"}`, `"Mouse Key Escape"`. A key from the mouse is
/// its own trigger, apart from the keyboard's: binding the mouse's Next or Esc leaves the keyboard's alone, under Hyper too.
/// Hyper + a button (P51, Q300) is the same trigger with `hyper: true`, a second bind beside the plain press's; the wheel's
/// two directions are triggers under Hyper only, "Hyper+Mouse Scroll Up". Holding a trigger (P74) is a trigger of its own,
/// "Mouse 4 Hold", on a code past every other: its bind (a ring) runs once the press outlasts Hold after, a quicker press
/// staying the button's click.
public enum MouseKeys {
    static let buttonBase: Int64 = 1000, mediaBase: Int64 = 1100, keyBase: Int64 = 1200, scrollBase: Int64 = 1328, end: Int64 = 1330
    /// Holds mirror every plain trigger below `end`, the wheel's aside: `hold(t)` is t's code plus this.
    static let holdOffset: Int64 = end - buttonBase, holdEnd: Int64 = end + (end - buttonBase)

    /// The trigger for a button: CGEvent's number, 0 the left button, so 3 is "Mouse 4", the usual back button.
    public static func button(_ number: Int64) -> Key { Key(keyCode: buttonBase + number, hyper: false) }

    /// The trigger for a media key the mouse sends, by its NX_KEYTYPE.
    public static func media(_ keyType: Int) -> Key { Key(keyCode: mediaBase + Int64(keyType), hyper: false) }

    /// The trigger for a keyboard key the mouse sends, by its virtual key code, with the modifiers it carries (each one
    /// both sides, as a mouse's app sets them).
    public static func key(_ keyCode: Int64, flags: UInt64 = 0) -> Key {
        Key(keyCode: keyBase + keyCode, modifiers: modifiers(flags), hyper: false)
    }

    /// Hyper + the wheel rolled up or down, one notch (P51).
    public static let scrollUp = Key(keyCode: scrollBase, hyper: true), scrollDown = Key(keyCode: scrollBase + 1, hyper: true)

    /// `key` under Hyper: the second bind a button carries.
    public static func underHyper(_ key: Key) -> Key { Key(keyCode: key.keyCode, modifiers: key.modifiers, hyper: true) }

    /// Holding `key` past Hold after (P74): its own trigger, never under Hyper, the modifiers a key the mouse sends carries kept.
    public static func hold(_ key: Key) -> Key { Key(keyCode: key.keyCode + holdOffset, modifiers: key.modifiers, hyper: false) }
    /// The trigger a hold is of; any other trigger as it is.
    public static func plain(_ key: Key) -> Key {
        isHold(key.keyCode) ? Key(keyCode: key.keyCode - holdOffset, modifiers: key.modifiers, hyper: false) : key
    }
    public static func isHold(_ code: Int64) -> Bool { (end..<holdEnd).contains(code) }

    public static func isMouse(_ code: Int64) -> Bool { (buttonBase..<holdEnd).contains(code) }
    public static func isMedia(_ code: Int64) -> Bool { (mediaBase..<keyBase).contains(code) }
    public static func isButton(_ code: Int64) -> Bool { (buttonBase..<mediaBase).contains(code) }
    public static func isKey(_ code: Int64) -> Bool { (keyBase..<scrollBase).contains(code) }
    public static func isScroll(_ code: Int64) -> Bool { (scrollBase..<end).contains(code) }
    /// A trigger a mouse bind may hold: any mouse trigger but the main clicks (Mouse 1 and 2, which the button tap never
    /// hears), the wheel's under Hyper only, so a plain scroll always scrolls.
    public static func isTrigger(_ key: Key) -> Bool {
        // A hold is of a plain trigger the wheel's scroll aside, never under Hyper.
        if isHold(key.keyCode) { let p = plain(key); return !key.hyper && !isScroll(p.keyCode) && isTrigger(p) }
        return isMouse(key.keyCode) && !isMainClick(key.keyCode) && (key.hyper || !isScroll(key.keyCode))
    }
    /// The left and right buttons, Mouse 1 and 2: their own clicks, and Hyper + drag's.
    public static func isMainClick(_ code: Int64) -> Bool { (buttonBase..<buttonBase + 2).contains(code) }
    /// The keyboard's key code a key trigger stands for; nil for any other trigger.
    public static func keyCode(of trigger: Key) -> Int64? { isKey(trigger.keyCode) ? trigger.keyCode - keyBase : nil }
    /// A trigger the mouse sends from its keyboard part, a media key or a key, as its own app set on a button: it is
    /// tied to the device it came from and to the button it was caught for.
    public static func isSent(_ code: Int64) -> Bool { (mediaBase..<scrollBase).contains(code) }

    /// NX_KEYTYPE names, as the keyboard's top row has them.
    static let mediaNames: [Int: String] = [0: "Volume Up", 1: "Volume Down", 7: "Mute", 16: "Play", 17: "Next", 18: "Previous",
                                             19: "Fast", 20: "Rewind"]

    /// "Mouse 4", "Mouse Next", "Mouse Media 9", "Mouse Key Escape", "Mouse Scroll Up", "Mouse 4 Hold"; nil for a keyboard code.
    public static func name(for code: Int64) -> String? {
        if isHold(code) { return name(for: code - holdOffset).map { $0 + " Hold" } }
        if isButton(code) { return "Mouse \(code - buttonBase + 1)" }
        if isScroll(code) { return code == scrollBase ? "Mouse Scroll Up" : "Mouse Scroll Down" }
        if isKey(code) { return "Mouse Key " + KeyNames.name(for: code - keyBase) }
        guard isMedia(code) else { return nil }
        let type = Int(code - mediaBase)
        return "Mouse " + (mediaNames[type] ?? "Media \(type)")
    }

    /// Reads `name(for:)` back, any case.
    public static func code(for name: String) -> Int64? {
        let lower = name.lowercased()
        guard lower.hasPrefix("mouse ") else { return nil }
        if lower.hasSuffix(" hold") {
            return code(for: String(name.dropLast(5))).flatMap { $0 < end && !isScroll($0) ? $0 + holdOffset : nil }
        }
        let rest = lower.dropFirst(6)
        if let n = Int64(rest), n >= 1, n <= mediaBase - buttonBase { return buttonBase + n - 1 }
        if rest == "scroll up" || rest == "scroll down" { return rest == "scroll up" ? scrollBase : scrollBase + 1 }
        if rest.hasPrefix("key "), let key = KeyNames.code(for: String(rest.dropFirst(4))), (0..<scrollBase - keyBase).contains(key) {
            return keyBase + key
        }
        if let (type, _) = mediaNames.first(where: { $0.value.lowercased() == rest }) { return mediaBase + Int64(type) }
        if rest.hasPrefix("media "), let type = Int64(rest.dropFirst(6)), type >= 0, type < keyBase - mediaBase { return mediaBase + type }
        return nil
    }

    /// A media key as a system-defined event carries it: NX_SYSDEFINED subtype 8 (NX_SUBTYPE_AUX_CONTROL_BUTTONS), the
    /// key type in data1's high 16 bits, the state in bits 8 to 15 (0x0A down, 0x0B up), a repeat in bit 0.
    public struct MediaPress: Equatable, Sendable {
        public var keyType: Int, isDown: Bool, isRepeat: Bool
        public init(keyType: Int, isDown: Bool, isRepeat: Bool) { self.keyType = keyType; self.isDown = isDown; self.isRepeat = isRepeat }

        public init?(subtype: Int, data1: Int) {
            let state = (data1 >> 8) & 0xFF
            guard subtype == 8, state == 0x0A || state == 0x0B else { return nil }
            self.init(keyType: (data1 >> 16) & 0xFFFF, isDown: state == 0x0A, isRepeat: data1 & 1 != 0)
        }

        public var key: Key { MouseKeys.media(keyType) }
    }

    /// The device a media trigger was learnt from: its vendor and product, which stay the same across a replug or a
    /// restart (a registry entry id does not), and its name for the page. A media key binds to this device alone, so a
    /// keyboard that also shows a mouse (Sven's Keychron V3 Max) keeps its own media keys.
    public struct Device: Hashable, Sendable, Codable {
        public var vendor: Int, product: Int, name: String
        public init(vendor: Int, product: Int, name: String) { self.vendor = vendor; self.product = product; self.name = name }

        public func isSame(as other: Device) -> Bool { vendor == other.vendor && product == other.product }
    }

    /// The highest button a mouse has, read from its HID report descriptor: the button usages (page 9) its mouse
    /// collection reports, at most the 32 a CGEvent numbers (0 to 31), so a trigger never leaves the button range. The
    /// descriptor is a device property any process reads, so listing a mouse's buttons needs no Input Monitoring; the
    /// media keys it may send stay unlisted, as its consumer part declares any usage of a range.
    public static func buttonCount(descriptor: [UInt8]) -> Int {
        var page: UInt32 = 0, usages: [UInt32] = []   // usages and usage maximums: the highest button is all that counts
        var mouse: [Bool] = []   // per open collection: whether it is, or sits in, a mouse
        var count = 0, i = 0
        while i < descriptor.count {
            let prefix = descriptor[i]
            if prefix == 0xFE { i += 3 + (i + 1 < descriptor.count ? Int(descriptor[i + 1]) : 0); continue }   // long item
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard i + size < descriptor.count else { break }
            let value = (0..<size).reduce(UInt32(0)) { $0 | UInt32(descriptor[i + 1 + $1]) << (8 * $1) }
            i += 1 + size
            // A 4-byte usage carries its own page in the high half.
            func usage(_ v: UInt32) -> UInt32 { size == 4 ? v : page << 16 | v }
            switch prefix & 0xFC {
            case 0x04: page = value                                    // usage page
            case 0x08, 0x28: usages.append(usage(value))               // usage, usage maximum
            case 0xA0:                                                 // collection
                mouse.append(mouse.last == true || usages.first == UInt32(0x01) << 16 | 0x02)
            case 0xC0: _ = mouse.popLast()                             // end collection
            case 0x80 where mouse.last == true:                        // input
                for u in usages where u >> 16 == 0x09 { count = max(count, Int(u & 0xFFFF)) }
            default: break
            }
            if prefix & 0x0C == 0 { usages = [] }   // a main item ends the locals
        }
        return min(count, 32)
    }

    /// A key press as Learn names it, "Cmd+[": its modifiers read from the event's flags, each side as one.
    public static func keyLabel(keyCode: Int64, flags: UInt64) -> String {
        Key(keyCode: keyCode, modifiers: modifiers(flags), hyper: false).label
    }

    /// The modifiers an event's flags hold, each one both sides.
    static func modifiers(_ flags: UInt64) -> Modifiers {
        let masks: [(UInt64, Modifiers)] = [(KeyEvent.shiftMask, .shift), (KeyEvent.ctrlMask, .ctrl), (KeyEvent.altMask, .alt),
                                            (KeyEvent.cmdMask, .cmd)]
        return masks.reduce(into: Modifiers()) { m, pair in if flags & pair.0 != 0 { m.formUnion(pair.1) } }
    }

    /// The catch's line when a key arrives instead of a mouse button, as a button remapped in the mouse's own app sends one
    /// (Q221). `isMouse` says whether the device that sent it shows a mouse, nil when the device is unknown; `press` names
    /// the button the catch waits for.
    public static func keyNote(_ key: String, from device: String?, isMouse: Bool?, press button: String? = nil) -> String {
        switch isMouse {
        case true?: "This button sends \(key), not a mouse button: reset it in \(app(device)) or bind that key."
        case false?: Catch.keyboard(press: button)
        case nil: "That was \(key), a key, not a mouse button. If your mouse sent it, reset that button in the mouse's own app or bind that key."
        }
    }

    /// Binds › Mouse's catch in plain words (Q257), as Sven picked them from the mockups.
    public enum Catch {
        public static func quiet(seconds: Int) -> String { "Nothing arrived in \(seconds) seconds." }
        /// P51: a button that works inside the mouse alone (the Pulsefire Core's DPI button behind the wheel, most likely)
        /// sends the Mac nothing, so no app can bind it.
        public static let quietWhy = "That button sends nothing to the Mac, so Pilot can't bind it. Some buttons work inside the "
            + "mouse alone, like a DPI button that changes the pointer speed. Or the mouse's own app switched it off."

        /// P57: nothing bindable arrived, but the mouse sent reports on its own vendor channel (a HyperX DPI press may),
        /// `report` the last one as the log has it (`learn: vendor report`), "report 6: 06 01 02 00".
        public static func vendorWhy(_ report: String) -> String {
            "Your mouse sent this on its own channel: \(report). Pilot can't bind it, and the mouse still changes its own "
                + "setting, like DPI."
        }

        public static func keyboard(press button: String?) -> String {
            "That was your keyboard. Press \(button ?? "the button") on the mouse."
        }

        /// A media key passed as the keyboard's because Pilot can't read input devices yet.
        public static func locked(_ key: String) -> String {
            "A \(key) arrived, but Pilot can't tell your mouse from your keyboard until you allow Input Monitoring."
        }

        public static func otherMouse(_ device: String, not mice: [String]) -> String {
            "That came from \(device), not \(mice.joined(separator: " or "))."
        }

        /// "Back sends Button 4.", "Back sends the Play key, from HyperX Pulsefire Core."; `button` nil for a button the
        /// drawing lacks.
        public static func sends(_ button: String?, _ key: Key, from device: String?) -> String {
            let what = MouseKeys.isSent(key.keyCode) ? "the \(MouseKeys.sends(key))" : MouseKeys.sends(key)
            return "\(button ?? "The button") sends \(what)" + (device.map { ", from \($0)." } ?? ".")
        }

        /// Q309: Other button… caught a button the drawing has. On Sven's Pulsefire Core the DPI button behind the wheel sends
        /// Button 3 as the wheel click does, from the same element of the same report: nothing tells the two apart.
        public static func shared(_ button: String, sends: String, device: String?) -> String {
            "That sent \(sends), the same as \(button). If you pressed another button, two buttons send \(sends) and Pilot "
                + "can't tell them apart: map one to another key in \(MouseKeys.app(device))."
        }

        public static func removed(_ button: String) -> String { "Remove: \(button) does its own job again." }
    }

    /// A button's name as drawn and listed: 3 to 5 the wheel click and the side buttons, the rest by number. P57: "Wheel
    /// click", not "Middle", so the wheel's press reads apart from its scrolling.
    public static func buttonName(_ n: Int) -> String {
        switch n {
        case 3: "Wheel click"
        case 4: "Back"
        case 5: "Forward"
        default: "Button \(n)"
        }
    }

    /// What a trigger sends, as Binds › Mouse names it: "Button 4", "Play key", "Esc key", "Cmd+[ key". The file keeps
    /// `name(for:)`.
    public static func sends(_ key: Key) -> String {
        if let n = number(key) { return "Button \(n)" }
        if isScroll(key.keyCode) { return key.keyCode == scrollBase ? "Scroll up" : "Scroll down" }
        if let code = keyCode(of: key) { return (key.modifiers.labels + [code == 53 ? "Esc" : KeyNames.name(for: code)]).joined(separator: "+") + " key" }
        return (name(for: key.keyCode).map { String($0.dropFirst("Mouse ".count)) } ?? "") + " key"
    }

    /// The button a plain trigger is (Mouse 4 is 4); nil for a media key.
    public static func number(_ key: Key) -> Int? { isButton(key.keyCode) ? Int(key.keyCode - buttonBase + 1) : nil }

    /// The app a mouse's buttons are set in: HyperX's NGenuity, or the maker's own.
    static func app(_ device: String?) -> String { device?.contains("HyperX") == true ? "NGenuity" : "the mouse's own app" }

    /// The consumer-page usages (HID page 0x0C) macOS turns into each NX key type; nil for a key type without one here,
    /// which any usage from the device answers.
    public static func usages(keyType: Int) -> Set<UInt32>? {
        switch keyType {
        case 0: [0xE9]                  // volume up
        case 1: [0xEA]                  // volume down
        case 7: [0xE2]                  // mute
        case 16: [0xCD, 0xB0, 0xB1]     // play/pause, play, pause
        case 17: [0xB5]                 // scan next track
        case 18: [0xB6]                 // scan previous track
        case 19: [0xB3]                 // fast forward
        case 20: [0xB4]                 // rewind
        default: nil
        }
    }

    /// The consumer presses the HID side saw from devices that show a mouse, newest last, for the tap to claim one each.
    public struct Presses: Sendable {
        public static let window: UInt64 = 150_000_000

        struct Press { var time: UInt64, usage: UInt32, device: Device }
        private var presses: [Press] = []

        public init() {}

        public mutating func note(time: UInt64, usage: UInt32, device: Device) {
            presses.append(Press(time: time, usage: usage, device: device))
            if presses.count > 8 { presses.removeFirst() }
        }

        /// Whose press a media key may be: Learn's, any device that shows a mouse; a bind's, only its own device.
        public enum Source: Equatable, Sendable {
            case anyMouse, device(Device)

            /// Learn listening, or the bind's device. A bind with no device recorded (hand-edited, or from an older file)
            /// has none: it is never the mouse's, so a keyboard that also shows a mouse keeps its media keys.
            public static func of(learning: Bool, bound: Device?) -> Source? { learning ? .anyMouse : bound.map(Source.device) }
        }

        /// The newest press from `source` under 150 ms old, of a usage `keyType` comes from, taken so it answers once.
        public mutating func claim(keyType: Int, from source: Source, now: UInt64) -> Device? {
            let usages = MouseKeys.usages(keyType: keyType)
            guard let i = presses.lastIndex(where: { p in
                guard now &- p.time < Self.window, usages.map({ $0.contains(p.usage) }) != false else { return false }
                if case .device(let device) = source { return p.device.isSame(as: device) }
                return true
            }) else { return nil }
            return presses.remove(at: i).device
        }
    }

    /// What the tap does with a mouse trigger's press.
    public enum Decision: Equatable, Sendable {
        /// Not the mouse's, or the mouse's with no bind: it goes on as today.
        case pass
        /// A repeat of a press already taken.
        case swallow
        case run(Key)
        /// The key up of a press that ran.
        case release(Key)
        /// The press of a trigger whose hold is bound (P74), taken: the tap waits Hold after, then asks `fire` for the hold.
        case arm(Key)
        /// That press let go before its hold ran: the trigger's click, its own bind; unbound, a media key goes on to macOS's
        /// Now Playing, and a button's or a keystroke's does nothing (Sven, Q370).
        case click(Key)
        /// Learning (the Binds page's Learn): taken, and the trigger goes to the page.
        case learn(Key)
    }

    /// A mouse trigger's press or release. Each new press decides: taken while learning or bound, and for a media key
    /// only once the mouse is found to have sent it (`fromMouse`, asked of the HID side only then), so the keyboard's
    /// media keys and an unbound button pass untouched. Under Hyper (P51) its Hyper bind runs, else its plain one as
    /// without Hyper. Repeats and the release follow that answer, by the plain trigger, so a release never splits from
    /// its press, even when Hyper came up between them.
    public struct Router: Sendable {
        /// `armed`: a hold's press waiting for Hold after (P74); its release before then is the click.
        struct Held: Sendable { var trigger: Key, learnt: Bool, armed = false }
        private var held: [Key: Held] = [:]   // plain trigger → the trigger that ran
        /// Presses of a held trigger that another device sent (the keyboard's Next while the mouse's is down): a system
        /// event names no sender, so each pairs with the next release, which passes with it, and the mouse's run still ends.
        private var passed: [Key: Int] = [:]

        public init() {}

        /// `hyper`: the layer is held as the press arrives. `fromMouse` is asked of the trigger tried. `holds`: whether a
        /// trigger's hold (P74) is bound, asked first, of `MouseKeys.hold(key)`.
        public mutating func route(_ key: Key, isDown: Bool, isRepeat: Bool = false, hyper: Bool = false, learning: Bool,
                                   isBound: (Key) -> Bool, fromMouse: (Key) -> Bool = { _ in true },
                                   holds: (Key) -> Bool = { _ in false }) -> Decision {
            if isDown && !isRepeat {
                // A new press decides again, so a hold whose release went by unseen never swallows it. A catch takes
                // what the button sends, Hyper or not.
                func takes(_ k: Key) -> Bool { (learning || isBound(k)) && fromMouse(k) }
                let underHyper = MouseKeys.underHyper(key), hold = MouseKeys.hold(key)
                // A bound hold waits (P74); its Hyper bind still runs at once under Hyper.
                let waits = !learning && !(hyper && takes(underHyper)) && !MouseKeys.isScroll(key.keyCode) && holds(hold) && fromMouse(hold)
                if let trigger = waits ? hold : hyper && !learning && takes(underHyper) ? underHyper : takes(key) ? key : nil {
                    held[key] = Held(trigger: trigger, learnt: learning, armed: waits)
                    passed[key] = nil   // counts left from releases the tap never saw would let this release go
                    return learning ? .learn(key) : waits ? .arm(key) : .run(trigger)
                }
                if held[key] != nil { passed[key, default: 0] += 1 }
                return .pass
            }
            guard let h = held[key] else { return .pass }
            if let n = passed[key] {
                if !isDown { passed[key] = n > 1 ? n - 1 : nil }
                return .pass
            }
            if isDown { return .swallow }
            held[key] = nil
            return h.learnt ? .swallow : h.armed ? .click(key) : .release(h.trigger)
        }

        /// Hold after ran out on `key`'s press (P74): its hold runs while the press is still down and waiting, once.
        public mutating func fire(_ key: Key) -> Decision {
            guard held[key]?.armed == true, passed[key] == nil, let h = held[key] else { return .pass }
            held[key]?.armed = false
            return .run(h.trigger)
        }
    }

    /// A key a mouse sends, pressed and released (Build 62). Each taken press is held by its key code and the HID service
    /// that sent it, so its release and repeats match on those alone: modifiers that change meanwhile (Shift, a macro
    /// letting go of Cmd first) never strand it, and the keyboard's same key, from another sender, never touches it.
    public struct KeyRouter: Sendable {
        struct Press: Hashable, Sendable { var keyCode: Int64, sender: UInt64 }
        /// `armed`: a hold's press waiting for Hold after (P74).
        struct Held: Sendable { var trigger: Key, learnt: Bool, armed = false }
        private var held: [Press: Held] = [:]

        public init() {}

        /// Whether a taken press on `keyCode` waits for its release: one emptiness check while nothing is held.
        public func holds(_ keyCode: Int64) -> Bool { !held.isEmpty && held.keys.contains { $0.keyCode == keyCode } }

        /// Forgets every hold: the tap was off, so their releases may never come (`HyperTap.releaseAll` ends their runs).
        public mutating func reset() { held = [:] }

        /// A key event from `sender`. A new press is taken only when `mayStart` (it is no layer key) and, as its mouse
        /// trigger, it is learnt or bound and `fromMouse` says the mouse sent it; a held press's repeats and release are
        /// taken whatever else changed, its release ending a run even when the bind is gone. `hyper`: the layer is held,
        /// with the sublayer's modifiers (the layer key's own left out); then its Hyper bind runs, else its plain one as
        /// a button's does (Router), so a bound key from the mouse never reaches the layer (Sven, 2026-10-19: Hyper +
        /// Forward, NGenuity's Esc, locked the screen).
        public mutating func route(keyCode: Int64, flags: UInt64, sender: UInt64, isDown: Bool, isRepeat: Bool, learning: Bool,
                                   mayStart: Bool, hyper: Modifiers? = nil, isBound: (Key) -> Bool, fromMouse: (Key) -> Bool,
                                   holds: (Key) -> Bool = { _ in false }) -> Decision {
            let press = Press(keyCode: keyCode, sender: sender)
            if let h = held[press] {
                if isDown && isRepeat { return .swallow }
                held[press] = nil
                // A new press on a hold whose release went by unseen decides again, never swallowed.
                if !isDown { return h.learnt ? .swallow : h.armed ? .click(MouseKeys.plain(h.trigger)) : .release(h.trigger) }
            }
            guard isDown, !isRepeat, mayStart, sender != 0 else { return .pass }
            func takes(_ k: Key) -> Bool { (learning || isBound(k)) && fromMouse(k) }
            let plain = hyper.map { Key(keyCode: MouseKeys.keyBase + keyCode, modifiers: $0, hyper: false) } ?? MouseKeys.key(keyCode, flags: flags)
            let underHyper = MouseKeys.underHyper(plain), hold = MouseKeys.hold(plain)
            let waits = !learning && !(hyper != nil && takes(underHyper)) && holds(hold) && fromMouse(hold)
            guard let trigger = waits ? hold : hyper != nil && !learning && takes(underHyper) ? underHyper : takes(plain) ? plain : nil else { return .pass }
            held[press] = Held(trigger: trigger, learnt: learning, armed: waits)
            return learning ? .learn(trigger) : waits ? .arm(plain) : .run(trigger)
        }

        /// Hold after ran out on the press of `plain` (P74): its hold runs while that press is still down and waiting, once.
        public mutating func fire(_ plain: Key) -> Decision {
            guard let press = held.first(where: { $0.value.armed && MouseKeys.plain($0.value.trigger) == plain })?.key, let h = held[press] else { return .pass }
            held[press]?.armed = false
            return .run(h.trigger)
        }
    }
}
