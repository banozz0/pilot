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

/// One mark on a capture, in the capture's points from its top left.
public struct Mark: Equatable, Sendable, Identifiable {
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
    }

    public let id: Int
    public var kind: Kind
    /// 0xRRGGBB.
    public var colour: UInt32
    /// 1 to 10, the footer's slider: a line's width, a blur's strength, a step's size, a spotlight's darkness.
    public var size: Int
    /// A text's face (Sven after build 82): its font, points, bold and italic; the other kinds ignore it.
    public var face: TextFace

    public init(id: Int, kind: Kind, colour: UInt32, size: Int, face: TextFace = .standard) {
        self.id = id
        self.kind = kind
        self.colour = colour
        self.size = min(10, max(1, size))
        self.face = face
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
        case .arrow(let a, let b, _), .measure(let a, let b, _):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -pad - 8, dy: -pad - 8)
        case .rect(let r, _), .ellipse(let r, _): return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .blur(let r, _), .box(let r, _), .spotlight(let r), .blurText(let r, _, _): return r
        case .pen(let p), .highlight(let p):
            guard let first = p.first else { return .null }
            let r = p.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            return r.insetBy(dx: -pad * (kindIsHighlight ? 3 : 1), dy: -pad * (kindIsHighlight ? 3 : 1))
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
        case .arrow(let a, let b, let curved):
            let head = lineWidth * 3.6
            if hypot(p.x - b.x, p.y - b.y) <= head + 2 { return true }
            let path = curved ? Self.curve(a, MarkupRenderer.bend(a, b), b) : [a, b]
            return Self.distance(p, toPolyline: path) <= slack
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
        case .arrow(let a, let b, let curved):
            let head = lineWidth * 3.6
            if near.insetBy(dx: -head, dy: -head).contains(b) { return true }
            return Self.crosses(curved ? Self.curve(a, MarkupRenderer.bend(a, b), b) : [a, b], near)
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
        }
        return copy
    }
}

/// A capture being marked up: its marks in drawing order, an optional crop, and undo and redo. Step counters number
/// themselves 1, 2, 3 in the order they were placed, so deleting one renumbers the rest.
public struct MarkupDocument: Equatable, Sendable {
    /// The capture's size in points.
    public let size: CGSize
    public private(set) var marks: [Mark] = []
    /// The part kept, in points; nil keeps it whole.
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

    public init(size: CGSize) { self.size = size }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    /// Whether anything was changed since it opened.
    public var edited: Bool { !marks.isEmpty || crop != nil || backdrop != nil }

    /// The part exported, in points, before any backdrop: the crop, or the whole capture.
    public var area: CGRect { crop ?? CGRect(origin: .zero, size: size) }

    /// The number the next step counter gets.
    public var nextStep: Int { marks.filter { if case .step = $0.kind { true } else { false } }.count + 1 }

    private mutating func record() {
        past.append(State(marks: marks, crop: crop, backdrop: backdrop))
        future = []
    }

