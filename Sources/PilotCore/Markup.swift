import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// The capture editor's tools (spec `capture.html` CP5–CP7; Sven's SuperCmd layout): 1 to 9 and 0 on the number keys,
/// crop, spotlight and the pixel ruler on C, F and R.
public enum MarkTool: Int, CaseIterable, Sendable {
    case select = 1, arrow, rect, ellipse, text, pen, highlighter, blur, box, step, crop, spotlight, ruler
    /// The colour picker (Q246): a click takes a pixel's colour as the drawing colour and copies its hex.
    case eyedropper

    /// The ten on the number keys, in the top bar's order.
    public static let numbered: [MarkTool] = [.select, .arrow, .rect, .ellipse, .text, .pen, .highlighter, .blur, .box, .step]
    /// The editor's top bar: the ten, then crop (Sven after build 82: it was on C alone) and the colour picker.
    public static let bar: [MarkTool] = numbered + [.crop, .eyedropper]

    /// The key that picks it: its digit, 0 for the step counter, C, F, R and I for the ones on letters.
    public var key: String {
        switch self {
        case .step: "0"
        case .crop: "C"
        case .spotlight: "F"
        case .ruler: "R"
        case .eyedropper: "I"
        default: "\(rawValue)"
        }
    }

    public var name: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .blur: "Blur"
        case .box: "Redact"
        case .step: "Step"
        case .crop: "Crop"
        case .spotlight: "Spotlight"
        case .ruler: "Ruler"
        case .eyedropper: "Colour picker"
        }
    }

    /// The tool a typed key picks: "1"…"9", "0", "c", "f", "r", "i".
    public static func picked(by key: String) -> MarkTool? {
        switch key.lowercased() {
        case "0": .step
        case "c": .crop
        case "f": .spotlight
        case "r": .ruler
        case "i": .eyedropper
        default: Int(key).flatMap { (1...9).contains($0) ? MarkTool(rawValue: $0) : nil }
        }
    }

    /// The two ways the tool draws, picked in the footer: straight or curved arrows, outline or filled shapes, plain or
    /// pill text, blur or pixelate, redact or erase. Nil for a tool with one way.
    public var styles: (String, String)? {
        switch self {
        case .arrow: ("Straight", "Curved")
        // A pen's line comes out neat unless it is Freehand (C6, Sven Q805).
        case .pen: ("Smooth", "Freehand")
        // Spotlight's second way is the magnifier (C5, Q805): a round zoomed callout of a small detail.
        case .spotlight: ("Spotlight", "Magnify")
        case .rect, .ellipse: ("Outline", "Filled")
        case .text: ("Plain", "Pill")
        case .blur: ("Blur", "Pixelate")
        case .box: ("Redact", "Erase")
        case .ruler: ("Pixels", "Points")
        default: nil
        }
    }

    /// Whether the colour swatches apply.
    public var coloured: Bool { ![.select, .blur, .box, .crop, .spotlight, .eyedropper].contains(self) }

    /// Whether the size slider applies.
    public var sized: Bool { ![.select, .crop, .ruler, .eyedropper].contains(self) }
}

/// One mark on a capture, in the capture's points from its top left; a mark on the backdrop, in the backdrop's canvas
/// points from its top left (P77).
public struct Mark: Equatable, Sendable, Identifiable {
    /// Where a mark lives (P77, Sven: a mark belongs to where you start drawing it): on the capture, moving with it, or on
    /// the backdrop, staying put in the canvas while the capture moves or grows.
    public enum Layer: Sendable { case capture, backdrop }

    public enum Kind: Equatable, Sendable {
        case arrow(from: CGPoint, to: CGPoint, curved: Bool)
        case rect(CGRect, filled: Bool)
        case ellipse(CGRect, filled: Bool)
        case text(String, at: CGPoint, pill: Bool)
        case pen([CGPoint])
        case highlight([CGPoint])
        case blur(CGRect, pixelate: Bool)
        /// Blur's Text only (story 195): the area dragged, and only the text read inside it blurred, a box a line.
        case blurText(CGRect, boxes: [CGRect], pixelate: Bool)
        case box(CGRect, erase: Bool)
        case step(Int, at: CGPoint)
        case spotlight(CGRect)
        /// The ruler's stamp: a line with end ticks and its length, in points or pixels.
        case measure(from: CGPoint, to: CGPoint, points: Bool)
        /// The magnifier (C5): a round lens in `lens` showing the capture round `focus` zoomed by the size; a lens moved
        /// off its detail rings the detail and points to it.
        case magnify(CGRect, focus: CGPoint)
    }

    public let id: Int
    public var kind: Kind
    /// 0xRRGGBB.
    public var colour: UInt32
    /// 1 to 10, the footer's slider: a line's width, a blur's strength, a step's size, a spotlight's darkness.
    public var size: Int
    /// A text's face (Sven after build 82): its font, points, bold and italic; the other kinds ignore it.
    public var face: TextFace
    public var layer: Layer
    /// A curved arrow's bend (C4, Sven Q805): where its curve's control point sits off the middle of its two ends, in
    /// points; nil bends it the standard fifth of its length to the left. A straight arrow ignores it.
    public var bend: CGPoint?

    public init(id: Int, kind: Kind, colour: UInt32, size: Int, face: TextFace = .standard, layer: Layer = .capture) {
        self.id = id
        self.kind = kind
        self.colour = colour
        self.size = min(10, max(1, size))
        self.face = face
        self.layer = layer
    }

    /// A curved arrow's control point; nil for a straight one or any other kind.
    public var control: CGPoint? {
        guard case .arrow(let a, let b, true) = kind else { return nil }
        guard let bend else { return MarkupRenderer.bend(a, b) }
        return CGPoint(x: (a.x + b.x) / 2 + bend.x, y: (a.y + b.y) / 2 + bend.y)
    }

    /// An arrow's line as drawn: its curve as 24 pieces, or its two ends.
    var arrowPath: [CGPoint] {
        guard case .arrow(let a, let b, _) = kind else { return [] }
        return control.map { Self.curve(a, $0, b) } ?? [a, b]
    }

