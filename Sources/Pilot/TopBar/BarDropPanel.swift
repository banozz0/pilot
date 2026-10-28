import AppKit
import PilotCore

/// What a bar drop shows, handed in by its owner as it opens: Ask AI's chat now, the terminal later (spec Bar drops T6).
@MainActor
struct BarDropFace {
    /// The drop's window around its content at its first size (BarDrops.panel); the content fills it as the drop moves
    /// between one and both open. BarDrops places it and sets its level.
    let panel: (CGSize) -> KeyPanel
    /// The drop's own keys, offered before its view sees them; true when taken. Escape never comes here: DropKeys has it.
    var keys: (UInt16, NSEvent.ModifierFlags, String?) -> Bool = { _, _, _ in false }
    /// A key passed on goes to the drop's text field when that lost the keyboard (Ask AI's input; a terminal keeps its own).
    var keepsField = true
    /// Told once the drop has closed, by any rule: its key, Escape, a click outside.
    var closed: () -> Void = {}
}

/// The bar drops on screen (spec Bar drops T5, notes › The drop panel): one non-activating key panel per open drop, so
/// the app Sven was in stays active, hung under the top bar where BarDropPlacement puts it. DropKeys is the truth for
/// what is open and has the keyboard; every change goes through it, then the panels follow. The drops open on the focused
/// display and stay there until both have closed. Nothing is made before the first open. Each drop's content sits in a
/// clip on the panel (BarDropClip) and slides inside it, so it comes from behind the bar with the keyboard already in it
/// (BarDropMotion, spec Bar drops T8); a bare terminal is dressed in its chrome (TerminalDropChrome) on the way in.
@MainActor
final class BarDrops {
    static let shared = BarDrops()

    /// Where the drops hang: the screen's frame, its visible frame and the top bar's strip on it, nil with no bar there.
    struct Spot: Equatable {
        var screen: CGRect
        var visible: CGRect
        var bar: CGRect?
    }

    private(set) var keys = DropKeys()
    private var panels: [BarDropKind: KeyPanel] = [:]
    /// What slides in each open drop's clip: the face's content, or the terminal's chrome round it.
    private var bodies: [BarDropKind: NSView] = [:]
    private var faces: [BarDropKind: BarDropFace] = [:]
    private var keyMonitors: [BarDropKind: Any] = [:]
    private var mouseMonitors: [Any] = []
    /// Where the open drops hang, taken as the first opens.
    private var spot: Spot?

    /// The top bar's window level now: TopBarWindows moves it between the status bar's and one under the menu bar as
    /// the menu bar peeks, and the open drops follow.
    var barLevel = TopBarWindows.aboveMenuBar {
        didSet { if barLevel != oldValue { panels.values.forEach { $0.level = level } } }
    }
    /// Where the next first drop hangs; tests fix it.
    var focused: @MainActor () -> Spot = BarDrops.focusedSpot
    /// No motion at all; tests set it so frames land at once.
    var still: @MainActor () -> Bool = { false }
    /// A click outside hides the drops; tests turn the watch off, as another test's click, or Sven's anywhere, closed
    /// their drop mid-test, and call `clicked(in:)` themselves.
    var watchesClicks = true
    /// How the drops move otherwise: Reduce Motion's fade, or the slide (BarDropMotion).
    var motion: @MainActor () -> BarDropMotion.Mode = BarDropMotion.live

    /// A drop's window: a borderless, non-activating key panel, so the app Sven was in stays active, around `content`.
    static func panel(_ content: NSView, title: String, appearance: NSAppearance?) -> KeyPanel {
        let panel = KeyPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = content
        panel.appearance = appearance
        panel.title = title   // what Accessibility and the tiler's list-windows read
        return panel
    }

    /// One under the top bar, so a drop comes from behind it and stays over the `.floating` windows and under the HUDs
    /// (Hyper+Space, the clipboard); with no bar on its screen, just over the floating windows.
    static func level(bar: NSWindow.Level?) -> NSWindow.Level {
        NSWindow.Level(rawValue: (bar ?? .floating).rawValue + (bar == nil ? 1 : -1))
    }

