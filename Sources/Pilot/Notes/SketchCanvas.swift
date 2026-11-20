import AppKit
import PilotCore
import SwiftUI

/// The sketch canvas (pilot-ui-redesign T29; round 2 shots 6c-draw and 6c-done): Insert › Sketch or ⌘⇧D opens it in
/// place, at the note's width, on the caret's line; pen, marker, eraser, ink colours, undo and Done sit under it. Each
/// stroke is a path, drawn every frame from its points through the same `Sketch.draw` the note's picture uses, never an
/// image buffer per stroke (the likeliest budget risk). Done saves the sketch as an SVG in attachments/ and links it on a
/// line of its own (Sketch.save); a sketch reopened from Edit sketch is written over its own file.
enum SketchTool: String, CaseIterable, Identifiable {
    case pen, marker, eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .marker: "Marker"
        case .eraser: "Eraser"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil"
        case .marker: "highlighter"
        case .eraser: "eraser"
        }
    }
}

/// The one sketch being drawn, in whichever note editor opened it: one at a time across Pilot.
@MainActor @Observable
final class SketchBoard {
    static let shared = SketchBoard()

    /// The editor drawn in, while open.
    @ObservationIgnored private(set) weak var view: NotesTextView?
    private(set) var isOpen = false
    /// The strokes so far, in the canvas's points (the sketch's own).
    var sketch = Sketch(width: 1, height: 1)
    /// The stroke under the pointer, not yet one of the sketch's.
    private(set) var current: Sketch.Stroke?
    var tool: SketchTool = .pen
    /// `#rrggbb`, or nil for the note's text colour (currentColor), so the sketch follows the theme.
    var ink: String?
    /// The strokes before each change, newest last: what Undo puts back.
    private(set) var history: [[Sketch.Stroke]] = []
    /// The link of the sketch reopened; nil for a new one.
    @ObservationIgnored private(set) var link: String?
    /// Where a new sketch goes: the caret when the canvas opened.
    @ObservationIgnored private(set) var at = 0
    /// An eraser drag already remembered for Undo, so one drag undoes as one.
    @ObservationIgnored private var erasing = false
    /// The editor's window closing while open: Done then, while the note's views are still there (the app window lets its
    /// tree go a pass after the close, AppWindowController.release), so the sketch is never lost with them.
    @ObservationIgnored private var closing: NSObjectProtocol?

    /// A new sketch's height; its width is the note's.
    static let height: Double = 220
    /// The fixed inks after the note's own: amber, blue and red, mid tones that read on a light and a dark note alike.
    static let inks = ["#f2b705", "#3b82f6", "#ef4444"]

