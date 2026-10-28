@preconcurrency import Cocoa
import IOKit.hid
import Observation
import os
import PilotCore
import Synchronization

private let mouseLog = Logger(subsystem: "dev.banozz.pilot", category: "mouse")

/// A mouse's extra buttons as binds (Q184): Binds › Mouse catches a button's press (Q257), then the bind runs on it. A plain button
/// (3 and up) comes through MouseButtonTap; a media key the mouse sends comes through the keyboard tap's system-defined
/// events, where MouseMedia tells the mouse's from the keyboard's. Both are on only while a mouse bind or a catch needs them,
/// and an unbound button passes as before.
@Observable @MainActor
final class MouseButtons {
    enum Learn: Equatable {
        case idle, listening
        /// Nothing arrived in the wait: the taps are off again, and Try again starts a new wait.
        case quiet
        /// The trigger pressed, and the device that sent a media key, which the bind is then held to.
        case got(Key, device: MouseKeys.Device?)
    }

    private(set) var learn: Learn = .idle
    /// Whether macOS lets Pilot read input devices (Input Monitoring): the mouse's media keys are told from the keyboard's
    /// only with it, when the mouse sends them from its keyboard part, as gaming mice do.
    private(set) var access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)

    /// The connected mice and their buttons from 3 up (`findMice`), each ready to bind without a press.
    struct Found: Equatable {
        var mice: [MouseKeys.Device] = []
        var buttons: [Key] = []
        var names: [String] { Array(Set(mice.map(\.name))).sorted() }
    }
    private(set) var found = Found()
    /// The catch's line while it waits: a key that arrived instead of a mouse button (Q221), or a media key Pilot can't
    /// place without Input Monitoring (`askAccess`).
    private(set) var note: String?
    private(set) var askAccess = false
    /// A catch that ended quiet: the last report the mouse sent on its own vendor channel meanwhile (P57), which Pilot
    /// logs but can't bind, a HyperX DPI press's most likely.
    private(set) var vendorReport: String?
    /// The button the catch is for, as drawn and listed (3 the wheel click): a media key caught is tied to it, so the bind
    /// shows on the button clicked (Sven, Build 60: the wheel click NGenuity set to Play read Not bound). Nil for
    /// Other button…, a button the drawing lacks.
    private(set) var target: Int?
    /// Whether the flow binds the button's second action, for Hyper + it (P51): the catch is the same, the bind is the
    /// trigger under Hyper.
    private(set) var hyper = false
    /// When the wait runs out, for the page's countdown.
    private(set) var deadline: Date?
    /// How long a catch waits for a press, in seconds.
    static var quietAfter: TimeInterval = 8

    @ObservationIgnored private let tap: HyperTap
    @ObservationIgnored private let buttons: MouseButtonTap
    @ObservationIgnored let media = MouseMedia()
    @ObservationIgnored private let vendor = MouseVendor()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var triggers: Set<Int64> = []
    /// Each bound media key's device: only a press from it is the trigger's.
    @ObservationIgnored private var devices: [Key: MouseKeys.Device] = [:]
    @ObservationIgnored private var quiet: DispatchWorkItem?
    /// Each sender a catch has looked up, so a held or repeated key reads the I/O registry once.
    @ObservationIgnored private var senders: [UInt64: MouseKeys.Device?] = [:]
    /// The HID services the mice send keys through, resolved off the tap's path, for the tap's `isKeyFromMouse`.
    @ObservationIgnored let keySenders = MouseSenders()
    /// The mouse the last key `isKeyFromMouse` took came from, for the catch's "from …".
    @ObservationIgnored private var lastKeyDevice: MouseKeys.Device?

    init(tap: HyperTap) {
        self.tap = tap
        buttons = MouseButtonTap(layer: tap)
        // A catch hears any mouse; a bound media key only the device it was caught from, and one with none is never the mouse's.
        tap.isFromMouse = { [unowned self] press, trigger in
            guard let source = MouseKeys.Presses.Source.of(learning: learn == .listening, bound: devices[trigger]) else { return false }
            return media.claim(press, from: source)
        }
        // A key the mouse sends: while a catch waits, from any mouse found; bound, only from the device it was caught from.
        tap.isKeyFromMouse = { [unowned self] trigger, sender in
            guard let device = keySenders.devices[sender] else {
                keySenders.missed(sender)
                return false
            }
            let mine = learn == .listening ? found.mice.contains { $0.isSame(as: device) } : devices[trigger]?.isSame(as: device) == true
            if mine { lastKeyDevice = device }
            return mine
        }
    }

    /// The taps the binds need: `running` while the keyboard tap is, `binds` the mouse binds, a hold's (P74) needing its
    /// trigger's.
    func arm(running: Bool, binds: [(trigger: Key, bind: BindStore.MouseBind)]) {
        self.running = running
        triggers = Set(binds.map { MouseKeys.plain($0.trigger).keyCode })
        tap.mouseKeyCodes = Set(binds.compactMap { MouseKeys.keyCode(of: MouseKeys.plain($0.trigger)) })
        devices = Dictionary(binds.compactMap { b in b.bind.device.map { (b.trigger, $0) } }, uniquingKeysWith: { a, _ in a })
        apply()
    }

    /// A catch keeps both on until its trigger is saved or dropped, so the caught press's release is taken too.
    private func apply() {
        let learning = switch learn { case .listening, .got: true; case .idle, .quiet: false }
        buttons.arm(running && (learning || triggers.contains(where: MouseKeys.isButton)))
        let keyDevices = devices.filter { MouseKeys.isKey($0.key.keyCode) }.map(\.value)
        keySenders.watch(running ? keyDevices + (learn == .listening ? found.mice : []) : [], fresh: learn == .listening)
        media.run(running && (learning || triggers.contains(where: MouseKeys.isMedia)), verbose: learn == .listening)
        // Through the picker too, so a report sent alongside the caught press is logged (Q309: is the DPI button's Button 3
        // told apart by one?); stopped here, never on the tap's path, where a catch's press only schedules this.
        if !learning { vendor.watch([]) }
    }

    /// The catch, for button `target` (nil: Other button…) and its Hyper bind when `hyper`: the next mouse button, or media
    /// key from the mouse, is taken and shown; nothing runs meanwhile. The keyboard tap only watches.
    func startLearning(for target: Int? = nil, hyper: Bool = false) {
        access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        stopListening()
        learn = .listening
        vendorReport = nil
        vendor.watch(found.mice)
        self.target = target
        self.hyper = hyper
        mouseLog.notice("learn: listening for \(target.map(String.init) ?? "another button", privacy: .public); Input Monitoring \(Self.describe(self.access), privacy: .public)")
        tap.captureMouse = { [weak self] key in
            guard let self else { return }
            stopListening()
            let device = MouseKeys.isMedia(key.keyCode) ? media.lastClaimed : MouseKeys.isKey(key.keyCode) ? lastKeyDevice : nil
            mouseLog.notice("learn: got \(key.label, privacy: .public)\(device.map { " from \($0.name) (\($0.vendor):\($0.product))" } ?? "", privacy: .public)")
            learn = .got(key, device: device)
            DispatchQueue.main.async { self.apply() }   // verbose off, after the tap callback
        }
        // A key is named after the tap callback, off its path: finding the device reads the I/O registry.
        tap.learnKey = { [weak self] key, sender in DispatchQueue.main.async { self?.heard(key, sender: sender) } }
        tap.learnMedia = { [weak self] keyType in DispatchQueue.main.async { self?.heardMedia(keyType) } }
        wait()
        apply()
    }

    /// The wait, from now: when it runs out with nothing caught, the catch ends quiet.
    private func wait() {
        quiet?.cancel()
        let quiet = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.learn == .listening else { return }
                let report = self.vendor.report
                mouseLog.notice("learn: nothing arrived\(report.map { "; last vendor \($0)" } ?? "", privacy: .public)")
                self.end(.quiet)
                self.vendorReport = report
            }
        }
        self.quiet = quiet
        deadline = Date(timeIntervalSinceNow: Self.quietAfter)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietAfter, execute: quiet)
    }

    /// A key pressed while the catch waits: named, with the device that sent it, as a mouse button remapped to a key sends
    /// one. The wait starts over for the button itself.
    private func heard(_ key: KeyEvent, sender: UInt64) {
        guard learn == .listening else { return }
        let device = sender == 0 ? nil : senders[sender] ?? {
            let device = Self.device(sender: sender)
            senders[sender] = device
            return device
        }()
        mouseLog.notice("learn: a key arrived from sender \(sender, privacy: .public)\(device.map { " (\($0.name), \($0.vendor):\($0.product))" } ?? " (not found)", privacy: .public)")
        note = MouseKeys.keyNote(MouseKeys.keyLabel(keyCode: key.keyCode, flags: key.flags), from: device?.name,
                                 isMouse: device.map { d in found.mice.contains { $0.isSame(as: d) } }, press: target.map(MouseKeys.buttonName))
        askAccess = false
        wait()
    }

    /// A media key the mouse was not found to send while the catch waits: the keyboard's, or, before Input Monitoring is
    /// allowed, anyone's. The wait starts over.
    private func heardMedia(_ keyType: Int) {
        guard learn == .listening else { return }
        access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        askAccess = access != kIOHIDAccessTypeGranted
        let key = MouseKeys.sends(MouseKeys.media(keyType))
        mouseLog.notice("learn: \(key, privacy: .public) passed as the keyboard's; Input Monitoring \(Self.describe(self.access), privacy: .public)")
        note = askAccess ? MouseKeys.Catch.locked(key) : MouseKeys.Catch.keyboard(press: target.map(MouseKeys.buttonName))
        wait()
    }

    /// The device behind a HID service's registry id, read from the I/O registry: no permission, nil when it is gone.
    nonisolated static func device(sender: UInt64) -> MouseKeys.Device? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(sender))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, nil,
                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        }
        guard let name = (property(kIOHIDProductKey) as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return MouseKeys.Device(vendor: property(kIOHIDVendorIDKey) as? Int ?? 0, product: property(kIOHIDProductIDKey) as? Int ?? 0, name: name)
    }

    /// The catch stops waiting: no key watch, no wait, no line.
    private func stopListening() {
        tap.learnKey = nil
        tap.learnMedia = nil
        senders = [:]
        quiet?.cancel()
        quiet = nil
        deadline = nil
        note = nil
        askAccess = false
    }

    /// Changes a bound button: straight to picking its action, as Pilot knows what the button sends. A catch that was
    /// waiting keeps its taps on, as after a press, and stops its verbose HID log.
    func pick(_ key: Key, device: MouseKeys.Device? = nil, button: Int? = nil, hyper: Bool = false) {
        end(.got(key, device: device))
        target = button
        self.hyper = hyper
    }

    /// The catch stops waiting and moves to `learn`, its taps set to match.
    private func end(_ learn: Learn) {
        tap.captureMouse = nil
        stopListening()
        self.learn = learn
        apply()
    }

    /// Lists the connected mice (`found`) from each one's HID report descriptor: a one-off look that opens nothing and
    /// keeps nothing, so it needs no Input Monitoring. A device with no button past the two main ones (a trackpad) is left
    /// out, and so is a pointer that has never sent an event, as a keyboard's receiver shows one (Keychron Link).
    func findMice() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse] as CFDictionary)
        var candidates: [Candidate] = []
        for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
            guard let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else { continue }
            var mouse = MouseMedia.info(device)
            mouse.name = mouse.name.trimmingCharacters(in: .whitespaces)
            candidates.append(Candidate(device: mouse, buttons: MouseKeys.buttonCount(descriptor: Array(descriptor)),
                                        sentEvents: Self.sentEvents(IOHIDDeviceGetService(device))))
        }
        let found = Self.found(candidates)
        mouseLog.notice("mice: \(found.names.joined(separator: ", "), privacy: .public), \(found.buttons.count + 2, privacy: .public) buttons; \(candidates.map { "\($0.device.name) \($0.buttons) \($0.sentEvents.map { $0 ? "used" : "never used" } ?? "unknown")" }.joined(separator: ", "), privacy: .public)")
        if found != self.found {
            self.found = found
            apply()
        }
    }

    /// A pointer the HID side lists: its device, its buttons, and whether it has sent an event since it was connected
    /// (nil when macOS does not say).
    struct Candidate { var device: MouseKeys.Device, buttons: Int, sentEvents: Bool? }

    /// The mice to show: those with a button past the main clicks that have sent an event, or whose use is unknown; when
    /// none has, every one with such a button, rather than none.
    static func found(_ candidates: [Candidate]) -> Found {
        let mice = candidates.filter { $0.buttons > 2 }
        let used = mice.filter { $0.sentEvents != false }
        var shown: [Candidate] = []
        for c in used.isEmpty ? mice : used where !shown.contains(where: { $0.device.isSame(as: c.device) }) { shown.append(c) }
        let count = shown.map(\.buttons).max() ?? 2
        return Found(mice: shown.map(\.device).sorted { $0.name < $1.name }, buttons: (2..<max(count, 2)).map { MouseKeys.button(Int64($0)) })
    }

    /// Whether the pointer behind `service` has sent an event: the event count its HID event service keeps for the
    /// WindowServer's client ("DebugState", read from the I/O registry, no permission). Nil when no such count is there.
    nonisolated static func sentEvents(_ service: io_service_t) -> Bool? {
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(children) }
        var seen = false, events = 0
        while case let entry = IOIteratorNext(children), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let state = IORegistryEntryCreateCFProperty(entry, "DebugState" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            seen = true
            events += state["EnqueueEventCount"] as? Int ?? 0
        }
        return seen ? events > 0 : nil
    }

    func cancel() {
        end(.idle)
        target = nil
        hyper = false
    }

    /// Asks macOS for Input Monitoring: its prompt the first time, Privacy & Security once it was denied.
    func requestAccess() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        } else {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if media.isRunning { media.run(false, verbose: false); apply() }
    }

    static func describe(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted: "granted"
        case kIOHIDAccessTypeDenied: "denied"
        default: "not asked"
        }
    }
}

