import AppKit
import PilotCore
import SwiftUI

/// The capture overlay (spec `capture.html` CP3): one panel per display over the stills grabbed at the press, so the
/// screen holds still while Sven picks. Picking an area, a crosshair and a loupe (8x, the point and the pixel's hex) follow
/// the pointer; picking a window, the plain arrow does and the window under it is ringed. A drag takes an area on release,
/// a click or Space then a click takes a window, Tab copies the pixel's colour, Return
/// takes the whole display, and Escape closes. It also closes the moment another app takes the keys (Cmd+Tab) or a
/// display comes, goes or changes, so it can never hold them or cover the wrong screen. Nothing is posted to another app: arrows move the pointer over the overlay itself.
/// Opened by Capture tool, it is the capture box (pilot-ui-redesign T23, S5 B; Sven, 2026-11-20): its letters switch the
/// mode on every display through the panels' own keys, no event tap (Q257).
@MainActor
final class CaptureOverlay {
    enum Result {
        case cancelled
        /// An area in the display's points; Return with nothing dragged gives the whole display.
        case area(DisplayGrab, CGRect)
        /// A window by its id, with its owner's process and the display it was picked on.
        case window(UInt32, owner: Int32, DisplayGrab)
        /// A colour as copied: `#RRGGBB`, or `rgb(r, g, b)`.
        case colour(String)
    }

    private var panels: [KeyPanel] = []
    private var views: [CaptureOverlayView] = []
    private let grabs: [DisplayGrab]
    private let windows: [CaptureSelection.Window]
    private let mode: CaptureSelection.Mode
    /// False in tests: the panels are made, never ordered onto Sven's screen.
    private let visible: Bool
    /// What the pick is for: a capture, a recording (story 192), a scrolling capture (CP11), text, a subject cut out,
    /// or a colour (P72). Only a capture's and a colour's Tab copies a colour; a scrolling capture, text and a subject
    /// take a clicked window's frame as their area.
    enum Purpose: Equatable { case capture, record, scroll, ocr, subject, colour }