    /// The magnifier's zoom for its size: 1.3× to 4×, 2.5× at the standard 5.
    public var zoom: CGFloat { 1 + CGFloat(size) * 0.3 }

    /// The detail a magnifier shows, round its focus: the lens's size over its zoom.
    public var magnified: CGRect? {
        guard case .magnify(let lens, let focus) = kind else { return nil }
        let r = lens.width / 2 / zoom
        return CGRect(x: focus.x - r, y: focus.y - r, width: 2 * r, height: 2 * r)
    }

    /// Whether it hides what is under it (a blur, a pixelate or a redact): a magnifier drawn before it shows it covered.
    public var covers: Bool {
        switch kind {
        case .blur, .blurText, .box: true
        default: false
        }
    }

    /// Whether it hides for good what is under it (a redact or a secure pixelate): a blur drawn over it reads it covered.
    public var seals: Bool {
        switch kind {
        case .box, .blur(_, true), .blurText(_, _, true): true
        default: false
        }
    }

    /// Whether a magnifier's lens has been moved off its detail, so the detail is ringed and pointed to.
    public var magnifierApart: Bool {
        guard case .magnify(let lens, let focus) = kind, let detail = magnified else { return false }
        return hypot(focus.x - lens.midX, focus.y - lens.midY) > lens.width / 2 + detail.width / 2 - 2
    }

    /// A line or arrow's width in points for its size.
    public var lineWidth: CGFloat { 1 + CGFloat(size) * 1.2 }
    /// A step disc's diameter, a text's size.
    public var stepDiameter: CGFloat { 16 + CGFloat(size) * 3 }
    /// A text's points: its face's, else from its size.
    public var fontSize: CGFloat { face.points ?? 10 + CGFloat(size) * 2 }

