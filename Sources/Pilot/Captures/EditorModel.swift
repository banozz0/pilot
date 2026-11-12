import AppKit
import Clipboard
import ImageScale
import Observation
import PilotCore

/// The capture editor's state (spec `capture.html` CP6, CP7; B, Sven Q805): the capture, its marks, the
/// picked tool and each tool's options, the mark being drawn, the text being typed, and what the keys do. The view
/// draws it; this decides. Points are the document's, from its top left: the capture's, or once its screen is read (P77)
/// the screen's, the capture `taken` inside it.
@Observable @MainActor
final class EditorModel {
    /// A key as the editor sees it.
    enum Key: Equatable {
        case char(String, command: Bool = false, shift: Bool = false)
        case escape, enter, delete
    }

    /// What the editor asks for: copy or save a copy of the flattened image and stay, Done, or Cancel.
    enum Outcome { case copy, saveCopy, done, cancel, pin }

    /// The capture as taken.
    let image: CGImage
    /// Pixels per point.
    let scale: CGFloat
    private(set) var document: MarkupDocument
    /// The screen the capture was cut from (P77): the document is made on it, so a crop pulled past the capture's edge
    /// uncrops, up to that display. Nil for a capture with none (a window, a file, markup, a whole display).
    let screen: CaptureGrab?
    /// What the canvas, the ruler, the colour picker and the export draw from: the screen, else the capture.
    var source: CGImage { screen?.image ?? image }
    /// Where the capture as taken sits, in the document's points.
    var taken: CGRect { document.taken }
    private(set) var tool: MarkTool = .arrow
    /// The slider's 1 to 10, the swatch picked and the footer's style toggle, per tool, so each tool keeps its own.
    private(set) var sizes: [MarkTool: Int] = [.highlighter: 5, .blur: 5, .spotlight: 5]
    private(set) var colours: [MarkTool: Int] = [:]
    private(set) var styles: [MarkTool: Int] = [:]
    /// The mark being dragged out, drawn before it is added.
    private(set) var draft: Mark?
    /// The text tool's face: new text takes it, and the footer's Font, Size, Bold and Italic set it.
    private(set) var textFace = TextFace(points: 18)
    /// The crop while Crop is the tool (the designer's mock, Sven Q413): dragged out or pulled by its handles, kept by
    /// Done or Return, or by picking another tool, dropped by Cancel or Escape. Nil while there is no area yet.
    private(set) var cropEdit: CGRect?
    /// The crop before a fresh drag began, back when the drag was only a click.
    @ObservationIgnored private var cropBefore: CGRect?
    /// The room's stage while Crop is the tool, as it was when Crop was picked, so a drag never moves the view under it.
    private(set) var cropStage: CGRect?
    /// Where the mark being drawn lives: a press off the part kept, with a backdrop on, draws on the backdrop (P77).
    @ObservationIgnored private var drawingOn: Mark.Layer = .capture
    /// A handle being dragged: the picked mark as it was (nil for the crop), the crop as it was, the grip, where it began.
    private struct Grab { let mark: Mark?; let crop: CGRect; let grip: Grip; let from: CGPoint }
    @ObservationIgnored private var grab: Grab?
    /// The picked mark as a handle drag has it, drawn before it is kept as one undo step.
    private(set) var draftResize: Mark?
    /// The handle under the pointer, for its resize arrow.
    private(set) var hoverGrip: Grip?
    /// The marks the select tool holds, picked in order: one by a click, any number by a drag round them (marquee).
    private(set) var picked: [Int] = []
    /// The one mark picked last, nil with none: the footer shows the backdrop while nothing is picked.
    var selected: Int? { picked.last }
    /// The select tool's drag over empty canvas, in capture points: every mark it touches is picked (Mark.touches), added
    /// to `base`, what was picked before a Shift-drag.
    private(set) var marquee: (box: CGRect, base: [Int])?
    /// The text mark being typed into.
    var typing: Int?
    var typed = ""
    /// Escape once with marks on arms the discard; a second press cancels.
    private(set) var discardArmed = false
    /// A short line over the canvas: "Saved a copy", "Copied", the discard warning.
    private(set) var hint: String?
    /// Read text (CP8): reading, then the lines and codes found, boxed on the capture in `readArea` (the crop then).
    enum Reading: Equatable { case reading, read([ReadLine]) }
    private(set) var reading: Reading?
    private(set) var readArea: CGRect = .zero
    /// The window's reader: reads the export and comes back through `showRead`.
    @ObservationIgnored var readText: () -> Void = {}
    /// Blur's Text only (story 195): a drag blurs just the text read inside it.
    private(set) var textOnly = false
    /// Auto-redact or a Text only blur is waiting for the capture's text.
    private(set) var finding = false
    /// Reads the capture as taken, never the marked-up export, and copies nothing; nil when the read failed. The window
    /// sets it.
    @ObservationIgnored var readCapture: () async -> [ReadLine]? = { [] }
    @ObservationIgnored private var captureLines: Task<[ReadLine]?, Never>?
    /// Reads the part of the screen the capture was cut from (P77) given in document points, as taken, its boxes fractions
    /// of that part; nil when the read failed. The window sets it when there is one.
    @ObservationIgnored var readScreen: (CGRect) async -> [ReadLine]? = { _ in [] }
    @ObservationIgnored private var screenLines: (part: CGRect, read: Task<[ReadLine]?, Never>)?
    /// The six swatches as 0xRRGGBB: the theme's accent, red, amber, green, blue, ink.
    let swatches: [UInt32]
    /// The colour the colour picker took off the capture, the seventh swatch once there is one.
    private(set) var pickedColour: UInt32?
    var palette: [UInt32] { swatches + (pickedColour.map { [$0] } ?? []) }
    /// The theme's accent and ground, for the backdrop panel's first gradient and colour.
    let accent: UInt32
    let ground: UInt32
    /// The ruler's two lines at the pointer, drawn until the pointer moves on or a click stamps them.
    private(set) var hovering: [Mark] = []
    /// The capture's pixels for the ruler, read once the ruler is first picked, off the main thread.
    @ObservationIgnored private var grid: PixelGrid?
    @ObservationIgnored private var gridLoading = false
    /// The colour under the colour picker, for the footer's readout; nil off the capture.
    private(set) var sampled: UInt32?
    /// Where the colour picker's loupe sits, in capture points: the pointer while it is over the capture with the picker
    /// on, nil otherwise (the pointer shows again).
    private(set) var loupeAt: CGPoint?
    /// Whether the loupe shows, for the canvas, which hides the pointer meanwhile: it changes only as the pointer comes
    /// onto the capture and leaves, so a move redraws the loupe alone.
    private(set) var loupeShown = false
    /// The tool the colour picker came from, picked again after a click.
    @ObservationIgnored private var beforePicker: MarkTool?
    /// Where a picked colour's hex and the strip's Copy text go: the window's pasteboard.
    @ObservationIgnored var copyColour: (String) -> Void = { _ in }
    /// The Image size chip's resize (Q246), applied after the export is flattened, so marks and crop stay in the capture's
    /// points; a later crop keeps its factor. Nil keeps the pixels. The canvas keeps showing the capture as taken.
    private(set) var resized: ResizeTarget?
    /// The toolbar's Upscale (Q248): its settings and run, and the window's start, which exports and hands it on.
    let upscale = UpscaleJob()
    @ObservationIgnored var startUpscale: () -> Void = {}
    /// The window's answer to an outcome; it flattens through `export()`, off the main thread.
    @ObservationIgnored var finish: (Outcome) -> Void = { _ in }
    @ObservationIgnored private var dragStart: CGPoint?
    /// Where a drag on a picked mark began: the picked marks move with it.
    @ObservationIgnored private var movingFrom: CGPoint?
    @ObservationIgnored private var hintClear: Task<Void, Never>?