/// The HID services each watched mouse sends keys through (Build 62, NGenuity's Esc on a side button), by registry id:
/// every service under the mouse's HID devices, its keyboard part's event service among them. Resolved from the I/O
/// registry on the main thread, never inside the tap callback: whenever the watched mice change or a catch starts,
/// whenever a HID event service publishes (a replug, a wake; the device's own match can come before its event service),
/// and once for each sender a bound key missed, so the tap only looks an id up. Nothing is watched, and no port is open,
/// while no mouse key is bound and no catch waits.
@MainActor
final class MouseSenders {
    /// The sending services' ids and the mouse each belongs to.
    var devices: [UInt64: MouseKeys.Device] = [:]
    private var watched: [MouseKeys.Device] = []
    private var port: IONotificationPortRef?
    private var connected: io_iterator_t = 0
    /// Senders a bound key came from that no watched mouse had, each resolved for once (the keyboard's stays a miss).
    private var misses: Set<UInt64> = []

    /// Watches `mice`; `fresh` reads their services again even when they are the same mice (a catch starting).
    func watch(_ mice: [MouseKeys.Device], fresh: Bool = false) {
        let models = { (list: [MouseKeys.Device]) in Set(list.map { [$0.vendor, $0.product] }) }
        guard fresh || models(mice) != models(watched) else { return }
        watched = models(mice).compactMap { m in mice.first { [$0.vendor, $0.product] == m } }
        listen(!watched.isEmpty)
        resolve()
    }