    /// The area the mark covers, its line's width included; a text's is measured with its face.
    public var bounds: CGRect {
        let pad = lineWidth * 2
        switch kind {
        case .arrow(let a, let b, _):
            return Self.box(control.map { Self.curveExtremes(a, $0, b) } ?? [a, b]).insetBy(dx: -pad - 8, dy: -pad - 8)
        case .measure(let a, let b, _):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -pad - 8, dy: -pad - 8)
        case .magnify(let lens, _):
            let ring = lens.insetBy(dx: -3, dy: -3)
            return magnifierApart ? ring.union(magnified!.insetBy(dx: -3, dy: -3)) : ring
        case .rect(let r, _), .ellipse(let r, _): return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .blur(let r, _), .box(let r, _), .spotlight(let r), .blurText(let r, _, _): return r
        case .pen(let p), .highlight(let p):
            guard !p.isEmpty else { return .null }
            return Self.box(p).insetBy(dx: -pad * (kindIsHighlight ? 3 : 1), dy: -pad * (kindIsHighlight ? 3 : 1))
        case .step(_, let c): return CGRect(x: c.x - stepDiameter / 2, y: c.y - stepDiameter / 2, width: stepDiameter, height: stepDiameter)
        case .text(let s, let at, let pill):
            let size = MarkupRenderer.textSize(s, fontSize: fontSize, face: face)
            let pad: CGFloat = pill ? fontSize * 0.6 : 0
            return CGRect(x: at.x, y: at.y, width: size.width + 2 * pad, height: size.height + (pill ? fontSize * 0.5 : 0))
        }
    }

    private var kindIsHighlight: Bool { if case .highlight = kind { true } else { false } }

    /// Whether a click at `p` lands on the mark as drawn (build 54): a line, an arrow, a pen or a ruler stamp along its
    /// stroke, an outline shape on its edge, a filled shape, blur, box, spotlight, step or text over its area, each with a
    /// few points of slack. Its bounding rectangle alone let an arrow across the capture swallow every click under it.
    public func hit(_ p: CGPoint) -> Bool {
        let slack = max(6, lineWidth / 2 + 4)
        switch kind {
        case .arrow(_, let b, _):
            let head = lineWidth * 3.6
            if hypot(p.x - b.x, p.y - b.y) <= head + 2 { return true }
            return Self.distance(p, toPolyline: arrowPath) <= slack
        case .magnify(let lens, _):
            if hypot(p.x - lens.midX, p.y - lens.midY) <= lens.width / 2 + 4 { return true }
            guard magnifierApart, let detail = magnified else { return false }
            return hypot(p.x - detail.midX, p.y - detail.midY) <= detail.width / 2 + 4
        case .measure(let a, let b, _):
            return Self.distance(p, toPolyline: [a, b]) <= slack || hypot(p.x - (a.x + b.x) / 2, p.y - (a.y + b.y) / 2) <= 18
        case .pen(let points):
            return Self.distance(p, toPolyline: points) <= slack
        case .highlight(let points):
            return Self.distance(p, toPolyline: points) <= max(slack, lineWidth * 2.5 + 2)
        case .rect(let r, let filled):
            if filled { return r.insetBy(dx: -slack, dy: -slack).contains(p) }
            return r.insetBy(dx: -slack, dy: -slack).contains(p) && !r.insetBy(dx: slack, dy: slack).contains(p)
        case .ellipse(let r, let filled):
            guard r.width > 0, r.height > 0 else { return false }
            let dx = (p.x - r.midX) / (r.width / 2), dy = (p.y - r.midY) / (r.height / 2)
            let radius = (dx * dx + dy * dy).squareRoot(), edge = slack / min(r.width, r.height) * 2
            return filled ? radius <= 1 + edge : abs(radius - 1) <= edge
        case .blur(let r, _), .box(let r, _), .spotlight(let r), .blurText(let r, _, _):
            return r.insetBy(dx: -2, dy: -2).contains(p)
        case .step, .text:
            return bounds.insetBy(dx: -4, dy: -4).contains(p)
        }
    }

    /// Whether the select tool's marquee `box` touches the mark as drawn (Sven on build 62: a marquee picked a mark only
    /// when it held all of it): a line, an arrow, a pen or a ruler stamp where its stroke crosses the box, an outline shape
    /// where its edge does, the rest wherever their area meets it, as Figma and Preview pick. An arrow's empty corners
    /// never count, as with `hit`.
    public func touches(_ box: CGRect) -> Bool {
        guard box.width > 0 || box.height > 0 else { return false }
        let near = box.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        switch kind {
        case .arrow(_, let b, _):
            let head = lineWidth * 3.6
            if near.insetBy(dx: -head, dy: -head).contains(b) { return true }
            return Self.crosses(arrowPath, near)
        case .magnify(let lens, _):
            return box.intersects(lens) || (magnifierApart && box.intersects(magnified!))
        case .measure(let a, let b, _):
            return Self.crosses([a, b], near)
        case .pen(let points):
            return Self.crosses(points, near)
        case .highlight(let points):
            return Self.crosses(points, box.insetBy(dx: -lineWidth * 2.5, dy: -lineWidth * 2.5))
        case .rect(let r, let filled):
            return near.intersects(r) && (filled || !r.insetBy(dx: lineWidth, dy: lineWidth).contains(box))
        case .ellipse(let r, let filled):
            guard r.width > 0, r.height > 0 else { return false }
            // In the ellipse's own units it is the unit circle: the box's nearest point inside it touches, and for an
            // outline its farthest corner must be outside too.
            func unit(_ x: CGFloat, _ y: CGFloat) -> CGFloat { hypot((x - r.midX) / (r.width / 2), (y - r.midY) / (r.height / 2)) }
            let nearest = unit(min(max(r.midX, near.minX), near.maxX), min(max(r.midY, near.minY), near.maxY))
            guard nearest <= 1 else { return false }
            if filled { return true }
            return [(near.minX, near.minY), (near.maxX, near.minY), (near.minX, near.maxY), (near.maxX, near.maxY)].contains { unit($0.0, $0.1) >= 1 }
        case .blur, .box, .spotlight, .blurText, .step, .text:
            return box.intersects(bounds)
        }
    }

    /// Whether a line through `points` crosses or lies in `box`.
    static func crosses(_ points: [CGPoint], _ box: CGRect) -> Bool {
        guard let first = points.first else { return false }
        if box.contains(first) { return true }
        return zip(points, points.dropFirst()).contains { a, b in
            // Liang–Barsky: clip the segment to the box; it touches when anything is left.
            var t0: CGFloat = 0, t1: CGFloat = 1
            let dx = b.x - a.x, dy = b.y - a.y
            for (p, q) in [(-dx, a.x - box.minX), (dx, box.maxX - a.x), (-dy, a.y - box.minY), (dy, box.maxY - a.y)] {
                if p == 0 { if q < 0 { return false } else { continue } }
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return false }
            }
            return true
        }
    }

    /// The smallest box round `points`.
    static func box(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// A quadratic curve's ends and the points where it turns on either axis: its box is theirs.
    static func curveExtremes(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> [CGPoint] {
        func turn(_ a: CGFloat, _ c: CGFloat, _ b: CGFloat) -> CGFloat? {
            let d = a - 2 * c + b
            guard abs(d) > 1e-6 else { return nil }
            let t = (a - c) / d
            return t > 0 && t < 1 ? t : nil
        }
        func at(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
        return [a, b] + [turn(a.x, c.x, b.x), turn(a.y, c.y, b.y)].compactMap { $0.map(at) }
    }

    /// A quadratic curve as 24 straight pieces.
    static func curve(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> [CGPoint] {
        (0...24).map { i in
            let t = CGFloat(i) / 24, u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        }
    }

    /// The shortest distance from `p` to a line through `points`.
    static func distance(_ p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        return zip(points, points.dropFirst()).map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }.min() ?? .infinity
    }

    /// The mark moved by `d`.
    public func moved(by d: CGPoint) -> Mark {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        func r(_ r: CGRect) -> CGRect { r.offsetBy(dx: d.x, dy: d.y) }
        var copy = self
        copy.kind = switch kind {
        case .arrow(let a, let b, let c): .arrow(from: m(a), to: m(b), curved: c)
        case .rect(let x, let f): .rect(r(x), filled: f)
        case .ellipse(let x, let f): .ellipse(r(x), filled: f)
        case .text(let s, let at, let p): .text(s, at: m(at), pill: p)
        case .pen(let p): .pen(p.map(m))
        case .highlight(let p): .highlight(p.map(m))
        case .blur(let x, let p): .blur(r(x), pixelate: p)
        case .blurText(let x, let boxes, let p): .blurText(r(x), boxes: boxes.map(r), pixelate: p)
        case .box(let x, let e): .box(r(x), erase: e)
        case .step(let n, let c): .step(n, at: m(c))
        case .spotlight(let x): .spotlight(r(x))
        case .measure(let a, let b, let p): .measure(from: m(a), to: m(b), points: p)
        // The detail stays where it is in the capture: a moved lens becomes a callout pointing back to it.
        case .magnify(let lens, let focus): .magnify(r(lens), focus: focus)
        }
        return copy
    }
}

/// A capture being marked up: its marks in drawing order, an optional crop, and undo and redo. Step counters number
/// themselves 1, 2, 3 in the order they were placed, so deleting one renumbers the rest. Made on the screen it was cut
/// from (P77), the document is the screen's: the capture is `taken` inside it, and a crop past its edge uncrops.
public struct MarkupDocument: Equatable, Sendable {
    /// The picture's size in points: the capture's, or the screen's it was cut from.
    public let size: CGSize
    /// Where the capture as taken sits, in points: all of `size` without its screen.
    public let taken: CGRect
    public private(set) var marks: [Mark] = []
    /// The part kept, in points; nil keeps it as taken.
    public private(set) var crop: CGRect?
    /// The frame the export sits in; nil exports the capture bare.
    public private(set) var backdrop: Backdrop?
    private var past: [State] = []
    private var future: [State] = []
    private var nextID = 1

    private struct State: Equatable, Sendable {
        var marks: [Mark]
        var crop: CGRect?
        var backdrop: Backdrop?
    }

    /// A capture `size` big; with `taken`, the screen it was cut from, `size` being the screen's and `taken` where the
    /// capture sits in it (P77).
    public init(size: CGSize, taken: CGRect? = nil) {
        self.size = size
        self.taken = taken ?? CGRect(origin: .zero, size: size)
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    /// Whether anything was changed since it opened.
    public var edited: Bool { !marks.isEmpty || crop != nil || backdrop != nil }

    /// The part exported, in points, before any backdrop: the crop, or the capture as taken.
    public var area: CGRect { crop ?? taken }

    /// The marks drawn on `layer`.
    public func marks(on layer: Mark.Layer) -> [Mark] { marks.filter { $0.layer == layer } }

    /// The number the next step counter gets.
    public var nextStep: Int { marks.filter { if case .step = $0.kind { true } else { false } }.count + 1 }

    private mutating func record() {
        past.append(State(marks: marks, crop: crop, backdrop: backdrop))
        future = []
    }

    /// Adds a mark; its id is returned.
    @discardableResult
    public mutating func add(_ kind: Mark.Kind, colour: UInt32, size: Int, face: TextFace = .standard, layer: Mark.Layer = .capture) -> Int {
        record()
        let id = nextID
        nextID += 1
        marks.append(Mark(id: id, kind: kind, colour: colour, size: size, face: face, layer: layer))
        renumber()
        return id
    }

    /// Adds several marks as one undo step (auto-redact's covers); their ids are returned.
    @discardableResult
    public mutating func add(_ kinds: [Mark.Kind], colour: UInt32, size: Int) -> [Int] {
        guard !kinds.isEmpty else { return [] }
        record()
        let ids = kinds.map { kind in
            defer { nextID += 1 }
            marks.append(Mark(id: nextID, kind: kind, colour: colour, size: size))
            return nextID
        }
        renumber()
        return ids
    }

    /// Changes a mark in place (moved, its style or text changed) as one undo step.
    public mutating func update(_ id: Int, _ change: (inout Mark) -> Void) { update([id], change) }

    /// Changes several marks the same way (a group moved or recoloured) as one undo step.
    public mutating func update(_ ids: [Int], _ change: (inout Mark) -> Void) {
        let changed = marks.map { mark in
            guard ids.contains(mark.id) else { return mark }
            var m = mark
            change(&m)
            return m
        }
        guard changed != marks else { return }
        record()
        marks = changed
        renumber()
    }

    public mutating func delete(_ id: Int) { delete([id]) }

    /// Deletes several marks as one undo step.
    public mutating func delete(_ ids: [Int]) {
        guard marks.contains(where: { ids.contains($0.id) }) else { return }
        record()
        marks.removeAll { ids.contains($0.id) }
        renumber()
    }

    /// Crops to `rect`, held inside the picture (so past the capture's edge it uncrops, up to its screen), or back to
    /// the capture as taken with nil, or with `taken` itself.
    public mutating func setCrop(_ rect: CGRect?) {
        let kept = rect.map { $0.intersection(CGRect(origin: .zero, size: size)).integral }
        let crop = kept.flatMap { $0.width >= 4 && $0.height >= 4 && $0 != taken ? $0 : nil }
        guard crop != self.crop else { return }
        record()
        self.crop = crop
    }

    /// Frames the export, or takes the frame away with nil; one undo step.
    public mutating func setBackdrop(_ backdrop: Backdrop?) {
        guard backdrop != self.backdrop else { return }
        record()
        self.backdrop = backdrop
    }

    public mutating func undo() {
        guard let last = past.popLast() else { return }
        future.append(State(marks: marks, crop: crop, backdrop: backdrop))
        (marks, crop, backdrop) = (last.marks, last.crop, last.backdrop)
    }

    public mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(State(marks: marks, crop: crop, backdrop: backdrop))
        (marks, crop, backdrop) = (next.marks, next.crop, next.backdrop)
    }

    /// The front capture mark under `point` as drawn (Mark.hit); the editor finds backdrop marks where it shows them.
    public func mark(at point: CGPoint) -> Mark? {
        marks.last { $0.layer == .capture && $0.hit(point) }
    }

    private mutating func renumber() {
        var n = 0
        for i in marks.indices {
            if case .step(_, let at) = marks[i].kind {
                n += 1
                marks[i].kind = .step(n, at: at)
            }
        }
    }
}

/// Draws marks with Core Graphics, Core Text and Core Image, the same for the editor's canvas and the flattened file,
/// so what Sven sees is what he copies.
public enum MarkupRenderer {
    /// `image` (the capture as taken) with `document`'s marks drawn on and its crop applied, at the image's own pixels;
    /// `scale` is pixels per point. `screen` is the still the capture was cut from when the document is placed on it
    /// (P77): the marks and the crop are drawn on it, so an uncrop brings its pixels back. The backdrop's marks go on
    /// the backdrop's canvas, over the capture.
    public static func flatten(_ image: CGImage, _ document: MarkupDocument, scale: CGFloat, screen: CGImage? = nil) -> CGImage? {
        // Drawn only over the part kept, so an export holds the part's pixels and never the whole screen's.
        let source = screen ?? image, whole = CGSize(width: source.width, height: source.height), marks = document.marks(on: .capture)
        let area = CaptureSelection.pixels(document.area, scale: scale, within: whole)
        // A capture fill shows the capture as marked, so a redaction or a secure pixelate is covered there too: the
        // capture as taken is drawn with the part kept, once, and each cut from it.
        let fills = document.backdrop?.fill == .capture && !marks.isEmpty
        let taken = fills ? CaptureSelection.pixels(document.taken, scale: scale, within: whole) : .null
        let both = area.union(taken)
        guard let drawn = marked(source, marks, size: document.size, scale: scale, part: both) else { return nil }
        func cut(_ r: CGRect) -> CGImage? { r == both ? drawn : drawn.cropping(to: r.offsetBy(dx: -both.minX, dy: -both.minY)) }
        guard let kept = cut(area) else { return nil }
        guard let backdrop = document.backdrop else { return kept }
        return framed(kept, backdrop, scale: scale, capture: fills ? cut(taken) : image, marks: document.marks(on: .backdrop))
    }

    /// `part` (pixels of `source`) with `marks` drawn on, at the source's pixels; `size` is the marks' picture in points.
    private static func marked(_ source: CGImage, _ marks: [Mark], size: CGSize, scale: CGFloat, part: CGRect) -> CGImage? {
        let h = CGFloat(source.height)
        guard !part.isEmpty, let ctx = CGContext(data: nil, width: Int(part.width), height: Int(part.height), bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.translateBy(x: -part.minX, y: part.maxY - h)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(source.width), height: h))
        // Points from the top left.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: scale, y: -scale)
        draw(marks, in: ctx, image: source, scale: scale, size: size)
        return ctx.makeImage()
    }

    /// Draws `marks` into `ctx`, whose space is the capture's points from the top left (y down). `image` is the capture,
    /// for blur and erase.
    public static func draw(_ marks: [Mark], in ctx: CGContext, image: CGImage, scale: CGFloat, size: CGSize) {
        for (i, mark) in marks.enumerated() {
            ctx.saveGState()
            if case .magnify = mark.kind {
                // The lens shows what is drawn before it, and every cover after it too: a redaction is never undone
                // by a lens that came first.
                let covers = marks[(i + 1)...].filter(\.covers)
                magnify(mark, under: Array(marks[..<i]) + covers, in: ctx, image: image, scale: scale, size: size)
            } else {
                // A blur reads the pixels under it: the redacts and pixelates before it are drawn into what it reads, so
                // a blur over one never brings the secret back.
                let sealed = mark.covers && !mark.seals ? marks[..<i].filter { $0.seals && $0.bounds.intersects(mark.bounds.insetBy(dx: -CGFloat(mark.size) * 4.2, dy: -CGFloat(mark.size) * 4.2)) } : []
                draw(mark, in: ctx, image: image, scale: scale, size: size, sealed: Array(sealed))
            }
            ctx.restoreGState()
        }
    }

    static func cg(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    /// Where a curved arrow bends: off the middle, a fifth of its length to the left of the way it goes.
    public static func bend(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), dx = b.x - a.x, dy = b.y - a.y
        return CGPoint(x: mid.x + dy * 0.2, y: mid.y - dx * 0.2)
    }

    private static func draw(_ mark: Mark, in ctx: CGContext, image: CGImage, scale: CGFloat, size: CGSize, sealed: [Mark] = []) {
        let colour = cg(mark.colour)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch mark.kind {
        case .arrow(let a, let b, _):
            let width = mark.lineWidth, head = width * 3.6
            let control = mark.control
            let towards = control ?? a
            let angle = atan2(b.y - towards.y, b.x - towards.x)
            let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: cg(0, 0.18))
            ctx.setStrokeColor(colour)
            ctx.setLineWidth(width)
            ctx.move(to: a)
            if let control { ctx.addQuadCurve(to: base, control: control) } else { ctx.addLine(to: base) }
            ctx.strokePath()
            ctx.setFillColor(colour)
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x - cos(angle - 0.45) * head, y: b.y - sin(angle - 0.45) * head))
            ctx.addLine(to: CGPoint(x: b.x - cos(angle + 0.45) * head, y: b.y - sin(angle + 0.45) * head))
            ctx.closePath()
            ctx.fillPath()
        case .rect(let r, let filled), .ellipse(let r, let filled):
            let path = CGMutablePath()
            if case .rect = mark.kind { path.addRoundedRect(in: r, cornerWidth: 3, cornerHeight: 3) } else { path.addEllipse(in: r) }
            ctx.addPath(path)
            if filled {
                ctx.setFillColor(cg(mark.colour, 0.35))
                ctx.fillPath()
                ctx.addPath(path)
            }
            ctx.setStrokeColor(colour)
            ctx.setLineWidth(mark.lineWidth)
            ctx.strokePath()
        case .pen(let points):
            guard points.count > 1 else { return }
            ctx.setStrokeColor(colour)
            ctx.setLineWidth(mark.lineWidth)
            ctx.addLines(between: points)
            ctx.strokePath()
        case .highlight(let points):
            guard points.count > 1 else { return }
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(cg(mark.colour, 0.45))
            ctx.setLineCap(.butt)
            ctx.setLineWidth(mark.lineWidth * 5)
            ctx.addLines(between: points)
            ctx.strokePath()
        case .blur(let r, true): noise(over: [r], mark, in: ctx, scale: scale)
        case .blurText(_, let boxes, true): noise(over: boxes, mark, in: ctx, scale: scale)
        case .blur(let r, false):
            guard let patch = soft(image, r, strength: mark.size, scale: scale, size: size, sealed: sealed) else { return }
            drawUpright(patch, in: r, ctx)
        case .blurText(_, let boxes, false):
            // One patch under all the lines, clipped to them: a box a patch would crowd the blur cache.
            let all = boxes.reduce(CGRect.null) { $0.union($1) }
            guard !all.isNull, let patch = soft(image, all, strength: mark.size, scale: scale, size: size, sealed: sealed) else { return }
            for box in boxes {
                let corner = min(3, box.width / 2, box.height / 2)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil))
            }
            ctx.clip()
            drawUpright(patch, in: all, ctx)
        case .box(let r, let erase):
            ctx.setFillColor(erase ? cg(edgeColour(image, r, scale: scale)) : cg(0x111111))
            ctx.fill(r)
        case .step(let n, let c):
            let d = mark.stepDiameter
            let disc = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: cg(0, 0.2))
            ctx.setFillColor(colour)
            ctx.fillEllipse(in: disc)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(cg(0xFFFFFF))
            ctx.setLineWidth(d > 22 ? 2 : 1.5)
            ctx.strokeEllipse(in: disc.insetBy(dx: 1, dy: 1))
            text("\(n)", centredIn: disc, fontSize: d * 0.52, colour: cg(0xFFFFFF), ctx)
        case .text(let s, let at, let pill):
            let fs = mark.fontSize, box = mark.bounds
            if pill {
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: cg(0, 0.18))
                ctx.setFillColor(colour)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil))
                ctx.fillPath()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                text(s, centredIn: box, fontSize: fs, face: mark.face, colour: cg(0xFFFFFF), ctx)
            } else {
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: cg(0, 0.25))
                text(s, centredIn: CGRect(origin: at, size: box.size), fontSize: fs, face: mark.face, colour: colour, ctx)
            }
        case .measure(let a, let b, let points):
            ctx.setStrokeColor(colour)
            ctx.setLineWidth(1.5)
            ctx.move(to: a); ctx.addLine(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x), tick: CGFloat = 5
            for p in [a, b] {
                ctx.move(to: CGPoint(x: p.x - sin(angle) * tick, y: p.y + cos(angle) * tick))
                ctx.addLine(to: CGPoint(x: p.x + sin(angle) * tick, y: p.y - cos(angle) * tick))
            }
            ctx.strokePath()
            let label = PixelRuler.label(a, b, scale: scale, points: points), fs: CGFloat = 11
            let size = textSize(label, fontSize: fs)
            let pill = CGRect(x: (a.x + b.x) / 2 - size.width / 2 - 6, y: (a.y + b.y) / 2 - size.height / 2, width: size.width + 12, height: size.height)
            ctx.setFillColor(colour)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            ctx.fillPath()
            text(label, centredIn: pill, fontSize: fs, colour: cg(0xFFFFFF), ctx)
        case .spotlight(let r):
            ctx.setFillColor(cg(0, 0.08 * CGFloat(mark.size)))
            ctx.addRect(CGRect(origin: .zero, size: size))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath(using: .evenOdd)
        case .magnify:
            // Drawn by `draw(_:in:…)`, which hands it the marks it must show inside the lens.
            break
        }
    }

    /// A magnifier (C5): a lens with the detail zoomed, read from `image` with `under` drawn on it first, so a redact or
    /// a secure pixelate stays covered inside the lens; off its detail it rings the detail and points to it.
    private static func magnify(_ mark: Mark, under: [Mark], in ctx: CGContext, image: CGImage, scale: CGFloat, size: CGSize) {
        guard case .magnify(let lens, let focus) = mark.kind, let detail = mark.magnified, lens.width >= 2 else { return }
        let ring = cg(0xFFFFFF), edge: CGFloat = 3
        if mark.magnifierApart {
            let r = detail.width / 2, angle = atan2(lens.midY - focus.y, lens.midX - focus.x)
            // White over a dark edge, so the ring and its line read on a light capture and a dark one.
            ctx.saveGState()
            ctx.addEllipse(in: detail)
            ctx.move(to: CGPoint(x: focus.x + cos(angle) * r, y: focus.y + sin(angle) * r))
            ctx.addLine(to: CGPoint(x: lens.midX - cos(angle) * lens.width / 2, y: lens.midY - sin(angle) * lens.width / 2))
            let link = ctx.path
            for (colour, width) in [(cg(0, 0.45), CGFloat(4)), (ring, 2)] {
                ctx.addPath(link!)
                ctx.setStrokeColor(colour)
                ctx.setLineWidth(width)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: cg(0, 0.4))
        ctx.setFillColor(ring)
        ctx.fillEllipse(in: lens.insetBy(dx: -edge, dy: -edge))
        ctx.restoreGState()
        // The detail as marked, cut at the picture's edge; only the marks over it (and a spotlight, which darkens round
        // itself) are drawn.
        let part = CaptureSelection.pixels(detail, scale: scale, within: CGSize(width: image.width, height: image.height))
        let over = under.filter { if case .spotlight = $0.kind { true } else { $0.bounds.intersects(detail) } }
        if let patch = marked(image, over, size: size, scale: scale, part: part) {
            let k = lens.width / detail.width, shown = CGRect(x: part.minX / scale, y: part.minY / scale, width: part.width / scale, height: part.height / scale)
            ctx.saveGState()
            ctx.addEllipse(in: lens)
            ctx.clip()
            ctx.interpolationQuality = .none
            drawUpright(patch, in: CGRect(x: lens.minX + (shown.minX - detail.minX) * k, y: lens.minY + (shown.minY - detail.minY) * k,
                                          width: shown.width * k, height: shown.height * k), ctx)
            ctx.restoreGState()
        }
        ctx.setStrokeColor(cg(0, 0.18))
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: lens.insetBy(dx: -edge, dy: -edge))
    }

    /// Secure pixelate (C10) over `rects`: noise from the mark's seed alone, on whole pixels, drawn opaque with no edge
    /// blending, so nothing of what was under it reaches the export. Text only's lines are squared off the same way, so
    /// no edge keeps a glyph.
    private static func noise(over rects: [CGRect], _ mark: Mark, in ctx: CGContext, scale: CGFloat) {
        let lines = rects.map { r in
            let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
            return CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale)
        }
        let all = lines.reduce(CGRect.null) { $0.union($1) }
        // Cells as big as Pixelate's were at `size`, one pixel each in the patch, drawn up without smoothing.
        let cell = max(2, (CGFloat(mark.size) * scale * 1.6).rounded())
        let cols = Int((all.width * scale / cell).rounded(.up)), rows = Int((all.height * scale / cell).rounded(.up))
        guard !all.isNull, let patch = noise(cols: cols, rows: rows, seed: seed(mark)) else { return }
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none
        ctx.addRects(lines)
        ctx.clip()
        drawUpright(patch, in: CGRect(x: all.minX, y: all.minY, width: CGFloat(cols) * cell / scale, height: CGFloat(rows) * cell / scale), ctx)
    }

    /// A blur's patch over `rect`: the kept one, or with `sealed` marks under it, read from the capture round it with
    /// them drawn on (never kept: what it reads changes as they move).
    private static func soft(_ image: CGImage, _ rect: CGRect, strength: Int, scale: CGFloat, size: CGSize, sealed: [Mark]) -> CGImage? {
        guard !sealed.isEmpty else { return blurred(image, rect, strength: strength, scale: scale) }
        // Room round the rect for the blur's reach (three of its radii), so its edge reads real pixels.
        let reach = CGFloat(strength) * 4.2
        let part = CaptureSelection.pixels(rect.insetBy(dx: -reach, dy: -reach), scale: scale, within: CGSize(width: image.width, height: image.height))
        guard let around = marked(image, sealed, size: size, scale: scale, part: part) else { return nil }
        return blur(around, rect.offsetBy(dx: -part.minX / scale, dy: -part.minY / scale), strength: strength, scale: scale)
    }

    /// Made once a run, so marks keep their noise while the app is up and no two runs share it.
    private static let salt = UInt64.random(in: .min ... .max)

    /// A secure pixelate's seed: its mark's id and the run's salt, never the pixels under it.
    static func seed(_ mark: Mark) -> UInt64 { splitmix(salt ^ UInt64(truncatingIfNeeded: mark.id) &* 0x9E37_79B9_7F4A_7C15) }

    private static func splitmix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Secure pixelate's cells, `cols` × `rows`, a pixel each: a grey from `seed` and the cell's place alone. It reads no
    /// pixel of the capture, so nothing under it can be got back.
    static func noise(cols: Int, rows: Int, seed: UInt64) -> CGImage? {
        guard cols >= 1, rows >= 1 else { return nil }
        var rgba = [UInt8](repeating: 255, count: cols * rows * 4)
        for y in 0..<rows {
            for x in 0..<cols {
                let n = splitmix(seed ^ UInt64(x) << 32 ^ UInt64(y))
                let grey = 80 + Int(n & 0x7F), tint = Int(n >> 8 & 0x0F) - 8, i = (y * cols + x) * 4
                (rgba[i], rgba[i + 1], rgba[i + 2]) = (UInt8(grey + tint), UInt8(grey), UInt8(grey - tint))
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// `image` drawn into `rect` of a top-left space without flipping it.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// The capture's pixels under `rect` (points), blurred; strength 1 to 10 (Pixelate draws noise instead, C10). Kept for the next redraw, as
    /// the editor's canvas draws every mark on every change.
    public static func blurred(_ image: CGImage, _ rect: CGRect, strength: Int, scale: CGFloat) -> CGImage? {
        let key = BlurCache.Key(image: ObjectIdentifier(image), rect: rect, strength: strength, scale: scale)
        if let kept = cache.get(key) { return kept }
        let made = blur(image, rect, strength: strength, scale: scale)
        if let made { cache.put(key, made) }
        return made
    }

    private static let cache = BlurCache()

    /// Drops every kept patch: an editor opening or closing calls it, so a later capture at the same memory address never
    /// gets an earlier capture's pixels.
    public static func forgetBlurs() { cache.clear() }

    private static func blur(_ image: CGImage, _ rect: CGRect, strength: Int, scale: CGFloat) -> CGImage? {
        let px = CGRect(x: rect.minX * scale, y: CGFloat(image.height) - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard px.width >= 1, px.height >= 1 else { return nil }
        let source = CIImage(cgImage: image).clampedToExtent()
        let filtered = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, CGFloat(strength) * scale * 1.4)])
        return context.createCGImage(filtered, from: px)
    }

    nonisolated(unsafe) static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The colour most common along `rect`'s edge (points): the background an erase fills with.
    public static func edgeColour(_ image: CGImage, _ rect: CGRect, scale: CGFloat) -> UInt32 {
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
            .insetBy(dx: -1, dy: -1).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard px.width >= 2, px.height >= 2, let cut = image.cropping(to: px) else { return 0xFFFFFF }
        let w = cut.width, h = cut.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0xFFFFFF }
        ctx.draw(cut, in: CGRect(x: 0, y: 0, width: w, height: h))
        var counts: [UInt32: Int] = [:]
        func add(_ x: Int, _ y: Int) {
            let i = (y * w + x) * 4
            counts[UInt32(rgba[i]) << 16 | UInt32(rgba[i + 1]) << 8 | UInt32(rgba[i + 2]), default: 0] += 1
        }
        for x in 0..<w { add(x, 0); add(x, h - 1) }
        for y in 0..<h { add(0, y); add(w - 1, y) }
        return counts.max { $0.value < $1.value }?.key ?? 0xFFFFFF
    }

    /// A text's size in `face` (the editor's bold system face by default) at `fontSize`.
    public static func textSize(_ s: String, fontSize: CGFloat, face: TextFace = .standard) -> CGSize {
        let line = CTLineCreateWithAttributedString(attributed(s.isEmpty ? " " : s, fontSize: fontSize, face: face, colour: cg(0)))
        let b = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGSize(width: ceil(b), height: ceil(fontSize * 1.3))
    }

    private static func attributed(_ s: String, fontSize: CGFloat, face: TextFace, colour: CGColor) -> CFAttributedString {
        NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): face.font(fontSize),
                                                   NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour])
    }

    /// One line of text centred in `box` of a top-left space.
    private static func text(_ s: String, centredIn box: CGRect, fontSize: CGFloat, face: TextFace = .standard, colour: CGColor, _ ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(attributed(s, fontSize: fontSize, face: face, colour: colour))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: box.midX - width / 2, y: box.midY + (ascent - descent) / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// The last few blurred patches, shared by the canvas and the export; any thread.
final class BlurCache: @unchecked Sendable {
    struct Key: Hashable {
        let image: ObjectIdentifier
        let rect: CGRect
        let strength: Int
        let scale: CGFloat

        func hash(into h: inout Hasher) {
            h.combine(image); h.combine(rect.minX); h.combine(rect.minY); h.combine(rect.width); h.combine(rect.height)
            h.combine(strength); h.combine(scale)
        }
    }

    private let lock = NSLock()
    private var kept: [Key: CGImage] = [:]
    private var order: [Key] = []

    func get(_ key: Key) -> CGImage? { lock.withLock { kept[key] } }

    func clear() { lock.withLock { kept = [:]; order = [] } }

    func put(_ key: Key, _ image: CGImage) {
        lock.withLock {
            if kept.updateValue(image, forKey: key) == nil { order.append(key) }
            while order.count > 24 { kept[order.removeFirst()] = nil }
        }
    }
}

/// A text mark's face (Sven after build 82: font, size, bold, italic), from the Mac's own faces, so nothing is bundled.
public struct TextFace: Equatable, Hashable, Sendable {
    public enum Family: String, CaseIterable, Sendable {
        case system, rounded, serif, mono, marker

        public var name: String {
            switch self {
            case .system: "System"
            case .rounded: "Rounded"
            case .serif: "Serif"
            case .mono: "Mono"
            case .marker: "Marker"
            }
        }
    }

    public var family: Family
    /// Its points, 10 to 120; nil takes them from the mark's 1 to 10 size, as text was before it had a face.
    public var points: CGFloat?
    public var bold: Bool
    public var italic: Bool

    public init(family: Family = .system, points: CGFloat? = nil, bold: Bool = true, italic: Bool = false) {
        self.family = family
        self.points = points.map(Self.held)
        self.bold = bold
        self.italic = italic
    }

    /// Bold system text, the face every text had before.
    public static let standard = TextFace()
    public static let range: ClosedRange<CGFloat> = 10...120

    public static func held(_ points: CGFloat) -> CGFloat { min(range.upperBound, max(range.lowerBound, points.rounded())) }

    /// The face at `size` points: SF Pro, its rounded and New York designs, SF Mono, Marker Felt; italic where the face has one.
    public func font(_ size: CGFloat) -> CTFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        var font: NSFont = switch family {
        case .system: system
        case .rounded: system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .serif: system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .mono: NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .marker: NSFont(name: bold ? "MarkerFelt-Wide" : "MarkerFelt-Thin", size: size) ?? system
        }
        if italic, let slanted = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: size) {
            font = slanted
        }
        return font as CTFont
    }
}

