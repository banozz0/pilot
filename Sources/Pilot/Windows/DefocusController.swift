import AppKit
import Observation
import PilotCore

/// Where Defocus draws; the real one is a panel per screen, tests a fake.
@MainActor
protocol DefocusSurface: AnyObject {
    /// Covers each of `screens` (AppKit frames), ordered directly below the window numbered `window`.
    func show(screens: [CGRect], below window: CGWindowID, look: Defocus.Look)
    func hide()
}

/// Where mouse moves come from: a listen-only event tap, a fake in the tests. `move` gets each move's horizontal and
/// vertical delta in points and its time in seconds since boot, `scroll` the time of each scroll or gesture.
@MainActor
protocol MouseMoveTap: AnyObject {
    /// False when the tap could not be made.
    func start(move: @escaping (Double, Double, TimeInterval) -> Void, scroll: @escaping (TimeInterval) -> Void) -> Bool
    func stop()
}

/// Defocus (card agent-bo-95423220, story 138, ADR 0009): everything but the focused window blurred and dimmed. A shake
/// (while the binds are armed and Tiling › Focused window's Shake to defocus is on) or windows.defocus toggles it; EngineObservers hands it
/// each read of the focused window, so the sharp window follows focus.
@MainActor
final class DefocusController {
    static let shared = DefocusController()

    private let surface: any DefocusSurface
    private let tap: any MouseMoveTap
    private let look: Look
    private let screens: () -> [CGRect]
    /// Says why a toggle did nothing: a HUD tip, a record in the tests.
    private let tell: @MainActor (String) -> Void
    /// On or off, turned by hand (shake or bind).
    private var on = false
    private var shake = ShakeDetector()
    private var window: WindowBorder.Window?
    /// The binds are armed; the shake tap runs only then, and only with Look's switch on.
    private var armed = false
    private var listening = false
    private var followingScreens: NSObjectProtocol?

    init(surface: any DefocusSurface = DefocusPanels(), tap: any MouseMoveTap = MouseMoveEventTap(), look: Look = .shared,
         screens: @escaping () -> [CGRect] = { NSScreen.screens.map(\.frame) }, tell: @escaping @MainActor (String) -> Void = { HUD.tip($0) }) {
        self.surface = surface; self.tap = tap; self.look = look; self.screens = screens; self.tell = tell
    }

    /// Look's blur and dim now; nil while both are off.
    private var current: Defocus.Look? {
        Defocus.look(strength: look.defocusStrength, dim: look.defocusDim, reduceTransparency: look.reduceTransparency)
    }

    /// On or off; with Blur and Dim both off, turning it on only tips that there is nothing to do.
    func toggle() {
        if !on, current == nil { return tell(Defocus.nothingToDo) }
        on.toggle()
        wlog.notice("defocus \(self.on ? "on" : "off", privacy: .public)")
        refresh()
    }

    func update(_ window: WindowBorder.Window?) {
        self.window = window
        refresh()
    }

    /// Hidden while off, while Blur and Dim are both off, or while no window can stay sharp (none, a dialog, minimised,
    /// fullscreen, no window number).
    private func refresh() {
        guard on, Defocus.keepsSharp(window), let id = window?.windowID, let current else { return surface.hide() }
        surface.show(screens: screens(), below: id, look: current)
    }

    /// The shake tap runs with the binds. Disarmed, Defocus turns off too: nothing could turn it off then.
    func arm(_ on: Bool) {
        let was = armed
        armed = on
        listen()
        if was, !on, self.on { toggle() }
    }

    /// Starts or stops the shake tap as the binds and Look's switch allow, at Look's Swings needed and Within; the switch
    /// going off leaves Defocus as it is.
    private func listen() {
        shake.swings = look.defocusShakeSwings
        shake.within = look.defocusShakeWithin
        let wanted = armed && look.defocusShake
        if wanted, !listening {
            listening = tap.start { [unowned self] dx, dy, t in
                guard shake.move(dx: dx, dy: dy, at: t) else { return }
                wlog.notice("defocus: shake")
                toggle()
            } scroll: { [unowned self] t in
                shake.scroll(at: t)
            }
            if !listening { wlog.error("defocus: mouse tap not created") }
        } else if !wanted, listening {
            tap.stop()
            listening = false
            shake = ShakeDetector()
        }
    }

    /// Follows Look's blur, dim, shake switch and tuning and Reduce Transparency, and screens coming and going, from now on.
    func start() {
        if followingScreens == nil {
            followingScreens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                      object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        withObservationTracking {
            _ = (look.defocusStrength, look.defocusDim, look.defocusShake, look.defocusShakeSwings, look.defocusShakeWithin, look.reduceTransparency)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.listen()
                self?.refresh()
                self?.start()
            }
        }
    }
}