    /// A bound key from a sender no watched mouse has: resolved once more, after the tap callback, in case the mouse's
    /// event service published after the last read.
    func missed(_ sender: UInt64) {
        guard !watched.isEmpty, misses.insert(sender).inserted else { return }
        DispatchQueue.main.async { [weak self] in self?.resolve() }
    }

    /// Reads every watched mouse's sending services afresh.
    func resolve() {
        guard !watched.isEmpty else { return devices = [:] }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, watched.map { [kIOHIDVendorIDKey: $0.vendor, kIOHIDProductIDKey: $0.product] } as CFArray)
        var found: [UInt64: MouseKeys.Device] = [:]
        for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
            var mouse = MouseMedia.info(device)
            mouse.name = mouse.name.trimmingCharacters(in: .whitespaces)
            for id in Self.ids(under: IOHIDDeviceGetService(device)) { found[id] = mouse }
        }
        devices = found
        mouseLog.notice("senders: \(found.count, privacy: .public) services for \(self.watched.map(\.name).joined(separator: ", "), privacy: .public)")
    }

    /// `service`'s registry id and every one under it.
    nonisolated static func ids(under service: io_service_t) -> [UInt64] {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        var ids = [id]
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS
        else { return ids }
        defer { IOObjectRelease(children) }
        while case let entry = IOIteratorNext(children), entry != 0 {
            if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS { ids.append(id) }
            IOObjectRelease(entry)
        }
        return ids
    }

    /// A HID device connecting resolves again, on the main run loop.
    private func listen(_ on: Bool) {
        if on, port == nil {
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
            let me = Unmanaged.passUnretained(self).toOpaque()
            IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"), hidConnected, me, &connected)
            Self.drain(connected)   // arms the notification
            self.port = port
        } else if !on, let port {
            if connected != 0 { IOObjectRelease(connected); connected = 0 }
            IONotificationPortDestroy(port)
            self.port = nil
        }
    }

    fileprivate func connectedDevice(_ iterator: io_iterator_t) {
        Self.drain(iterator)
        resolve()
    }

    nonisolated private static func drain(_ iterator: io_iterator_t) {
        while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
    }
}