    private let opened: Purpose
    /// The capture box's mode, nil for a press that captures at once; T24's view draws it.
    private(set) var box: CaptureBox?
    /// What the pick is for now: the box's mode while it is up, else what the press opened it for.
    var purpose: Purpose { box?.purpose ?? opened }
    private var done: ((Result) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// When the overlay was put up and drew its first frame, tracked its first pointer move (and how: the pointer read
    /// at a display frame, or a drag) and heard its first mouse-moved event, with whether one of its panels held the keys
    /// and Pilot was the active app at that move (capture-lag). Nil: none before it closed.
    struct Tracking {
        var shown: ContinuousClock.Instant?
        var frame: ContinuousClock.Instant?
        var move: (at: ContinuousClock.Instant, source: String, key: Bool, active: Bool)?
        var event: ContinuousClock.Instant?
    }
    /// Hears the Tracking once, at close.
    var tracked: ((Tracking) -> Void)?
    private var tracking = Tracking()
    /// Stops the display frames the pointer is read at.
    private var stopTicking: (() -> Void)?
    /// The display the pointer was on at the last frame.
    private var under: CaptureOverlayView?

    init(grabs: [DisplayGrab], windows: [CaptureSelection.Window], mode: CaptureSelection.Mode, purpose: Purpose = .capture,
         box: CaptureBox? = nil, visible: Bool = true, done: @escaping (Result) -> Void) {
        self.grabs = grabs
        self.windows = windows
        self.mode = box?.mode ?? mode
        self.visible = visible
        opened = purpose
        self.box = box
        self.done = done
    }

    /// The overlay's display views, for tests.
    var displays: [CaptureOverlayView] { views }

    func show() {
        let pointer = NSEvent.mouseLocation
        var key: CaptureOverlayView?
        for grab in grabs {
            // Offscreen in a test, the grab's own frame stands in for its screen.
            guard let frame = NSScreen.screens.first(where: { $0.displayID == grab.id })?.frame
                    ?? (visible ? nil : CGRect(origin: .zero, size: grab.frame.size)) else { continue }
            let local = CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
            let selection = CaptureSelection(size: grab.frame.size, windows: CaptureSelection.windows(windows, on: grab.frame),
                                             mode: mode, pointer: local)
            let view = CaptureOverlayView(grab: grab, selection: selection, accent: Self.accent(), purpose: purpose, box: box) { [weak self] outcome, view in
                self?.handle(outcome, from: view)
            }
            view.entered = { [weak self] in self?.focus($0) }
            view.pressed = { [weak self] in self?.press($0) }
            view.holding = { [weak self] in self?.hold($0) }
            view.takeHeld = { [weak self] in self?.takeHeld() ?? false }
            view.drawn = { [weak self] in if self?.tracking.frame == nil { self?.tracking.frame = .now } }
            view.moved = { [weak self] in self?.moved($0) }
            view.heard = { [weak self] in if self?.tracking.event == nil { self?.tracking.event = .now } }
            let panel = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.acceptsMouseMovedEvents = true
            panel.escape = { [weak self] in self?.close() }
            // The still is the panel's own layer, which the compositor shows; the view over it draws only the marks.
            let still = CaptureStillView(grab: grab, frame: CGRect(origin: .zero, size: frame.size))
            view.drawsStill = false
            view.frame = still.bounds
            view.autoresizingMask = [.width, .height]
            still.addSubview(view)
            panel.contentView = still
            panel.setFrame(frame, display: false)
            panels.append(panel)
            views.append(view)
            if visible { panel.orderFrontRegardless() }
            if frame.contains(pointer) { key = view }
        }
        guard let first = key ?? views.first, let panel = first.window else { return close() }
        guard visible else { return }
        panel.makeKey()
        panel.makeFirstResponder(first)
        first.cursor.set()
        // The pointer is read at every display frame, so the crosshair follows it from the first frame whether or not
        // macOS sends this inactive app's panel its mouse-moved events (capture-lag); the events are only timed.
        for view in views { view.followed = true }
        stopTicking = DragFollower.displayTicker(rate: nil) { [weak self] in self?.tick() }
        tracking.shown = .now
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
                // Key moving between the overlay's own panels is fine; anything else taking it closes the overlay.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.closeUnlessKey() } }
            },
            // A display plugged, unplugged or rearranged: the stills no longer match the screens.
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
        ]
    }

    /// A letter pressed in the capture box: the box's mode changes on every display.
    func press(_ letter: CaptureBox.Letter) {
        guard var box else { return }
        box.press(letter)
        self.box = box
        for view in views { view.show(box) }
    }

    /// The box holds one area at a time: a drag on one display lets go of another's.
    private func hold(_ view: CaptureOverlayView) {
        for other in views where other !== view { other.drop() }
    }

    /// Return in the box takes the held area, on whichever display it is; false when none is held.
    private func takeHeld() -> Bool {
        guard let view = views.first(where: { $0.held != nil }), let rect = view.held else { return false }
        close(.area(view.grab, rect))
        return true
    }

    /// The panel under the pointer takes the keys, so Space and Tab act on the display Sven is looking at.
    func focus(_ view: CaptureOverlayView) {
        guard let panel = view.window, !panel.isKeyWindow else { return }
        panel.makeKey()
        panel.makeFirstResponder(view)
    }

    private func closeUnlessKey() {
        guard !panels.isEmpty, !panels.contains(where: \.isKeyWindow) else { return }
        close()
    }

    /// Closes every panel and reports `result`, once: a second close does nothing.
    func close(_ result: Result = .cancelled) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        stopTicking?()
        stopTicking = nil
        tracked?(tracking)
        tracked = nil
        for panel in panels { panel.orderOut(nil); panel.contentView = nil }
        panels = []
        views = []
        NSCursor.arrow.set()
        let done = self.done
        self.done = nil
        done?(result)
    }

    private func handle(_ outcome: CaptureSelection.Outcome, from view: CaptureOverlayView) {
        switch outcome {
        case .none: break
        case .close: close()
        // Pick a colour takes nothing but a colour: Return or a click on a window does nothing.
        case .area where purpose == .colour, .window where purpose == .colour: break
        case .area(let rect): close(.area(view.grab, rect))
        case .window(let id):
            let window = view.selection.windows.first { $0.id == id }
            if [.scroll, .ocr, .subject].contains(purpose), let window { return close(.area(view.grab, window.frame)) }
            close(.window(id, owner: window?.owner ?? 0, view.grab))
        case .colour(let point):
            guard purpose == .capture || purpose == .colour else { return }
            close(.colour(view.hex(at: point) ?? "#000000"))
        case .rgb(let point):
            guard purpose == .capture || purpose == .colour, let colour = view.colour(at: point) else { return }
            close(.colour(ColourAnswer.formats(colour)[1]))
        case .pointer(let point):
            // Over the overlay only: the cursor moves on this display, nothing reaches an app.
            CGWarpMouseCursorPosition(CGPoint(x: view.grab.frame.minX + point.x, y: view.grab.frame.minY + point.y))
        }
    }

    /// One display frame: the pointer read where it is now, without waiting for a mouse-moved event, on the display it
    /// is on. Coming onto a display gives its panel the keys; a press held is the drag's, which its events carry.
    private func tick() {
        let mouse = NSEvent.mouseLocation
        guard let view = views.first(where: { $0.window?.frame.contains(mouse) == true }) else { return under = nil }
        if view !== under {
            under = view
            view.enter()
        }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        view.track(view.local(mouse), by: "frame read")
    }

    /// The first pointer move tracked.
    private func moved(_ source: String) {
        guard tracking.move == nil else { return }
        tracking.move = (.now, source, panels.contains(where: \.isKeyWindow), NSApp.isActive)
    }

    /// The picked style's one signal colour, as Hyper and the selected tool use it.
    static func accent() -> NSColor { NSColor(Color(Look.shared.chromeTokens(.hud).colors.accent)) }
}

extension CaptureBox {
    /// What the overlay's pick is for in this mode: Scroll a scrolling capture, Record a recording, Text a read.
    var purpose: CaptureOverlay.Purpose {
        how == .scroll ? .scroll : what == .record ? .record : what == .text ? .ocr : .capture
    }

