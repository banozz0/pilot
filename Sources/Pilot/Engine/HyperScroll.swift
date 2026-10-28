@preconcurrency import Cocoa
import PilotCore

/// Hyper+scroll (Omarchy ideas T2, Q95): a session tap on scroll-wheel events only, beside the keyboard tap, whose mask
/// never gains the wheel (typing-lag rule). Installed with the binds but enabled only while Hyper is down, so a disabled
/// tap sees no scroll and never any key. A wheel notch under Hyper is taken from the app and steps the workspace
/// (WorkspaceScroll); every other scroll (trackpad, momentum) goes on to the app. Once Hyper + scroll up or down is bound
/// (Binds › Mouse, P51), each step runs that bind instead, a trackpad's or a smooth wheel's fine deltas adding up to one
/// step first, and every vertical scroll under Hyper is taken; a direction left unbound still steps the workspace by notch.
/// An open ring (P74) turns it on too: every vertical scroll then steps the ring, Hyper or not, and nothing else.
/// Hyper + a sideways scroll steps focus a column left or right, which moves a scrolling workspace's strip (spec
/// scrolling-layout T12, Paneru's modifier + wheel): a trackpad's two fingers, a tilting wheel, or Shift + the wheel.
@MainActor
final class HyperScroll {
    /// The keyboard tap, told a step took the held layer: no quick-tap Escape at its release, and the overlay closes.
    private let layer: HyperTap
    /// Runs after the callback returned.
    var onStep: (WorkspaceScroll.Fire) -> Void = { _ in }
    /// A sideways step, previous for left: runs after the callback returned.
    var onSideways: (WorkspaceScroll.Fire) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var down = false
    /// Hyper + scroll up and down as bound when Hyper went down, natural scrolling as the first scroll of the hold reads
    /// it, and whether the hold has taken a scroll yet: read once per hold, never per event.
    private var bound: Set<Key> = []
    private var inverted: Bool?
    private var used = false
    /// A bound step's length in points, about six lines: one flick runs a few steps, never one per event.
    private var steps = WorkspaceScroll.Steps(length: 60)
    /// A sideways step's length in points, longer than a bound step's: one column is a deliberate swipe.
    private var sideSteps = WorkspaceScroll.Steps(length: 120)
    /// The main-queue hop for a sideways step, made once: the callback only adds to it, which allocates nothing, and steps
    /// that pile up before it runs all run.
    private let sideHop = (left: DispatchSource.makeUserDataAddSource(queue: .main), right: DispatchSource.makeUserDataAddSource(queue: .main))
    /// The open ring's step, +1 the next ring, -1 the one before; nil while no ring is open.
    private var ring: ((Int) -> Void)?
    private var on: Bool { down || ring != nil }

    init(layer: HyperTap) {
        self.layer = layer
        for (source, fire) in [(sideHop.left, WorkspaceScroll.Fire.previous), (sideHop.right, .next)] {
            source.setEventHandler { [weak self, unowned source] in
                MainActor.assumeIsolated { for _ in 0..<source.data { self?.onSideways(fire) } }
            }
            source.activate()
        }
    }