private let hidConnected: IOServiceMatchingCallback = { refcon, iterator in
    guard let refcon else { return }
    let senders = Unmanaged<MouseSenders>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { senders.connectedDevice(iterator) }
}

/// Mouse buttons 3 and up (otherMouseDown/Up) on a session tap of their own, so the keyboard tap's mask never gains the
/// mouse (typing-lag rule). Installed only while a button bind or Learn needs it; the keyboard tap decides each press.
@MainActor
final class MouseButtonTap {
    private let layer: HyperTap
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(layer: HyperTap) { self.layer = layer }

    func arm(_ on: Bool) {
        if on, tap == nil {
            let mask = (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
            let me = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: buttonCallback, userInfo: me) else {
                return mouseLog.error("buttons: mouse button tap not created")
            }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tap = tap
            self.source = source
            mouseLog.notice("buttons: tap on")
        } else if !on, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            self.tap = nil; source = nil
            mouseLog.notice("buttons: tap off")
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type == .otherMouseDown || type == .otherMouseUp else { return pass }
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        return layer.mouseButton(number, isDown: type == .otherMouseDown) ? nil : pass
    }
}

private let buttonCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MouseButtonTap>.fromOpaque(userInfo).takeUnretainedValue()
    nonisolated(unsafe) let event = event
    return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
}