/// A borderless, click-through panel per screen at the normal window level, ordered directly below the focused window,
/// so the window server blurs (CGSSetWindowBackgroundBlurRadius, as iTerm2 does) and dims every window under it; the
/// focused window, anything floating, the Dock, the menu bar and Pilot's own bar and panels stay above it. Reading what
/// is behind is the window server's job: no Screen Recording.
@MainActor
final class DefocusPanels: DefocusSurface {
    private var panels: [NSPanel] = []
    /// The last overlay drawn: AX sends a move or a resize many times over, and an unchanged overlay is left alone.
    private var drawn: (screens: [CGRect], below: CGWindowID, look: Defocus.Look)?
    private static let fade: TimeInterval = 0.18
    /// The normal windows' level: under the menu bar and Pilot's top bar at either of theirs, so neither is ever dimmed.
    static let level = NSWindow.Level.normal

    func show(screens: [CGRect], below window: CGWindowID, look: Defocus.Look) {
        if let drawn, drawn.screens == screens, drawn.below == window, drawn.look == look { return }
        let appearing = drawn == nil
        let fades = appearing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let restyle = appearing || drawn?.look != look || panels.count != screens.count
        while panels.count < screens.count { panels.append(Self.panel()) }
        while panels.count > screens.count { panels.removeLast().orderOut(nil) }
        for (panel, frame) in zip(panels, screens) {
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            if appearing { panel.alphaValue = fades ? 0 : 1 }
            panel.order(.below, relativeTo: Int(window))
            guard restyle else { continue }
            panel.backgroundColor = NSColor.black.withAlphaComponent(look.dim)
            // The window has its number once ordered in.
            WindowServerBlur.set(look.blurRadius, on: panel.windowNumber)
        }
        if fades {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fade
                for panel in panels { panel.animator().alphaValue = 1 }
            }
        }
        drawn = (screens, window, look)
    }

    func hide() {
        guard drawn != nil else { return }
        for panel in panels { panel.orderOut(nil) }
        drawn = nil
    }

    private static func panel() -> NSPanel {
        let panel = WindowBorderPanel.overlay()
        panel.level = level
        return panel
    }
}

/// The window server's blur behind a window, through SkyLight's CGSSetWindowBackgroundBlurRadius (private, looked up
/// once); a radius of 0 is none. When the call is gone, Defocus is dim only, and says so once in the log.
@MainActor
enum WindowServerBlur {
    private typealias Connection = @convention(c) () -> Int32
    private typealias SetRadius = @convention(c) (Int32, Int32, Int32) -> Int32
    private static let calls: (Connection, SetRadius)? = {
        // RTLD_DEFAULT: every image loaded in the process.
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(handle, "CGSMainConnectionID"), let set = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else {
            wlog.error("defocus: CGSSetWindowBackgroundBlurRadius not found, dim only")
            return nil
        }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(set, to: SetRadius.self))
    }()

    static func set(_ radius: Int, on window: Int) {
        guard let (connection, set) = calls, window > 0 else { return }
        let status = set(connection(), Int32(window), Int32(radius))
        if status != 0 { wlog.error("defocus: blur radius on window \(window) failed (\(status))") }
    }
}

/// Mouse moves (not drags) from a listen-only tap, only while armed, and the scrolls and gestures that silence them: a
/// scroll wheel event (a Magic Mouse or trackpad scroll, momentum included), a pinch, a rotate or a swipe. Not the raw
/// gesture events: one finger moving the pointer on a trackpad sends those too, a hundred a second.
@MainActor
final class MouseMoveEventTap: MouseMoveTap {
    private static let silencers: [UInt] = [UInt(CGEventType.scrollWheel.rawValue), NSEvent.EventType.magnify.rawValue,
                                              NSEvent.EventType.rotate.rawValue, NSEvent.EventType.swipe.rawValue]
    private let tap = ListenOnlyTap(mask: silencers.reduce(CGEventMask(1) << CGEventType.mouseMoved.rawValue) { $0 | CGEventMask(1) << $1 })

    func start(move: @escaping (Double, Double, TimeInterval) -> Void, scroll: @escaping (TimeInterval) -> Void) -> Bool {
        tap.start { event in
            // Uptime when the event arrives, as the rest of Pilot times things: CGEvent's timestamp is not nanoseconds on every Mac.
            let t = ProcessInfo.processInfo.systemUptime
            if event.type == .mouseMoved {
                move(event.getDoubleValueField(.mouseEventDeltaX), event.getDoubleValueField(.mouseEventDeltaY), t)
            } else {
                scroll(t)
            }
        }
    }

    func stop() { tap.stop() }
}