    /// Window picks a window; Area, Full and Scroll pick on the area selection, Full taking the whole display.
    var mode: CaptureSelection.Mode { how == .window ? .window : .area }
}

extension CaptureOverlay.Result {
    /// An area or a window picked, which the box's timer waits on; a colour or a close is taken at once.
    var picked: Bool {
        switch self {
        case .area, .window: true
        case .cancelled, .colour: false
        }
    }
}

/// One display's overlay: the frozen still, dimmed outside the selection, the selection or the hovered window ringed in
/// the accent, a crosshair and the loupe. Flipped, so its points are CaptureSelection's.
final class CaptureOverlayView: NSView {
    let grab: DisplayGrab
    private(set) var selection: CaptureSelection
    private let accent: NSColor
    private let opened: CaptureOverlay.Purpose
    /// The capture box's mode on this display; nil when the press captures at once.
    private(set) var box: CaptureBox?
    private var purpose: CaptureOverlay.Purpose { box?.purpose ?? opened }
    private let still: NSImage
    private let report: (CaptureSelection.Outcome, CaptureOverlayView) -> Void
    /// The box's bar, handles and readouts in the picked theme (T24, CaptureBoxView.swift).
    private lazy var chrome = CaptureBoxChrome(tokens: Look.shared.chromeTokens(.hud), scale: grab.scale)
    /// The bar's picture for the mode it was drawn in, with its parts' frames, drawn again only when the mode changes.
    private var bar: (box: CaptureBox, image: NSImage, parts: [CaptureBox.Part: CGRect])?
    /// A press that began on the bar, and the part under it: its release there clicks that part, and nothing under
    /// the bar is picked or dragged meanwhile.
    private var barPress: BarPress?
    private struct BarPress { let part: CaptureBox.Part? }
    /// The pointer last set over a held area's handle or body, so a move sets it only when it changes.
    private var gripCursor: NSCursor?
    /// False over a CaptureStillView, whose layer shows the still: the view then draws only its marks.
    var drawsStill = true
    /// The crosshair's two lines and the loupe, views of their own over the marks: a move only moves them and redraws
    /// the loupe's own points, never the whole display (capture-lag: a full redraw per move held the 3440x1440 display's
    /// main thread over 100 ms a move).
    private let across = CaptureLine(), down = CaptureLine()
    private let magnifier = CaptureLoupeView()
    /// Each pointer move tracked, with how it came, each frame drawn and each mouse-moved event heard: the overlay
    /// times the first of each.
    var moved: ((String) -> Void)?
    var drawn: (() -> Void)?
    var heard: (() -> Void)?
    /// The overlay reads the pointer at each display frame and tracks it here; mouse-moved events then only count.
    var followed = false
    /// The last point tracked, so a still pointer tracks nothing.
    private var tracked: CGPoint?