    /// Adds a mark; its id is returned.
    @discardableResult
    public mutating func add(_ kind: Mark.Kind, colour: UInt32, size: Int, face: TextFace = .standard) -> Int {
        record()
        let id = nextID
        nextID += 1
        marks.append(Mark(id: id, kind: kind, colour: colour, size: size, face: face))
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

    /// Crops to `rect` (inside the capture), or back to the whole with nil.
    public mutating func setCrop(_ rect: CGRect?) {
        let kept = rect.map { $0.intersection(CGRect(origin: .zero, size: size)).integral }
        let crop = kept.flatMap { $0.width >= 4 && $0.height >= 4 ? $0 : nil }
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

    /// The front mark under `point` as drawn (Mark.hit), for the select tool.
    public func mark(at point: CGPoint) -> Mark? {
        marks.last { $0.hit(point) }
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
    /// `image` with `document`'s marks drawn on and its crop applied, at the image's own pixels; `scale` is pixels per
    /// point.
    public static func flatten(_ image: CGImage, _ document: MarkupDocument, scale: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Points from the top left.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(document.marks, in: ctx, image: image, scale: scale, size: document.size)
        guard let whole = ctx.makeImage() else { return nil }
        let cut = document.crop.flatMap { crop in
            whole.cropping(to: CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral)
        } ?? whole
        guard let backdrop = document.backdrop else { return cut }
        return framed(cut, backdrop, scale: scale, capture: image)
    }

    /// Draws `marks` into `ctx`, whose space is the capture's points from the top left (y down). `image` is the capture,
    /// for blur and erase.
    public static func draw(_ marks: [Mark], in ctx: CGContext, image: CGImage, scale: CGFloat, size: CGSize) {
        for mark in marks {
            ctx.saveGState()
            draw(mark, in: ctx, image: image, scale: scale, size: size)
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

    private static func draw(_ mark: Mark, in ctx: CGContext, image: CGImage, scale: CGFloat, size: CGSize) {
        let colour = cg(mark.colour)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch mark.kind {
        case .arrow(let a, let b, let curved):
            let width = mark.lineWidth, head = width * 3.6
            let control = bend(a, b)
            let towards = curved ? control : a
            let angle = atan2(b.y - towards.y, b.x - towards.x)
            let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: cg(0, 0.18))
            ctx.setStrokeColor(colour)
            ctx.setLineWidth(width)
            ctx.move(to: a)
            if curved { ctx.addQuadCurve(to: base, control: control) } else { ctx.addLine(to: base) }
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
        case .blur(let r, let pixelate):
            guard let patch = blurred(image, r, pixelate: pixelate, strength: mark.size, scale: scale) else { return }
            drawUpright(patch, in: r, ctx)
        case .blurText(_, let boxes, let pixelate):
            // One patch under all the lines, clipped to them: a box a patch would crowd the blur cache.
            let all = boxes.reduce(CGRect.null) { $0.union($1) }
            guard !all.isNull, let patch = blurred(image, all, pixelate: pixelate, strength: mark.size, scale: scale) else { return }
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
        }
    }

    /// `image` drawn into `rect` of a top-left space without flipping it.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// The capture's pixels under `rect` (points), blurred or pixelated; strength 1 to 10. Kept for the next redraw, as
    /// the editor's canvas draws every mark on every change.
    public static func blurred(_ image: CGImage, _ rect: CGRect, pixelate: Bool, strength: Int, scale: CGFloat) -> CGImage? {
        let key = BlurCache.Key(image: ObjectIdentifier(image), rect: rect, pixelate: pixelate, strength: strength, scale: scale)
        if let kept = cache.get(key) { return kept }
        let made = blur(image, rect, pixelate: pixelate, strength: strength, scale: scale)
        if let made { cache.put(key, made) }
        return made
    }

    private static let cache = BlurCache()

    /// Drops every kept patch: an editor opening or closing calls it, so a later capture at the same memory address never
    /// gets an earlier capture's pixels.
    public static func forgetBlurs() { cache.clear() }

    private static func blur(_ image: CGImage, _ rect: CGRect, pixelate: Bool, strength: Int, scale: CGFloat) -> CGImage? {
        let px = CGRect(x: rect.minX * scale, y: CGFloat(image.height) - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard px.width >= 1, px.height >= 1 else { return nil }
        let source = CIImage(cgImage: image).clampedToExtent()
        let amount = CGFloat(strength) * scale
        let filtered = pixelate
            ? source.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(2, amount * 1.6), kCIInputCenterKey: CIVector(x: px.minX, y: px.minY)])
            : source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, amount * 1.4)])
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
        let pixelate: Bool
        let strength: Int
        let scale: CGFloat

        func hash(into h: inout Hasher) {
            h.combine(image); h.combine(rect.minX); h.combine(rect.minY); h.combine(rect.width); h.combine(rect.height)
            h.combine(pixelate); h.combine(strength); h.combine(scale)
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