    /// Opens the canvas on `view`: a new sketch at the caret, or the sketch `link` names to edit. Typing goes nowhere
    /// while it is open, so the words under the canvas are never changed unseen.
    func open(on view: NotesTextView, link: String? = nil) {
        if isOpen { done() }
        guard view.isEditable, let folder = view.folder else { return NSSound.beep() }
        if let link {
            guard let url = NoteAttachments.url(link, in: folder), let saved = Sketch.read(at: url) else { return NSSound.beep() }
            sketch = saved
        } else {
            sketch = Sketch(width: max((view.textContainer?.size.width ?? NotesMeasure.panel).rounded(.down), 120), height: Self.height)
        }
        self.view = view
        self.link = link
        at = view.selectedRange().location
        history = []
        current = nil
        isOpen = true
        closing = view.window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.done() }
            }
        }
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        // The canvas and its tools in sight: the note scrolls to them when they would run past its foot.
        if let corner = view.sketchCorner(at: at, link: link) {
            view.scrollToVisible(NSRect(x: corner.x, y: corner.y - 8, width: 1, height: sketch.height + SketchCanvas.gap + 56))
        }
    }

    /// The pointer at `point` with the button down: a pen or marker stroke grows, the eraser takes out what it touches.
    func draw(to point: CGPoint) {
        let p = Sketch.Point(min(max(point.x, 0), sketch.width), min(max(point.y, 0), sketch.height))
        switch tool {
        case .eraser:
            let hit = IndexSet(sketch.strokes.indices.filter { Self.touches(sketch.strokes[$0], p) })
            guard !hit.isEmpty else { return }
            if !erasing { history.append(sketch.strokes); erasing = true }
            sketch.strokes.remove(atOffsets: hit)
        case .pen, .marker:
            guard var stroke = current else {
                current = Sketch.Stroke(tool: tool == .marker ? .marker : .pen, ink: ink,
                                        width: tool == .marker ? Sketch.markerWidth : Sketch.penWidth, points: [p])
                return
            }
            // Points under a point apart add nothing a line can show.
            guard let last = stroke.points.last, hypot(p.x - last.x, p.y - last.y) >= 1 else { return }
            stroke.points.append(p)
            current = stroke
        }
    }

    /// The button up: the stroke drawn becomes the sketch's.
    func lift() {
        erasing = false
        guard let stroke = current else { return }
        history.append(sketch.strokes)
        sketch.strokes.append(stroke)
        current = nil
    }

    func undo() {
        guard let last = history.popLast() else { return }
        current = nil
        sketch.strokes = last
    }

    /// Done, and the way out when the note goes elsewhere (another note, the Trash question, the window closing): a new
    /// sketch with strokes saved in attachments/ and linked at the caret on a line of its own, as an edit Undo takes back;
    /// a sketch reopened written over its file, or its line taken out once every stroke is gone. Nothing drawn changes
    /// nothing.
    func done() {
        guard isOpen else { return }
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
        lift()
        isOpen = false
        let (view, link, sketch) = (self.view, self.link, self.sketch)
        self.view = nil
        self.link = nil
        history = []
        guard let view, let folder = view.folder else { return }
        do {
            if let link {
                guard let url = NoteAttachments.url(link, in: folder) else { return }
                if sketch.strokes.isEmpty {
                    Self.removeLine(of: link, in: view)
                } else {
                    try sketch.write(to: url)
                    view.forgetSketch(link)
                }
            } else if !sketch.strokes.isEmpty {
                let markdown = try sketch.save(in: folder, now: .now)
                Self.insert(markdown, at: at, in: view)
                noteslog.notice("notes: a sketch of \(sketch.strokes.count) strokes saved in attachments")
            }
        } catch {
            noteslog.error("notes: sketch not saved: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    /// The link on a line of its own at `at`, as insertPictures puts a picture's.
    private static func insert(_ markdown: String, at location: Int, in view: NotesTextView) {
        let s = view.string as NSString
        let at = min(location, s.length)
        let before = at > 0 && s.character(at: at - 1) != 10 ? "\n" : ""
        view.insertText(before + markdown + "\n", replacementRange: NSRange(location: at, length: 0))
    }

    /// Takes out the line that shows `link`, as an edit Undo takes back; the file stays, as a picture's does.
    private static func removeLine(of link: String, in view: NotesTextView) {
        let s = view.string as NSString
        let found = s.range(of: "](\(link))")
        guard found.location != NSNotFound else { return }
        let line = s.lineRange(for: found)
        guard view.shouldChangeText(in: line, replacementString: "") else { return }
        view.textStorage?.replaceCharacters(in: line, with: "")
        view.didChangeText()
    }

    /// Whether the eraser at `p` touches `stroke`: within its half width and a fingertip's room of any of its lines.
    static func touches(_ stroke: Sketch.Stroke, _ p: Sketch.Point) -> Bool {
        let reach = stroke.width / 2 + 6
        let points = stroke.drawn
        return zip(points, points.dropFirst()).contains { a, b in
            let (dx, dy) = (b.x - a.x, b.y - a.y)
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length, 0), 1)
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)) <= reach
        }
    }
}

extension Sketch {
    /// The sketches a note shows: its picture links to an SVG.
    static func count(in text: String) -> Int {
        guard text.contains(".svg") else { return 0 }
        let s = text as NSString
        return links.matches(in: text, range: NSRange(location: 0, length: s.length)).count { isSVG(s.substring(with: $0.range(at: 2))) }
    }

    private static let links = try! NSRegularExpression(pattern: NoteAttachments.link)
}

extension NotesTextView {
    /// Each sketch the note draws and its picture's frame, in the scroll view's points from its top left (as the format
    /// bar's selection is), so the canvas and Edit sketch sit on it.
    func sketchFrames() -> [(link: String, frame: CGRect)] {
        sketchRects().compactMap { sketch in inScroll(sketch.rect).map { (sketch.link, $0) } }
    }

    /// Each sketch the note draws and its picture's rect, in the view's points.
    private func sketchRects() -> [(link: String, rect: NSRect)] {
        guard let storage = textStorage else { return [] }
        var links: [String] = []
        storage.enumerateAttribute(.notesImage, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let link = value as? String { links.append(link) }
        }
        let rects = pictureRects()
        // Paired by order; a picture that stopped reading since the last restyle leaves them unpaired, and none is offered.
        guard links.count == rects.count else { return [] }
        return zip(links, rects).compactMap { link, picture in Sketch.isSVG(link) ? (link, picture.rect) : nil }
    }

    /// Where the canvas's top left goes, in the scroll view's points from its top left.
    func sketchOrigin(at location: Int, link: String?) -> CGPoint? {
        sketchCorner(at: location, link: link).flatMap { inScroll(NSRect(origin: $0, size: NSSize(width: 1, height: 1)))?.origin }
    }

