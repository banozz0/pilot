import AppKit
import Clipboard
import ImageScale
import Observation
import PilotCore

/// The capture editor's state (spec `capture.html` CP6, CP7; direction A, Sven Q169): the capture, its marks, the
/// picked tool and each tool's options, the mark being drawn, the text being typed, and what the keys do. The view
/// draws it; this decides. Points are the capture's, from its top left.
@Observable @MainActor
final class EditorModel {
    /// A key as the editor sees it.
    enum Key: Equatable {
        case char(String, command: Bool = false, shift: Bool = false)
        case escape, enter, delete
    }

    /// What the editor asks for: copy or save a copy of the flattened image and stay, Done, or Cancel.
    enum Outcome { case copy, saveCopy, done, cancel, pin }

    let image: CGImage
    /// Pixels per point.
    let scale: CGFloat
    private(set) var document: MarkupDocument
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
    /// Reads the capture as taken, never the marked-up export, and copies nothing; the window sets it.
    @ObservationIgnored var readCapture: () async -> [ReadLine] = { [] }
    @ObservationIgnored private var captureLines: Task<[ReadLine], Never>?
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
    /// Where a picked colour's hex goes: the window's pasteboard.
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

    init(image: CGImage, scale: CGFloat, accent: UInt32, dark: Bool, ground: UInt32 = 0x1A1B1F) {
        self.image = image
        self.scale = scale
        document = MarkupDocument(size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
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
        if tool == .crop, self.tool != .crop { cropEdit = document.crop }
        hoverGrip = nil
        self.tool = tool
        if tool != .select { picked = [] }
        discardArmed = false
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
        guard picked.count == 1, let mark = document.marks.first(where: { $0.id == picked[0] }) else { return nil }
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
        dragStart = p
        switch tool {
        case .select:
            if let mark = selectedMark, let g = grip(at: p) {
                grab = Grab(mark: mark, crop: .zero, grip: g, from: p)
                return
            }
            if let mark = document.mark(at: p) {
                // Shift-click takes a mark into the group or out of it; a drag on a picked mark moves the whole group.
                if shift, picked.contains(mark.id) { picked.removeAll { $0 == mark.id }; dragStart = nil; return }
                if shift { picked.append(mark.id) } else if !picked.contains(mark.id) { picked = [mark.id] }
                movingFrom = p
            } else {
                if !shift { picked = [] }
                marquee = (CGRect(origin: p, size: .zero), picked)
            }
        case .step:
            picked = [document.add(.step(0, at: p), colour: colour, size: size(of: .step))]
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
            let id = document.add(.text("", at: CGPoint(x: p.x, y: p.y - lift), pill: second), colour: colour, size: size(of: .text), face: textFace)
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
        if let grab {
            let d = CGPoint(x: p.x - grab.from.x, y: p.y - grab.from.y)
            if let mark = grab.mark {
                draftResize = mark.resized(grab.grip, by: d, keepRatio: shift, fromCentre: option)
            } else {
                cropEdit = held(grab.grip.resize(grab.crop, by: d, keepRatio: shift, fromCentre: option), moving: grab.grip == .box(0, 0))
            }
            return
        }
        if let movingFrom {
            draftMove = CGPoint(x: p.x - movingFrom.x, y: p.y - movingFrom.y)
            return
        }
        if let base = marquee?.base {
            let box = Self.rect(start, p)
            marquee = (box, base)
            let touched = base + document.marks.filter { !base.contains($0.id) && $0.touches(box) }.map(\.id)
            if touched != picked { picked = touched }
            return
        }
        if tool == .crop { cropEdit = held(Self.rect(start, p), moving: false); return }
        if tool == .ruler {
            hovering = []
            draft = Mark(id: 0, kind: .measure(from: start, to: p, points: second), colour: colour, size: 1)
            return
        }
        var path: [CGPoint] = []
        if case .pen(let points)? = draft?.kind { path = points }
        if case .highlight(let points)? = draft?.kind { path = points }
        draft = shape(from: start, to: p, path: path + [p])
    }

    /// Where a dragged mark is being moved to, drawn before the move is kept.
    private(set) var draftMove: CGPoint?

    /// The pointer came up at `p`: the shape is kept, unless it is too small to mean anything.
    func end(_ p: CGPoint, shift: Bool = false, option: Bool = false) {
        drag(p, shift: shift, option: option)
        defer { dragStart = nil; draft = nil; draftMove = nil; movingFrom = nil; marquee = nil; grab = nil; draftResize = nil; cropBefore = nil }
        if let grab {
            if let mark = draftResize, mark != grab.mark { document.update(mark.id) { $0 = mark } }
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
        guard let draft, Self.counts(draft) else { return }
        if textOnly, case .blur(let area, let pixelate) = draft.kind { return blurText(area, pixelate: pixelate, strength: draft.size) }
        picked = [document.add(draft.kind, colour: draft.colour, size: draft.size)]
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
        case .spotlight: .spotlight(r)
        case .ruler: .measure(from: a, to: b, points: second)
        default: nil
        }
        return kind.map { Mark(id: 0, kind: $0, colour: colour, size: size(of: tool)) }
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
        default: true
        }
    }

    // MARK: Handles and crop

    /// The handle at `p` (capture points): the one picked mark's with Select, the crop's with Crop; nil elsewhere.
    func grip(at p: CGPoint) -> Grip? {
        let reach = Grip.reach / max(0.01, zoom * preview.k)
        if tool == .crop, let crop = cropEdit { return Grip.nearest(Grip.grips(ofCrop: crop), to: p, reach: reach) }
        guard tool == .select, let mark = selectedMark else { return nil }
        return Grip.nearest(Grip.grips(of: mark), to: p, reach: reach)
    }

    /// A crop held inside the capture: a moved one keeps its size, a pulled one is cut at the edge.
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

    /// Whole capture: no crop.
    func clearCrop() {
        cropEdit = nil
        document.setCrop(nil)
    }

    /// The part the export keeps: the crop being edited while Crop is the tool, else the document's.
    var area: CGRect { tool == .crop ? cropEdit ?? CGRect(origin: .zero, size: size) : document.area }

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
                case "z": shift ? document.redo() : document.undo(); loadPicture(); syncCrop()
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

    func undo() { commitText(); document.undo(); picked = []; loadPicture(); syncCrop() }

    /// After an undo or redo, Crop's handles sit on the crop there is.
    private func syncCrop() { if tool == .crop { cropEdit = document.crop } }

    /// The top bar's Read text: the marked-up capture's lines (a blurred secret stays unread), boxed where they are.
    func startReading() {
        commitText()
        commitCrop()
        readArea = document.crop ?? CGRect(origin: .zero, size: document.size)
        reading = .reading
        readText()
    }

    func showRead(_ lines: [ReadLine]) {
        guard reading != nil else { return }
        reading = .read(lines)
    }

    /// Nothing selected: the footer shows the backdrop.
    func deselect() { picked = [] }

    /// ⌘A: Select comes up holding every mark.
    func selectAll() {
        pick(.select)
        picked = document.marks.map(\.id)
    }

    func deleteSelected() {
        document.delete(picked)
        picked = []
    }

    /// The capture with its marks and crop, at its own pixels, drawn off the main thread (a blur over a 5K capture takes
    /// a while, and the Hyper tap's run loop is the main one).
    func export() async -> CGImage? {
        commitText()
        commitCrop()
        guard document.edited || resized != nil else { return image }
        let job = Unchecked((image, document, scale, document.edited, resized.map { _ in exportSize }))
        return await Task.detached(priority: .userInitiated) {
            let (image, document, scale, edited, size) = job.value
            let flat = edited ? MarkupRenderer.flatten(image, document, scale: scale) : image
            guard let flat, let size else { return Unchecked(flat) }
            return Unchecked(Resample.image(flat, width: Int(size.width), height: Int(size.height)))
        }.value.value
    }

    /// The size the export has before a resize, in pixels: the crop's or the capture's, in the backdrop's canvas.
    var flatSize: CGSize {
        let r = area.size, c = document.backdrop?.canvas(for: r) ?? r
        return CGSize(width: (c.width * scale).rounded(), height: (c.height * scale).rounded())
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

    /// The capture's own lines with their words' boxes, read once while the editor is open.
    private func capturedLines() async -> [ReadLine] {
        if captureLines == nil {
            let read = readCapture
            captureLines = Task { await read() }
        }
        return await captureLines?.value ?? []
    }

    /// The top bar's Redact: each email, card number, IP address, key and phone number in the capture's text gets a
    /// redact mark of its own, all in one undo step; Select comes up, so a click and ⌫ take one away. A second press
    /// adds only what is not covered yet. Hints and the log carry counts, never the text.
    func redactSensitive() {
        commitText()
        guard !finding else { return }
        finding = true
        Task { @MainActor in
            let found = AutoRedact.cover(await capturedLines(), size: size)
            finding = false
            let covered = document.marks.compactMap { if case .box(let r, _) = $0.kind { r.insetBy(dx: -1, dy: -1) } else { nil } }
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
        if on { Task { _ = await capturedLines() } }
    }

    /// A Text only drag: the lines read inside `area` blurred, as one mark.
    private func blurText(_ area: CGRect, pixelate: Bool, strength: Int) {
        finding = true
        Task { @MainActor in
            let boxes = AutoRedact.text(await capturedLines(), in: area, size: size)
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

    /// The capture's pixel under the point `p`.
    private func cell(_ p: CGPoint) -> (x: Int, y: Int) { (Int((p.x * scale).rounded(.down)), Int((p.y * scale).rounded(.down))) }

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
        guard let grid, CGRect(origin: .zero, size: size).contains(p) else { return [] }
        let (l, r, u, d) = PixelRuler.lines(grid, at: p, scale: scale)
        return [Mark(id: 0, kind: .measure(from: l, to: r, points: second), colour: colour, size: 1),
                Mark(id: 0, kind: .measure(from: u, to: d, points: second), colour: colour, size: 1)]
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
        pictureTask = Task { @MainActor in
            let made = await Task.detached(priority: .userInitiated) { Unchecked(MarkupRenderer.backdropPicture(b, capture: still.value, side: 1600)) }.value
            guard !Task.isCancelled else { return }
            backdropPicture = made.value
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
        let a = document.area, c = b.canvas(for: a.size)
        let k = min(1, size.width / c.width, size.height / c.height)
        return Preview(k: k, origin: CGPoint(x: (size.width - c.width * k) / 2, y: (size.height - c.height * k) / 2), canvas: c, spot: b.spot(for: a.size), area: a)
    }

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
    /// per cent, a pinch or ⌘-scroll pick, from `fit` to `maxZoom`.
    private(set) var zoom: CGFloat = 1
    /// The capture's top left in the room: centred on an axis where it fits, else wherever scrolling or zooming put it.
    private(set) var origin: CGPoint = .zero
    /// The zoom follows the room while it is the fit.
    @ObservationIgnored private var fitted = true
    static let maxZoom: CGFloat = 8
    /// The keys' and buttons' grid, 25 % a step (Sven on build 67, P46); `fit` is the bottom step.
    static let zoomStep: CGFloat = 0.25

    /// The zoom that shows the whole capture inside the room's margin, never past actual size.
    var fit: CGFloat { EditorLayout.fit(size, inside: room.insetBy(dx: EditorLayout.margin, dy: EditorLayout.margin).size) }

    var canZoomIn: Bool { zoom < Self.maxZoom - 0.001 }
    var canZoomOut: Bool { zoom > fit + 0.001 }

    func setRoom(_ frame: CGRect) {
        guard frame != room else { return }
        room = frame
        zoom(to: fitted ? fit : zoom)
    }

    /// Zooms to `z`, held between `fit` and `maxZoom`, keeping the capture under `anchor` (a point in the room) where it
    /// is: the pointer for a pinch or ⌘-scroll, the room's centre for the keys and buttons.
    func zoom(to z: CGFloat, about anchor: CGPoint? = nil) {
        let a = anchor ?? CGPoint(x: room.width / 2, y: room.height / 2), low = fit
        let next = min(Self.maxZoom, max(low, z)), k = next / zoom
        fitted = abs(next - low) < 0.001
        // A pinch or scroll past either end writes nothing, so the canvas does not redraw for it.
        if next != zoom { zoom = next }
        move(to: CGPoint(x: a.x - (a.x - origin.x) * k, y: a.y - (a.y - origin.y) * k))
    }

    /// The next 25 % up or down from any zoom: a fitted 18 % goes to 25 %, and 60 % down to 50 %.
    func zoomIn() { zoom(to: (((zoom + 0.001) / Self.zoomStep).rounded(.down) + 1) * Self.zoomStep) }
    func zoomOut() { zoom(to: (((zoom - 0.001) / Self.zoomStep).rounded(.up) - 1) * Self.zoomStep) }

    /// A plain scroll moves the capture by `d` while it is larger than the room; one that fits stays centred.
    func pan(by d: CGSize) { move(to: CGPoint(x: origin.x + d.width, y: origin.y + d.height)) }

    /// The capture's top left to `o`, kept so the capture covers the room on each axis it is larger than and is centred
    /// on each it fits; a move that changes nothing writes nothing.
    private func move(to o: CGPoint) {
        func axis(_ v: CGFloat, _ length: CGFloat, _ room: CGFloat) -> CGFloat {
            length <= room ? (room - length) / 2 : min(0, max(room - length, v))
        }
        let next = CGPoint(x: axis(o.x, size.width * zoom, room.width), y: axis(o.y, size.height * zoom, room.height))
        if next != origin { origin = next }
    }

    /// Where the capture shows in the room.
    var shown: CGRect { CGRect(x: origin.x, y: origin.y, width: size.width * zoom, height: size.height * zoom) }

    /// A point in the room as a point on the capture, through the backdrop's preview; `roomPoint` the other way.
    func capturePoint(inRoom p: CGPoint) -> CGPoint { capturePoint(CGPoint(x: (p.x - origin.x) / zoom, y: (p.y - origin.y) / zoom)) }

    func roomPoint(_ p: CGPoint) -> CGPoint {
        let c = canvasPoint(p)
        return CGPoint(x: origin.x + c.x * zoom, y: origin.y + c.y * zoom)
    }

    func say(_ text: String) {
        hint = text
        hintClear?.cancel()
        hintClear = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { hint = nil }
        }
    }
}
