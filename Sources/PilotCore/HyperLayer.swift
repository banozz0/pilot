import Foundation

/// One keyboard event as the tap sees it, stripped to what the layer needs.
public struct KeyEvent: Sendable, Equatable {
    public enum Kind: Sendable { case keyDown, keyUp, flagsChanged }
    public var kind: Kind
    public var keyCode: Int64
    /// Raw CGEventFlags: device bits for the layer key, shift for binds.
    public var flags: UInt64
    public var autorepeat: Bool
    public var time: TimeInterval

    public init(kind: Kind, keyCode: Int64, flags: UInt64 = 0, autorepeat: Bool = false, time: TimeInterval = 0) {
        self.kind = kind; self.keyCode = keyCode; self.flags = flags; self.autorepeat = autorepeat; self.time = time
    }

    public static let shiftMask: UInt64 = 0x20000  // CGEventFlags.maskShift
    public static let ctrlMask: UInt64 = 0x40000, altMask: UInt64 = 0x80000, cmdMask: UInt64 = 0x100000
    /// CGEventFlags.maskSecondaryFn.
    public static let fnMask: UInt64 = 0x800000
    /// NX_DEVICELALTKEYMASK, NX_DEVICELCMDKEYMASK: left Option and left Command down.
    public static let leftAltDeviceMask: UInt64 = 0x20, leftCmdDeviceMask: UInt64 = 0x8
    /// NX_DEVICERCTLKEYMASK: right Control down.
    public static let rightCtrlDeviceMask: UInt64 = 0x2000
    public var shift: Bool { flags & Self.shiftMask != 0 }

    /// cmd, ctrl and alt (CGEventFlags maskCommand, maskControl, maskAlternate): the chord a keyboard sends as Hyper.
    public static let chordMask: UInt64 = cmdMask | ctrlMask | altMask
    public var isChord: Bool { flags & Self.chordMask == Self.chordMask }

    /// A paste pressed: Cmd+V going down, Shift or Option allowed, Control not, not a repeat (card agent-bo-95423071).
    public var isPaste: Bool {
        kind == .keyDown && keyCode == KeyCode.v && !autorepeat && flags & (Self.cmdMask | Self.ctrlMask) == Self.cmdMask
    }

    /// Each modifier's mask with its left and right device bits (IOLLEvent.h NX_DEVICE*KEYMASK) and its left and right
    /// key codes (kVK_Shift, kVK_RightShift and so on).
    private static let sides: [(mask: UInt64, left: UInt64, right: UInt64, modifiers: (left: Modifiers, right: Modifiers),
                                keys: (left: Int64, right: Int64))] = [
        (shiftMask, 0x2, 0x4, (.leftShift, .rightShift), (56, 60)),
        (ctrlMask, 0x1, rightCtrlDeviceMask, (.leftCtrl, .rightCtrl), (KeyCode.leftControl, KeyCode.rightControl)),
        (altMask, 0x20, 0x40, (.leftAlt, .rightAlt), (KeyCode.leftOption, KeyCode.rightOption)),
        (cmdMask, 0x8, 0x10, (.leftCmd, .rightCmd), (KeyCode.leftCommand, KeyCode.rightCommand)),
    ]

    /// Both device bits of the modifier `mask` is, left and right.
    static func deviceBits(of mask: UInt64) -> UInt64 { sides.first { $0.mask == mask }.map { $0.left | $0.right } ?? 0 }

    /// One modifier side's mask and device bit (`.leftCtrl` is ctrlMask and NX_DEVICELCTLKEYMASK); nil for none or both.
    public static func bits(of side: Modifiers) -> (mask: UInt64, device: UInt64)? {
        for m in sides {
            if side == m.modifiers.left { return (m.mask, m.left) }
            if side == m.modifiers.right { return (m.mask, m.right) }
        }
        return nil
    }

