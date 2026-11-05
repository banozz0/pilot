@preconcurrency import Cocoa
import PilotCore

/// The HID-level event tap (ADR 0001). Swallows the layer key, swallows every key while Hyper is held and
/// runs the bound action in-process. Never re-posts or rewrites a key to trigger another app's hotkey.
@MainActor
final class HyperTap {
    /// Events Pilot posts itself (quick-tap Escape, later ctrl+N) carry this so the tap lets them through.
    static let ownEventMark: Int64 = 0x50494C54  // "PILT"
    /// Log every keyboard event the tap sees (debug level). Set PILOT_TRACE=1 in the environment.
    static let traceEvents = ProcessInfo.processInfo.environment["PILOT_TRACE"] == "1"

    private(set) var layer: HyperLayer
    var isBound: (Key) -> Bool = { _ in false }
    var onLayerChange: (Bool) -> Void = { _ in }
    var onRun: (Key, _ autorepeat: Bool) -> Void = { _, _ in }
    var onUnbound: (Key, _ autorepeat: Bool) -> Void = { _, _ in }
    /// The key a bind ran came up, or the tap lost track of it: a held action ends (card agent-bo-95423008).
    var onRelease: (Key) -> Void = { _ in }
    var onToggleCapsLock: () -> Void = { }
    /// Shift, Ctrl, Alt or Cmd pressed or released while the layer is held: the sublayer they name.
    var onModifiers: (Modifiers) -> Void = { _ in }
    /// Any key the layer takes, bound, unbound or recorded by the Binds editor: the hold-Hyper overlay closes on it.
    var onKey: () -> Void = { }
    /// One-shot: the next Hyper key comes here instead of running its bind (the Binds editor's Record, which takes a
    /// plain combo too).
    var captureNext: ((Key) -> Void)?
    /// The capture takes Hyper keys alone: a Cmd, Ctrl or Alt combo and every plain key go on as if none waited, so typing
    /// in the front app goes on under the bind hint's wait (story 122).
    var captureOnlyHyper = false
    /// While set, every Hyper key comes here too: the Binds board picks it (card agent-bo-95422993, G5). A bound one
    /// still runs, so every bind works with the board in front (T48, Sven 2026-11-04); a free one only picks. Plain
    /// combos run as ever, so the window's own Cmd keys keep working.
    var picking: ((Key) -> Void)?
    var onTapDisabled: (String) -> Void = { _ in }
    /// A Cmd+V going past, Sven's or one Pilot posted: a paste in sequence moves on (card agent-bo-95423071). Watched,
    /// never swallowed; it must return at once, as it runs inside the tap callback.
    var onPaste: () -> Void = { }
    /// Esc went down, whatever the layer does with it: a tiler drag under way is cancelled (card agent-bo-95423034).
    var onEscape: () -> Void = { }
    /// A take of Pilot's own dictation is starting or listening (Sven on Build 63: "esc doesn't stop dictation"): the
    /// keyboard's Esc, which the pill never gets as it is never key, is taken and `onDictationEscape` cancels the take as
    /// the pill's ✕ does. False outside a take, so every key pays this one check.
    var cancelsDictationOnEscape = false
    var onDictationEscape: () -> Void = { }
    /// A scrolling capture is running (Sven, 2026-10-18): the keyboard's Esc or Return ends it and keeps what it caught,
    /// whichever app is in front, Pilot's own control too, and the key is taken. Nil outside a capture.
    var endScrollCapture: (() -> Void)?
    /// A ring is open (P74): the keyboard's Esc goes back up a level inside a group, else closes it, running nothing, and
    /// is taken, under Hyper too (a ring a key holds open has Hyper down). Nil while no ring is open.
    var endRing: (() -> Void)?
    /// The open ring closed outright, running nothing, whatever level shows: every hold let go at once (releaseAll).
    var closeRing: (() -> Void)?
    /// How long a mouse trigger whose hold is bound must stay down before the hold runs (P74, Settings › Rings' Hold after);
    /// a quicker press is its click.
    var holdAfter: TimeInterval = 0.18
    /// A hold-bound media key let go before Hold after with no Click bind: it goes on to macOS's own Now Playing as Pilot's
    /// own media key, after the callback returned (ADR 0001: posted keys only into macOS's own). A button's or a keystroke's
    /// quick press runs its Click bind or nothing (Sven, Q370).
    var onReplay: (Key) -> Void = { _ in }
    /// The hold's one timer, armed as a hold-bound press is taken: off the tap's callback, so a test replaces it and calls
    /// `holdFired(_:)` itself. It carries the hold generation it was armed in.
    var armHold: (HyperTap, Key) -> Void = { tap, key in
        let generation = tap.holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + tap.holdAfter) { [weak tap] in
            MainActor.assumeIsolated { tap?.holdFired(key, generation: generation) }
        }
    }
    /// Bumped whenever every hold is let go (releaseAll): a timer armed before then finds a press whose release was lost
    /// and runs nothing, so no ring opens that nothing will close.
    private(set) var holdGeneration = 0
    /// Every key down the tap lets through to the focused app, with the characters it types, read only when asked:
    /// snippets watch for a keyword (card agent-bo-95423044). True keeps it from the app.
    var onTyped: (KeyEvent, () -> String) -> Bool = { _, _ in false }
    /// The keyboard's brightness up or down, as a system-defined event (card agent-bo-95423314). True takes it from
    /// macOS; it must return at once, as it runs inside the tap callback.
    var onBrightness: (BrightnessKeys.Press) -> Bool = { _ in false }
    /// One-shot: the next mouse trigger, a plain button or a media key the mouse sent, comes here and is taken (Binds ›
    /// Mouse's Learn, Q184).
    var captureMouse: ((Key) -> Void)?
    /// Learn listening (MouseButtons): each key pressed, with the HID service that sent it, so a mouse button remapped to
    /// a key is named (Q221). Only watched, never taken; nil outside Learn, so the tap pays one check.
    var learnKey: ((KeyEvent, UInt64) -> Void)?
    /// The catch waiting (MouseButtons): the key type of each media key that passes as the keyboard's, so Binds › Mouse
    /// says so, or asks for Input Monitoring. Only watched, never taken; nil outside a catch.
    var learnMedia: ((Int) -> Void)?
    /// The key codes bound as keys a mouse sends (MouseKeys.key, NGenuity's Esc on a side button): only these, any key
    /// while a catch waits, and the release of one taken, ask `isKeyFromMouse`, so every other key pays one set lookup.
    var mouseKeyCodes: Set<Int64> = []
    /// Whether a key, as its mouse trigger, came from the mouse it is bound to, or from a mouse at all while a catch waits;
    /// the second value is the HID service that sent it. Inside the tap callback: a lookup in ids resolved beforehand
    /// (MouseSenders), never the I/O registry.
    var isKeyFromMouse: (Key, UInt64) -> Bool = { _, _ in false }
    /// The event field holding the registry id of the HID service that sent the event (undocumented; Learn's log shows it).
    /// Nil if macOS ever drops it: Learn then names the key without its device.
    static let senderField = CGEventField(rawValue: 87)
    /// `senderField`, resolved when the tap is made, never first inside its callback.
    private let senderField = HyperTap.senderField
    /// Whether the mouse, not the keyboard, sent this media key (MouseMedia). Asked only for a first press that is bound
    /// to a mouse trigger or learnt, inside the tap callback, so it must return within milliseconds.
    var isFromMouse: (MouseKeys.MediaPress, Key) -> Bool = { _, _ in false }
    /// Whether a layer key is physically down now, read from the HID state rather than from events: a release the tap
    /// never saw (macOS had it off, a password field took the keyboard) must not leave the layer stuck down. Engine sets
    /// `hidKeyState`; the default trusts the events, so a test's tap never reads the real keyboard.
    var isLayerKeyDown: (LayerKey) -> Bool = { _ in true }
    static let hidKeyState: (LayerKey) -> Bool = { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0.keyCode)) }
    /// Voice › Dictation key (Q224): its tap or hold, for dictation's own action. The key is never taken.
    var onDictationKey: (DictationKeyWatch.Decision) -> Void = { _ in }
    /// Whether a mouse button went down or the wheel scrolled in the last so many seconds, asked once on a release that
    /// would be a dictation tap and once as a hold would start (a Ctrl+click or Ctrl+scroll zoom is neither). Engine sets
    /// `hidClickedWithin`; a test's tap never reads the real mouse.
    var clickedWithin: (TimeInterval) -> Bool = { _ in false }
    static let hidClickedWithin: (TimeInterval) -> Bool = { seconds in
        [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < seconds
        }
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lockObserver: (any NSObjectProtocol)?
    private let escapeSource = CGEventSource(stateID: .hidSystemState)
    /// The last four modifier changes the tap saw, Pilot's own too: what `optionWithoutCommand` logs (Sven on Build 74,
    /// "Cmd+C sometimes types ç"): their flags and the HID service that sent each, never a key code or text.
    private var recentModifiers: [(flags: UInt64, own: Bool, sender: UInt64)] = []
    /// Keys whose keyDown ran a bind, by key code, until their keyUp.
    private var down: [Int64: Key] = [:]
    private var mouse = MouseKeys.Router()
    private var mouseKeys = MouseKeys.KeyRouter()
    /// The dictation key picked, kept while a layer key takes it, so it comes back when that key stops being one.
    private var dictationPick: (key: DictationKey, mode: DictationKeyMode) = (.off, .toggle)
    private var dictationKey = DictationKeyWatch()
    /// Hold mode's one timer, armed as the key goes down alone: held past the tap window, talking starts. Off the tap's
    /// callback, so a test replaces it and calls `dictationKeyHeld(at:)` itself.
    var armDictationHold: (HyperTap) -> Void = { tap in
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationKeyWatch.window) { [weak tap] in
            MainActor.assumeIsolated { tap?.dictationKeyHeld(at: ProcessInfo.processInfo.systemUptime) }
        }
    }
    /// Secure input is on (a password field): the dictation key's release may never reach the tap, so it is ignored.
    private var secureInput = false
    /// The keys a modal took (dictation's Esc, a scrolling capture's Esc or Return), each until its release: their repeats
    /// and release are taken too, even once the modal has ended.
    private var modalKeysDown: Set<Int64> = []
    /// Lock keyboard for cleaning (KeyboardLock): while set, every key is taken before anything else looks at it. Nil
    /// otherwise, so an unlocked key pays this one check.
    private(set) var keyboardLock: KeyboardLock?
    /// Esc went down (true) or came up while locked, at that uptime: the 3 s hold starts or stops.
    var onLockEscape: (Bool, TimeInterval) -> Void = { _, _ in }
    /// The lock ended, whichever way: the overlay closes.
    var onUnlock: (KeyboardLock.End) -> Void = { _ in }

    init(layer: HyperLayer) { self.layer = layer }

    var isRunning: Bool { tap != nil }

    func update(layerKeys: [LayerKey], quickTapEscape: Bool) {
        let wasDown = layer.isDown
        layer = HyperLayer(layerKeys: layerKeys, quickTapEscape: quickTapEscape, quickTapWindow: layer.quickTapWindow, isOn: layer.isOn)
        if wasDown { onLayerChange(false) }
        update(dictationKey: dictationPick.key, mode: dictationPick.mode)
    }

    /// The quick tap's window, kept across re-arms (HoldOverlay.quickTapWindow).
    func update(quickTapWindow: TimeInterval) { layer.quickTapWindow = quickTapWindow }

    /// The dictation key and its mode; a layer key is Hyper, never the dictation key too.
    func update(dictationKey key: DictationKey, mode: DictationKeyMode) {
        dictationPick = (key, mode)
        let next = DictationKeyWatch(key: key.isFree(layerKeys: layer.layerKeys) ? key : .off, mode: mode)
        guard next.key != dictationKey.key || next.mode != dictationKey.mode else { return }
        dictated(dictationKey.reset())
        dictationKey = next
    }

    private func dictated(_ decision: DictationKeyWatch.Decision) {
        switch decision {
        case .none: break
        case .arm: armDictationHold(self)
        case .toggle, .hold: onDictationKey(decision)
        }
    }

    /// Hold mode's timer fired.
    func dictationKeyHeld(at now: TimeInterval) { dictated(dictationKey.held(at: now, clickedWithin: clickedWithin)) }

    /// Secure input on or off (SecureInputMonitor): on, the dictation key is let go and ignored until it is off.
    func setSecureInput(_ on: Bool) {
        secureInput = on
        if on { dictated(dictationKey.reset()) }
    }

    /// The layer let go without its key's release: a fresh layer, reported off once if it was down.
    private func dropLayer() {
        releaseMayBeLost = false
        update(layerKeys: layer.layerKeys, quickTapEscape: layer.quickTapEscape)
    }

    /// The layer key's release may have gone past the tap unseen: the screen locked or a password field took the keyboard
    /// while Hyper was held. Until the layer changes, a key under Hyper checks the key's real state.
    private(set) var releaseMayBeLost = false

    func mayHaveLostRelease() { if layer.isDown { releaseMayBeLost = true } }

    /// Whether Hyper is held, as a mouse press or a scroll under it asks (P51): once its release may have gone by unseen
    /// (the screen locked or secure input came on: `releaseMayBeLost`), the layer key's real state answers first
    /// (dropLayerIfKeyUp), so such a release does not keep a click or a scroll taken. A tap macOS turned off settles its
    /// own at re-enable (tapDisabled); a release lost any other way is not checked here. A mouse event's flags are not read: a modifier layer key (Control, Option or Command) may not show its device bit there.
    func isHyperHeld() -> Bool {
        if releaseMayBeLost { dropLayerIfKeyUp() }
        return layer.isDown
    }

    /// The layer is down but no layer key is: its release was lost, so let it go. `flags` is the arriving event's, whose
    /// device bits answer for a modifier layer key. Caps Lock has no bit, and the HID read is the key's state
    /// now, not the event's: a stalled tap reaching a fast Hyper+H after Caps Lock came up would drop a held layer. So an
    /// event trusts that read only once a release may be lost; the tap's own re-enable always reads it.
    private func dropLayerIfKeyUp(flags: UInt64? = nil) {
        guard layer.isDown else { return }
        let held = layer.layerKeys.contains { key in
            if let flags, let bit = key.deviceFlag { return flags & bit != 0 }
            return flags != nil && !releaseMayBeLost || isLayerKeyDown(key)
        }
        if held {
            releaseMayBeLost = false   // read down now with the tap on: its release will be seen
        } else {
            log.notice("Hyper release lost: layer let go")
            dropLayer()
        }
    }

    /// Hyper on or off (card agent-bo-95422986); the tap stays installed, so plain combos still run.
    func setHyper(_ on: Bool) {
        let wasDown = layer.isDown
        layer.isOn = on
        if wasDown && !on { onLayerChange(false) }
    }

    enum StartError: Error { case tapCreationFailed }

    func start() throws(StartError) {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventMask(BrightnessKeys.eventType))
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Last among HID taps, whenever Pilot starts: a keyboard-sharing app's tap (Deskflow) swallows every key while
        // its input is on another computer, so Hyper+Space reaches that computer rather than opening Pilot's menu (T29).
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback, userInfo: me) else {
            throw .tapCreationFailed
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: ScreenEvents.locked, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mayHaveLostRelease() }
        }
    }

    /// Off without being taken down: macOS stops sending Pilot any key until resume. Bitwarden's unlock pauses it so the
    /// master password typed into bw never reaches Pilot (card agent-bo-95422814).
    private(set) var isPaused = false

    func pause() {
        guard let tap, !isPaused else { return }
        unlockKeyboard(.tapOff)
        isPaused = true
        CGEvent.tapEnable(tap: tap, enable: false)
        dropLayer()
        releaseAll()
    }

    func resume() {
        guard let tap, isPaused else { return }
        isPaused = false
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        unlockKeyboard(.tapOff)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        dropLayer()
        releaseAll()
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        tap = nil; source = nil; lockObserver = nil
    }

    /// Key ups the tap will not see (paused, stopped, or dropped while macOS had it off) end every hold now.
    private func releaseAll() {
        // An open ring closes first, running nothing: its trigger's release below was lost, never let go on a wedge.
        closeRing?()
        holdGeneration &+= 1
        let keys = down.values
        down = [:]
        mouseKeys.reset()   // a button's late release is still taken (`mouse` keeps its holds); a key's passes
        modalKeysDown = []
        keys.forEach(onRelease)
        dictated(dictationKey.reset())
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapDisabled(type == .tapDisabledByTimeout ? "timeout" : "user input")
            return pass
        }
        if keyboardLock != nil { return locked(type, event) ? nil : pass }
        if Self.traceEvents {
            log.debug("event \(type.rawValue, privacy: .public) key \(event.getIntegerValueField(.keyboardEventKeycode), privacy: .public) flags \(event.flags.rawValue, privacy: .public)\(event.getIntegerValueField(.eventSourceUserData) == Self.ownEventMark ? " (own)" : "", privacy: .public)")
        }
        if type.rawValue == BrightnessKeys.eventType {
            let own = event.getIntegerValueField(.eventSourceUserData) == Self.ownEventMark
            return systemDefined(event, own: own) ? nil : pass
        }
        let kind: KeyEvent.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return pass
        }
        let e = KeyEvent(kind: kind, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                         flags: event.flags.rawValue,
                         autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                         time: ProcessInfo.processInfo.systemUptime)
        if kind == .flagsChanged {
            if recentModifiers.count == 4 { recentModifiers.removeFirst() }
            recentModifiers.append((e.flags, event.getIntegerValueField(.eventSourceUserData) == Self.ownEventMark, sender(of: event)))
        }
        // A Cmd+V that reaches the app counts, Pilot's own too (the first paste of a sequence, Omarchy's Hyper+V); one the
        // layer takes does not (Hyper+V with right Command as the layer key carries Command).
        if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventMark {
            if e.isPaste { onPaste() }
            return pass
        }
        // A layer key or a Hyper chord is the keyboard's, never a mouse button's: Learn watches neither.
        func mouseMay() -> Bool { !layer.isDown && layer.layerKey(keyCode: e.keyCode) == nil }
        // A key a mouse sends (its app set it on a button) is the mouse's: taken while a catch waits or when bound, from
        // that mouse only, so its Esc is caught rather than cancelling; the keyboard's same key goes on below. Under Hyper
        // a bound one runs its Hyper bind, else its plain one, and never reaches the layer. A taken press's repeats and
        // release follow it by sender, even once the catch has ended or a layer key went down.
        if kind != .flagsChanged, captureMouse != nil || mouseKeyCodes.contains(e.keyCode) || mouseKeys.holds(e.keyCode) {
            let sender = self.sender(of: event)
            let hyper = kind == .keyDown && !e.autorepeat && isHyperHeld() ? layer.sublayer(flags: e.flags) : nil
            let decision = mouseKeys.route(keyCode: e.keyCode, flags: e.flags, sender: sender, isDown: kind == .keyDown,
                                           isRepeat: e.autorepeat, learning: captureMouse != nil,
                                           mayStart: layer.layerKey(keyCode: e.keyCode) == nil, hyper: hyper,
                                           isBound: isBound, fromMouse: { isKeyFromMouse($0, sender) }, holds: isBound)
            if take(decision) { return nil }
        }
        // After the mouse's keys: a side button bound to Esc did its bind above, so only the keyboard's Esc gets here.
        if cancelsDictationOnEscape || endScrollCapture != nil || endRing != nil || !modalKeysDown.isEmpty, kind != .flagsChanged, modalKey(e) { return nil }
        if let learnKey, kind == .keyDown, !e.autorepeat, mouseMay() { learnKey(e, sender(of: event)) }
        if route(e) { return nil }
        if e.isPaste { onPaste() }
        guard kind == .keyDown else { return pass }
        optionWithoutCommand(e, from: sender(of: event))
        return onTyped(e, { Self.characters(of: event) }) ? nil : pass
    }

    /// A C or V reaching the app with Option and no Command or Control, as a keyboard sent it: ç or √ where a copy or a
    /// paste was meant. The tap passes it untouched, so the modifier changes before it say who sent the Option: left
    /// Option's device bit (0x20) without Command is the keyboard's; Command (0x100000) there and gone from the key lost it
    /// in the HID state; the sender ids name the keyboard or the mouse (the media log lines list each device's). Logs
    /// modifier flags and device ids only, never which key or what it types.
    private func optionWithoutCommand(_ e: KeyEvent, from sender: UInt64) {
        guard !e.autorepeat, e.keyCode == KeyCode.c || e.keyCode == KeyCode.v,
              e.flags & KeyEvent.chordMask == KeyEvent.altMask else { return }
        let before = recentModifiers.map { "0x\(String($0.flags, radix: 16)) from \($0.sender)\($0.own ? " (own)" : "")" }
        log.notice("Option without Command on a copy or paste key, flags 0x\(String(e.flags, radix: 16), privacy: .public) from \(sender, privacy: .public); modifier changes before it: \(before.joined(separator: ", "), privacy: .public)")
    }

    /// What a press of `keyCode` does while a modal runs: Esc cancels a dictation take; Esc or Return ends a scrolling
    /// capture. Nil lets it pass.
    /// Under Hyper only an open ring takes its Esc (a key holds it open); every other key is the layer's.
    private func modalAction(_ keyCode: Int64, underHyper: Bool = false) -> (() -> Void)? {
        if let endRing, keyCode == KeyCode.escape { return endRing }
        if underHyper { return nil }
        if cancelsDictationOnEscape, keyCode == KeyCode.escape { return onDictationEscape }
        switch keyCode {
        case KeyCode.escape, KeyCode.returnKey, KeyCode.keypadEnter: return endScrollCapture
        default: return nil
        }
    }

    /// A key while a modal runs: true takes it. A press decides afresh, so a release the tap missed never keeps a key
    /// taken; its repeats and release go where the press went, even once the modal has ended, so the app never gets a
    /// release without its press. Under Hyper the key is the layer's (modalAction); with Cmd, Ctrl or Option it is a
    /// shortcut (Cmd+Opt+Esc opens Force Quit).
    private func modalKey(_ e: KeyEvent) -> Bool {
        switch e.kind {
        case .keyDown where !e.autorepeat:
            let action = e.flags & KeyEvent.chordMask != 0 ? nil : modalAction(e.keyCode, underHyper: layer.isDown)
            if let action { modalKeysDown.insert(e.keyCode); action() } else { modalKeysDown.remove(e.keyCode) }
            return action != nil
        case .keyUp: return modalKeysDown.remove(e.keyCode) != nil
        default: return modalKeysDown.contains(e.keyCode)
        }
    }

    /// The registry id of the HID service that sent `event`; 0 when macOS does not say.
    private func sender(of event: CGEvent) -> UInt64 {
        senderField.map { UInt64(bitPattern: event.getIntegerValueField($0)) } ?? 0
    }

    /// Locks the keyboard (KeyboardLock): from now every key is taken until `unlockKeyboard`. The layer and every hold let
    /// go first, as their releases will not be seen. Refused while the tap is not taking keys (off, paused) or already
    /// locked, so a lock never claims keys it cannot take.
    func lockKeyboard(_ lock: KeyboardLock) -> Bool {
        guard tap != nil, !isPaused, keyboardLock == nil else { return false }
        dropLayer()
        releaseAll()
        keyboardLock = lock
        return true
    }

    /// Ends the lock, once: every later call does nothing. A key the lock took that is still down (Esc, held 3 s) stays
    /// taken as a modal's key, its repeats and release with it (modalKey), so none reaches the app in front.
    func unlockKeyboard(_ end: KeyboardLock.End) {
        guard let lock = keyboardLock else { return }
        keyboardLock = nil
        modalKeysDown.formUnion(lock.takenDown)
        onUnlock(end)
    }

    /// An event while the keyboard is locked: true takes it. Pilot's own posts pass; of the system-defined events only the
    /// keys' are taken (KeyboardLock.takes), so the mouse stays live. Past the safety unlock the lock ends and the event goes
    /// the unlocked way, a held key's repeat taken with its release (unlockKeyboard).
    private func locked(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.ownEventMark, var lock = keyboardLock else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if type.rawValue == BrightnessKeys.eventType {
            if now >= lock.until { unlockKeyboard(.safety); return handle(type: type, event: event) == nil }
            return NSEvent(cgEvent: event).map { KeyboardLock.takes(systemDefinedSubtype: Int($0.subtype.rawValue), data1: $0.data1) } ?? true
        }
        let kind: KeyEvent.Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return false
        }
        let outcome = lock.handle(KeyEvent(kind: kind, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue,
                                           autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, time: now))
        keyboardLock = lock
        switch outcome {
        case .take: return true
        case .pass: return false
        case .escape(let down): onLockEscape(down, now); return true
        case .expired: unlockKeyboard(.safety); return handle(type: type, event: event) == nil
        }
    }

    /// macOS turned the tap off: back on, and every release it may have missed meanwhile is settled now. Keys went past it
    /// meanwhile, so a keyboard lock ends.
    func tapDisabled(_ reason: String) {
        unlockKeyboard(.tapOff)
        if let tap, !isPaused { CGEvent.tapEnable(tap: tap, enable: true) }
        dropLayerIfKeyUp()
        releaseAll()
        onTapDisabled(reason)
    }

    /// A system-defined event: a media key the mouse sent and a bind or Learn wants is taken; the brightness keys go to
    /// onBrightness, which may take them; every other one (volume, media, the keyboard's own) passes untouched. Pilot's
    /// own media keys (Post.media) are never the mouse's.
    private func systemDefined(_ event: CGEvent, own: Bool) -> Bool {
        guard let ns = NSEvent(cgEvent: event) else { return false }
        let subtype = Int(ns.subtype.rawValue), data1 = ns.data1
        if captureMouse != nil {
            log.notice("mouse learn: system-defined subtype \(subtype, privacy: .public) data1 0x\(String(data1, radix: 16), privacy: .public)\(own ? " (own)" : "", privacy: .public) fields \(Self.fields(of: event), privacy: .public)")
        }
        if !own, let media = MouseKeys.MediaPress(subtype: subtype, data1: data1) {
            let hyper = media.isDown && !media.isRepeat && isHyperHeld()
            let decision = mouse.route(media.key, isDown: media.isDown, isRepeat: media.isRepeat, hyper: hyper, learning: captureMouse != nil,
                                       isBound: isBound, fromMouse: { isFromMouse(media, $0) }, holds: isBound)
            if take(decision) { return true }
            if let learnMedia, media.isDown, !media.isRepeat { learnMedia(media.keyType) }
        }
        guard let press = BrightnessKeys.press(subtype: subtype, data1: data1) else { return false }
        return onBrightness(press)
    }

    /// A mouse button past 2 (MouseButtonTap): true takes it. Paused (Bitwarden's unlock) or the keyboard locked, every
    /// press passes and no mouse bind runs. Under Hyper its Hyper bind runs (P51).
    func mouseButton(_ number: Int64, isDown: Bool) -> Bool {
        guard !isPaused, keyboardLock == nil else { return false }
        if captureMouse != nil, isDown { log.notice("mouse learn: button \(number, privacy: .public) (Mouse \(number + 1, privacy: .public))") }
        return take(mouse.route(MouseKeys.button(number), isDown: isDown, hyper: isDown && isHyperHeld(), learning: captureMouse != nil,
                                isBound: isBound, holds: isBound))
    }

    /// One step of Hyper + the wheel, bound (HyperScroll, after its callback): run and let go at once.
    func scrolled(_ key: Key) {
        guard keyboardLock == nil else { return }
        _ = take(.run(key))
        _ = take(.release(key))
    }

    /// Hold after ran out on a hold-bound press (P74): its hold runs if the press is still down and waiting, and every
    /// hold was not let go since the timer was armed (`generation`; nil from a test).
    func holdFired(_ key: Key, generation: Int? = nil) {
        guard !isPaused, keyboardLock == nil, generation.map({ $0 == holdGeneration }) ?? true else { return }
        _ = take(MouseKeys.isKey(key.keyCode) ? mouseKeys.fire(key) : mouse.fire(key))
    }

    /// Runs what a mouse trigger's decision says: true takes the event.
    private func take(_ decision: MouseKeys.Decision) -> Bool {
        switch decision {
        case .pass: return false
        case .swallow: return true
        // Held in `down` with the keys, so releaseAll ends a held mouse bind too. A bind run under Hyper, its Hyper one or
        // its plain one, used the held layer: no quick-tap Escape at its release.
        case .run(let key):
            layerUsed()
            down[key.keyCode] = key
            onRun(key, false)
        case .release(let key): if let key = down.removeValue(forKey: key.keyCode) { onRelease(key) }
        case .arm(let key): armHold(self, key)
        // A click with a bind of its own runs it at once; with none, a media key goes on to Now Playing, and a button's or
        // a keystroke's does nothing (Sven, Q370).
        case .click(let key):
            if isBound(key) { _ = take(.run(key)); _ = take(.release(key)) } else if MouseKeys.isMedia(key.keyCode) { onReplay(key) }
        case .learn(let key):
            let capture = captureMouse
            captureMouse = nil
            capture?(key)
        }
        return true
    }

    /// Every integer field the event has set, "n=v" for fields 0 to 199: Learn's log line, so the first press shows
    /// whether any field names the device that sent it.
    static func fields(of event: CGEvent) -> String {
        (UInt32(0)..<200).compactMap { raw -> String? in
            guard let field = CGEventField(rawValue: raw) else { return nil }
            let v = event.getIntegerValueField(field)
            return v == 0 ? nil : "\(raw)=\(v)"
        }.joined(separator: " ")
    }

    /// The characters a key event types, as the focused app gets them (the layout and Shift or Option applied).
    static func characters(of event: CGEvent) -> String {
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        return String(utf16CodeUnits: units, count: length)
    }

    /// What the tap does with a key event, CGEvent aside, so tests drive it: true swallows it.
    func route(_ e: KeyEvent) -> Bool {
        if e.kind == .keyDown, e.keyCode == KeyCode.escape { onEscape() }
        // Watched, never taken: a lone tap of the dictation key reaches the app as the plain modifier it is.
        if dictationKey.key != .off, !secureInput { dictated(dictationKey.handle(e, layerDown: layer.isDown, clickedWithin: clickedWithin)) }
        // One HID read per key pressed under Hyper, never per typed key: a layer stuck down lets this key through.
        if e.kind == .keyDown, !e.autorepeat, layer.isDown, layer.layerKey(keyCode: e.keyCode) == nil { dropLayerIfKeyUp(flags: e.flags) }
        if e.kind == .flagsChanged, layer.isDown, layer.layerKey(keyCode: e.keyCode) == nil { onModifiers(layer.sublayer(flags: e.flags)) }
        let onlyHyper = captureOnlyHyper, bound = isBound
        let decision = layer.handle(e, isBound: captureNext == nil ? isBound : { $0.hyper || !onlyHyper || bound($0) })
        if e.kind == .keyUp, let key = down.removeValue(forKey: e.keyCode) { onRelease(key) }
        switch decision {
        case .pass: return false
        case .swallow: return true
        case .layerOn:
            releaseMayBeLost = false
            onLayerChange(true)
        case .layerOff(let quickTap):
            releaseMayBeLost = false
            onLayerChange(false)
            // During a take or a scrolling capture the quick tap's Esc is theirs, as the keyboard's is; posted, it would
            // pass as Pilot's own.
            if quickTap { if let action = modalAction(KeyCode.escape) { action() } else { postEscape() } }
        case .run(let key, let autorepeat):
            onKey()
            if let capture = captureNext, key.hyper || !captureOnlyHyper { captureNext = nil; capture(key) }
            else {
                // The board shows the key, then the bind runs: a pick never eats a bound key (T48).
                _ = pick(key, autorepeat)
                if !autorepeat { down[e.keyCode] = key }
                onRun(key, autorepeat)
            }
        case .unbound(let key):
            onKey()
            if !pick(key, e.autorepeat) { onUnbound(key, e.autorepeat) }
        case .toggleCapsLock: onToggleCapsLock()
        }
        return true
    }

    /// Hyper held alone at a mouse press's flags (HyperLayer.isHeldAlone).
    func isHeldAlone(flags: UInt64) -> Bool { layer.isHeldAlone(flags: flags) }

    /// A Hyper drag took the held layer (MouseDragTap): no quick-tap Escape at its release, and the overlay closes as
    /// for a key. No bind runs: the tap never sees the mouse.
    func layerUsed() {
        guard layer.isDown else { return }
        layer.markUsed()
        onKey()
    }

    /// A Hyper key to the Binds board while it picks, once per press; false when it is not picking. A free key stops
    /// here; a bound one runs after it (route).
    private func pick(_ key: Key, _ autorepeat: Bool) -> Bool {
        guard let picking, key.hyper else { return false }
        if !autorepeat { picking(key) }
        return true
    }

    /// The one key Pilot sends to the focused app: Escape for a quick tap of the layer key, as the user asked.
    private func postEscape() {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: escapeSource, virtualKey: CGKeyCode(KeyCode.escape), keyDown: down) else { continue }
            e.setIntegerValueField(.eventSourceUserData, value: Self.ownEventMark)
            e.post(tap: .cghidEventTap)
        }
        log.notice("quick tap: Escape")
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HyperTap>.fromOpaque(userInfo).takeUnretainedValue()
    // The tap's run loop source lives on the main run loop, so this runs on the main thread.
    nonisolated(unsafe) let event = event
    return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
}