    static let red: UInt32 = 0xF0443A, amber: UInt32 = 0xF5A524, green: UInt32 = 0x2FB566, blue: UInt32 = 0x3A7BF2
    /// The select tool's handles: one fixed blue, so the theme's colour means only the picked tool (designer's note).
    static let selection: UInt32 = 0x2B7BF2
    /// Snap and guide lines (C3, C7): one fixed pink, apart from the selection's blue and the theme's colour.
    static let guide: UInt32 = 0xFF2D95

    /// `screen` is ignored when it is not this capture's (a file written over since).
    init(image: CGImage, scale: CGFloat, accent: UInt32, dark: Bool, ground: UInt32 = 0x1A1B1F, screen: CaptureGrab? = nil) {
        self.image = image
        self.scale = scale
        let screen = screen.flatMap { $0.fits(width: image.width, height: image.height, scale: scale) ? $0 : nil }
        self.screen = screen
        document = screen.map { MarkupDocument(size: $0.size, taken: $0.takenPoints) }
            ?? MarkupDocument(size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        swatches = [accent, Self.red, Self.amber, Self.green, Self.blue, dark ? 0xFFFFFF : 0x15161A]
        self.accent = accent
        self.ground = ground
    }

    var size: CGSize { document.size }
    func size(of tool: MarkTool) -> Int { sizes[tool] ?? 4 }
    /// Red until another is picked: marks read on any capture.
    func colourIndex(of tool: MarkTool) -> Int { colours[tool] ?? 1 }
    func style(of tool: MarkTool) -> Int { styles[tool] ?? 0 }
    var colour: UInt32 { palette[colourIndex(of: tool)] }
    var second: Bool { style(of: tool) == 1 }

    // MARK: Options

    func pick(_ tool: MarkTool) {
        commitText()
        reading = nil
        hovering = []
        if tool == .ruler || tool == .eyedropper { loadGrid() }
        if tool == .eyedropper, self.tool != .eyedropper { beforePicker = self.tool }
        sampled = nil
        loupeAt = nil
        loupeShown = false
        if self.tool == .crop, tool != .crop { commitCrop() }
        if tool == .crop, self.tool != .crop {
            cropEdit = cropShown
            cropStage = document.taken.union(document.area)
            loadEdges()
        }
        guides = []
        hoverGrip = nil
        self.tool = tool
        if tool != .select { picked = [] }
        discardArmed = false
        restage()
    }

    /// The slider moved: the tool's size, and the selected mark's when one is picked.
    func setSize(_ value: Int) {
        let v = min(10, max(1, value))
        sizes[tool] = v
        if tool == .select { document.update(picked) { $0.size = v } }
    }

    func setColour(_ index: Int) {
        colours[tool] = index
        if tool == .select { document.update(picked) { $0.colour = palette[index] } }
        if let typing { document.update(typing) { $0.colour = palette[index] } }
    }

    // MARK: Text face

    /// The one picked mark, as a handle drag has it.
    var selectedMark: Mark? {
        guard picked.count == 1, let mark = marks.first(where: { $0.id == picked[0] }) else { return nil }
        return draftResize?.id == mark.id ? draftResize : mark
    }

    /// The face the footer shows: the picked text's with Select, else the text tool's.
    var shownFace: TextFace {
        guard tool == .select, let mark = selectedMark, mark.isText else { return textFace }
        var face = mark.face
        face.points = mark.fontSize
        return face
    }

    /// The footer's Plain or Pill: the picked text's with Select, else the text tool's style.
    var shownPill: Bool {
        if tool == .select, let mark = selectedMark, case .text(_, _, let pill) = mark.kind { return pill }
        return style(of: .text) == 1
    }

    /// Font, Size, Bold or Italic changed: the text tool's face, the text being typed, and with Select the picked texts.
    func setFace(_ change: (inout TextFace) -> Void) {
        change(&textFace)
        document.update(textTargets) { mark in
            var face = mark.face
            face.points = mark.fontSize
            change(&face)
            mark.face = face
        }
    }

    func setPill(_ pill: Bool) {
        if tool != .select { styles[.text] = pill ? 1 : 0 }
        document.update(textTargets) { mark in
            if case .text(let s, let at, _) = mark.kind { mark.kind = .text(s, at: at, pill: pill) }
        }
    }

    /// The text marks a footer change reaches: the one being typed, and with Select the picked ones.
    private var textTargets: [Int] {
        let ids = (typing.map { [$0] } ?? []) + (tool == .select ? picked : [])
        return document.marks.filter { ids.contains($0.id) && $0.isText }.map(\.id)
    }

    func setStyle(_ index: Int) { styles[tool] = index }

    // MARK: Drawing

    /// The pointer went down at `p`, Shift held or not.
    func begin(_ p: CGPoint, shift: Bool = false) {
        commitText()
        discardArmed = false
        drawingOn = startsOnBackdrop(p) ? .backdrop : .capture
        dragLines = nil
        if tool == .crop { loadTextEdges() }
        let p = guided(p)
        dragStart = p
        switch tool {
        case .select:
            if let mark = selectedMark, let g = grip(at: p) {
                grab = Grab(mark: mark, crop: .zero, grip: g, from: p)
                return
            }
            if let mark = mark(at: p) {
                // Shift-click takes a mark into the group or out of it; a drag on a picked mark moves the whole group.
                if shift, picked.contains(mark.id) { picked.removeAll { $0 == mark.id }; dragStart = nil; return }
                if shift { picked.append(mark.id) } else if !picked.contains(mark.id) { picked = [mark.id] }
                movingFrom = p
            } else {
                if !shift { picked = [] }
                marquee = (CGRect(origin: p, size: .zero), picked)
            }
        case .step:
            picked = [document.add(.step(0, at: unplaced(p)), colour: colour, size: size(of: .step), layer: drawingOn)]
            dragStart = nil
        case .ruler:
            draft = Mark(id: 0, kind: .measure(from: p, to: p, points: second), colour: colour, size: 1)
        case .eyedropper:
            dragStart = nil
            if let rgb = pixel(at: p) { takeColour(rgb) }
        case .crop:
            // A handle pulls the crop, a drag inside moves it, a drag anywhere else starts a new one.
            if let crop = cropEdit, let g = grip(at: p) ?? (crop.contains(p) ? .box(0, 0) : nil) {
                grab = Grab(mark: nil, crop: crop, grip: g, from: p)
            } else {
                cropBefore = cropEdit
                cropEdit = nil
            }
        case .text:
            let lift = (textFace.points ?? 18) * 0.65
            let id = document.add(.text("", at: unplaced(CGPoint(x: p.x, y: p.y - lift)), pill: second), colour: colour, size: size(of: .text),
                                  face: textFace, layer: drawingOn)
            typing = id
            typed = ""
            dragStart = nil
        default:
            draft = shape(from: p, to: p, path: [p])
        }
    }

    /// The pointer moved to `p` with the button down; on a handle Shift keeps a corner's proportions and Option pulls the
    /// opposite edge too.
    func drag(_ p: CGPoint, shift: Bool = false, option: Bool = false) {
        guard let start = dragStart else { return }
        if let g = grab, g.grip == .bend, let mark = g.mark, mark.control == nil, case .arrow(let a, let b, _) = mark.kind {
            // A straight arrow's middle bends it when pulled sideways (C4) and moves it when pulled along, as before.
            let d = CGPoint(x: p.x - g.from.x, y: p.y - g.from.y)
            guard hypot(d.x, d.y) >= 2 else { return }
            let along = d.x * (b.x - a.x) + d.y * (b.y - a.y), across = d.y * (b.x - a.x) - d.x * (b.y - a.y)
            if abs(along) >= abs(across) { grab = nil; movingFrom = g.from }
        }
        if let grab {
            let d = CGPoint(x: p.x - grab.from.x, y: p.y - grab.from.y)
            if let mark = grab.mark {
                draftResize = guidedResize(mark, grab.grip, by: d, keepRatio: shift, fromCentre: option)
            } else {
                // A crop's edges snap to the picture's edges, its windows and its text (C3); a moved crop keeps its size.
                var edges = (SnapEdge.whole, SnapEdge.whole)
                if case .box(let x, let y) = grab.grip, x != 0 || y != 0 { edges = (SnapEdge(x), SnapEdge(y)) }
                let pulled = grab.grip.resize(grab.crop, by: d, keepRatio: shift, fromCentre: option)
                cropEdit = held(shift || option ? pulled : snap(pulled, edges.0, edges.1, to: lines { cropLines }), moving: grab.grip == .box(0, 0))
            }
            return
        }
        if let movingFrom {
            draftMove = guidedMove(CGPoint(x: p.x - movingFrom.x, y: p.y - movingFrom.y))
            return
        }
        if let base = marquee?.base {
            let box = Self.rect(start, p)
            marquee = (box, base)
            let touched = base + marks.filter { !base.contains($0.id) && $0.touches(box) }.map(\.id)
            if touched != picked { picked = touched }
            return
        }
        if tool == .crop { cropEdit = held(snap(Self.rect(start, p), .both, .both, to: lines { cropLines }), moving: false); return }
        if tool == .ruler {
            hovering = []
            draft = Mark(id: 0, kind: .measure(from: start, to: p, points: second), colour: colour, size: 1)
            return
        }
        var path: [CGPoint] = []
        if case .pen(let points)? = draft?.kind { path = points }
        if case .highlight(let points)? = draft?.kind { path = points }
        draft = shape(from: start, to: guided(p), path: path + [p])
    }

    /// Where a dragged mark is being moved to, drawn before the move is kept.
    private(set) var draftMove: CGPoint?

    /// The pointer came up at `p`: the shape is kept, unless it is too small to mean anything.
    func end(_ p: CGPoint, shift: Bool = false, option: Bool = false) {
        drag(p, shift: shift, option: option)
        defer { dragStart = nil; draft = nil; draftMove = nil; movingFrom = nil; marquee = nil; grab = nil; draftResize = nil; cropBefore = nil; guides = []; dragLines = nil }
        if let grab {
            if let mark = draftResize, mark != grab.mark { document.update(mark.id) { $0 = self.unplaced(mark) } }
            return
        }
        if movingFrom != nil, let d = draftMove, abs(d.x) + abs(d.y) > 0.5 {
            document.update(picked) { $0 = $0.moved(by: d) }
            return
        }
        if tool == .crop {
            // A click is no area: the crop there was stays.
            if let c = cropEdit, c.width < 4 || c.height < 4 { cropEdit = cropBefore }
            if cropEdit == nil { cropEdit = cropBefore }
            return
        }
        if tool == .ruler, case .measure(let a, let b, _)? = draft?.kind, hypot(b.x - a.x, b.y - a.y) < 4 {
            // A click stamps the two lines the ruler shows there.
            for mark in rulerMarks(at: p) { document.add(mark.kind, colour: mark.colour, size: 1) }
            hovering = []
            return
        }
        guard var draft, Self.counts(draft) else { return }
        if textOnly, case .blur(let area, let pixelate) = draft.kind { return blurText(area, pixelate: pixelate, strength: draft.size) }
        // The smooth pen (C6): the line comes out neat as the pointer comes up, unless the pen is Freehand.
        if case .pen(let points) = draft.kind, !second { draft.kind = .pen(Smoothing.stroke(points)) }
        picked = [document.add(unplaced(draft).kind, colour: draft.colour, size: draft.size, layer: draft.layer)]
    }

    /// The mark the tool makes between two points.
    private func shape(from a: CGPoint, to b: CGPoint, path: [CGPoint]) -> Mark? {
        let r = Self.rect(a, b)
        let kind: Mark.Kind? = switch tool {
        case .arrow: .arrow(from: a, to: b, curved: second)
        case .rect: .rect(r, filled: second)
        case .ellipse: .ellipse(r, filled: second)
        case .pen: .pen(path)
        case .highlighter: .highlight(path)
        case .blur: .blur(r, pixelate: second)
        case .box: .box(r, erase: second)
        case .spotlight: second ? Self.lens(over: r) : .spotlight(r)
        case .ruler: .measure(from: a, to: b, points: second)
        default: nil
        }
        return kind.map { Mark(id: 0, kind: $0, colour: colour, size: size(of: tool), layer: drawingOn) }
    }

    /// The magnifier dragged over `r` (C5): a round lens on the detail, as wide as the drag's longer side, zooming its
    /// middle; Select moves the lens off it into a callout.
    static func lens(over r: CGRect) -> Mark.Kind {
        let d = max(r.width, r.height)
        return .magnify(CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d), focus: CGPoint(x: r.midX, y: r.midY))
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// A shape a click left, or a line with no length, is not kept.
    static func counts(_ mark: Mark) -> Bool {
        switch mark.kind {
        case .arrow(let a, let b, _): hypot(b.x - a.x, b.y - a.y) >= 6
        case .pen(let p), .highlight(let p): p.count >= 2
        case .rect(let r, _), .ellipse(let r, _), .blur(let r, _), .box(let r, _), .spotlight(let r): r.width >= 4 && r.height >= 4
        case .measure(let a, let b, _): hypot(b.x - a.x, b.y - a.y) >= 4
        case .magnify(let lens, _): lens.width >= 8
        default: true
        }
    }

    // MARK: Snap edges (C3) and guides (C7), Sven Q805

    /// A line a drag snapped to, drawn while the drag lasts: a vertical one at `x`, a horizontal one at `y`.
    enum Guide: Equatable {
        case x(CGFloat), y(CGFloat)

        /// The guide drawn across `r`.
        func segment(across r: CGRect) -> (CGPoint, CGPoint) {
            switch self {
            case .x(let x): (CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.maxY))
            case .y(let y): (CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y))
            }
        }
    }

    /// Which sides of a box snap on one axis: the low (left or top), the high, each on its own, neither, or the whole box
    /// (its nearest side or middle).
    enum SnapEdge {
        case low, high, both, none, whole

        /// A grip's side on one axis: -1 the low, 1 the high, 0 neither.
        init(_ side: Int) { self = side < 0 ? .low : side > 0 ? .high : .none }
    }

    typealias Lines = (xs: [CGFloat], ys: [CGFloat])

    private(set) var guides: [Guide] = []
    /// Whether drags snap: the editor's window and capture markup turn it on as they open; a model made on its own, as
    /// the exact-geometry tests drive it, draws where the pointer goes.
    var snaps = false
    /// The tools whose drags snap to other marks and the centre.
    static let guided: Set<MarkTool> = [.arrow, .rect, .ellipse, .blur, .box, .spotlight]
    /// The picture's long straight edges (a card's, a panel's, a window's) as fractions of its size, read off the main
    /// thread as Crop is first picked; the text's edges in the document's points, once the capture's text is read.
    @ObservationIgnored private var pictureEdges: Lines?
    @ObservationIgnored private var textEdges: Lines?
    @ObservationIgnored private var edgesLoad: Task<Void, Never>?
    @ObservationIgnored private var textLoad: Task<Void, Never>?
    /// The lines this drag snaps to, worked out at its first move: nothing they come from changes while it lasts.
    @ObservationIgnored private var dragLines: Lines?

    /// How near a dragged edge or point must come to a line to snap: six screen points, in the document's.
    private var snapReach: CGFloat { 6 / max(0.01, zoom * preview.k) }

    private func loadEdges() {
        guard snaps, edgesLoad == nil else { return }
        let still = Unchecked(source)
        edgesLoad = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) { SnapEdges.lines(still.value) }.value
            self?.pictureEdges = found
        }
    }

    /// The capture's text, read once a crop is first dragged (the read Redact and Text only share), for its edges.
    private func loadTextEdges() {
        guard snaps, textLoad == nil else { return }
        textLoad = Task { @MainActor [weak self] in
            guard let self else { return }
            let (read, from) = await lines(over: document.taken)
            textEdges = CaptureText.edges(read ?? [], in: from)
        }
    }

    #if DEBUG
    /// The picture's edges read at once, for a render.
    func loadEdgesNow() { pictureEdges = SnapEdges.lines(source) }
    #endif

    /// The lines a crop's edges snap to: the picture's own edges, the capture as taken, the windows on its screen, and
    /// the cards and text in it.
    private var cropLines: Lines {
        var xs = [0, size.width, taken.minX, taken.maxX], ys = [0, size.height, taken.minY, taken.maxY]
        for w in screen?.windows ?? [] { xs += [w.minX, w.maxX]; ys += [w.minY, w.maxY] }
        if let e = textEdges { xs += e.xs; ys += e.ys }
        // The picture's edges are read on a smaller copy: one near an exact line (a window's side, the capture's) gives
        // way to it, the rest sit on whole pixels.
        func rough(_ v: [CGFloat], _ length: CGFloat, _ exact: [CGFloat]) -> [CGFloat] {
            v.map { ($0 * length * scale).rounded() / scale }.filter { r in !exact.contains { abs($0 - r) <= 3 } }
        }
        if let e = pictureEdges { (xs, ys) = (xs + rough(e.xs, size.width, xs), ys + rough(e.ys, size.height, ys)) }
        return (xs, ys)
    }

    /// The lines a mark snaps to: every other mark's edges and middle, and the part kept's, the backdrop's canvas's too.
    private func guideLines(excluding ids: [Int]) -> Lines {
        var boxes = [document.area]
        if let o = canvasOrigin, let b = framed { boxes.append(CGRect(origin: o, size: b.canvas(for: document.area.size))) }
        boxes += marks.filter { !ids.contains($0.id) }.compactMap(\.guideFrame)
        return (boxes.flatMap { [$0.minX, $0.midX, $0.maxX] }, boxes.flatMap { [$0.minY, $0.midY, $0.maxY] })
    }

    /// This drag's lines, made by `make` at its first use.
    private func lines(_ make: () -> Lines) -> Lines {
        if let dragLines { return dragLines }
        let made = make()
        dragLines = made
        return made
    }

    /// One axis of a box snapped to `lines`; the lines it met come back with it.
    private func axis(_ lo: CGFloat, _ hi: CGFloat, _ edge: SnapEdge, _ lines: [CGFloat]) -> (lo: CGFloat, hi: CGFloat, at: [CGFloat]) {
        let reach = snapReach
        func near(_ v: CGFloat) -> CGFloat? { SnapEdges.nearest(v, in: lines, within: reach) }
        switch edge {
        case .whole:
            let best = [lo, (lo + hi) / 2, hi].compactMap { v in near(v).map { (by: $0 - v, at: $0) } }.min { abs($0.by) < abs($1.by) }
            guard let best else { return (lo, hi, []) }
            return (lo + best.by, hi + best.by, [best.at])
        case .low: return near(lo).map { ($0, hi, [$0]) } ?? (lo, hi, [])
        case .high: return near(hi).map { (lo, $0, [$0]) } ?? (lo, hi, [])
        case .both:
            let l = near(lo), h = near(hi)
            return (l ?? lo, h ?? hi, [l, h].compactMap { $0 })
        case .none: return (lo, hi, [])
        }
    }

    /// `r` snapped to `lines`, the guides set to the lines it met; unchanged while snapping is off.
    private func snap(_ r: CGRect, _ x: SnapEdge, _ y: SnapEdge, to lines: @autoclosure () -> Lines) -> CGRect {
        guard snaps else { return r }
        let l = lines(), h = axis(r.minX, r.maxX, x, l.xs), v = axis(r.minY, r.maxY, y, l.ys)
        let met = h.at.map(Guide.x) + v.at.map(Guide.y)
        if met != guides { guides = met }
        return CGRect(x: h.lo, y: v.lo, width: h.hi - h.lo, height: v.hi - v.lo)
    }

    /// A point snapped to the other marks and the centre (C7), when the tool snaps.
    private func guided(_ p: CGPoint, excluding ids: [Int] = []) -> CGPoint {
        guard Self.guided.contains(tool) || !ids.isEmpty else { return p }
        return snap(CGRect(origin: p, size: .zero), .whole, .whole, to: lines { guideLines(excluding: ids) }).origin
    }

    /// The picked marks' move, snapped so their box's side or middle meets another mark's or the centre (C7). A click
    /// is no move: it never snaps the mark off where it is.
    private func guidedMove(_ d: CGPoint) -> CGPoint {
        let box = marks.filter { picked.contains($0.id) }.compactMap(\.guideFrame).reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull, abs(d.x) + abs(d.y) >= 1 else { return d }
        let to = snap(box.offsetBy(dx: d.x, dy: d.y), .whole, .whole, to: lines { guideLines(excluding: picked) })
        return CGPoint(x: to.minX - box.minX, y: to.minY - box.minY)
    }

    /// The picked mark with `grip` dragged by `d`, the edge or end it moves snapped (C7); a kept ratio, a text's corner, an
    /// arrow's bend and a magnifier don't snap.
    private func guidedResize(_ mark: Mark, _ grip: Grip, by d: CGPoint, keepRatio: Bool, fromCentre: Bool) -> Mark {
        var d = d
        switch (grip, mark.kind) {
        case (.start, .arrow(let a, _, _)), (.start, .measure(let a, _, _)), (.end, .arrow(_, let a, _)), (.end, .measure(_, let a, _)):
            let to = guided(CGPoint(x: a.x + d.x, y: a.y + d.y), excluding: [mark.id])
            d = CGPoint(x: to.x - a.x, y: to.y - a.y)
        case (.box(let x, let y), .rect), (.box(let x, let y), .ellipse), (.box(let x, let y), .blur), (.box(let x, let y), .box),
             (.box(let x, let y), .spotlight):
            guard !keepRatio, let f = mark.resized(grip, by: d, fromCentre: fromCentre).guideFrame else { break }
            let to = snap(f, SnapEdge(x), SnapEdge(y), to: lines { guideLines(excluding: [mark.id]) })
            d.x += to.minX - f.minX + to.maxX - f.maxX
            d.y += to.minY - f.minY + to.maxY - f.maxY
        default: break
        }
        return mark.resized(grip, by: d, keepRatio: keepRatio, fromCentre: fromCentre)
    }

    // MARK: Handles and crop

    /// The handle at `p` (capture points): the one picked mark's with Select, the crop's with Crop; nil elsewhere.
    func grip(at p: CGPoint) -> Grip? {
        let reach = Grip.reach / max(0.01, zoom * preview.k)
        if tool == .crop, let crop = cropEdit { return Grip.nearest(Grip.grips(ofCrop: crop), to: p, reach: reach) }
        guard tool == .select, let mark = selectedMark else { return nil }
        return Grip.nearest(Grip.grips(of: mark), to: p, reach: reach)
    }

    /// A crop held inside the picture (the screen, when the capture kept one: so past the capture's edge it uncrops): a
    /// moved one keeps its size, a pulled one is cut at the edge.
    private func held(_ r: CGRect, moving: Bool) -> CGRect {
        let whole = CGRect(origin: .zero, size: size)
        guard moving else { let kept = r.intersection(whole); return kept.isNull ? .zero : kept }
        return CGRect(x: min(max(0, r.minX), whole.width - r.width), y: min(max(0, r.minY), whole.height - r.height), width: r.width, height: r.height)
    }

    /// The crop being edited is kept (one undo step), the tool stays.
    func commitCrop() {
        guard tool == .crop else { return }
        document.setCrop(cropEdit)
    }

    /// The crop's Done or Return: kept, and back to Select.
    func applyCrop() {
        commitCrop()
        pick(.select)
    }

    /// The crop's Cancel or Escape: the crop as it was, and back to Select.
    func cancelCrop() {
        cropEdit = document.crop
        pick(.select)
    }

    /// Whole capture: everything taken, the screen round the capture too when it kept one (P77, round 2's crop strip);
    /// the view steps back to show it all.
    func clearCrop() {
        let whole = CGRect(origin: .zero, size: size)
        cropEdit = screen == nil ? nil : whole
        document.setCrop(whole)
        if let stage = cropStage { cropStage = stage.union(whole) }
        restage()
    }

    /// As taken (P77): back to the capture's own area, after any crop or uncrop.
    func cropAsTaken() {
        document.setCrop(nil)
        cropEdit = cropShown
        restage()
    }

    /// The crop strip's As taken shows: the capture kept its screen, and the part kept is not the capture as taken.
    var showsAsTaken: Bool { screen != nil && area != document.taken }

    /// Crop's frame as Crop opens or after an undo: the document's crop, else with a screen the capture as taken (so its
    /// handles can be pulled out), else none.
    private var cropShown: CGRect? { document.crop ?? (screen == nil ? nil : document.taken) }

    /// The part the export keeps: the crop being edited while Crop is the tool, else the document's.
    var area: CGRect { tool == .crop ? cropEdit ?? document.taken : document.area }

    /// The backdrop the canvas frames the capture in: none while cropping, so the whole capture shows round the crop.
    var framed: Backdrop? { tool == .crop ? nil : backdrop }

    /// The text being typed goes into its mark; an empty one is dropped.
    func commitText() {
        guard let id = typing else { return }
        typing = nil
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        typed = ""
        if text.isEmpty { document.delete(id) } else {
            document.update(id) { mark in
                if case .text(_, let at, let pill) = mark.kind { mark.kind = .text(text, at: at, pill: pill) }
            }
        }
    }

    // MARK: Keys

    /// A key while the editor has the keyboard; true when it was the editor's. While text is typed, only Escape and
    /// Return are, and they end the typing.
    func key(_ key: Key) -> Bool {
        if typing != nil {
            guard key == .escape || key == .enter else { return false }
            commitText()
            return true
        }
        switch key {
        case .escape where tool == .eyedropper:
            // Esc leaves the colour picker for the tool it came from, never the editor.
            pick(beforePicker ?? .select)
        case .escape where tool == .crop: cancelCrop()
        case .enter where tool == .crop: applyCrop()
        case .escape:
            if document.edited, !discardArmed {
                discardArmed = true
                say("Press Esc again to throw away your marks")
            } else {
                finish(.cancel)
            }
        case .enter: finish(.done)
        case .delete:
            guard !picked.isEmpty else { return false }
            deleteSelected()
        case .char(let c, let command, let shift):
            discardArmed = false
            if command {
                switch c.lowercased() {
                case "z": shift ? redo() : undo()
                case "a": selectAll()
                case "c": finish(.copy); say("Copied")
                case "s": finish(.saveCopy); say("Saved a copy")
                case "=", "+": zoomIn()
                case "-": zoomOut()
                case "0": zoom(to: fit)
                default: return false
                }
            } else if let tool = MarkTool.picked(by: c) {
                pick(tool)
            } else if c.lowercased() == "b" {
                panelOpen.toggle()
            } else {
                return false
            }
        }
        return true
    }

    /// History's Undo and ⌘Z, Redo and ⇧⌘Z (B): one step back or forward, the picks dropped.
    func undo() { commitText(); document.undo(); picked = []; loadPicture(); syncCrop() }
    func redo() { commitText(); document.redo(); picked = []; loadPicture(); syncCrop() }

    /// After an undo or redo, Crop's handles sit on the crop there is.
    private func syncCrop() {
        if tool == .crop { cropEdit = cropShown }
        restage()
    }

    /// The top bar's Read text: the marked-up capture's lines (a blurred secret stays unread), boxed where they are.
    func startReading() {
        commitText()
        commitCrop()
        readArea = document.area
        reading = .reading
        readText()
    }

    func showRead(_ lines: [ReadLine]) {
        guard reading != nil else { return }
        reading = .read(lines)
    }

    /// The strip's Copy text: every line read, copied again.
    func copyRead() {
        guard case .read(let lines) = reading, !lines.isEmpty else { return }
        copyColour(ReadLines.copied(lines))
        say("Copied the text")
    }

    /// Nothing selected: the footer shows the backdrop.
    func deselect() { picked = [] }

    /// ⌘A: Select comes up holding every mark.
    func selectAll() {
        pick(.select)
        picked = marks.map(\.id)
    }

    func deleteSelected() {
        document.delete(picked)
        picked = []
    }

    /// The capture with its marks and crop, at its own pixels, drawn off the main thread (a blur over a 5K capture takes
    /// a while, and the Hyper tap's run loop is the main one).
    func export(committing: Bool = true) async -> CGImage? {
        if committing { commitText(); commitCrop() }
        var document = self.document
        if !committing {
            if tool == .crop { document.setCrop(cropEdit) }
            if let id = typing {
                let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { document.delete(id) }
                else { document.update(id) { if case .text(_, let at, let pill) = $0.kind { $0.kind = .text(text, at: at, pill: pill) } } }
            }
        }
        guard document.edited || resized != nil else { return image }
        let job = Unchecked((image, document, scale, document.edited, resized.map { _ in exportSize }, screen?.image))
        return await Task.detached(priority: .userInitiated) {
            let (image, document, scale, edited, size, screen) = job.value
            let flat = edited ? MarkupRenderer.flatten(image, document, scale: scale, screen: screen) : image
            guard let flat, let size else { return Unchecked(flat) }
            return Unchecked(Resample.image(flat, width: Int(size.width), height: Int(size.height)))
        }.value.value
    }

    /// The size the export has before a resize, in pixels: the crop's or the capture's, in the backdrop's canvas.
    var flatSize: CGSize {
        let r = area.size
        // A backdrop sized for a place exports at the place's pixels (C9).
        return document.backdrop?.pixels(for: r, scale: scale) ?? CGSize(width: (r.width * scale).rounded(), height: (r.height * scale).rounded())
    }

    /// The size the export has, in pixels: the Image size chip's.
    var exportSize: CGSize {
        let flat = flatSize
        guard let resized else { return flat }
        let (w, h) = resized.applied(width: Int(flat.width), height: Int(flat.height))
        return CGSize(width: w, height: h)
    }

    /// The chip's popover opens on the resize last applied, else the export's size.
    var resizeTarget: ResizeTarget { resized ?? ResizeTarget(width: Int(flatSize.width), height: Int(flatSize.height)) }

    /// The popover's Apply: the export is resampled to the target, high quality; nil, the original size, takes it back.
    func resize(to target: ResizeTarget?) { resized = target?.changed == true ? target : nil }

    // MARK: Auto-redact (story 195)

    /// The lines with their words' boxes read over all of `part` (document points), and the document's rect they were read
    /// from: the capture as taken while `part` is inside it, else just that part of the screen it was cut from (P77), so an
    /// uncropped part is read too and nothing outside it. A read is kept while the editor is open (the screen's for the same
    /// part); nil lines when it failed, and the next press reads again.
    private func lines(over part: CGRect) async -> (lines: [ReadLine]?, from: CGRect) {
        let t = document.taken
        guard let screen, !t.insetBy(dx: -0.01, dy: -0.01).contains(part) else {
            if captureLines == nil { let read = readCapture; captureLines = Task { await read() } }
            let read = await captureLines?.value
            if read == nil { captureLines = nil }
            return (read, t)
        }
        // Whole pixels of the screen, so the boxes line up with what was read.
        let px = CGRect(x: part.minX * screen.scale, y: part.minY * screen.scale, width: part.width * screen.scale, height: part.height * screen.scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: screen.image.width, height: screen.image.height))
        let from = CGRect(x: px.minX / screen.scale, y: px.minY / screen.scale, width: px.width / screen.scale, height: px.height / screen.scale)
        let task: Task<[ReadLine]?, Never>
        if let held = screenLines, held.part == from { task = held.read } else {
            let read = readScreen
            task = Task { await read(from) }
            screenLines = (from, task)
        }
        let lines = await task.value
        if lines == nil, screenLines?.read == task { screenLines = nil }
        return (lines, from)
    }

    /// The top bar's Redact: each email, card number, IP address, key and phone number in the part kept's text gets a
    /// redact mark of its own, all in one undo step; Select comes up, so a click and ⌫ take one away. A second press
    /// adds only what is not covered yet. Hints and the log carry counts, never the text.
    func redactSensitive() {
        commitText()
        guard !finding else { return }
        finding = true
        Task { @MainActor in
            // All the part kept is read, an uncropped part too; what lies outside it is not kept, so not counted.
            let kept = area
            let (lines, from) = await lines(over: kept)
            guard let read = lines else { finding = false; return say("Couldn't read the text") }
            let found = AutoRedact.cover(read, size: from.size).map { (kind: $0.kind, rect: $0.rect.offsetBy(dx: from.minX, dy: from.minY)) }
                .filter { $0.rect.intersects(kept) }
            finding = false
            let covered = document.marks(on: .capture).compactMap { if case .box(let r, _) = $0.kind { r.insetBy(dx: -1, dy: -1) } else { nil } }
            let fresh = found.filter { f in !covered.contains { $0.contains(f.rect) } }
            PilotCapture.log.notice("auto-redact: \(found.count, privacy: .public) found, \(fresh.count, privacy: .public) new")
            guard !fresh.isEmpty else { return say(found.isEmpty ? "Nothing sensitive found" : "All covered already") }
            document.add(fresh.map { .box($0.rect, erase: style(of: .box) == 1) }, colour: 0, size: size(of: .box))
            pick(.select)
            let kinds = Dictionary(grouping: fresh, by: \.kind)
            say("Covered " + Sensitive.allCases.compactMap { k in kinds[k].map { k.named($0.count) } }.joined(separator: ", "))
        }
    }

    /// Blur's Text only on or off; on, the capture's text is read ahead, so the first drag is quick.
    func setTextOnly(_ on: Bool) {
        textOnly = on
        if on { let kept = area; Task { _ = await lines(over: kept) } }
    }

    /// A Text only drag: the lines read inside `area` blurred, as one mark. The part kept is read (the read Redact and
    /// Text only share), the drag too where it reaches past it.
    private func blurText(_ area: CGRect, pixelate: Bool, strength: Int) {
        finding = true
        let part = self.area.union(area)
        Task { @MainActor in
            let (lines, from) = await lines(over: part)
            guard let read = lines else { finding = false; return say("Couldn't read the text") }
            let boxes = AutoRedact.text(read, in: area.offsetBy(dx: -from.minX, dy: -from.minY), size: from.size)
                .map { $0.offsetBy(dx: from.minX, dy: from.minY) }
            finding = false
            guard !boxes.isEmpty else { return say("No text in that area") }
            picked = [document.add(.blurText(area, boxes: boxes, pixelate: pixelate), colour: 0, size: strength)]
        }
    }

    // MARK: Ruler

    private func loadGrid() {
        guard grid == nil, !gridLoading else { return }
        gridLoading = true
        let still = Unchecked(image)
        Task { @MainActor in
            grid = await Task.detached(priority: .userInitiated) { PixelGrid(still.value) }.value
            gridLoading = false
        }
    }

    #if DEBUG
    /// The ruler's pixels read at once, for a render.
    func loadGridNow() { grid = PixelGrid(image) }
    #endif

    /// The pointer over the capture (nil when it left): with the ruler, its two lines there.
    func hover(_ p: CGPoint?) {
        if tool == .select || tool == .crop {
            let g = p.flatMap(grip(at:))
            if g != hoverGrip { hoverGrip = g }
            return
        }
        if tool == .eyedropper {
            let rgb = p.flatMap(pixel(at:))
            if rgb != sampled { sampled = rgb }
            let at = rgb == nil ? nil : p
            if at != loupeAt { loupeAt = at }
            if (at != nil) != loupeShown { loupeShown = at != nil }
            return
        }
        guard tool == .ruler, dragStart == nil, let p else {
            if !hovering.isEmpty { hovering = [] }
            return
        }
        hovering = rulerMarks(at: p)
    }

    /// The capture's colour at `p`, nil off it or before its pixels are read.
    private func pixel(at p: CGPoint) -> UInt32? {
        let (x, y) = cell(p)
        return grid?.rgb(x: x, y: y)
    }

    /// The capture's pixel under the point `p`. The ruler and the colour picker read the capture as taken, never its
    /// screen, so their pixels stay capture-sized.
    private func cell(_ p: CGPoint) -> (x: Int, y: Int) {
        let o = document.taken.origin
        return (Int(((p.x - o.x) * scale).rounded(.down)), Int(((p.y - o.y) * scale).rounded(.down)))
    }

    /// The loupe's pixels: `side` × `side` of the capture's own, rows top first, centred on the one `pixel(at:)` reads;
    /// nil cells are off the capture.
    func pixels(around p: CGPoint, side: Int) -> [UInt32?] {
        guard let grid else { return [] }
        let (cx, cy) = cell(p), r = side / 2
        return (cy - r...cy + r).flatMap { y in (cx - r...cx + r).map { x in grid.rgb(x: x, y: y) } }
    }

    /// The colour picker's click: the colour becomes the seventh swatch and every coloured tool's colour, its hex is
    /// copied, and the tool it came from is picked again (it stays when it came from one without a colour).
    func takeColour(_ rgb: UInt32) {
        pickedColour = rgb
        for t in MarkTool.allCases where t.coloured { colours[t] = swatches.count }
        let hex = ColourAnswer.hex(rgb)
        copyColour(hex)
        say("Copied \(hex)")
        if let back = beforePicker, back.coloured { pick(back) }
    }

    /// The ruler's two lines across the colour at `p`: none off the capture or before its pixels are read.
    private func rulerMarks(at p: CGPoint) -> [Mark] {
        let o = document.taken.origin
        guard let grid, document.taken.contains(p) else { return [] }
        func back(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x + o.x, y: q.y + o.y) }
        let (l, r, u, d) = PixelRuler.lines(grid, at: CGPoint(x: p.x - o.x, y: p.y - o.y), scale: scale)
        return [Mark(id: 0, kind: .measure(from: back(l), to: back(r), points: second), colour: colour, size: 1),
                Mark(id: 0, kind: .measure(from: back(u), to: back(d), points: second), colour: colour, size: 1)]
    }

    // MARK: Backdrop (CP12; P70, the backdrop panel)

    /// The backdrop the canvas shows: a slider's while it moves, else the document's.
    var backdrop: Backdrop? { backdropDraft ?? document.backdrop }
    /// A slider's backdrop while it moves; kept as one undo step when it lets go.
    private(set) var backdropDraft: Backdrop?
    /// Whether the backdrop panel shows at the editor's left (B, or the top bar's Backdrop); the window remembers it.
    var panelOpen = false { didSet { if panelOpen != oldValue { panelChanged(panelOpen) } } }
    @ObservationIgnored var panelChanged: (Bool) -> Void = { _ in }
    /// A picture fill's picture at the preview's size (1600 on its longer side), read off the main thread when the fill
    /// or its blur changes; the export reads its own at full size.
    private(set) var backdropPicture: CGImage?
    @ObservationIgnored private var pictureOf: (fill: Backdrop.Fill, blur: Backdrop.Blur)?
    @ObservationIgnored private var pictureTask: Task<Void, Never>?

    /// A backdrop kept (a tile, a preset, None, a slider let go): one undo step.
    func setBackdrop(_ b: Backdrop?) {
        commitText()
        backdropDraft = nil
        document.setBackdrop(b)
        loadPicture()
    }

    /// Changes the backdrop there is, or a new one in the accent's wash; one undo step.
    func setBackdrop(_ change: (inout Backdrop) -> Void) {
        var b = backdrop ?? BackdropLibrary.standard(accent: accent)
        change(&b)
        setBackdrop(b)
    }

    /// A slider moving: the canvas shows `b` at once, nothing is kept until it lets go.
    func previewBackdrop(_ b: Backdrop) { backdropDraft = b }

    /// Reads the picture a picture fill needs for the preview, once per fill and blur; nil for any other fill.
    func loadPicture() {
        guard let b = backdrop, b.fill.picture else {
            pictureTask?.cancel()
            pictureOf = nil
            if backdropPicture != nil { backdropPicture = nil }
            return
        }
        if let had = pictureOf, had.fill == b.fill, had.blur == b.shownBlur { return }
        pictureOf = (b.fill, b.shownBlur)
        pictureTask?.cancel()
        let still = Unchecked(image)
        pictureTask = Task { @MainActor [weak self] in
            let made = await Task.detached(priority: .userInitiated) { Unchecked(MarkupRenderer.backdropPicture(b, capture: still.value, side: 1600)) }.value
            guard !Task.isCancelled else { return }
            self?.backdropPicture = made.value
        }
    }

    #if DEBUG
    /// The preview's picture read at once, for a render.
    func loadPictureNow() {
        guard let b = backdrop else { return }
        pictureOf = (b.fill, b.shownBlur)
        backdropPicture = MarkupRenderer.backdropPicture(b, capture: image, side: 1600)
    }
    #endif

    /// How the canvas shows the export: the backdrop's canvas fitted into the capture's room, the part kept in its spot.
    /// Without a backdrop it is the capture as it is, the crop shaded.
    struct Preview: Equatable {
        let k: CGFloat
        let origin: CGPoint
        /// The export's size in points, and where the part sits in it.
        let canvas: CGSize
        let spot: CGRect
        let area: CGRect
    }

    var preview: Preview {
        let whole = CGRect(origin: .zero, size: size)
        guard let b = framed else { return Preview(k: 1, origin: .zero, canvas: size, spot: whole, area: whole) }
        let box = stage, a = document.area, c = b.canvas(for: a.size)
        let k = min(1, box.width / c.width, box.height / c.height)
        return Preview(k: k, origin: CGPoint(x: box.minX + (box.width - c.width * k) / 2, y: box.minY + (box.height - c.height * k) / 2),
                       canvas: c, spot: b.spot(for: a.size), area: a)
    }

    // MARK: The stage and backdrop marks (P77)

    /// The part of the document the room shows and the zoom fits: the capture as taken and the part kept, both whole (an
    /// uncrop grows it); while cropping, that as Crop opened. All of a capture with no screen, as before.
    var stage: CGRect {
        if tool == .crop, let cropStage { return cropStage }
        return document.taken.union(document.area)
    }

    /// Where the backdrop's canvas has its top left, in the document's points while a backdrop frames the capture (nil
    /// otherwise): backdrop marks are kept in the canvas's points from its top left, so they stay put as the capture moves
    /// in it or grows.
    var canvasOrigin: CGPoint? {
        guard let b = framed else { return nil }
        let a = document.area, spot = b.spot(for: a.size)
        return CGPoint(x: a.minX - spot.minX, y: a.minY - spot.minY)
    }

    /// The marks as the canvas shows them, in the document's points: the capture's, and the backdrop's on its canvas,
    /// hidden while no backdrop frames the capture (they come back with one).
    var marks: [Mark] {
        let o = canvasOrigin
        return document.marks.compactMap { m in m.layer == .capture ? m : o.map { m.moved(by: $0) } }
    }

    /// The front mark under `p` as drawn, either layer.
    func mark(at p: CGPoint) -> Mark? { marks.last { $0.hit(p) } }

    /// A mark shown on the canvas as the document keeps it: a backdrop mark back in the canvas's points.
    private func unplaced(_ m: Mark) -> Mark {
        guard m.layer == .backdrop, let o = canvasOrigin else { return m }
        return m.moved(by: CGPoint(x: -o.x, y: -o.y))
    }

    /// A point where a mark starts, in the document's points, as the layer it starts on keeps it.
    private func unplaced(_ p: CGPoint) -> CGPoint {
        guard drawingOn == .backdrop, let o = canvasOrigin else { return p }
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    /// A press at `p` starts a backdrop mark (Sven: a mark belongs to where you start drawing it): a backdrop frames the
    /// capture, `p` is off the part kept, and the tool draws there: blur, redact, spotlight and the ruler read or cover
    /// the capture's own pixels, so they stay on it.
    private func startsOnBackdrop(_ p: CGPoint) -> Bool {
        guard framed != nil, !document.area.contains(p) else { return false }
        return [.arrow, .rect, .ellipse, .text, .pen, .highlighter, .step].contains(tool)
    }

    /// The view follows a stage that changed: refitted while it was the fit, else held at its zoom and recentred.
    private func restage() { if room != .zero { zoom(to: fitted ? fit : zoom) } }

    /// A point on the capture as a point on the canvas, the other way round.
    func canvasPoint(_ p: CGPoint) -> CGPoint {
        let v = preview
        return CGPoint(x: v.origin.x + (p.x - v.area.minX + v.spot.minX) * v.k, y: v.origin.y + (p.y - v.area.minY + v.spot.minY) * v.k)
    }

    /// A point on the canvas (in the capture's room) as a point on the capture.
    func capturePoint(_ p: CGPoint) -> CGPoint {
        let v = preview
        return CGPoint(x: (p.x - v.origin.x) / v.k - v.spot.minX + v.area.minX, y: (p.y - v.origin.y) / v.k - v.spot.minY + v.area.minY)
    }

    // MARK: Zoom (P33, Sven Q280, Q281)

    /// The sunken ground the capture sits on, in the window's points from its top left; the view sets it.
    private(set) var room: CGRect = .zero
    /// Screen points a capture point: `fit` as the editor opens, then what ⌘+, ⌘−, ⌘0, the footer's buttons and its
    /// per cent, a pinch or ⌘-scroll pick, from `fit` to `EditorLayout.zoomMost`.
    private(set) var zoom: CGFloat = 1
    /// The capture's top left in the room: centred on an axis where it fits, else wherever scrolling or zooming put it.
    private(set) var origin: CGPoint = .zero
    /// The zoom follows the room while it is the fit.
    @ObservationIgnored private var fitted = true

    /// The zoom that shows the whole capture inside the room's margin and clear of the tool rail on either side (so it
    /// stays centred), never past actual size.
    var fit: CGFloat { EditorLayout.fit(stage.size, inside: fitRoom) }

    private var fitRoom: CGSize { room.insetBy(dx: EditorLayout.margin + EditorLayout.rail, dy: EditorLayout.margin).size }

    /// The zoom out stops at: the fit, or while cropping a capture with its screen, one that shows all the screen round
    /// the stage, so an uncrop can reach every edge.
    var least: CGFloat {
        guard tool == .crop else { return fit }
        let s = stage, w = 2 * max(s.midX, size.width - s.midX), h = 2 * max(s.midY, size.height - s.midY)
        return min(fit, EditorLayout.fit(CGSize(width: w, height: h), inside: fitRoom))
    }

    var canZoomIn: Bool { zoom < EditorLayout.zoomMost - 0.001 }
    var canZoomOut: Bool { zoom > least + 0.001 }

    func setRoom(_ frame: CGRect) {
        guard frame != room else { return }
        room = frame
        zoom(to: fitted ? fit : zoom)
    }

    /// Zooms to `z`, held between `fit` and `EditorLayout.zoomMost`, keeping the capture under `anchor` (a point in the room) where it
    /// is: the pointer for a pinch or ⌘-scroll, the room's centre for the keys and buttons.
    func zoom(to z: CGFloat, about anchor: CGPoint? = nil) {
        let a = anchor ?? CGPoint(x: room.width / 2, y: room.height / 2), low = least
        let next = min(EditorLayout.zoomMost, max(low, z)), k = next / zoom
        fitted = next < fit + 0.001
        // A pinch or scroll past either end writes nothing, so the canvas does not redraw for it.
        if next != zoom { zoom = next }
        move(to: CGPoint(x: a.x - (a.x - origin.x) * k, y: a.y - (a.y - origin.y) * k))
    }


    /// A plain scroll moves the capture by `d` while it is larger than the room; one that fits stays centred.
    func pan(by d: CGSize) { move(to: CGPoint(x: origin.x + d.width, y: origin.y + d.height)) }

    /// The capture's top left to `o`, kept so the capture covers the room on each axis it is larger than and is centred
    /// on each it fits; a move that changes nothing writes nothing.
    private func move(to o: CGPoint) {
        let next = EditorLayout.clamp(o, content: CGSize(width: stage.width * zoom, height: stage.height * zoom), room: room.size)
        if next != origin { origin = next }
    }

    /// Where the stage shows in the room; `origin` is its top left.
    var shown: CGRect { CGRect(x: origin.x, y: origin.y, width: stage.width * zoom, height: stage.height * zoom) }

    /// A point in the room as a point on the document, through the backdrop's preview; `roomPoint` the other way.
    func capturePoint(inRoom p: CGPoint) -> CGPoint {
        let s = stage.origin
        return capturePoint(CGPoint(x: (p.x - origin.x) / zoom + s.x, y: (p.y - origin.y) / zoom + s.y))
    }

    func roomPoint(_ p: CGPoint) -> CGPoint {
        let c = canvasPoint(p), s = stage.origin
        return CGPoint(x: origin.x + (c.x - s.x) * zoom, y: origin.y + (c.y - s.y) * zoom)
    }

    func say(_ text: String) {
        hint = text
        hintClear?.cancel()
        // Weak, as the picture's task: a closed editor goes at once, never 1.6 s later.
        hintClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { self?.hint = nil }
        }
    }
}