    /// Every modifier's mask with both its device bits, Fn's too: any modifier held.
    public static let modifierMask: UInt64 = sides.reduce(fnMask) { $0 | $1.mask | $1.left | $1.right }

    /// The plain combos this keyDown can be (story 51), most specific first: the more held modifiers a candidate names
    /// by the side their device bit gives, rather than as either side, the earlier. A modifier with no device bit (a
    /// posted event) is either side.
    public var plainCombos: [Key] {
        var choices: [Modifiers] = [[]]
        for m in Self.sides where flags & m.mask != 0 {
            let left = flags & m.left != 0, right = flags & m.right != 0
            let both = m.modifiers.left.union(m.modifiers.right)
            let exact: Modifiers = left == right ? both : left ? m.modifiers.left : m.modifiers.right
            let options = exact == both ? [both] : [exact, both]
            choices = options.flatMap { o in choices.map { $0.union(o) } }
        }
        func oneSided(_ m: Modifiers) -> Int { Self.sides.count { m.contains($0.modifiers.left) != m.contains($0.modifiers.right) } }
        return choices.sorted { oneSided($0) > oneSided($1) }.map { Key(keyCode: keyCode, modifiers: $0, hyper: false) }
    }

    /// A keystroke into the focused app as a keyboard sends it (card agent-bo-95422753): each modifier pressed, the key
    /// down and up, the modifiers released in reverse, every event carrying exactly the flags held at that moment and
    /// the last none. A modifier named on both sides presses its left key. Posting only the key with the modifier's flag
    /// left macOS holding it (Command stuck after Cmd+V), and an event with no flags set takes the source's own.
    public static func keystroke(_ keyCode: Int64, modifiers: Modifiers) -> [KeyEvent] {
        let pressed: [(code: Int64, side: Modifiers)] = sides.compactMap { m in
            modifiers.contains(m.modifiers.left) ? (m.keys.left, m.modifiers.left)
                : modifiers.contains(m.modifiers.right) ? (m.keys.right, m.modifiers.right) : nil
        }
        var held = Modifiers(), downs: [KeyEvent] = [], ups: [KeyEvent] = []
        for m in pressed { held.insert(m.side); downs.append(KeyEvent(kind: .flagsChanged, keyCode: m.code, flags: flags(for: held))) }
        let all = flags(for: held)
        for m in pressed.reversed() { held.remove(m.side); ups.append(KeyEvent(kind: .flagsChanged, keyCode: m.code, flags: flags(for: held))) }
        return downs + [KeyEvent(kind: .keyDown, keyCode: keyCode, flags: all), KeyEvent(kind: .keyUp, keyCode: keyCode, flags: all)] + ups
    }

    /// The flags a posted event carries for `modifiers`: one side sets that side's device bit too, both sides only the
    /// modifier's own mask, which plainCombos reads as either side.
    public static func flags(for modifiers: Modifiers) -> UInt64 {
        sides.reduce(0) { flags, m in
            let left = modifiers.contains(m.modifiers.left), right = modifiers.contains(m.modifiers.right)
            guard left || right else { return flags }
            return flags | m.mask | (left == right ? 0 : left ? m.left : m.right)
        }
    }
}

/// What the tap should do with an event.
public enum LayerDecision: Sendable, Equatable {
    /// Not ours: let it through.
    case pass
    /// Ours: eat it, nothing to run.
    case swallow
    case layerOn
    /// The layer key came up. `quickTap` means nothing was pressed and it was short: send Escape.
    case layerOff(quickTap: Bool)
    /// A bound key went down while Hyper is held.
    case run(Key, autorepeat: Bool)
    /// An unbound key went down while Hyper is held (swallowed, worth logging).
    case unbound(Key)
    /// Shift+Caps Lock: flip the real Caps Lock state, the key's old job (story 54).
    case toggleCapsLock
}

