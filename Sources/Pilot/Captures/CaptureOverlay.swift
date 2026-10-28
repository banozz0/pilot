import AppKit
import PilotCore
import SwiftUI

/// The capture overlay (spec `capture.html` CP3): one panel per display over the stills grabbed at the press, so the
/// screen holds still while Sven picks. A crosshair and a loupe (8x, the point and the pixel's hex) follow the pointer;
/// a drag takes an area on release, a click or Space then a click takes a window, Tab copies the pixel's colour, Return
/// takes the whole display, and Escape closes. It also closes the moment another app takes the keys (Cmd+Tab) or a
/// display comes, goes or changes, so it can never hold them or cover the wrong screen. Nothing is posted to another app: arrows move the pointer over the overlay itself.
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
        /// Capture markup's area with its marks drawn on, at its scale (P72).
        case marked(CGImage, CGFloat)
    }

    private var panels: [KeyPanel] = []
    private var views: [CaptureOverlayView] = []
    private let grabs: [DisplayGrab]
    private let windows: [CaptureSelection.Window]
    private let mode: CaptureSelection.Mode
    /// Smart selection on from the start: Capture a UI element (P72).
    private let smart: Bool
    /// False in tests: the panels are made, never ordered onto Sven's screen.
    private let visible: Bool
    /// What the pick is for: a capture, a recording (story 192), a scrolling capture (CP11), text, a subject cut out,
    /// marks drawn before saving, or a colour (P72). Only a capture's and a colour's Tab copies a colour; a scrolling
    /// capture, text and a subject take a clicked window's frame as their area, and markup draws in it.
    enum Purpose: Equatable { case capture, record, scroll, ocr, subject, markup, colour }

    private let purpose: Purpose
    private var done: ((Result) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(grabs: [DisplayGrab], windows: [CaptureSelection.Window], mode: CaptureSelection.Mode, purpose: Purpose = .capture, smart: Bool = false,
         visible: Bool = true, done: @escaping (Result) -> Void) {
        self.grabs = grabs
        self.windows = windows
        self.mode = mode
        self.smart = smart
        self.visible = visible
        self.purpose = purpose
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
                                             mode: mode, pointer: local, smart: smart)
            let view = CaptureOverlayView(grab: grab, selection: selection, accent: Self.accent(), purpose: purpose) { [weak self] outcome, view in
                self?.handle(outcome, from: view)
            }
            view.entered = { [weak self] in self?.focus($0) }
            let panel = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.acceptsMouseMovedEvents = true
            // Escape while marking up is the markup's: its first press only warns while there are marks.
            panel.escape = { [weak self, weak view] in if view?.escapeMarkup() != true { self?.close() } }
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
        NSCursor.crosshair.set()
        // Capture a UI element rings the one under the pointer before it moves.
        if smart { (first.contentView as? CaptureOverlayView)?.lookUpElement() }
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

    /// The panel under the pointer takes the keys, so Space and Tab act on the display Sven is looking at.
    func focus(_ view: CaptureOverlayView) {
        // Marking up keeps the keys on its display, for its text and its tools.
        guard let panel = view.window, !panel.isKeyWindow, !marking else { return }
        panel.makeKey()
        panel.makeFirstResponder(view)
    }

    /// A markup is under way on one of the displays.
    private var marking: Bool { views.contains { $0.markup != nil } }

    private func closeUnlessKey() {
        guard !panels.isEmpty, !panels.contains(where: \.isKeyWindow) else { return }
        close()
    }

    /// Closes every panel and reports `result`, once: a second close does nothing.
    func close(_ result: Result = .cancelled) {
        // Blurred patches a markup drew stay cached until the editor's next open otherwise.
        if marking { MarkupRenderer.forgetBlurs() }
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
        // One markup at a time: another display's pick does nothing while one is under way.
        if marking { return }
        switch outcome {
        case .none: break
        case .close: close()
        // Pick a colour takes nothing but a colour: Return or a click on a window does nothing.
        case .area where purpose == .colour, .window where purpose == .colour: break
        case .area(let rect) where purpose == .markup: mark(rect, on: view)
        case .area(let rect): close(.area(view.grab, rect))
        case .window(let id):
            let window = view.selection.windows.first { $0.id == id }
            if purpose == .markup, let window { return mark(window.frame, on: view) }
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

    /// Capture markup: the area stays frozen and takes marks; Save hands the marked area on, Cancel closes.
    private func mark(_ rect: CGRect, on view: CaptureOverlayView) {
        let accent = Look.shared.chromeTokens(.hud).colors.accent.rgb
        guard let markup = CaptureMarkup(grab: view.grab, area: rect.intersection(view.bounds), accent: accent) else {
            return close()
        }
        var saving = false
        markup.model.finish = { [weak self, weak markup] outcome in
            // Once Save has started, an Escape before the export lands no longer throws the marks away.
            guard let self, let markup, !saving else { return }
            if outcome == .cancel { return close() }
            saving = true
            Task { @MainActor in
                guard let image = await markup.model.export() else { return self.close() }
                self.close(.marked(image, markup.model.scale))
            }
        }
        view.markup = markup
    }

    /// The picked style's one signal colour, as Hyper and the selected tool use it.
    static func accent() -> NSColor { NSColor(Color(Look.shared.chromeTokens(.hud).colors.accent)) }
}

/// One display's overlay: the frozen still, dimmed outside the selection, the selection or the hovered window ringed in
/// the accent, a crosshair and the loupe. Flipped, so its points are CaptureSelection's.
final class CaptureOverlayView: NSView {
    let grab: DisplayGrab
    private(set) var selection: CaptureSelection
    private let accent: NSColor
    private let purpose: CaptureOverlay.Purpose
    private let still: NSImage
    private let report: (CaptureSelection.Outcome, CaptureOverlayView) -> Void

    init(grab: DisplayGrab, selection: CaptureSelection, accent: NSColor, purpose: CaptureOverlay.Purpose = .capture,
         report: @escaping (CaptureSelection.Outcome, CaptureOverlayView) -> Void) {
        self.grab = grab
        self.selection = selection
        self.accent = accent
        self.purpose = purpose
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    /// The pointer came onto this display; the overlay gives its panel the keys.
    var entered: ((CaptureOverlayView) -> Void)?

    override func mouseEntered(with event: NSEvent) { entered?(self) }

    /// Capture markup under way on this display (P72): the pointer and the keys draw marks in its area.
    var markup: CaptureMarkup? {
        didSet { needsDisplay = true }
    }

    /// Escape for the markup, true when one is under way: it ends typing, warns once over marks, then cancels.
    func escapeMarkup() -> Bool {
        guard let markup else { return false }
        _ = markup.model.key(.escape)
        needsDisplay = true
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        guard markup == nil else { return }
        update { $0.move(to: point(event)) }
        lookUpElement()
    }
    /// Hands an event to the markup under way and redraws only its area and bar; false with none.
    private func marking(_ body: (CaptureMarkup) -> Void) -> Bool {
        guard let markup else { return false }
        body(markup)
        setNeedsDisplay(markup.dirty)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let p = point(event), shift = event.modifierFlags.contains(.shift)
        guard !marking({ $0.mouseDown(p, shift: shift) }), purpose != .colour else { return }
        update { $0.press(at: p) }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        guard !marking({ $0.mouseDragged(p) }) else { return }
        update { $0.move(to: p) }
    }
    override func mouseUp(with event: NSEvent) {
        let p = point(event)
        guard !marking({ $0.mouseUp(p) }) else { return }
        // Pick a colour: a click copies the pixel's hex, Shift-click its rgb().
        if purpose == .colour {
            update { $0.move(to: p) }
            return report(event.modifierFlags.contains(.shift) ? .rgb(selection.pointer) : .colour(selection.pointer), self)
        }
        finish { $0.release(at: p) }
    }

    override func keyDown(with event: NSEvent) {
        if let markup {
            if markup.key(event) { setNeedsDisplay(markup.dirty) }
            return
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
        if key == .smart { elements = [] }
        finish { $0.key(key, shift: event.modifierFlags.contains(.shift)) }
        if key == .smart { lookUpElement() }
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
        guard markup == nil else { return }
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
        if let markup {
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: markup.area))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.3).setFill()
            dim.fill()
            markup.draw(in: bounds, accent: accent)
            return hint(markup.model.hint ?? "Mark up: 2 to 0 pick a tool   ⌘Z undo   Return save   Esc cancel")
        }
        let hole: CGRect? = switch selection.mode {
        case .area: selection.area ?? selection.element
        case .window: selection.hovered?.frame
        }
        let ringed = selection.mode == .window || selection.area == nil
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
            if selection.mode == .area, let area = selection.area { label("\(Int(area.width * grab.scale)) × \(Int(area.height * grab.scale))", below: area) }
        }
        if !selection.isDragging { crosshair() }
        loupe()
        hint(hintText)
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
        switch (purpose, selection.mode) {
        case (.colour, _): "Pick a colour: click copies its hex, Shift-click its rgb   Tab  hex   Shift-Tab  rgb   Scroll  zoom   Esc"
        case (_, .area) where selection.smart: "Smart: drag loosely, it snaps to the content   Click a UI element   Scroll  bigger or smaller   A  off   Esc"
        case (.capture, .area): "Drag an area   A  smart   Click or Space  window   Tab  hex   Shift-Tab  rgb   Scroll  zoom   Return  whole screen   Esc"
        case (.capture, .window): "Click a window   Space  area   Tab  hex   Shift-Tab  rgb   Esc"
        case (.record, .area): "Record: drag an area   Click a window for its app   Return  this screen   Esc"
        case (.record, .window): "Record: click a window for its app   Space  area   Esc"
        case (.scroll, .area): "Scrolling capture: drag the part that scrolls   Click a window for all of it   Esc"
        case (.scroll, .window): "Scrolling capture: click the window that scrolls   Space  area   Esc"
        case (.ocr, .area): "Read text: drag over the words or a QR code   A  smart   Click a window for all of it   Esc"
        case (.ocr, .window): "Read text: click a window   Space  area   Esc"
        case (.subject, .area): "Capture subject: drag round it   A  smart   Click a window for all of it   Esc"
        case (.subject, .window): "Capture subject: click a window   Space  area   Esc"
        case (.markup, .area): "Mark up: drag the area to draw on   A  smart   Click a window   Return  whole screen   Esc"
        case (.markup, .window): "Mark up: click a window to draw on   Space  area   Esc"
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