/// Tells a media key the mouse sent from the keyboard's (Q184). A CGEvent names no device, so an IOHIDManager, never
/// seizing, watches the consumer controls (usage page 0x0C) of every HID device on a queue of its own and notes each press
/// from a device whose vendor and product also show a mouse. The tap claims the newest such press under 150 ms old of the
/// usage its key type comes from, from the device the bind was learnt from (MouseKeys.Presses); the HID report reaches
/// Pilot straight from the kernel, ahead of the WindowServer's event, and the tap waits up to 15 ms for it otherwise.
final class MouseMedia: Sendable {
    /// A vendor and product, the part of a device that shows a mouse.
    private struct Model: Hashable { var vendor: Int, product: Int }

    private struct State {
        var presses = MouseKeys.Presses()
        var mice: Set<Model> = []
        var verbose = false
        var lastClaimed: MouseKeys.Device?
    }

    private let state = Mutex(State())
    private let arrived = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "dev.banozz.pilot.mouse-hid", qos: .userInteractive)
    nonisolated(unsafe) private var manager: IOHIDManager?
    private let retiring = RetiringManagers()

    static let wait = 5, waits = 3

    var isRunning: Bool { manager != nil }
    /// Managers cancelled whose handler has not run yet (tests).
    var retiringCount: Int { retiring.count }

    /// The device of the last press claimed, for Learn's "from …".
    var lastClaimed: MouseKeys.Device? { state.withLock { $0.lastClaimed } }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// On or off; `verbose` logs every consumer and button value the HID side sees (Learn).
    @MainActor func run(_ on: Bool, verbose: Bool) {
        state.withLock { $0.verbose = verbose }
        if on, manager == nil {
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching: [[String: Int]] = [
                [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
                [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
            ]
            IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
            IOHIDManagerSetInputValueMatchingMultiple(manager, [[kIOHIDElementUsagePageKey: kHIDPage_Consumer],
                                                                [kIOHIDElementUsagePageKey: kHIDPage_Button]] as CFArray)
            let me = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAdded, me)
            IOHIDManagerRegisterInputValueCallback(manager, valueArrived, me)
            IOHIDManagerSetDispatchQueue(manager, queue)
            retiring.prepare(manager)
            let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerActivate(manager)
            self.manager = manager
            mouseLog.notice("media: HID watch on, open 0x\(String(UInt32(bitPattern: opened), radix: 16), privacy: .public), Input Monitoring \(MouseButtons.describe(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)), privacy: .public)")
        } else if !on, let manager {
            retiring.cancel(manager)
            self.manager = nil
            state.withLock { $0 = State() }
            mouseLog.notice("media: HID watch off")
        }
    }

    /// Whether the mouse sent the media key the tap holds: from `source`, of the usage its key type comes from, waited for
    /// up to 15 ms. Runs inside the tap callback.
    func claim(_ press: MouseKeys.MediaPress, from source: MouseKeys.Presses.Source) -> Bool {
        // Signals left by presses claimed without a wait would end the waits below at once.
        while arrived.wait(timeout: .now()) == .success {}
        for attempt in 0...Self.waits {
            let now = Self.now()
            let found = state.withLock { s in
                let found = s.presses.claim(keyType: press.keyType, from: source, now: now)
                if found != nil { s.lastClaimed = found }
                return found
            }
            if let found {
                mouseLog.notice("media: key type \(press.keyType, privacy: .public) from \(found.name, privacy: .public)")
                return true
            }
            if attempt < Self.waits { _ = arrived.wait(timeout: .now() + .milliseconds(Self.wait)) }
        }
        mouseLog.debug("media: key type \(press.keyType, privacy: .public) not from \(String(describing: source), privacy: .public)")
        return false
    }

    fileprivate func added(_ device: IOHIDDevice) {
        let info = Self.info(device)
        let pairs = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]]) ?? []
        let mouse = pairs.contains { $0[kIOHIDDeviceUsagePageKey] == kHIDPage_GenericDesktop && $0[kIOHIDDeviceUsageKey] == kHIDUsage_GD_Mouse }
        if mouse { state.withLock { _ = $0.mice.insert(Model(vendor: info.vendor, product: info.product)) } }
        let service = IOHIDDeviceGetService(device)
        var registry: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registry)
        mouseLog.notice("media: device \(info.name, privacy: .public) vendor \(info.vendor, privacy: .public) product \(info.product, privacy: .public) usages \(pairs.map { "\($0[kIOHIDDeviceUsagePageKey] ?? 0):\($0[kIOHIDDeviceUsageKey] ?? 0)" }.joined(separator: ","), privacy: .public) registry \(registry, privacy: .public)\(mouse ? " (mouse)" : "", privacy: .public)")
    }

    fileprivate func arrived(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        let device = IOHIDElementGetDevice(element)
        let info = Self.info(device)
        let (verbose, noted) = state.withLock { s -> (Bool, Bool) in
            guard page == UInt32(kHIDPage_Consumer), pressed, usage != 0, s.mice.contains(Model(vendor: info.vendor, product: info.product))
            else { return (s.verbose, false) }
            s.presses.note(time: Self.now(), usage: usage, device: info)
            return (s.verbose, true)
        }
        if noted { arrived.signal() }
        if verbose {
            mouseLog.notice("learn: HID page 0x\(String(page, radix: 16), privacy: .public) usage 0x\(String(usage, radix: 16), privacy: .public) value \(IOHIDValueGetIntegerValue(value), privacy: .public) from \(info.name, privacy: .public) (\(info.vendor, privacy: .public):\(info.product, privacy: .public))")
        }
    }

    static func info(_ device: IOHIDDevice) -> MouseKeys.Device {
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0 }
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "an unnamed device"
        return MouseKeys.Device(vendor: int(kIOHIDVendorIDKey), product: int(kIOHIDProductIDKey), name: name)
    }
}