    init(grab: DisplayGrab, selection: CaptureSelection, accent: NSColor, purpose: CaptureOverlay.Purpose = .capture, box: CaptureBox? = nil,
         report: @escaping (CaptureSelection.Outcome, CaptureOverlayView) -> Void) {
        self.grab = grab
        self.selection = selection
        self.accent = accent
        opened = purpose
        self.box = box
        self.report = report
        still = NSImage(cgImage: grab.image, size: grab.frame.size)
        super.init(frame: CGRect(origin: .zero, size: grab.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        magnifier.owner = self
        for part in [across, down, magnifier] { addSubview(part) }
        placePointer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    /// A window is picked with the plain arrow, an area or a colour with the crosshair (Sven, 2026-11-12); the box's
    /// Full screen, which needs no pick, with the arrow too.
    var cursor: NSCursor { (selection.mode == .window || full) && purpose != .colour ? .arrow : .crosshair }

    /// The loupe and the crosshair are for picking a point: an area or a colour, never a window or Full.
    private var pointing: Bool { (selection.mode == .area && !full) || purpose == .colour }

    /// The box is on Full: a click or Return takes the whole display, and nothing is dragged.
    private var full: Bool { box?.how == .full }

    /// The box's mode, changed by a letter on any display: what the pick is for, area or window, redrawn.
    func show(_ box: CaptureBox) {
        let moved = box.how != self.box?.how
        self.box = box
        redrawAll()
        // The timer, Record or Text leave the pick as it was: the elements found and the pointer stay.
        guard moved else { return }
        if selection.mode != box.mode { _ = selection.key(.space) }
        if full, selection.smart { _ = selection.key(.smart) }
        // Window and Full take no area: a held one is let go. Area and Scroll keep it.
        if !holds { drop() }
        elements = []
        window?.invalidateCursorRects(for: self)
        if window?.isKeyWindow == true { cursor.set() }
    }

    /// A letter pressed in the capture box; the overlay changes the mode on every display.
    var pressed: ((CaptureBox.Letter) -> Void)?

    /// The box's area once a drag is let go (shots 5c-area, 5c-scroll): its handles adjust it, the letters and the timer
    /// act on it, and Return takes it. Without the box a drag captures at once, as before.
    private(set) var held: CGRect?
    /// The handle or the held area being dragged, with where the drag began and the area then.
    private var gripping: (grip: CaptureBox.Grip, start: CGPoint, from: CGRect)?
    /// The overlay lets go of any other display's held area.
    var holding: ((CaptureOverlayView) -> Void)?
    /// The overlay's Return on a held area; false when none is held.
    var takeHeld: (() -> Bool)?

    /// A drag in the box's area modes is held rather than taken: Area, Scroll, Record and Text, not Window or Full.
    private var holds: Bool { box != nil && selection.mode == .area && !full && purpose != .colour }

    /// Lets go of the held area.
    func drop() {
        held = nil
        gripping = nil
        redrawAll()
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// `screen`, a point in AppKit's global coordinates, in this view's points.
    func local(_ screen: CGPoint) -> CGPoint {
        guard let window else { return screen }
        return convert(window.convertPoint(fromScreen: screen), from: nil)
    }

    /// The pointer came onto this display; the overlay gives its panel the keys.
    var entered: ((CaptureOverlayView) -> Void)?

    override func mouseEntered(with event: NSEvent) { enter() }

    /// The pointer came onto this display, by its event or the overlay's frame read.
    func enter() {
        entered?(self)
        cursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        heard?()
        if !followed { track(point(event), by: "event") }
    }

    /// The pointer at `p`, from a mouse-moved event or the overlay's frame read.
    func track(_ p: CGPoint, by source: String) {
        guard p != tracked else { return }
        tracked = p
        update { $0.move(to: p) }
        lookUpElement()
        pointHeld(at: selection.pointer)
        moved?(source)
    }

    /// Over a held area's handle a resize arrow, over the area a hand, elsewhere the overlay's own pointer.
    private func pointHeld(at p: CGPoint) {
        guard let box else { return }
        let grip = gripping?.grip ?? held.flatMap { CaptureBox.grip(at: p, of: $0) }
        let onBar = gripping == nil && barFrame(box)?.contains(p) == true
        let shape = onBar ? .arrow : CaptureBoxChrome.cursor(for: grip, dragging: gripping != nil) ?? cursor
        guard shape !== gripCursor else { return }
        gripCursor = shape
        if window?.isKeyWindow == true { shape.set() }
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        if let box, barFrame(box)?.contains(p) == true { return barPress = BarPress(part: barPart(at: p)) }
        guard purpose != .colour, !full else { return }
        if let held, let grip = CaptureBox.grip(at: p, of: held) {
            gripping = (grip, p, held)
            return
        }
        // A press off the held area starts a new one.
        if held != nil { drop() }
        update { $0.press(at: p) }
    }

    #if DEBUG
    /// Holds `rect` as a let-go drag would, for the renders.
    func hold(_ rect: CGRect) {
        held = rect
        redrawAll()
    }
    #endif
    override func mouseDragged(with event: NSEvent) {
        guard barPress == nil else { return }
        let p = point(event)
        tracked = p
        repaint {
            if let gripping { held = CaptureBox.adjusted(gripping.from, gripping.grip, from: gripping.start, to: p, within: bounds) }
            selection.move(to: p)
        }
        pointHeld(at: p)
        moved?("drag")
    }
    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        if let press = barPress {
            barPress = nil
            if let part = press.part, barPart(at: p) == part { click(part) }
            return
        }
        // Pick a colour: a click copies the pixel's hex, Shift-click its rgb().
        if purpose == .colour {
            update { $0.move(to: p) }
            return report(event.modifierFlags.contains(.shift) ? .rgb(selection.pointer) : .colour(selection.pointer), self)
        }
        if full { return report(.area(selection.bounds), self) }
        if gripping != nil {
            gripping = nil
            update { $0.move(to: p) }
            return pointHeld(at: p)
        }
        if holds {
            let dragged = selection.isDragging
            let released = selection.release(at: p)
            let outcome = dragged ? snapped(released) : released
            redrawAll()
            // An area is held for its handles and Return; a click on a window still takes the window.
            guard case .area(let rect) = outcome else { return report(outcome, self) }
            held = rect
            holding?(self)
            return
        }
        finish { $0.release(at: p) }
    }

    override func keyDown(with event: NSEvent) {
        // The box's letters (Q257) and Space between Area and Window; A in Area stays smart selection, A's key before the box.
        if let box, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            if let letter = CaptureBox.Letter(typed: event.charactersIgnoringModifiers), !(letter == .area && box.how == .area) {
                pressed?(letter)
                return
            }
            if Int64(event.keyCode) == KeyCode.space {
                pressed?(box.how == .window ? .area : .window)
                return
            }
        }
        let key: CaptureSelection.Key? = switch Int64(event.keyCode) {
        case KeyCode.escape: .escape
        case 49: .space
        case 36, 76: .enter
        case 48: .tab
        case 123: .left
        case 124: .right
        case 126: .up
        case 125: .down
        // A by its letter, so smart selection sits on A in any layout.
        default: event.charactersIgnoringModifiers?.lowercased() == "a" ? .smart : nil
        }
        guard let key else { return }
        if key == .enter, box != nil, takeHeld?() == true { return }
        if key == .smart { elements = [] }
        let mode = selection.mode
        finish { $0.key(key, shift: event.modifierFlags.contains(.shift)) }
        if key == .smart { lookUpElement() }
        // Space or A switched between area and window: the pointer changes with it.
        if selection.mode != mode {
            window?.invalidateCursorRects(for: self)
            cursor.set()
        }
    }

    /// Applies a release or a key and reports its outcome, a dragged area snapped first when smart is on.
    private func finish(_ change: (inout CaptureSelection) -> CaptureSelection.Outcome) {
        let dragged = selection.isDragging
        let outcome = change(&selection)
        redrawAll()
        report(dragged ? snapped(outcome) : outcome, self)
    }

    /// Smart selection: a dragged area trimmed to its content, in whole points.
    func snapped(_ outcome: CaptureSelection.Outcome) -> CaptureSelection.Outcome {
        guard selection.smart, case .area(let rect) = outcome else { return outcome }
        let s = grab.scale
        let p = CaptureTrim.trim(grab.image, pixels: CaptureSelection.pixels(rect, scale: s, within: CGSize(width: grab.image.width, height: grab.image.height)))
        return .area(CGRect(x: p.minX / s, y: p.minY / s, width: p.width / s, height: p.height / s).integral)
    }

    /// Smart selection's UI elements under the pointer, smallest first, and which one is ringed; the scroll wheel
    /// walks out to bigger ones and back.
    private var elements: [CGRect] = []
    private var level = 0
    private var looking = false
    private var scrolled: CGFloat = 0
    /// Where the UI elements come from: Accessibility, off the main thread. A test sets its own.
    var findElements: @Sendable (CGPoint, pid_t) -> [CGRect] = { CaptureElements.frames(at: $0, pid: $1) }

    /// Asks the app under the pointer for its UI element there, one question at a time; a pointer that moved on while
    /// it was asked asks again. Nothing runs unless smart is on, so the overlay itself never waits on another app.
    func lookUpElement() {
        guard selection.smart, selection.mode == .area, !selection.isDragging, !looking,
              elements.first?.contains(selection.pointer) != true else { return showElement() }
        guard let owner = selection.hovered?.owner, owner > 0, owner != getpid() else {
            elements = []
            if selection.element != nil { repaint { selection.element = nil } }
            return
        }
        looking = true
        let asked = selection.pointer, origin = grab.frame.origin, find = findElements
        let global = CGPoint(x: origin.x + asked.x, y: origin.y + asked.y)
        Task { [weak self] in
            let frames = await Task.detached { find(global, owner) }.value
            guard let self else { return }
            looking = false
            let found = frames.map { $0.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds) }.filter { !$0.isEmpty }
            // The ringed element still in the new chain keeps its place, so a scrolled-out pick holds as the pointer moves.
            level = selection.element.flatMap { found.firstIndex(of: $0) } ?? 0
            elements = found
            showElement()
            if selection.pointer != asked { lookUpElement() }
        }
    }

    private func showElement() {
        guard selection.smart else { return }
        level = min(level, max(elements.count - 1, 0))
        let element = elements.indices.contains(level) && elements[level].contains(selection.pointer) ? elements[level] : nil
        guard element != selection.element else { return }
        repaint { selection.element = element }
    }

    override func scrollWheel(with event: NSEvent) {
        guard selection.smart else { return zoomLoupe(event) }
        guard !elements.isEmpty, let step = wheelStep(event) else { return }
        level = max(level + step, 0)
        showElement()
    }

    /// The wheel's travel in whole steps, 1 up and -1 down; nil until a step's worth has built up.
    private func wheelStep(_ event: NSEvent) -> Int? {
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        guard abs(scrolled) >= 1 else { return nil }
        defer { scrolled = 0 }
        return scrolled > 0 ? 1 : -1
    }

    /// A key, a release or the box's mode changed what the whole display shows.
    private func redrawAll() {
        needsDisplay = true
        placePointer()
    }

    private func update(_ change: (inout CaptureSelection) -> Void) {
        repaint { change(&selection) }
    }

    /// What the view's own drawing stands on as the pointer moves: the selection's hole and ring, the area and its size,
    /// the held area's handles, the box's bar.
    private struct Marks: Equatable {
        var hole: CGRect?, area: CGRect?, held: CGRect?, bar: CGRect?
    }

    private var marks: Marks { Marks(hole: hole, area: selection.area, held: held, bar: box.flatMap { barFrame($0) }) }

    /// The points `marks` can paint: the hole, the area and the held area with room round them for the ring, the
    /// handles and the size label or chip beside them (which can sit a chip's width to the side), and the bar.
    private func painted(_ m: Marks) -> CGRect {
        let near = [m.hole, m.area, m.held].compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }
        let round = near.isNull ? near : near.insetBy(dx: -320, dy: -64)
        return m.bar.map { round.union($0.insetBy(dx: -2, dy: -2)) } ?? round
    }