    /// Where the canvas's top left goes, in the view's points: on the sketch reopened; for a new one at the text's left
    /// edge, where its picture will be once saved: on the caret's line when that line is empty, under it otherwise.
    func sketchCorner(at location: Int, link: String?) -> NSPoint? {
        if let link { return sketchRects().first { $0.link == link }?.rect.origin }
        guard let layout = layoutManager else { return nil }
        let s = string as NSString
        let at = min(location, s.length)
        let line: NSRect
        if at == s.length, s.length == 0 || s.character(at: s.length - 1) == 10, !layout.extraLineFragmentRect.isEmpty {
            line = layout.extraLineFragmentRect
        } else {
            line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: min(at, s.length - 1)), effectiveRange: nil)
        }
        let paragraph = s.paragraphRange(for: NSRange(location: at, length: 0))
        let empty = s.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let top = (empty ? line.minY : line.maxY) + Self.pictureGap
        return NSPoint(x: textContainerOrigin.x, y: top + textContainerOrigin.y)
    }

    /// `rect` in the view's points as the scroll view's, from its top left.
    private func inScroll(_ rect: NSRect) -> CGRect? {
        guard let scroll = enclosingScrollView else { return nil }
        let r = convert(rect, to: scroll)
        return scroll.isFlipped ? r : CGRect(x: r.minX, y: scroll.bounds.height - r.maxY, width: r.width, height: r.height)
    }
}

/// The canvas and its tools, at the sketch's size: the drawing surface on the raised fill in the accent's ring (the live
/// thing), the tools in a pill under it.
struct SketchCanvas: View {
    @Environment(\.style) private var style
    @Bindable var board: SketchBoard
    /// The note's text colour: the ink of a stroke with none of its own.
    let ink: NSColor

    static let gap: CGFloat = 12

    var body: some View {
        VStack(spacing: Self.gap) {
            surface
            tools
        }
    }

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Canvas { context, _ in
            var shown = board.sketch
            if let current = board.current { shown.strokes.append(current) }
            context.withCGContext { cg in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                shown.draw(ink: ink)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        .frame(width: board.sketch.width, height: board.sketch.height)
        .background(style.color(\.raised), in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(style.color(\.accent)) }
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 0).onChanged { board.draw(to: $0.location) }.onEnded { _ in board.lift() })
        .pointerStyle(.rectSelection)
        .accessibilityElement()
        .accessibilityLabel("Sketch")
        .accessibilityValue(board.sketch.strokes.count == 1 ? "1 stroke" : "\(board.sketch.strokes.count) strokes")
    }

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(SketchTool.allCases) { tool in
                icon(tool.symbol, label: tool.title, on: board.tool == tool) { board.tool = tool }
            }
            rule
            swatch(nil)
            ForEach(SketchBoard.inks, id: \.self) { swatch($0) }
            rule
            // Dimmed, never disabled: ⌘Z stays the canvas's while it is open, never reaching the words under it.
            icon("arrow.uturn.backward", label: "Undo", on: false) { board.undo() }
                .opacity(board.history.isEmpty ? 0.4 : 1)
                .keyboardShortcut("z", modifiers: .command)
            rule
            Button { board.done() } label: {
                Text("Done").styleText(\.body).fontWeight(.semibold).foregroundStyle(style.color(\.accent))
                    .padding(.horizontal, 10).frame(height: 30).contentShape(.rect)
            }
            .buttonStyle(.plain).focusable(false)
            .help("Keep the sketch in the note")
        }
        .padding(4)
        .background(style.color(\.panel), in: .rect(cornerRadius: 11, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(style.color(\.line2)) }
        .accessibilityElement(children: .contain).accessibilityLabel("Sketch tools")
    }

    private var rule: some View {
        Rectangle().fill(style.color(\.line2)).frame(width: 1, height: 18).padding(.horizontal, 5).accessibilityHidden(true)
    }

    private func icon(_ symbol: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(style.color(on ? \.accent : \.text2))
                .frame(width: 32, height: 30)
                .instrumentRaised(on, radius: 7)
                .contentShape(.rect)
        }
        .buttonStyle(.plain).focusable(false)
        .help(label).accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// An ink to pick: nil is the note's own, drawn half the text colour and half the panel's, as it follows the theme.
    private func swatch(_ hex: String?) -> some View {
        let on = board.ink == hex
        return Button { board.ink = hex } label: {
            ZStack {
                if let hex {
                    Circle().fill(Color(hex: Contrast.hex(hex)))
                } else {
                    Circle().fill(LinearGradient(stops: [.init(color: Color(ink), location: 0.5), .init(color: style.color(\.panel), location: 0.5)],
                                                 startPoint: .bottomLeading, endPoint: .topTrailing))
                        .overlay { Circle().strokeBorder(style.color(\.line2)) }
                }
            }
            .frame(width: 18, height: 18)
            .padding(4)
            .overlay { if on { Circle().strokeBorder(style.color(\.accent), lineWidth: 2) } }
            .frame(width: 32, height: 30)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).focusable(false)
        .accessibilityLabel(Self.name(hex))
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(Self.name(hex))
    }

    static func name(_ hex: String?) -> String {
        switch hex {
        case nil: "Note’s ink"
        case SketchBoard.inks[0]: "Amber"
        case SketchBoard.inks[1]: "Blue"
        default: "Red"
        }
    }
}