private let deviceAdded: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<MouseMedia>.fromOpaque(context).takeUnretainedValue().added(device)
}

private let valueArrived: IOHIDValueCallback = { context, _, _, value in
    guard let context else { return }
    Unmanaged<MouseMedia>.fromOpaque(context).takeUnretainedValue().arrived(value)
}

/// Learn's look at the found mice's vendor-defined HID parts (P57): a HyperX mouse may report a DPI press there, where no
/// CGEvent shows it. On only while a catch waits, a manager of its own opens just those parts (usage pages 0xFF00 and
/// 0xFF01) of the mice found, never seizing and never writing, and logs each new report of a vendor collection with its
/// id and bytes, never a key report that shares the part (NGenuity sends its Esc through it). The media watch is left alone.
final class MouseVendor: Sendable {
    private struct State {
        /// Each open part's name and vendor input report ids, by device.
        var parts: [UInt: (name: String, ids: Set<UInt32>)] = [:]
        var last: (id: UInt32, bytes: [UInt8])?
        var report: String?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "dev.banozz.pilot.mouse-vendor", qos: .utility)
    nonisolated(unsafe) private var manager: IOHIDManager?
    private let retiring = RetiringManagers()

    /// The last watch's last vendor report, "report 6: 06 01 02 00"; kept after it stops, for the quiet box.
    var report: String? { state.withLock { $0.report } }