/// The layer state machine. Pure, so it is tested without a window server (ADR 0001: the tap owns the binds).
public struct HyperLayer: Sendable {
    /// Each alone is Hyper, all binds the same (Sven 2026-10-12); Caps Lock first, never empty.
    public let layerKeys: [LayerKey]
    /// Per modifier, fixed with the keys, the flag that makes it a sublayer while held (the sublayer reads them on every
    /// modifier change): its mask when no layer key is that modifier; else the device bit of the side that is no layer
    /// key, 0 when both sides are, so never.
    private let ctrlNeeds: UInt64, altNeeds: UInt64, cmdNeeds: UInt64
    public var quickTapEscape: Bool
    /// A hold shorter than this with no key pressed counts as a tap. It ends where the hold-Hyper overlay shows, so a
    /// hold that showed the overlay never also sends Escape (card agent-bo-95422993, G10).
    public var quickTapWindow: TimeInterval
    /// Hyper on (card agent-bo-95422986). Off, the layer key and chord Hyper stop and Caps Lock flips Caps Lock again;
    /// plain combos are not Hyper and still run. Off while held lets the layer go: the tap reports that.
    public var isOn = true {
        didSet { if !isOn { isDown = false; heldBy = nil } }
    }

    public private(set) var isDown = false
    /// The layer key that put the layer down: its release ends the layer; another layer key meanwhile is swallowed.
    private var heldBy: LayerKey?
    private var usedWhileDown = false
    private var downSince: TimeInterval = 0
    /// Keys whose chord or plain-combo keyDown ran a bind, so their keyUp is swallowed too, whatever the modifiers are by then.
    private var chordKeys: Set<Int64> = []

    public init(layerKeys: [LayerKey], quickTapEscape: Bool = false, quickTapWindow: TimeInterval = HoldOverlay.delay, isOn: Bool = true) {
        self.layerKeys = LayerKey.ordered(layerKeys) ?? [.capsLock]
        let keys = self.layerKeys
        func needs(_ mask: UInt64) -> UInt64 {
            let picked = keys.reduce(UInt64(0)) { $1.modifierMask == mask ? $0 | ($1.deviceFlag ?? 0) : $0 }
            return picked == 0 ? mask : KeyEvent.deviceBits(of: mask) & ~picked
        }
        ctrlNeeds = needs(KeyEvent.ctrlMask); altNeeds = needs(KeyEvent.altMask); cmdNeeds = needs(KeyEvent.cmdMask)
        self.quickTapEscape = quickTapEscape; self.quickTapWindow = quickTapWindow; self.isOn = isOn
    }

    public init(layerKey: LayerKey, quickTapEscape: Bool = false, quickTapWindow: TimeInterval = HoldOverlay.delay, isOn: Bool = true) {
        self.init(layerKeys: [layerKey], quickTapEscape: quickTapEscape, quickTapWindow: quickTapWindow, isOn: isOn)
    }

    /// The layer key `keyCode` is, if any: at most seven compares, on every event.
    public func layerKey(keyCode: Int64) -> LayerKey? {
        for key in layerKeys where key.keyCode == keyCode { return key }
        return nil
    }