    /// Applies `change`, then redraws only what it moved: the marks it changed, old and new, and the crosshair and the
    /// loupe at the pointer. A move over an area with nothing picked redraws nothing of the display itself.
    private func repaint(_ change: () -> Void) {
        let before = marks
        change()
        let after = marks
        if before != after {
            let dirty = painted(before).union(painted(after)).intersection(bounds)
            if !dirty.isNull { setNeedsDisplay(dirty) }
        }
        placePointer()
    }

    /// The crosshair's lines through the pointer and the loupe beside it, while an area or a colour is picked; the
    /// lines go while a drag draws its area.
    private func placePointer() {
        across.isHidden = !pointing || selection.isDragging
        down.isHidden = across.isHidden
        magnifier.isHidden = !pointing
        guard pointing else { return }
        let p = selection.pointer
        across.frame = CGRect(x: bounds.minX, y: p.y, width: bounds.width, height: 1)
        down.frame = CGRect(x: p.x, y: bounds.minY, width: 1, height: bounds.height)
        // The loupe is laid out and redrawn only when the pointer or the zoom changed, once for the move and its draw.
        guard placed?.pointer != p || placed?.level != loupeLevel else { return }
        let layout = loupeLayout()
        placed = (p, loupeLevel, layout)
        magnifier.frame = layout.whole
        magnifier.needsDisplay = true
    }