    /// Watches `mice`'s vendor parts afresh; none stops.
    @MainActor func watch(_ mice: [MouseKeys.Device]) {
        if let manager {
            retiring.cancel(manager)
            self.manager = nil
        }
        guard !mice.isEmpty else { return }
        state.withLock { $0 = State() }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, mice.flatMap { m in
            [0xFF00, 0xFF01].map { [kIOHIDVendorIDKey: m.vendor, kIOHIDProductIDKey: m.product, kIOHIDDeviceUsagePageKey: $0] }
        } as CFArray)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, vendorPartAdded, me)
        IOHIDManagerRegisterInputReportCallback(manager, vendorReportArrived, me)
        IOHIDManagerSetDispatchQueue(manager, queue)
        retiring.prepare(manager)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(manager)
        self.manager = manager
        mouseLog.notice("learn: vendor watch on for \(mice.map(\.name).joined(separator: ", "), privacy: .public), open 0x\(String(UInt32(bitPattern: opened), radix: 16), privacy: .public)")
    }

    /// A vendor part opened: the report ids that carry vendor inputs alone, so a report with a key or a media key in it
    /// (the Pulsefire Core's keys and media keys share report 6's part) is never logged; a part without report ids
    /// (id 0) counts only when it is a vendor device itself.
    fileprivate func added(_ device: IOHIDDevice) {
        let inputs = ((IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? [])
            .filter { (1...5).contains(IOHIDElementGetType($0).rawValue) }
        let isVendor = { (e: IOHIDElement) in IOHIDElementGetUsagePage(e) >= 0xFF00 }
        var ids = Set(inputs.filter(isVendor).map(IOHIDElementGetReportID)).subtracting(inputs.filter { !isVendor($0) }.map(IOHIDElementGetReportID))
        if (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0) < 0xFF00 { ids.remove(0) }
        let name = MouseMedia.info(device).name
        state.withLock { $0.parts[UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())] = (name, ids) }
        mouseLog.notice("learn: vendor part of \(name, privacy: .public), input report ids \(ids.sorted().map(String.init).joined(separator: ","), privacy: .public)")
    }

    /// A report from an open part: one on a vendor report id that differs from the last is kept and logged.
    fileprivate func arrived(from sender: UnsafeMutableRawPointer?, id: UInt32, _ bytes: UnsafeBufferPointer<UInt8>) {
        let name = state.withLock { s -> String? in
            guard let part = s.parts[UInt(bitPattern: sender)], part.ids.contains(id),
                  s.last.map({ $0.id != id || !$0.bytes.elementsEqual(bytes) }) ?? true else { return nil }
            s.last = (id, Array(bytes))
            return part.name
        }
        guard let name else { return }
        let report = "report \(id): " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        state.withLock { $0.report = report }
        mouseLog.notice("learn: vendor \(report, privacy: .public) from \(name, privacy: .public)")
    }
}

private let vendorPartAdded: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<MouseVendor>.fromOpaque(context).takeUnretainedValue().added(device)
}

private let vendorReportArrived: IOHIDReportCallback = { context, _, sender, _, id, report, length in
    guard let context else { return }
    Unmanaged<MouseVendor>.fromOpaque(context).takeUnretainedValue().arrived(from: sender, id: id, UnsafeBufferPointer(start: report, count: length))
}

/// IOHIDManagers cancelled but not yet done (MouseMedia's, MouseVendor's): each is let go in its cancel handler, never
/// before (IOHIDManager.h). IOKit runs the handler on the manager's queue, so it is made here, outside the main actor: one
/// written in a main-actor method inherits that actor and traps there (Build 55's crash on ending Learn).
final class RetiringManagers: @unchecked Sendable {
    /// Main thread only.
    private var held: [ObjectIdentifier: IOHIDManager] = [:]

    var count: Int { held.count }

    /// Sets `manager`'s cancel handler, before it is activated.
    func prepare(_ manager: IOHIDManager) {
        let id = ObjectIdentifier(manager)
        IOHIDManagerSetCancelHandler(manager) { [weak self] in DispatchQueue.main.async { self?.held[id] = nil } }
    }

    /// Cancels `manager`, held until its handler has run: releasing it sooner can crash the queue's last callback.
    @MainActor func cancel(_ manager: IOHIDManager) {
        held[ObjectIdentifier(manager)] = manager
        IOHIDManagerCancel(manager)
    }
}