    /// Installed while the binds are armed, off until Hyper goes down.
    func arm(_ on: Bool) {
        if on, tap == nil {
            let me = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
                                              callback: scrollCallback, userInfo: me) else {
                return log.error("scroll: Hyper+scroll tap not created")
            }
            CGEvent.tapEnable(tap: tap, enable: on)
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.tap = tap
            self.source = source
        } else if !on, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            self.tap = nil; source = nil
        }
    }

    /// Hyper down or up, from inside the keyboard tap's callback: the WindowServer round trip waits until it returned.
    func hyper(_ isDown: Bool) {
        down = isDown
        bound = isDown ? Set([MouseKeys.scrollUp, MouseKeys.scrollDown].filter(layer.isBound)) : []
        inverted = nil
        used = false
        steps.reset()
        sideSteps.reset()
        enable()
    }

    /// A ring opened with its step, or closed with nil: the tap is on while it is open.
    func ring(_ step: ((Int) -> Void)?) {
        ring = step
        inverted = nil
        steps.reset()
        enable()
    }

    /// On or off as Hyper and the ring say, after the callback: the WindowServer round trip waits until it returned.
    private func enable() {
        let wanted = on
        DispatchQueue.main.async { [weak self] in
            guard let self, let tap, on == wanted else { return }
            CGEvent.tapEnable(tap: tap, enable: wanted)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, on { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        // A scroll already queued when Hyper came up or the ring closed.
        guard on, type == .scrollWheel else { return pass }
        var e = WorkspaceScroll.Event(delta: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                                      continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                                      phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                                      momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        // A gesture's start counts afresh both ways, whichever way it begins (Moody on T12).
        if e.phase == Int64(CGScrollPhase.began.rawValue) { steps.reset(); sideSteps.reset() }
        // An open ring takes every vertical scroll, each step turning it, so the app below never scrolls under it.
        if let ring {
            guard let fire = step(&e, event) else { return pass }   // sideways
            if let fire { DispatchQueue.main.async { ring(fire == .next ? 1 : -1) } }
            return nil
        }
        if let side = sideways(event, e) {
            guard layer.isHyperHeld() else { return pass }
            if !used { used = true; layer.layerUsed() }
            if let fire = sideSteps.step(side) { (fire == .next ? sideHop.right : sideHop.left).add(data: 1) }
            return nil
        }
        guard !bound.isEmpty || e.isNotch else { return pass }
        // A layer whose release went by unseen lets go here, and the scroll reaches the app.
        guard layer.isHyperHeld() else { return pass }
        guard let fire = step(&e, event) else { return pass }   // no upright delta
        if !used { used = true; layer.layerUsed() }
        guard let fire else { return nil }
        let key = fire == .previous ? MouseKeys.scrollUp : MouseKeys.scrollDown
        if bound.contains(key) {
            DispatchQueue.main.async { [weak self] in self?.layer.scrolled(key) }
        } else if !e.continuous {
            stepWorkspace(fire)
        }
        return nil
    }

    /// The scroll's step, a trackpad's fine deltas adding up first: `.some(nil)` while they add up, nil for a scroll with no
    /// upright delta. `handle` resets the counts as a gesture begins, whichever way it begins.
    private func step(_ e: inout WorkspaceScroll.Event, _ event: CGEvent) -> WorkspaceScroll.Fire?? {
        if e.continuous { e.points = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) }
        if inverted == nil { inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false }
        e.inverted = inverted ?? false
        let fire = steps.step(e)
        return e.delta != 0 || e.points != 0 ? .some(fire) : nil
    }

    /// The scroll as a sideways one, nil when it is upright: Axis 2 the larger; with Shift held every scroll, its upright
    /// delta taken as sideways where macOS left it upright. Its delta is the one the app would see, so the strip moves the
    /// way content scrolls, natural scrolling or not.
    private func sideways(_ event: CGEvent, _ e: WorkspaceScroll.Event) -> WorkspaceScroll.Event? {
        var x = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        var px = e.continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) : 0
        let py = e.continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) : 0
        let upright = e.continuous ? abs(px) <= abs(py) : abs(x) <= abs(e.delta)
        if upright, event.flags.contains(.maskShift) {
            x = e.delta; px = py
        } else if upright {
            return nil
        }
        guard x != 0 || px != 0 else { return nil }
        return WorkspaceScroll.Event(delta: x, continuous: e.continuous, phase: e.phase, momentumPhase: e.momentumPhase, points: px)
    }

    /// The workspace step, after the callback returned.
    private func stepWorkspace(_ fire: WorkspaceScroll.Fire) {
        DispatchQueue.main.async { [weak self] in
            log.notice("scroll: \(fire == .next ? "next" : "previous", privacy: .public) workspace")
            self?.onStep(fire)
        }
    }
}

private let scrollCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HyperScroll>.fromOpaque(userInfo).takeUnretainedValue()
    // The tap's run loop source lives on the main run loop, so this runs on the main thread.
    nonisolated(unsafe) let event = event
    return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
}