    public mutating func handle(_ e: KeyEvent, isBound: (Key) -> Bool) -> LayerDecision {
        if let key = layerKey(keyCode: e.keyCode), let down = Self.isPressed(key, e) {
            if !isOn {
                guard key.needsCapsLockRemap else { return .pass }
                return down && !e.autorepeat ? .toggleCapsLock : .swallow
            }
            // A repeat with the layer off belongs to a Shift+Caps Lock press: one toggle, never a late layerOn.
            if down, !isDown, e.autorepeat { return .swallow }
            if down, !isDown, e.shift, key.needsCapsLockRemap { return .toggleCapsLock }
            return transition(key, down: down, at: e.time)
        }
        switch e.kind {
        case .flagsChanged:
            return .pass   // shift and friends still reach the app; binds read them from the event
        case .keyUp:
            return chordKeys.remove(e.keyCode) != nil || isDown ? .swallow : .pass
        case .keyDown:
            if isDown {
                usedWhileDown = true
                let key = Key(keyCode: e.keyCode, modifiers: sublayer(e))
                return isBound(key) ? .run(key, autorepeat: e.autorepeat) : .unbound(key)
            }
            // Chord Hyper (story 93): a cmd+ctrl+alt keyDown from the keyboard, Shift optional. A bound chord runs and
            // is swallowed with its keyUp; any other chord passes untouched, so another app's own hotkey still sees
            // it. Nothing is reposted.
            if e.isChord {
                guard isOn else { return .pass }
                let key = Key(keyCode: e.keyCode, modifiers: e.shift ? .shift : [])
                guard isBound(key) else { return .pass }
                chordKeys.insert(e.keyCode)
                return .run(key, autorepeat: e.autorepeat)
            }
            // Plain combo (story 51): cmd, ctrl or alt without Hyper, left and right apart; the most specific bind wins.
            // An unbound one passes untouched, so right Alt keeps typing accents.
            guard e.flags & KeyEvent.chordMask != 0, let key = e.plainCombos.first(where: isBound) else { return .pass }
            chordKeys.insert(e.keyCode)
            return .run(key, autorepeat: e.autorepeat)
        }
    }

    /// Hyper held with no sublayer, as a mouse press sees it (story 119's Hyper drag): the layer key down, or a keyboard's
    /// cmd+ctrl+alt chord without Shift.
    public func isHeldAlone(flags: UInt64) -> Bool {
        let e = KeyEvent(kind: .keyDown, keyCode: 0, flags: flags)
        return isDown ? sublayer(e).isEmpty : isOn && e.isChord && !e.shift
    }

    /// Something other than a key used the held layer (a Hyper drag): its release is no quick tap, so no Escape follows.
    public mutating func markUsed() { usedWhileDown = true }

    /// The sublayer `flags` name while the layer is held: what the hold-Hyper overlay pages by.
    public func sublayer(flags: UInt64) -> Modifiers { sublayer(KeyEvent(kind: .keyDown, keyCode: 0, flags: flags)) }

    /// Shift, Ctrl, Alt and Cmd held with the layer key, either side, except a layer key's own side: right Option as a
    /// layer key is no Alt sublayer, left Option with it is. A chord's cmd+ctrl+alt is the chord itself.
    private func sublayer(_ e: KeyEvent) -> Modifiers {
        var held: Modifiers = e.shift ? .shift : []
        if e.isChord { return held }
        if e.flags & KeyEvent.ctrlMask != 0, e.flags & ctrlNeeds != 0 { held.formUnion(.ctrl) }
        if e.flags & KeyEvent.altMask != 0, e.flags & altNeeds != 0 { held.formUnion(.alt) }
        if e.flags & KeyEvent.cmdMask != 0, e.flags & cmdNeeds != 0 { held.formUnion(.cmd) }
        return held
    }

    private static func isPressed(_ layerKey: LayerKey, _ e: KeyEvent) -> Bool? {
        if let flag = layerKey.deviceFlag {
            guard e.kind == .flagsChanged else { return nil }
            return e.flags & flag != 0
        }
        switch e.kind {
        case .keyDown: return true
        case .keyUp: return false
        case .flagsChanged: return nil
        }
    }

    private mutating func transition(_ key: LayerKey, down: Bool, at time: TimeInterval) -> LayerDecision {
        // A second layer key while the first holds the layer is used, so the release is no quick tap; its own release,
        // like an autorepeat or a duplicate flag change, is swallowed.
        if isDown, heldBy != key {
            if down { usedWhileDown = true }
            return .swallow
        }
        if down == isDown { return .swallow }
        isDown = down
        heldBy = down ? key : nil
        if down {
            usedWhileDown = false
            downSince = time
            return .layerOn
        }
        let tapped = quickTapEscape && !usedWhileDown && (time - downSince) < quickTapWindow
        return .layerOff(quickTap: tapped)
    }
}
