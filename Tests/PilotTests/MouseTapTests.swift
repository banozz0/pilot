import AppKit
import IOKit.hid
import PilotCore
import Testing
@testable import Pilot

/// Mouse button binds through the tap (Q184): a media key the mouse sends passes untouched while unbound and runs its
/// bind once bound; the keyboard's own media keys and Pilot's posted ones always pass; Learn takes the next one. Events
/// are made, never posted.
@MainActor
@Suite("Mouse tap")
struct MouseTapTests {
    let type = CGEventType(rawValue: BrightnessKeys.eventType)!

    func media(_ key: Int, down: Bool = true, own: Bool = false) throws -> CGEvent {
        let ns = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, subtype: 8, data1: key << 16 | (down ? 0x0A : 0x0B) << 8, data2: -1))
        let event = try #require(ns.cgEvent)
        if own { event.setIntegerValueField(.eventSourceUserData, value: HyperTap.ownEventMark) }
        return event
    }

    /// A tap whose binds are `bound`, the mouse sending every media key unless `fromMouse` says otherwise.
    func tap(bound: [Key: String], fromMouse: Bool = true) -> (HyperTap, runs: () -> [Key], releases: () -> [Key]) {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        var runs: [Key] = [], releases: [Key] = []
        tap.isBound = { bound[$0] != nil }
        tap.isFromMouse = { _, _ in fromMouse }
        tap.onRun = { key, _ in runs.append(key) }
        tap.onRelease = { releases.append($0) }
        return (tap, { runs }, { releases })
    }

    @Test("An unbound media key from the mouse passes untouched; a bound one runs its action and takes its release")
    func mediaFromMouse() throws {
        let (free, freeRuns, _) = tap(bound: [:])
        let event = try media(17)
        #expect(free.handle(type: type, event: event)?.takeUnretainedValue() === event, "the same event goes on, untouched")
        #expect(free.handle(type: type, event: try media(17, down: false)) != nil && freeRuns().isEmpty)

        let (bound, runs, releases) = tap(bound: [MouseKeys.media(17): "media.playPause"])
        #expect(bound.handle(type: type, event: try media(17)) == nil)
        #expect(bound.handle(type: type, event: try media(17, down: false)) == nil)
        #expect(runs() == [MouseKeys.media(17)] && releases() == [MouseKeys.media(17)])
        #expect(bound.handle(type: type, event: try media(16)) != nil, "the mouse's Play has no bind: it plays as before")
    }

    @Test("The keyboard's own Next and Pilot's posted one pass even with the mouse's Next bound")
    func keyboardPasses() throws {
        let (keyboard, runs, _) = tap(bound: [MouseKeys.media(17): "apps.terminal"], fromMouse: false)
        #expect(keyboard.handle(type: type, event: try media(17)) != nil && runs().isEmpty)
        let (own, ownRuns, _) = tap(bound: [MouseKeys.media(17): "apps.terminal"])
        #expect(own.handle(type: type, event: try media(17, own: true)) != nil && ownRuns().isEmpty)
    }

    @Test("Learn takes the next mouse trigger, a media key or a button, once; then they pass again")
    func learn() throws {
        let (tap, runs, _) = tap(bound: [:])
        var learnt: [Key] = []
        tap.captureMouse = { learnt.append($0) }
        #expect(tap.handle(type: type, event: try media(18)) == nil)
        #expect(tap.handle(type: type, event: try media(18, down: false)) == nil)
        let again = try media(18)
        #expect(tap.captureMouse == nil && tap.handle(type: type, event: again) != nil)
        tap.captureMouse = { learnt.append($0) }
        #expect(tap.mouseButton(3, isDown: true) && tap.mouseButton(3, isDown: false))
        #expect(!tap.mouseButton(3, isDown: true) && !tap.mouseButton(3, isDown: false))
        #expect(learnt == [MouseKeys.media(18), MouseKeys.button(3)] && runs().isEmpty)
    }

    @Test("A bound button runs on its press and releases on its release; an unbound one passes")
    func buttons() {
        let (tap, runs, releases) = tap(bound: [MouseKeys.button(4): "workspaces.next"])
        #expect(!tap.mouseButton(3, isDown: true) && !tap.mouseButton(3, isDown: false))
        #expect(tap.mouseButton(4, isDown: true) && tap.mouseButton(4, isDown: false))
        #expect(runs() == [MouseKeys.button(4)] && releases() == [MouseKeys.button(4)])
    }

    @Test("Through MouseButtons: a device-less media bind passes the Keychron's Next and never asks the HID side")
    func devicelessBindPasses() throws {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        let mouse = MouseButtons(tap: tap)
        var runs: [Key] = []
        tap.onRun = { key, _ in runs.append(key) }
        tap.isBound = { $0 == MouseKeys.media(17) }
        mouse.arm(running: false, binds: [(MouseKeys.media(17), BindStore.MouseBind(action: "media.next", device: nil))])
        let start = ContinuousClock.now
        #expect(tap.handle(type: type, event: try media(17)) != nil && runs.isEmpty)
        #expect(ContinuousClock.now - start < .milliseconds(5), "no 15 ms wait for a press that cannot be claimed")
    }

    @Test("A held mouse bind ends when the tap stops, as a held key does; its late release is still taken")
    func releaseAll() {
        let (tap, _, releases) = tap(bound: [MouseKeys.button(4): "dictation.hold"])
        #expect(tap.mouseButton(4, isDown: true))
        tap.stop()
        #expect(releases() == [MouseKeys.button(4)])
        #expect(tap.mouseButton(4, isDown: false) && releases() == [MouseKeys.button(4)], "no second release")
    }

    func key(_ code: CGKeyCode, down: Bool = true, flags: CGEventFlags = [], repeats: Bool = false, own: Bool = false, sender: Int64 = 42) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        if repeats { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        if own { event.setIntegerValueField(.eventSourceUserData, value: HyperTap.ownEventMark) }
        event.setIntegerValueField(try #require(HyperTap.senderField), value: sender)
        return event
    }

    @Test("While Learn listens each key pressed is reported with its sender and still goes on; a repeat, the layer key and Pilot's own keys are not")
    func learnKeyWatched() throws {
        let (tap, _, _) = tap(bound: [:])
        let press = try key(33, flags: .maskCommand)
        #expect(tap.handle(type: .keyDown, event: press)?.takeUnretainedValue() === press, "no hook: the key goes on")
        var heard: [(code: Int64, flags: UInt64, sender: UInt64)] = []
        tap.learnKey = { e, sender in heard.append((e.keyCode, e.flags, sender)) }
        #expect(tap.handle(type: .keyDown, event: press)?.takeUnretainedValue() === press, "watched, never taken")
        _ = tap.handle(type: .keyDown, event: try key(33, flags: .maskCommand, repeats: true))
        _ = tap.handle(type: .keyDown, event: try key(33, own: true))
        _ = tap.handle(type: .keyDown, event: try key(CGKeyCode(LayerKey.capsLock.keyCode)))
        _ = tap.handle(type: .keyUp, event: try #require(CGEvent(keyboardEventSource: nil, virtualKey: 33, keyDown: false)))
        // Hyper held: Hyper+[ is the keyboard's chord, never a mouse button's.
        let layer = CGKeyCode(LayerKey.capsLock.keyCode)
        _ = tap.handle(type: .keyDown, event: try key(layer))
        #expect(tap.layer.isDown, "the layer key holds Hyper")
        _ = tap.handle(type: .keyDown, event: try key(33))
        _ = tap.handle(type: .keyUp, event: try #require(CGEvent(keyboardEventSource: nil, virtualKey: layer, keyDown: false)))
        try #require(heard.count == 1, "only the first press: \(heard.map(\.code))")
        #expect(heard[0].code == 33 && heard[0].flags & KeyEvent.cmdMask != 0)
        #expect(heard[0].sender == 42, "the sender field survives on a made event")
        #expect(MouseKeys.keyLabel(keyCode: heard[0].code, flags: heard[0].flags) == "Cmd+[")
    }

    /// Waits for the catch's main-queue hop to land, 10 s at most, then lets the expectations say what is missing: in the
    /// full suite other tests hold the main thread for seconds, so a fixed sleep woke before the hop, or after the wait.
    /// Past the deadline it yields once more, so a hop queued behind a hold of over 10 s still lands first.
    func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done() {
            let late = ContinuousClock.now > deadline
            try await Task.sleep(for: .milliseconds(10))
            if late { return }
        }
    }

    @Test("The catch names a key that arrives instead of a button and waits again; with nothing it ends quiet, its taps off")
    func learnNotes() async throws {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        let mouse = MouseButtons(tap: tap)
        let saved = MouseButtons.quietAfter
        defer { MouseButtons.quietAfter = saved }
        MouseButtons.quietAfter = 3600   // never ends the catch here: a held main thread outlasted 5 s

        mouse.startLearning(for: 4)
        let first = try #require(mouse.deadline)
        try #require(tap.learnKey != nil && tap.learnMedia != nil && mouse.target == 4)
        tap.learnKey?(KeyEvent(kind: .keyDown, keyCode: 33, flags: KeyEvent.cmdMask), 0)   // a sender no registry entry has
        try await until { mouse.note != nil }
        #expect(mouse.note == MouseKeys.keyNote("Cmd+[", from: nil, isMouse: nil) && mouse.learn == .listening,
                "the key, its device unknown; still waiting")
        #expect(try #require(mouse.deadline) > first, "the wait started over")
        mouse.cancel()
        #expect(mouse.note == nil && tap.learnKey == nil && tap.learnMedia == nil && mouse.learn == .idle && mouse.target == nil)

        MouseButtons.quietAfter = 0.05
        mouse.startLearning(for: 5)
        try await until { mouse.learn == .quiet }
        #expect(mouse.learn == .quiet && mouse.target == 5, "nothing arrived: the wait is over, Try again knows the button")
        #expect(tap.captureMouse == nil && tap.learnKey == nil && tap.learnMedia == nil && mouse.deadline == nil)
        mouse.pick(MouseKeys.button(3), button: 4)
        #expect(mouse.note == nil && mouse.learn == .got(MouseKeys.button(3), device: nil) && mouse.target == 4)
        mouse.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(mouse.learn == .idle, "a cancelled catch's wait never lands")
    }

    @Test("While the catch waits, an Esc the mouse sends is caught with its release; the keyboard's Esc goes on (Build 62)")
    func catchMouseKey() throws {
        let (tap, runs, _) = tap(bound: [:])
        var caught: [Key] = [], asked: [UInt64] = []
        tap.isKeyFromMouse = { _, sender in asked.append(sender); return sender == 7 }   // 7 the HyperX, 42 the keyboard
        tap.captureMouse = { caught.append($0) }
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 42)) != nil, "the keyboard's Esc cancels as before")
        #expect(caught.isEmpty && tap.captureMouse != nil)
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil)
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil, "its release is taken too")
        #expect(caught == [MouseKeys.key(53)] && runs().isEmpty && asked == [42, 7])
    }

    @Test("A bound key from the mouse runs only from that mouse; the keyboard's same key and every other key pass, unasked")
    func boundMouseKey() throws {
        let bound = MouseKeys.key(53, flags: KeyEvent.cmdMask)
        let (tap, runs, releases) = tap(bound: [bound: "media.playPause"])
        var asked = 0
        tap.isKeyFromMouse = { _, sender in asked += 1; return sender == 7 }
        tap.mouseKeyCodes = [53]
        #expect(tap.handle(type: .keyDown, event: try key(53, flags: .maskCommand, sender: 7)) == nil)
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, flags: .maskCommand, sender: 7)) == nil)
        #expect(runs() == [bound] && releases() == [bound])
        #expect(tap.handle(type: .keyDown, event: try key(53, flags: .maskCommand, sender: 42)) != nil, "the keyboard's Cmd+Esc")
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) != nil, "plain Esc from the mouse has no bind")
        #expect(asked == 2, "plain Esc is not bound, so nothing asked")
        _ = tap.handle(type: .keyDown, event: try key(0, sender: 7))
        #expect(asked == 2 && runs() == [bound], "a key code with no mouse bind never asks")
    }

    /// A tap with the mouse's Esc bound, the HyperX sending as 7, the keyboard as 42.
    func escBound(_ trigger: Key = MouseKeys.key(53)) -> (HyperTap, runs: () -> [Key], releases: () -> [Key], bound: (Bool) -> Void) {
        var isBound = true
        let (tap, runs, releases) = tap(bound: [:])
        tap.isBound = { $0 == trigger && isBound }
        tap.isKeyFromMouse = { _, sender in sender == 7 }
        tap.mouseKeyCodes = [53]
        return (tap, runs, releases, { isBound = $0 })
    }

    @Test("Moody (a): the keyboard's Esc held across the mouse's press keeps all its events; the mouse's release still ends its run")
    func keyboardHeldAcrossMouse() throws {
        let (tap, runs, releases, _) = escBound()
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 42)) != nil)
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil)
        #expect(tap.handle(type: .keyDown, event: try key(53, repeats: true, sender: 42)) != nil, "the keyboard's repeat goes on")
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 42)) != nil, "the keyboard's release goes on")
        #expect(releases().isEmpty)
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil)
        #expect(runs() == [MouseKeys.key(53)] && releases() == [MouseKeys.key(53)])
    }

    @Test("Moody (b): the keyboard's Esc pressed while the mouse's is held never strands the mouse's release")
    func keyboardPressDuringMouseHold() throws {
        let (tap, _, releases, _) = escBound()
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil)
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 42)) != nil)
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil)
        #expect(releases() == [MouseKeys.key(53)], "the held action ends")
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 42)) != nil)
    }

    @Test("Moody (c): a release whose modifiers changed (a macro letting go of Cmd first) still ends the run")
    func modifiersChange() throws {
        let cmdEsc = MouseKeys.key(53, flags: KeyEvent.cmdMask)
        let (tap, runs, releases, _) = escBound(cmdEsc)
        #expect(tap.handle(type: .keyDown, event: try key(53, flags: .maskCommand, sender: 7)) == nil)
        #expect(tap.handle(type: .keyDown, event: try key(53, flags: .maskShift, repeats: true, sender: 7)) == nil, "its repeat, Shift now")
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil)
        #expect(runs() == [cmdEsc] && releases() == [cmdEsc])
    }

    @Test("The layer key going down between the mouse's press and release, or the bind's removal, never strands the release")
    func releaseAfterLayerOrRemove() throws {
        let (tap, runs, releases, bound) = escBound()
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil)
        _ = tap.handle(type: .keyDown, event: try key(CGKeyCode(LayerKey.capsLock.keyCode)))
        #expect(tap.layer.isDown)
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil && releases() == [MouseKeys.key(53)])
        // Sven, 2026-10-19: Hyper + Forward (NGenuity's Esc) locked the screen. Under the layer the mouse's Esc runs its
        // plain bind, as a button's does, and never reaches the layer as Hyper + Esc.
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil)
        #expect(runs() == [MouseKeys.key(53), MouseKeys.key(53)], "a new press under the layer runs the mouse's bind")
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil)
        _ = tap.handle(type: .keyUp, event: try key(CGKeyCode(LayerKey.capsLock.keyCode), down: false))
        #expect(!tap.layer.isDown)

        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil)
        bound(false)   // Remove while held
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil)
        #expect(releases() == Array(repeating: MouseKeys.key(53), count: 3), "the run ends")
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) != nil, "unbound now: the mouse's Esc is Esc again")

        // Its Hyper bind alone (Sven's Hyper + Forward runs Copy): it runs under the layer only; the plain press and the
        // keyboard's Hyper + Esc are not the mouse's.
        let hyperEsc = MouseKeys.underHyper(MouseKeys.key(53))
        let (htap, hruns, hreleases, _) = escBound(hyperEsc)
        #expect(htap.handle(type: .keyDown, event: try key(53, sender: 7)) != nil, "no plain bind: the mouse's Esc goes on")
        _ = htap.handle(type: .keyUp, event: try key(53, down: false, sender: 7))
        _ = htap.handle(type: .keyDown, event: try key(CGKeyCode(LayerKey.capsLock.keyCode)))
        #expect(htap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil)
        #expect(htap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil)
        #expect(hruns() == [hyperEsc] && hreleases() == [hyperEsc])
        _ = htap.handle(type: .keyDown, event: try key(53, sender: 42))
        #expect(hruns() == [hyperEsc], "the keyboard's Hyper + Esc is the layer's")
    }

    @Test("Moody round 2: a new press on a hold whose release went by decides again; the tap going off forgets every hold")
    func staleHold() throws {
        let (tap, runs, releases, _) = escBound()
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil)
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil, "down, down: the second press runs, never lost")
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil)
        #expect(runs().count == 2 && releases().count == 1)

        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil)
        tap.tapDisabled("timeout")   // its release goes by while the tap is off
        #expect(releases().count == 2, "the tap going off ended the run")
        #expect(tap.handle(type: .keyDown, event: try key(53, sender: 7)) == nil && runs().count == 4, "the next press runs")
        #expect(tap.handle(type: .keyUp, event: try key(53, down: false, sender: 7)) == nil && releases().count == 3)
    }

    @Test("Moody round 2: the keyboard's Next pressed while the mouse's is held keeps its events, and the mouse's run always ends")
    func mediaHeldAcrossKeyboard() throws {
        var fromMouse = true
        let (tap, runs, releases) = tap(bound: [MouseKeys.media(17): "media.playPause"])
        tap.isFromMouse = { _, _ in fromMouse }
        #expect(tap.handle(type: type, event: try media(17)) == nil)
        fromMouse = false
        #expect(tap.handle(type: type, event: try media(17)) != nil, "the keyboard's Next")
        #expect(tap.handle(type: type, event: try media(17, down: false)) != nil, "its release goes with it")
        #expect(tap.handle(type: type, event: try media(17, down: false)) == nil, "the mouse's release ends the run")
        #expect(runs() == [MouseKeys.media(17)] && releases() == [MouseKeys.media(17)])

        // The releases the other way round: the first passes with the keyboard's press, the second still ends the run.
        fromMouse = true
        _ = tap.handle(type: type, event: try media(17))
        fromMouse = false
        _ = tap.handle(type: type, event: try media(17))
        #expect(tap.handle(type: type, event: try media(17, down: false)) != nil)
        #expect(tap.handle(type: type, event: try media(17, down: false)) == nil && releases().count == 2, "never stuck")
    }

    @Test("Moody round 3: the keyboard's Next counted during the mouse's, both releases lost to a tap timeout, the next press still ends")
    func stalePassedCount() throws {
        var fromMouse = true
        let (tap, runs, releases) = tap(bound: [MouseKeys.media(17): "media.playPause"])
        tap.isFromMouse = { _, _ in fromMouse }
        #expect(tap.handle(type: type, event: try media(17)) == nil)
        fromMouse = false
        #expect(tap.handle(type: type, event: try media(17)) != nil, "the keyboard's Next, counted")
        tap.tapDisabled("timeout")   // both releases go by while the tap is off
        #expect(releases().count == 1)
        fromMouse = true
        #expect(tap.handle(type: type, event: try media(17)) == nil && runs().count == 2)
        #expect(tap.handle(type: type, event: try media(17, down: false)) == nil, "its release is the mouse's, not a stale count's")
        #expect(releases().count == 2)
    }

    @Test("Through MouseButtons: a bound key is the mouse's only from a sender id resolved for its device, never by a registry read in the tap")
    func senderIds() throws {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        let mouse = MouseButtons(tap: tap)
        let core = MouseKeys.Device(vendor: 1008, product: 3471, name: "HyperX Pulsefire Core")
        let other = MouseKeys.Device(vendor: 1133, product: 45108, name: "Logitech MX Master 3S")
        mouse.arm(running: false, binds: [(MouseKeys.key(53), BindStore.MouseBind(action: "media.next", device: core, button: 4))])
        #expect(tap.mouseKeyCodes == [53])
        mouse.keySenders.devices = [7: core, 8: other]
        #expect(tap.isKeyFromMouse(MouseKeys.key(53), 7))
        #expect(!tap.isKeyFromMouse(MouseKeys.key(53), 8), "another mouse's Esc")
        #expect(!tap.isKeyFromMouse(MouseKeys.key(53), 42), "an id no mouse has: the keyboard's")
        mouse.arm(running: false, binds: [])
        #expect(tap.mouseKeyCodes.isEmpty && !tap.isKeyFromMouse(MouseKeys.key(53), 7))
    }

    @Test("A HID device's sender ids hold every service under it, its event service among them (read-only registry walk)")
    func idsUnderDevice() throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let services = ((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []).map(IOHIDDeviceGetService)
        let withEvents = try #require(services.first { service in
            MouseSenders.ids(under: service).count > 1 && Self.hasEventService(under: service)
        }, "no HID device with an event service on this Mac")
        var own: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(withEvents, &own)
        let ids = MouseSenders.ids(under: withEvents)
        #expect(ids.first == own && Set(ids).count == ids.count)
        #expect(try ids.contains(#require(Self.eventService(under: withEvents))))
    }

    static func hasEventService(under service: io_service_t) -> Bool { eventService(under: service) != nil }

    static func eventService(under service: io_service_t) -> UInt64? {
        var children: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(children) }
        while case let entry = IOIteratorNext(children), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOHIDEventService") != 0 {
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(entry, &id)
                return id
            }
        }
        return nil
    }

    @Test("While the catch waits, a media key the mouse did not send passes and is named; the mouse's is caught")
    func learnMedia() throws {
        let (keyboard, runs, _) = tap(bound: [:], fromMouse: false)
        var heard: [Int] = [], caught: [Key] = []
        keyboard.learnMedia = { heard.append($0) }
        keyboard.captureMouse = { caught.append($0) }
        #expect(keyboard.handle(type: type, event: try media(16)) != nil, "the keyboard's Play plays")
        _ = keyboard.handle(type: type, event: try media(16, down: false))
        #expect(heard == [16] && caught.isEmpty && runs().isEmpty, "named once, on its press")

        let (fromMouse, _, _) = tap(bound: [:])
        heard = []
        fromMouse.learnMedia = { heard.append($0) }
        fromMouse.captureMouse = { caught.append($0) }
        #expect(fromMouse.handle(type: type, event: try media(16)) == nil)
        #expect(caught == [MouseKeys.media(16)] && heard.isEmpty)
    }
}