    /// The focused display (the one holding the focused window) and the top bar's strip on it.
    static func focusedSpot() -> Spot {
        guard let screen = Screens.focusedScreen ?? NSScreen.main else {
            let fallback = CGRect(x: 0, y: 0, width: BarDropPlacement.width, height: BarDropPlacement.height)
            return Spot(screen: fallback, visible: fallback, bar: nil)
        }
        let bar = Screens.bars[screen.localizedName].map { TopBarGeometry.frame(screen: screen.frame, strip: $0) }
        return Spot(screen: screen.frame, visible: screen.visibleFrame, bar: bar)
    }

    /// The open drops' level: one under the bar when their screen has one.
    private var level: NSWindow.Level { Self.level(bar: spot?.bar == nil ? nil : barLevel) }

    func isOpen(_ drop: BarDropKind) -> Bool { panels[drop] != nil }
    func window(_ drop: BarDropKind) -> NSWindow? { panels[drop] }

    /// Opens `drop` showing `face` beside any other, and gives it the keyboard; an open one keeps its face.
    func open(_ drop: BarDropKind, face: BarDropFace) {
        guard !keys.open.contains(drop) else { return }
        faces[drop] = face
        keys.toggle(drop)
        sync()
    }

    func close(_ drop: BarDropKind) {
        guard keys.open.contains(drop) else { return }
        keys.toggle(drop)
        sync()
    }

    /// The drop's key (T4's bar item and T7's binds): closes it when open, else opens it with `face`.
    func toggle(_ drop: BarDropKind, face: @autoclosure () -> BarDropFace) {
        keys.open.contains(drop) ? close(drop) : open(drop, face: face())
    }

    func hideAll() {
        keys.clickOutside()
        sync()
    }

    /// A key in `drop` at `time` (the event clock): true when taken. Escape goes by DropKeys: Ask AI closes on one; the
    /// terminal's passes on, and a second within 0.4 s closes the drop after its view has had it.
    func key(in drop: BarDropKind, _ code: UInt16, _ flags: NSEvent.ModifierFlags, _ chars: String?, at time: TimeInterval) -> Bool {
        guard keys.open.contains(drop) else { return false }
        if keys.focused != drop { keys.click(in: drop) }
        guard Int64(code) == KeyCode.escape else {
            keys.typed()
            // Return may have run a `cd`: the terminal's header reads its folder again.
            if code == 36 || code == 76 { (bodies[drop] as? TerminalDropChrome)?.refreshSoon() }
            return faces[drop]?.keys(code, flags, chars) == true
        }
        let escape = keys.escape(at: time)
        if escape.closes != nil {
            if escape.passes { DispatchQueue.main.async { [weak self] in self?.sync() } } else { sync() }
        }
        return !escape.passes
    }

    /// A click in `window`, nil in another app: in a drop it takes the keyboard; on the top bar it leaves the drops to
    /// the item clicked (a bar drop's item toggles its own); anywhere else it hides both.
    func clicked(in window: NSWindow?) {
        if let window, let drop = panels.first(where: { $0.value === window })?.key { return keys.click(in: drop) }
        if window is TopBarPanel { return }
        hideAll()
    }

