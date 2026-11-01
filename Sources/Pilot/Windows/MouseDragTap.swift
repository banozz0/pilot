@preconcurrency import Cocoa
import PilotCore
import PilotTiler

/// Alt+drag (card agent-bo-95422930, yabai's mouse_modifier): the modifier plus a left drag moves the window under the
/// cursor, plus a right drag resizes it. Hyper as the modifier is the layer held alone, asked of the keyboard tap; the
/// keyboard tap never sees the mouse, so a Hyper drag runs no bind. A tiled window's move is the tiler's mouse drag, which Pilot starts itself
/// (TilerDrag.begin: the tiler never sees the swallowed press), so layout leaves the window to Pilot while its drop zone
/// and live swap follow; once the last frame is written Pilot hands it the release (TilerDrag.end), which drops it. A
/// tiled window's resize shows an outline of only what the tiler can do (TilerDrag.reach) and lands that frame at the
/// release (DragSession). Writes follow the mouse at the screen's rate, newest point first (LatestWins); another app's
/// window is written through AX off the main thread, so a slow app never stalls the tap; Pilot's own window through
/// AppKit, since AX from Pilot to itself can block the main thread (OwnApp). Hyper + right-click on a file (story 199)
/// is this tap's too, so it and a Hyper resize never race in two taps: with Hyper the drag modifier, a right press over
/// a file waits for its release, a resize once it moves past `clickSlop`, the file menu if it never does; with no drag
/// modifier picked, the tap is on only while Hyper is held.
@MainActor
final class MouseDragTap {
    /// What a drag writes to: another app's window through AX, or one of Pilot's own through AppKit.
    private enum Target { case ax(AXUIElement), own(NSWindow) }

    private let modifier: () -> DragModifier
    /// The keyboard tap, whose layer is Hyper: Hyper is no flag the press carries.
    private let layer: HyperTap
    private let tiler: TilerService
    /// A tiled resize's outline, in AppKit coordinates; nil hides it. Engine draws it as the drop zone.
    var outline: (CGRect?) -> Void = { _ in }
    /// Hyper + right-click on a file: what the press named and where, after the callback returned (FileActionsMenu).
    var openFiles: (FileActionsMenu.Source, CGPoint) -> Void = { _, _ in }
    /// The desktop's widgets (Q668): Hyper held alone and a left press on one moves it, a right press resizes it (Q695),
    /// whatever the drag modifier; a plain right press opens its menu (Edit widget). `grab` (true for a resize) answers
    /// inside the callback from the panels' own frames (no window server call), and so does `cancel`, before the press
    /// that found a grab still held can start its own; the moves, the drop and the menu run after it returned.
    struct WidgetHooks {
        /// `over` says whether a shown widget is at the point, from the panels' frames alone, before the window list is read.
        let over: (CGPoint) -> Bool, grab: (CGPoint, Bool) -> Bool, drag: (CGPoint) -> Void, drop: () -> Void
        let menu: (CGPoint) -> Void
        /// A grab whose release went by unseen ends with nothing kept: its panel back where it was, no save, no menu.
        let cancel: () -> Void
    }
    var widgets: WidgetHooks?
    /// A widget shows on the desktop: the tap is on for its right presses (its menu), else Finder would take them.
    var widgetsShown = false { didSet { enable() } }
    /// The right press a widget's menu took: its drags and its release are taken too, so Finder never sees half a click.
    private var menuDown = false
    /// A widget's press is held, and by which button: its drags and its release are taken too, so Finder never draws a
    /// selection box or opens its menu.
    private var widgetDown: MouseDrag.Button?
    /// A drag modifier is picked: the tap is on all the time, else only while Hyper is held or a file press is still down.
    var dragging = true { didSet { enable() } }
    private var hyperDown = false
    /// The right press Hyper + right-click took: its drags and its release are taken too, so no context menu opens.
    private var fileClickDown = false
    /// A Hyper right press over a file that could also start a resize (Hyper the drag modifier): the drag session holds
    /// it, its window not yet matched, until it moves past `clickSlop` (a resize) or comes up (the file menu).
    private var waiting: (files: FileActionsMenu.Source, point: CGPoint, window: WindowInfo)?
    /// How far a waiting press moves before it is a resize, in points.
    static let clickSlop: CGFloat = 4
    private var wanted: Bool { dragging || hyperDown || fileClickDown || widgetDown != nil || widgetsShown || menuDown }
    /// What the tap was last set to, so a Hyper press with a drag modifier picked costs no WindowServer call.
    private var enabled = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Which events the drag keeps from the app, and the drag's session (DragTracker).
    private var tracker = DragTracker()
    /// Set once the press is matched to its window, after the tap callback returned.
    private var target: Target?
    /// The drag's points, written at most once per display frame.
    private var frames = LatestWins<CGPoint>(interval: 1.0 / 60)
    /// The release's resize in flight with the tiler: the drag ends after it.
    private var tilerBusy = false
    /// The tiler holds this move as its mouse drag (TilerDrag.begin), so the drag's end hands it the release.
    private var tilerHolds = false
    /// The mouse-up's point, where a held move drops; nil until the release.
    private var releasePoint: CGPoint?
    /// The main screen's height, read once per drag, for AppKit's flipped coordinates.
    private var primaryHeight: CGFloat = 0
    /// Mouse events in and frame writes out, for the drag's log line.
    private var counts = (events: 0, writes: 0, start: ContinuousClock.now)
    /// AX writes into other apps, one at a time, off the main thread.
    private static let axQueue = DispatchQueue(label: "dev.banozz.pilot.drag-ax", qos: .userInteractive)