/// The smooth pen (C6, Sven Q805): a freehand line made neat, the hand's shake averaged out, the turns it meant kept,
/// then rounded.
public enum Smoothing {
    public static func stroke(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        // Points under a point apart say nothing but the shake.
        var kept = [points[0]]
        for p in points.dropFirst() where hypot(p.x - kept.last!.x, p.y - kept.last!.y) >= 1 { kept.append(p) }
        if kept.last != points.last { kept.append(points.last!) }
        guard kept.count > 2 else { return kept }
        // Each point averaged with two either side, the ends where they were.
        let n = kept.count
        let averaged = (0..<n).map { i -> CGPoint in
            guard i > 0, i < n - 1 else { return kept[i] }
            let near = kept[max(0, i - 2)...min(n - 1, i + 2)]
            return CGPoint(x: near.reduce(0) { $0 + $1.x } / CGFloat(near.count), y: near.reduce(0) { $0 + $1.y } / CGFloat(near.count))
        }
        // The fewest points that stay within ¾ of a point of the line, then each corner cut twice (Chaikin).
        var line = simplified(averaged, within: 0.75)
        for _ in 0..<2 where line.count > 2 {
            var cut = [line[0]]
            for (a, b) in zip(line, line.dropFirst()) {
                cut.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                cut.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            cut.append(line[line.count - 1])
            line = cut
        }
        return line
    }

    /// Ramer–Douglas–Peucker: the points a line through `points` needs to stay within `within` of it.
    static func simplified(_ points: [CGPoint], within: CGFloat) -> [CGPoint] {
        guard points.count > 2, let a = points.first, let b = points.last else { return points }
        var far = 0, most: CGFloat = 0
        for i in 1..<(points.count - 1) {
            let d = Mark.distance(points[i], toPolyline: [a, b])
            if d > most { most = d; far = i }
        }
        guard most > within else { return [a, b] }
        return simplified(Array(points[...far]), within: within).dropLast() + simplified(Array(points[far...]), within: within)
    }
}

/// Snap edges (C3, Sven Q805): the long straight edges in a picture, a window's, a card's or a panel's side, for a crop
/// to snap to. Read on a copy at most `longest` pixels a side, off the main thread.
public enum SnapEdges {
    /// The edges as fractions of the picture's width (`xs`) and height (`ys`): where the grey changes across a column or
    /// a row for a long run, a short gap allowed.
    public static func lines(_ image: CGImage, longest: Int = 1000) -> (xs: [CGFloat], ys: [CGFloat]) {
        let k = min(1, CGFloat(longest) / CGFloat(max(image.width, image.height, 1)))
        let w = max(3, Int(CGFloat(image.width) * k)), h = max(3, Int(CGFloat(image.height) * k))
        var grey = [UInt8](repeating: 0, count: w * h)
        let drawn = grey.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return ([], []) }
        // The buffer's first row is the picture's top, as PixelGrid reads it.
        func at(_ x: Int, _ y: Int) -> Int { Int(grey[y * w + x]) }
        func runs(count: Int, along: Int, step: (Int, Int) -> Int) -> [Int] {
            let least = max(16, along / 12)
            var found: [Int] = []
            for i in 1..<(count - 1) {
                var run = 0, best = 0, missed = 0
                for j in 0..<along {
                    if abs(step(i, j)) > 10 { run += 1; missed = 0; best = max(best, run) } else if run > 0, missed < 2 { missed += 1 } else { run = 0; missed = 0 }
                }
                if best >= least, found.last.map({ i - $0 > 1 }) ?? true { found.append(i) }
            }
            return found
        }
        let xs = runs(count: w, along: h) { x, y in at(x + 1, y) - at(x - 1, y) }
        let ys = runs(count: h, along: w) { y, x in at(x, y + 1) - at(x, y - 1) }
        return (xs.map { CGFloat($0) / CGFloat(w) }, ys.map { CGFloat($0) / CGFloat(h) })
    }

    /// The line in `lines` nearest `v` within `reach`, nil with none.
    public static func nearest(_ v: CGFloat, in lines: [CGFloat], within reach: CGFloat) -> CGFloat? {
        var best: CGFloat?, gap = reach
        for line in lines where abs(line - v) <= gap { (best, gap) = (line, abs(line - v)) }
        return best
    }
}