    /// The panels follow DropKeys: closed drops go, open ones take their frames, the focused one the keyboard.
    private func sync() {
        // The bar drops' items relight from here, however a drop opened or closed (spec Bar drops T4).
        defer { if self === BarDrops.shared { BarDropLights.shared.refresh() } }
        for drop in Array(panels.keys) where !keys.open.contains(drop) { remove(drop) }
        guard !keys.open.isEmpty else {
            spot = nil
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors = []
            return
        }
        let spot = self.spot ?? focused()
        self.spot = spot
        let frames = BarDropPlacement.frames(open: keys.open, screen: spot.screen, visible: spot.visible, bar: spot.bar)
        let motion = mode
        for (drop, frame) in frames {
            if let panel = panels[drop] {
                guard panel.frame != frame else { continue }
                // The one left slides back to the centre, or the first aside for the second, on the drawer's curve.
                if motion == .slide {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = BarDropMotion.down
                        context.timingFunction = BarDropMotion.drawer
                        panel.animator().setFrame(frame, display: true)
                    }
                } else {
                    panel.setFrame(frame, display: true)
                }
            } else if let face = faces[drop] {
                make(drop, face: face, frame: frame, motion: motion)
            }
        }
        if let focused = keys.focused, let panel = panels[focused], !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
        if watchesClicks, mouseMonitors.isEmpty { watchClicks() }
    }

    /// How the drops move now: not at all while still, else as BarDropMotion says.
    private var mode: BarDropMotion.Mode { still() ? .none : motion() }

    /// The drop's panel on its frame from frame 0, so keys land at once, its content sliding down inside it from behind
    /// the bar, the contents fading in; a 100 ms fade under Reduce Motion; at once while still.
    private func make(_ drop: BarDropKind, face: BarDropFace, frame: CGRect, motion: BarDropMotion.Mode) {
        BarDropMotion.opening = motion == .slide
        let panel = face.panel(frame.size)
        BarDropMotion.opening = false
        let body = dress(drop, panel)
        panel.level = level
        panels[drop] = panel
        bodies[drop] = body
        panel.setFrame(frame, display: false)
        switch motion {
        case .slide: body.setFrameOrigin(CGPoint(x: 0, y: frame.height))
        case .fade: panel.alphaValue = 0
        case .none: break
        }
        let keepsField = face.keepsField
        keyMonitors[drop] = HUD.showSearchPanel(panel, handle: { [weak self] in
            self?.key(in: drop, $0, $1, $2, at: ProcessInfo.processInfo.systemUptime) == true
        }, keepsSearch: { keepsField }, onlyPanel: true, log: { tblog.debug("bar drop \(drop.rawValue, privacy: .public): \($0, privacy: .public)") })
        switch motion {
        case .slide:
            NSAnimationContext.runAnimationGroup { context in
                context.duration = BarDropMotion.down
                context.timingFunction = BarDropMotion.drawer
                body.animator().setFrameOrigin(.zero)
            }
            (body as? TerminalDropChrome)?.fadeIn()
        case .fade:
            NSAnimationContext.runAnimationGroup { context in
                context.duration = BarDropMotion.fade
                panel.animator().alphaValue = 1
            }
        case .none: break
        }
    }

    /// The face's content moved into a clip filling the panel, so it can slide cut at the panel's top edge; a bare
    /// terminal goes into its chrome first. The view that had the keyboard keeps it. Returns what slides.
    private func dress(_ drop: BarDropKind, _ panel: KeyPanel) -> NSView {
        guard let content = panel.contentView else { return NSView() }
        let responder = panel.firstResponder as? NSView
        let clip = BarDropClip(frame: CGRect(origin: .zero, size: content.frame.size))
        panel.contentView = clip
        let body: NSView = (content as? TerminalSurface).map { surface in
            TerminalDropChrome(surface: surface, hide: { [weak self] in self?.close(drop) })
        } ?? content
        body.frame = clip.bounds
        body.autoresizingMask = [.width, .height]
        clip.addSubview(body)
        if let responder, responder.isDescendant(of: clip) { panel.makeFirstResponder(responder) }
        return body
    }

    /// The drop's panel goes with its content, so its view's onDisappear runs (Ask AI's chat stops showing): its content
    /// slides back up behind the bar first (160 ms), or fades (100 ms). The drop is closed from the first frame: its
    /// keys, its light and its window(_:) are gone, and opening it again makes a new panel.
    private func remove(_ drop: BarDropKind) {
        keyMonitors.removeValue(forKey: drop).map(NSEvent.removeMonitor)
        let body = bodies.removeValue(forKey: drop)
        if let panel = panels.removeValue(forKey: drop) {
            let gone = { panel.orderOut(nil); panel.contentView = nil }
            switch mode {
            case .slide where body != nil:
                panel.makeFirstResponder(nil)   // no key reaches the shell or the chat while it goes
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = BarDropMotion.up
                    context.timingFunction = BarDropMotion.away
                    body?.animator().setFrameOrigin(CGPoint(x: 0, y: panel.frame.height))
                }, completionHandler: gone)
            case .fade:
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = BarDropMotion.fade
                    panel.animator().alphaValue = 0
                }, completionHandler: gone)
            default:
                gone()
            }
        }
        faces.removeValue(forKey: drop)?.closed()
    }

    /// While a drop is open: a click in another app, or in another of Pilot's windows, goes to `clicked`.
    private func watchClicks() {
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked(in: nil) }
        }) { mouseMonitors.append(outside) }
        if let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.clicked(in: event.window) }
            return event
        }) { mouseMonitors.append(inside) }
    }
}