    init(modifier: @escaping () -> DragModifier, layer: HyperTap, tiler: TilerService) {
        self.modifier = modifier
        self.layer = layer
        self.tiler = tiler
    }

    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Session level, so the button state the tiler reads (NSEvent.pressedMouseButtons) should be recorded before this tap
        // drops the press; unverified until the live check.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mouseCallback, userInfo: me) else {
            return wlog.error("drag: mouse tap not created")
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        enabled = wanted
        CGEvent.tapEnable(tap: tap, enable: enabled)
        self.tap = tap
        self.source = source
        wlog.notice("drag: mouse tap installed")
    }

    /// Hyper down or up, from inside the keyboard tap's callback: the WindowServer round trip waits until it returned.
    func hyper(_ down: Bool) {
        hyperDown = down
        enable()
    }

    /// On or off as the drag modifier, Hyper and a file press say, after the callback returned.
    private func enable() {
        let on = wanted
        DispatchQueue.main.async { [weak self] in
            guard let self, let tap, wanted == on, enabled != on else { return }
            enabled = on
            CGEvent.tapEnable(tap: tap, enable: on)
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        fileClickDown = false; enabled = false; waiting = nil; menuDown = false
        if widgetDown != nil { widgetDown = nil; widgets?.drop() }
        end()
    }

    private static func button(_ type: CGEventType) -> MouseDrag.Button? {
        switch type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: .left
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: .right
        default: nil
        }
    }

    /// Only cheap work here (a flag test, the window server's list): AX calls into other apps wait until the callback returned.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // Only a timeout turns back on (AGENTS.md): .tapDisabledByUserInput is Pilot's own switch-off, which a re-enable here
        // would race, leaving the tap on while `enabled` says off.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout, let tap, wanted { CGEvent.tapEnable(tap: tap, enable: true); enabled = true }
            return pass
        }
        // A press of the held button while a widget is still held: that grab's release went by unseen (a tap timeout), so
        // it is cancelled now, inside the callback, before this press can start a grab of its own; the press goes on.
        if let held = widgetDown, Self.button(type) == held, type == .leftMouseDown || type == .rightMouseDown {
            widgetDown = nil
            enable()
            widgets?.cancel()
        }
        if let held = widgetDown, Self.button(type) == held, type != .leftMouseDown, type != .rightMouseDown {
            let point = event.location, up = type == .leftMouseUp || type == .rightMouseUp
            if up { widgetDown = nil; enable() }
            DispatchQueue.main.async { [weak self] in if up { self?.widgets?.drop() } else { self?.widgets?.drag(point) } }
            return nil
        }
        if type == .leftMouseDown || type == .rightMouseDown, tracker.session == nil, let widgets, layer.isHeldAlone(flags: event.flags.rawValue),
           widgets.over(event.location), front(at: event.location, aboveDesktop: true) == nil, widgets.grab(event.location, type == .rightMouseDown) {
            widgetDown = Self.button(type)
            layer.layerUsed()
            return nil
        }
        // A plain right press on a shown widget, with no window over it: its menu, after the callback returned.
        if type == .rightMouseDown, tracker.session == nil, let widgets, widgetsShown, !layer.isHyperHeld(),
           event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
           widgets.over(event.location), front(at: event.location, aboveDesktop: true) == nil {
            menuDown = true
            let point = event.location
            DispatchQueue.main.async { widgets.menu(point) }
            return nil
        }
        if menuDown, type == .rightMouseDragged || type == .rightMouseUp {
            if type == .rightMouseUp { menuDown = false; enable() }
            return nil
        }
        if fileClickDown, type == .rightMouseDragged || type == .rightMouseUp {
            if type == .rightMouseUp { fileClickDown = false; enable() }
            return nil
        }
        if type == .rightMouseDown {
            // A right press while one is still taken or waiting: that one's release went by unseen, so it lets go.
            if fileClickDown { fileClickDown = false; enable() }
            if menuDown { menuDown = false; enable() }
            if waiting != nil { dropWaiting() }
            if tracker.session != nil, layer.isHyperHeld() { wlog.notice("file click: passed, a drag is still live") }
            if tracker.session == nil, let files = fileClick(at: event.location) {
                layer.layerUsed()
                let point = event.location
                if let started = begin(.right, event) {
                    _ = tracker.passes(.down(.right, begun: started.drag))
                    waiting = (files, point, started.window)
                    return nil
                }
                fileClickDown = true
                DispatchQueue.main.async { [weak self] in self?.openFiles(files, point) }
                return nil
            }
        }
        if type == .rightMouseUp, let held = waiting {
            dropWaiting()
            DispatchQueue.main.async { [weak self] in self?.openFiles(held.files, held.point) }
            return nil
        }
        guard let button = Self.button(type) else { return pass }
        let passes: Bool
        switch type {
        case .leftMouseDown, .rightMouseDown:
            let started = begin(button, event)
            passes = tracker.passes(.down(button, begun: started?.drag))
            if !passes, let started {
                if started.hyper { layer.layerUsed() }
                DispatchQueue.main.async { [weak self] in self?.attach(started.window) }
            }
        case .leftMouseDragged, .rightMouseDragged:
            passes = tracker.passes(.dragged(button))
            if !passes { counts.events += 1; offer(event.location) }
            if let held = waiting, button == .right,
               hypot(event.location.x - held.point.x, event.location.y - held.point.y) > Self.clickSlop {
                waiting = nil
                DispatchQueue.main.async { [weak self] in self?.attach(held.window) }
            }
        default:   // the mouse-up
            let live = tracker.session != nil && !tracker.released
            // A tiled move's up is the tiler's release, which Pilot hands it once the last frame is written (TilerDrag.end).
            passes = tracker.passes(.up(button)) && !(live && tilerHolds)
            if live && tracker.released { releasePoint = event.location; offer(event.location) }
        }
        return passes ? pass : nil
    }

    /// A waiting press let go unmatched: its session ends with nothing written, never focused or logged as a drag.
    private func dropWaiting() {
        waiting = nil
        tracker.end(); pending = nil; counts = (0, 0, .now); generation += 1
    }

    /// The front window at `point`; the Dock's see-through one over a whole screen is looked through, as a drag does, and
    /// so is an overlay app's (Cua Driver's agent cursor, layer 0, over the desktop), never a full-screen app's window.
    /// `aboveDesktop` leaves out the desktop's own levels (Finder's icons, Pilot's widgets): a window at layer 0 or above
    /// there, Pilot's menu or chat among them, keeps a Hyper press for itself, never a widget under it.
    private func front(at point: CGPoint, aboveDesktop: Bool = false) -> (info: WindowInfo, layer: Int, alpha: Double)? {
        let clickThrough = EngineObservers.clickThrough(), screens = Screens.frames
        return EngineObservers.onScreen().first(where: {
            $0.alpha > 0 && $0.info.frame.contains(point) && !clickThrough.contains($0.info.id) && (!aboveDesktop || $0.layer >= 0)
                && !(screens.contains($0.info.frame) && ($0.layer != 0 || Self.overlay($0.info.pid)))
        })
    }

    /// What a right press under Hyper names for the file menu: a Finder window or the desktop (no window under the
    /// pointer) for Finder's Accessibility to read once the callback returned, or the menu's file row under the pointer.
    /// Anything else, Pilot's other windows too, gets its click as it was. Only cheap work here: the layer's state, the
    /// window server's list and the menu's own model.
    private func fileClick(at point: CGPoint) -> FileActionsMenu.Source? {
        guard layer.isHyperHeld() else { return nil }
        guard let front = front(at: point) else { return .finder }
        if front.info.pid == ProcessInfo.processInfo.processIdentifier {
            let file = PilotMenu.shared.file(at: CGPoint(x: point.x, y: Screens.primaryHeight - point.y))
            if file == nil { wlog.notice("file click: passed, Pilot's window \(front.info.id) has no file row under the pointer") }
            return file.map { .files([$0]) }
        }
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: DesktopIcons.finder).first?.processIdentifier
        guard front.info.pid == finder else {
            // Which window kept the press from Finder: a press Sven meant for a file names it here.
            let owner = NSRunningApplication(processIdentifier: front.info.pid)?.bundleIdentifier ?? "pid \(front.info.pid)"
            wlog.notice("file click: passed, \(owner, privacy: .public)'s window \(front.info.id) at layer \(front.layer) is under the pointer")
            return nil
        }
        return .finder
    }

    /// Another app with no Dock icon (an agent's cursor, a screen overlay): its whole-screen window takes no click in
    /// practice. Never Pilot's own, which clickThrough already tells.
    private static func overlay(_ pid: pid_t) -> Bool {
        pid != ProcessInfo.processInfo.processIdentifier
            && NSRunningApplication(processIdentifier: pid).map { $0.activationPolicy != .regular } ?? false
    }

    /// The drag this press starts: the modifier alone over another app's normal window or Pilot's own (MouseDrag.hit),
    /// never while one is live. Pilot's click-through windows (none take a click) are looked through; its panels, menu
    /// and bars stop it.
    private func begin(_ button: MouseDrag.Button, _ event: CGEvent) -> (drag: MouseDrag, window: WindowInfo, hyper: Bool)? {
        let flags = event.flags.rawValue, point = event.location, modifier = modifier()
        let hyper = modifier == .hyper && layer.isHeldAlone(flags: flags)
        guard tracker.session == nil, modifier.matches(flags: flags, hyper: hyper) else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        let clickThrough = EngineObservers.clickThrough(), draggable = Self.draggableOwn()
        let listed = EngineObservers.onScreen().filter { !clickThrough.contains($0.info.id) }
        let windows = listed.map { ($0.layer, $0.alpha, $0.info.frame, $0.info.pid == me && !draggable.contains($0.info.id)) }
        guard let i = MouseDrag.hit(point, among: windows, screens: Screens.frames) else { return nil }
        let info = listed[i].info
        return MouseDrag.begin(button, flags: flags, hyper: hyper, at: point, modifier: modifier, window: (Int(info.id), info.frame)).map { ($0, info, hyper) }
    }

    /// Pilot's windows a drag moves like any app's: its own normal windows (the app window), as the tiler lays them out
    /// (OwnApp): titled, movable, at the normal level, and no panel, sheet or child window.
    static func draggableOwn(_ windows: [NSWindow] = NSApp.windows) -> Set<CGWindowID> {
        Set(windows.compactMap { isDraggableOwn($0) ? CGWindowID(exactly: $0.windowNumber) : nil })
    }

    static func isDraggableOwn(_ w: NSWindow) -> Bool { w.isMovable && TilerOwnWindows.isLaidOut(w) }

    /// The press's window, focused first, since the tiler treats a move as the mouse's only for its focused window.
    private func attach(_ info: WindowInfo) {
        let id = Int(info.id)
        guard let drag = tracker.session?.drag, drag.windowID == id else { return }
        if let own = NSApp.windows.first(where: { $0.windowNumber == id }) {
            target = .own(own)
            NSApp.activate()
            own.makeKeyAndOrderFront(nil)
        } else if let ax = AXWindow.matching(info) {
            target = .ax(ax.element)
            ax.focus()
        } else {
            wlog.notice("drag: window \(id, privacy: .public) has no AX window, nothing done")
            return end()
        }
        frames = LatestWins(interval: 1.0 / Double(max(NSScreen.main?.maximumFramesPerSecond ?? 60, 60)))
        counts = (counts.events, 0, .now)
        primaryHeight = Screens.primaryHeight
        let tiled = tiler.isRunning ? UInt32(exactly: drag.windowID) : nil
        // The tiler's tree, read in-process: a tiled window's resize stays inside its reach, its move is the tiler's drag.
        if drag.button == .right, let reach = tiled.flatMap(TilerDrag.reach) { tracker.tile(within: reach) }
        if drag.button == .left { tilerHolds = tiled.map(TilerDrag.begin) ?? false }
        pump()
    }

    /// A point from the tap: written now if a frame is due, else once the write in flight or the frame's wait is over.
    private func offer(_ point: CGPoint) {
        guard target != nil else { return pending = point }
        step(frames.offer(point, now: Self.now), fromTap: true)
    }

    /// A point that came before the window was matched.
    private var pending: CGPoint?
    /// Counts drags, so a write or wait from one that ended never lands on the next.
    private var generation = 0

    /// What the coalescer says to do. A write asked for inside the tap callback runs after it returned.
    private func step(_ step: LatestWins<CGPoint>.Step, fromTap: Bool = false) {
        switch step {
        case .idle: pump()
        case .wait(let delay):
            let drag = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == drag else { return }
                self.step(frames.woke(now: Self.now))
            }
        case .write(let point):
            let drag = generation
            let write = { @MainActor [weak self] in
                guard let self, generation == drag else { return }
                counts.writes += 1
                perform(tracker.effect(at: point)) { [weak self] in
                    guard let self, generation == drag else { return }
                    self.step(frames.written(now: Self.now))
                }
            }
            if fromTap { DispatchQueue.main.async(execute: write) } else { write() }
        }
    }

    /// Picks up a point that waited for the window, and ends the drag once released with nothing left to write.
    private func pump() {
        guard tracker.session != nil, target != nil, !tilerBusy else { return }
        if let point = pending { pending = nil; return step(frames.offer(point, now: Self.now)) }
        guard tracker.released, frames.isIdle else { return }
        let last = tracker.finish()
        if last == .none { return end() }
        perform(last) { [weak self] in self?.pump() }
    }

    /// One effect, then `done` on the main thread once it is written.
    private func perform(_ effect: DragSession.Effect, done: @escaping @MainActor () -> Void) {
        switch effect {
        case .none: done()
        case .position(let p): write(p, nil, done)
        case .frame(let r): write(r.origin, r.size, done)
        case .outline(let r): outline(WindowGeometry.flip(r, primaryHeight: primaryHeight)); done()
        case .tiled(let frame):
            guard let id = tracker.session.flatMap({ UInt32(exactly: $0.drag.windowID) }) else { return done() }
            tilerBusy = true
            outline(nil)
            Task {
                await tiler.perform("windows.dragResize") { _ in try await TilerDrag.resize(id, to: frame) }
                tilerBusy = false
                done()
            }
        }
    }

    /// The window's top-left (AX coordinates) and, for a resize, its size.
    private func write(_ origin: CGPoint, _ size: CGSize?, _ done: @escaping @MainActor () -> Void) {
        switch target {
        case .own(let window):
            let frame = WindowGeometry.flip(CGRect(origin: origin, size: size ?? window.frame.size), primaryHeight: primaryHeight)
            if size == nil { window.setFrameOrigin(frame.origin) } else { window.setFrame(frame, display: true) }
            done()
        case .ax(let element):
            nonisolated(unsafe) let element = element
            Self.axQueue.async {
                AXWindow.write(element, origin: origin, size: size)
                DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
            }
        case nil: done()
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func end() {
        if let drag = tracker.session?.drag {
            let ms = Int((ContinuousClock.now - counts.start) / .milliseconds(1))
            wlog.notice("drag: \(drag.kind == .move ? "move" : "resize", privacy: .public) of window \(drag.windowID, privacy: .public) done: \(self.counts.events, privacy: .public) mouse events, \(self.counts.writes, privacy: .public) frame writes in \(ms, privacy: .public) ms\(self.tilerHolds ? ", dropped by the tiler" : "", privacy: .public)")
        }
        outline(nil)
        if tilerHolds { TilerDrag.end(at: releasePoint) }
        tracker.end(); target = nil; pending = nil; counts = (0, 0, .now); generation += 1
        tilerHolds = false; releasePoint = nil
    }
}

private let mouseCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MouseDragTap>.fromOpaque(userInfo).takeUnretainedValue()
    // The tap's run loop source lives on the main run loop, so this runs on the main thread.
    nonisolated(unsafe) let event = event
    return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
}
