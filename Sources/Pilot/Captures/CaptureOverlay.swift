import AppKit
import PilotCore
import SwiftUI

/// The capture overlay (spec `capture.html` CP3): one panel per display over the stills grabbed at the press, so the
/// screen holds still while Sven picks. Picking an area, a crosshair and a loupe (8x, the point and the pixel's hex) follow
/// the pointer; picking a window, the plain arrow does and the window under it is ringed. A drag takes an area on release,
/// a click or Space then a click takes a window, Tab copies the pixel's colour, Return
/// takes the whole display, and Escape closes. It also closes the moment another app takes the keys (Cmd+Tab) or a
/// display comes, goes or changes, so it can never hold them or cover the wrong screen. Nothing is posted to another app: arrows move the pointer over the overlay itself.
/// Opened by a capture bind with Captures › Capture box on, it is the capture box (pilot-ui-redesign T23, S5 B): its
/// letters switch the mode on every display through the panels' own keys, no event tap (Q257).
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
        var key: KeyPanel?
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
            let panel = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.acceptsMouseMovedEvents = true
            panel.escape = { [weak self] in self?.close() }
            panel.contentView = view
            panel.setFrame(frame, display: false)
            panels.append(panel)
            views.append(view)
            if visible { panel.orderFrontRegardless() }
            if frame.contains(pointer) { key = panel }
        }
        guard let first = key ?? panels.first else { return close() }
        guard visible else { return }
        first.makeKey()
        first.makeFirstResponder(first.contentView)
        (first.contentView as? CaptureOverlayView)?.cursor.set()
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

    /// The box's keys in one line, its choices in brackets: a stand-in for the mode bar T24 draws.
    var hint: String {
        func item(_ title: String, _ letter: Letter?, _ on: Bool) -> String {
            let words = [title, letter.map { String($0.rawValue).uppercased() }].compactMap(\.self).joined(separator: " ")
            return on ? "[\(words)]" : words
        }
        let hows = [item("Area", .area, how == .area), item("Window", .window, how == .window), item("Full", .full, how == .full),
                    item("Scroll", .scroll, how == .scroll)]
        let whats = [item("Photo", nil, what == .photo), item("Record", .record, what == .record), item("Text", .text, what == .text)]
        let timed = item("Timer \(timer == 0 ? "off" : "\(timer) s")", .timer, false)
        return (hows + ["·"] + whats + ["·", timed, "·", "Return  \(action)", "Esc"]).joined(separator: "  ")
    }
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
        needsDisplay = true
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
        needsDisplay = true
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// The pointer came onto this display; the overlay gives its panel the keys.
    var entered: ((CaptureOverlayView) -> Void)?

    override func mouseEntered(with event: NSEvent) {
        entered?(self)
        cursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        update { $0.move(to: point(event)) }
        lookUpElement()
    }

    override func mouseDown(with event: NSEvent) {
        guard purpose != .colour, !full else { return }
        let p = point(event)
        if let held, let grip = CaptureBox.grip(at: p, of: held) {
            gripping = (grip, p, held)
            return
        }
        // A press off the held area starts a new one.
        if held != nil { drop() }
        update { $0.press(at: p) }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let gripping { held = CaptureBox.adjusted(gripping.from, gripping.grip, from: gripping.start, to: p, within: bounds) }
        update { $0.move(to: p) }
    }
    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        // Pick a colour: a click copies the pixel's hex, Shift-click its rgb().
        if purpose == .colour {
            update { $0.move(to: p) }
            return report(event.modifierFlags.contains(.shift) ? .rgb(selection.pointer) : .colour(selection.pointer), self)
        }
        if full { return report(.area(selection.bounds), self) }
        if gripping != nil { gripping = nil; return update { $0.move(to: p) } }
        if holds {
            let dragged = selection.isDragging
            let released = selection.release(at: p)
            let outcome = dragged ? snapped(released) : released
            needsDisplay = true
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
        needsDisplay = true
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
            selection.element = nil
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
        selection.element = element
        needsDisplay = true
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

    private func update(_ change: (inout CaptureSelection) -> Void) {
        change(&selection)
        needsDisplay = true
    }

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

    override func draw(_ dirtyRect: NSRect) {
        still.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        let hole: CGRect? = switch selection.mode {
        case .area where full: bounds.insetBy(dx: 1.5, dy: 1.5)
        case .area: held ?? selection.area ?? selection.element
        case .window: selection.hovered?.frame
        }
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
            if selection.mode == .area, let area { label("\(Int(area.width * grab.scale)) × \(Int(area.height * grab.scale))", below: area) }
            if let held { handles(held) }
        }
        if pointing {
            if !selection.isDragging { crosshair() }
            loupe()
        }
        hint(hintText)
    }

    /// The held area's eight handles, plain squares in the accent: a stand-in for T24's.
    private func handles(_ rect: CGRect) {
        for point in CaptureBox.Grip.handles.compactMap({ $0.point(on: rect) }) {
            let square = NSBezierPath(rect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            square.fill()
            accent.setStroke()
            square.lineWidth = 1
            square.stroke()
        }
    }

    private func crosshair() {
        let p = selection.pointer
        let line = NSBezierPath()
        line.move(to: CGPoint(x: bounds.minX, y: p.y + 0.5)); line.line(to: CGPoint(x: bounds.maxX, y: p.y + 0.5))
        line.move(to: CGPoint(x: p.x + 0.5, y: bounds.minY)); line.line(to: CGPoint(x: p.x + 0.5, y: bounds.maxY))
        line.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        line.stroke()
    }

    /// The magnifier's pixels a side, odd so one sits in the middle; the scroll wheel steps through them (P72).
    static let loupeCells: [CGFloat] = [7, 9, 11, 15, 21, 31]
    private var loupeLevel = 3

    /// The scroll wheel zooms the magnifier, up in, down out; smart selection keeps the wheel for its elements.
    private func zoomLoupe(_ event: NSEvent) {
        guard let step = wheelStep(event) else { return }
        loupeLevel = min(max(loupeLevel - step, 0), Self.loupeCells.count - 1)
        needsDisplay = true
    }

    /// The magnifier (P72, after Snapzy's): 15 by 15 pixels round the pointer at 8x (the scroll wheel zooms from 4x to
    /// 17x), a grid between the pixels and the middle one ringed; under it a swatch, the pixel's hex and rgb, and the
    /// point.
    private func loupe() {
        let p = selection.pointer, side: CGFloat = 120, cells = Self.loupeCells[loupeLevel], half = (cells - 1) / 2
        let colour = colour(at: p)
        let text = colour.map { ColourAnswer.formats($0)[0...1].joined(separator: "  ") } ?? ""
        let coords = "\(Int(p.x)), \(Int(p.y))"
        var frame = CGRect(x: p.x + 24, y: p.y + 24, width: side, height: side)
        if frame.maxX > bounds.maxX - 8 { frame.origin.x = p.x - 24 - side }
        if frame.maxY + 46 > bounds.maxY - 8 { frame.origin.y = p.y - 24 - side - 46 }
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
        let size = (text as NSString).size(withAttributes: attrs), line = size.height
        let panel = CGRect(x: frame.minX, y: frame.maxY + 6, width: max(side, size.width + 34), height: line * 2 + 12)
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
        if let box { return box.hint }
        return switch (purpose, selection.mode) {
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