    /// The loupe as last placed: for which pointer and zoom, and where.
    private var placed: (pointer: CGPoint, level: Int, layout: LoupeLayout)?

    /// The pixel under `point` as #RRGGBB, read from the still.
    func hex(at point: CGPoint) -> String? { colour(at: point).map(ColourAnswer.hex) }

    /// The pixel under `point` as 0xRRGGBB, read from the still.
    func colour(at point: CGPoint) -> UInt32? {
        let x = Int(point.x * grab.scale), y = Int(point.y * grab.scale)
        guard x >= 0, y >= 0, x < grab.image.width, y < grab.image.height,
              let pixel = grab.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UInt32(rgba[0]) << 16 | UInt32(rgba[1]) << 8 | UInt32(rgba[2])
    }

    /// The part of the display left undimmed: the area picked or dragged, the element or the window under the pointer.
    private var hole: CGRect? {
        switch selection.mode {
        case .area where full: bounds.insetBy(dx: 1.5, dy: 1.5)
        case .area: held ?? selection.area ?? selection.element
        case .window: selection.hovered?.frame
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        defer { drawn?() }
        if drawsStill {
            still.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        }
        let hole = hole
        let area = held ?? selection.area
        let ringed = selection.mode == .window || area == nil
        // Dim all but the selection: an even-odd path with the hole cut out.
        let dim = NSBezierPath(rect: bounds)
        if let hole { dim.append(NSBezierPath(rect: hole)); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()
        if let hole {
            if ringed { accent.withAlphaComponent(0.15).setFill(); NSBezierPath(rect: hole).fill() }
            accent.setStroke()
            let ring = NSBezierPath(rect: hole.insetBy(dx: -0.5, dy: -0.5))
            ring.lineWidth = ringed ? 3 : 1
            ring.stroke()
            if let box {
                readout(area: selection.mode == .area ? area : nil, clear: barFrame(box))
            } else if selection.mode == .area, let area {
                label(size(area), below: area)
            }
            if let held { chrome.handles(held, accent: accent) }
        }
        if let box { drawBar(box) } else { hint(hintText) }
    }

    /// `rect`'s size in the display's pixels.
    private func size(_ rect: CGRect) -> String { "\(Int(rect.width * grab.scale)) × \(Int(rect.height * grab.scale))" }

    /// The box's readout (shots 5c-*): an area's size by its right edge, on the side the bar (`clear`) leaves free, the
    /// hovered window's app and size over its top right, Full's display and size at the top of the screen.
    private func readout(area: CGRect?, clear bar: CGRect?) {
        if full {
            let name = NSScreen.screens.first { $0.displayID == grab.id }?.localizedName
            chrome.chip(name: name, figures: "\(grab.image.width) × \(grab.image.height)") { CGPoint(x: (bounds.midX - $0.width / 2).rounded(), y: 22) }
        } else if selection.mode == .window, let window = selection.hovered {
            let name = window.owner > 0 ? NSRunningApplication(processIdentifier: window.owner)?.localizedName : nil
            chrome.chip(name: name, figures: size(window.frame)) { chip in
                let x = min(max(window.frame.maxX - chip.width, bounds.minX + 4), bounds.maxX - chip.width - 4)
                let above = window.frame.minY - chip.height - 8
                return CGPoint(x: x, y: above >= bounds.minY + 4 ? above : window.frame.minY + 8)
            }
        } else if let area {
            chrome.chip(name: nil, figures: size(area)) { chip in
                let x = min(max(area.maxX - chip.width, bounds.minX + 4), bounds.maxX - chip.width - 4)
                let places = [area.maxY + 10, area.minY - chip.height - 10].filter { $0 >= bounds.minY + 4 && $0 + chip.height <= bounds.maxY - 4 }
                let free = places.first { y in bar.map { !$0.intersects(CGRect(x: x, y: y, width: chip.width, height: chip.height)) } ?? true }
                // Neither side free of the bar: inside the area's top right.
                return CGPoint(x: x, y: free ?? area.minY + 8)
            }
        }
    }

    /// The bar's picture for `box`, made once per mode.
    private func barImage(_ box: CaptureBox) -> NSImage? {
        if bar?.box != box { bar = chrome.bar(box).map { (box, $0.image, $0.parts) } }
        return bar?.image
    }

    /// The bar's part under `p`, in the view's points; nil off the bar or between its parts.
    func barPart(at p: CGPoint) -> CaptureBox.Part? {
        guard let box, let frame = barFrame(box), frame.contains(p), let parts = bar?.parts else { return nil }
        return parts.first { $0.value.offsetBy(dx: frame.minX, dy: frame.minY).contains(p) }?.key
    }

    /// Where each of the bar's parts is now, in the view's points; for tests.
    var barParts: [CaptureBox.Part: CGRect] {
        guard let box, let frame = barFrame(box), let parts = bar?.parts else { return [:] }
        return parts.mapValues { $0.offsetBy(dx: frame.minX, dy: frame.minY) }
    }

    /// A click on the bar (Sven, 2026-11-20): a choice or the timer as its letter, the action button as Return, Close
    /// as Esc.
    private func click(_ part: CaptureBox.Part) {
        switch part {
        case .action:
            if takeHeld?() == true { return }
            finish { $0.key(.enter) }
        case .close:
            finish { $0.key(.escape) }
        default:
            if let letter = box?.letter(for: part) { pressed?(letter) }
        }
    }

    /// Where the bar goes (Sven, 2026-11-20): under the held or dragged area, so it follows a drag and a resize; at the
    /// display's foot for Full, Window and before an area is dragged (`CaptureBox.barFrame`).
    private func barFrame(_ box: CaptureBox) -> CGRect? {
        guard let image = barImage(box) else { return nil }
        let area = selection.mode == .area && !full ? held ?? selection.area : nil
        return CaptureBox.barFrame(image.size, under: area, within: bounds)
    }

    /// The box's bar, under the picked area.
    private func drawBar(_ box: CaptureBox) {
        guard let image = barImage(box), let frame = barFrame(box) else { return hint(box.action) }
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The magnifier's pixels a side, odd so one sits in the middle; the scroll wheel steps through them (P72).
    static let loupeCells: [CGFloat] = [7, 9, 11, 15, 21, 31]
    private var loupeLevel = 3

    /// The scroll wheel zooms the magnifier, up in, down out; smart selection keeps the wheel for its elements.
    private func zoomLoupe(_ event: NSEvent) {
        guard let step = wheelStep(event) else { return }
        loupeLevel = min(max(loupeLevel - step, 0), Self.loupeCells.count - 1)
        placePointer()
    }

    /// Where the loupe goes for the pointer: its magnifier, its colour panel under it with the pixel's colour, text and
    /// line height, and both with room for their strokes (the loupe view's frame).
    private struct LoupeLayout {
        let frame: CGRect, panel: CGRect, colour: UInt32?, text: String, line: CGFloat, whole: CGRect
    }

    /// The magnifier's side, in points.
    private static let loupeSide: CGFloat = 120

    private func loupeLayout() -> LoupeLayout {
        let p = selection.pointer, side = Self.loupeSide
        let colour = colour(at: p)
        let text = colour.map { ColourAnswer.formats($0)[0...1].joined(separator: "  ") } ?? ""
        var frame = CGRect(x: p.x + 24, y: p.y + 24, width: side, height: side)
        if frame.maxX > bounds.maxX - 8 { frame.origin.x = p.x - 24 - side }
        if frame.maxY + 46 > bounds.maxY - 8 { frame.origin.y = p.y - 24 - side - 46 }
        let size = (text as NSString).size(withAttributes: Self.attributes), line = size.height
        let panel = CGRect(x: frame.minX, y: frame.maxY + 6, width: max(side, size.width + 34), height: line * 2 + 12)
        return LoupeLayout(frame: frame, panel: panel, colour: colour, text: text, line: line,
                           whole: frame.union(panel).insetBy(dx: -2, dy: -2).integral)
    }

    /// The magnifier (P72, after Snapzy's): 15 by 15 pixels round the pointer at 8x (the scroll wheel zooms from 4x to
    /// 17x), a grid between the pixels and the middle one ringed; under it a swatch, the pixel's hex and rgb, and the
    /// point. In this view's points, as last placed; its own view draws it.
    fileprivate func loupe() {
        let p = selection.pointer, side = Self.loupeSide, cells = Self.loupeCells[loupeLevel], half = (cells - 1) / 2
        let layout = placed?.layout ?? loupeLayout()
        let (frame, panel, colour, text, line) = (layout.frame, layout.panel, layout.colour, layout.text, layout.line)
        let coords = "\(Int(p.x)), \(Int(p.y))"
        let px = (p.x * grab.scale).rounded(.down), py = (p.y * grab.scale).rounded(.down)
        let source = CGRect(x: px - half, y: py - half, width: cells, height: cells)
        let cell = side / cells
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        NSColor.black.setFill(); clip.fill()
        clip.addClip()
        if let cut = grab.image.cropping(to: source.intersection(CGRect(x: 0, y: 0, width: grab.image.width, height: grab.image.height))) {
            NSGraphicsContext.current?.imageInterpolation = .none
            let offset = CGPoint(x: max(0, -source.minX) * cell, y: max(0, -source.minY) * cell)
            NSImage(cgImage: cut, size: CGSize(width: cut.width, height: cut.height))
                .draw(in: CGRect(x: frame.minX + offset.x, y: frame.minY + offset.y, width: CGFloat(cut.width) * cell, height: CGFloat(cut.height) * cell),
                      from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        }
        // The pixel grid, faint mid-grey so it shows on light and dark pixels alike, where a pixel is big enough to tell apart.
        if cell >= 6 {
            let grid = NSBezierPath()
            for i in 1..<Int(cells) {
                let o = (CGFloat(i) * cell).rounded() + 0.25
                grid.move(to: CGPoint(x: frame.minX + o, y: frame.minY)); grid.line(to: CGPoint(x: frame.minX + o, y: frame.maxY))
                grid.move(to: CGPoint(x: frame.minX, y: frame.minY + o)); grid.line(to: CGPoint(x: frame.maxX, y: frame.minY + o))
            }
            grid.lineWidth = 0.5
            NSColor(white: 0.5, alpha: 0.35).setStroke()
            grid.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        accent.setStroke()
        let middle = NSBezierPath(rect: CGRect(x: frame.minX + half * cell, y: frame.minY + half * cell, width: cell, height: cell))
        middle.lineWidth = 1.5
        middle.stroke()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
        // The colour panel: swatch, hex and rgb, then the point.
        let attrs = Self.attributes
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6).fill()
        let swatch = CGRect(x: panel.minX + 7, y: panel.minY + 5, width: line, height: line)
        if let colour {
            NSColor(Color(hex: colour)).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
            NSColor.white.withAlphaComponent(0.5).setStroke()
            NSBezierPath(roundedRect: swatch.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        }
        (text as NSString).draw(at: CGPoint(x: swatch.maxX + 6, y: panel.minY + 5), withAttributes: attrs)
        (coords as NSString).draw(at: CGPoint(x: swatch.maxX + 6, y: panel.minY + 7 + line),
                                  withAttributes: [.font: attrs[.font]!, .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
    }

    /// What the keys do, for the purpose and the mode.
    private var hintText: String {
        switch (purpose, selection.mode) {
        case (.colour, _): "Pick a colour: click copies its hex, Shift-click its rgb   Tab  hex   Shift-Tab  rgb   Scroll  zoom   Esc"
        case (_, .area) where selection.smart: "Smart: drag loosely, it snaps to the content   Click a UI element   Scroll  bigger or smaller   A  off   Esc"
        case (.capture, .area): "Drag an area   A  smart   Click or Space  window   Tab  hex   Shift-Tab  rgb   Scroll  zoom   Return  whole screen   Esc"
        case (.capture, .window): "Click a window   Space  area   Esc"
        case (.record, .area): "Record: drag an area   Click a window for its app   Return  this screen   Esc"
        case (.record, .window): "Record: click a window for its app   Space  area   Esc"
        case (.scroll, .area): "Scrolling capture: drag the part that scrolls   Click a window for all of it   Esc"
        case (.scroll, .window): "Scrolling capture: click the window that scrolls   Space  area   Esc"
        case (.ocr, .area): "Read text: drag over the words or a QR code   A  smart   Click a window for all of it   Esc"
        case (.ocr, .window): "Read text: click a window   Space  area   Esc"
        case (.subject, .area): "Capture subject: drag round it   A  smart   Click a window for all of it   Esc"
        case (.subject, .window): "Capture subject: click a window   Space  area   Esc"

        }
    }

    /// The keys, once, at the foot of the display.
    private func hint(_ text: String) {
        let attrs = Self.attributes
        let size = (text as NSString).size(withAttributes: attrs)
        let box = CGRect(x: bounds.midX - size.width / 2 - 12, y: bounds.maxY - size.height - 36, width: size.width + 24, height: size.height + 10)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 12, y: box.minY + 5), withAttributes: attrs)
    }

    private func label(_ text: String, below rect: CGRect) {
        let attrs = Self.attributes
        let size = (text as NSString).size(withAttributes: attrs)
        var box = CGRect(x: rect.minX, y: rect.maxY + 6, width: size.width + 12, height: size.height + 6)
        if box.maxY > bounds.maxY - 4 { box.origin.y = rect.minY - box.height - 6 }
        box.origin.x = min(max(box.minX, bounds.minX + 4), bounds.maxX - box.width - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
    ]
}

/// The frozen still under a display's overlay, shown as its layer's contents: the compositor draws it, so neither the
/// overlay's first frame nor a pointer move redraws its pixels on the main thread (capture-lag).
final class CaptureStillView: NSView {
    init(grab: DisplayGrab, frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = grab.image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        layer?.isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    /// The contents were set once; nothing to draw.
    override func updateLayer() {}
}

/// One of the crosshair's lines: the pointer's row or column, which a move only moves. Clicks go through to the overlay.
private final class CaptureLine: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.55).setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// The loupe beside the pointer, drawn by its overlay in the overlay's points. Clicks go through to the overlay.
private final class CaptureLoupeView: NSView {
    weak var owner: CaptureOverlayView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.translateBy(x: -frame.minX, y: -frame.minY)
        owner?.loupe()
    }
}
