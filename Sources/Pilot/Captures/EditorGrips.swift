import CoreGraphics
import PilotCore
import SwiftUI

/// A handle on the picked mark or the crop (Sven after build 82, the designer's mock): a box's eight, a line's two ends.
/// `box(x, y)` names the edges it moves, -1 the left or top, 1 the right or bottom, 0 neither; `box(0, 0)` moves the
/// whole box (a drag inside the crop). `bend` sits on an arrow's middle and curves it (C4); `focus` sits on the detail a
/// magnifier shows and moves it (C5).
enum Grip: Equatable {
    case box(Int, Int)
    case start, end, bend, focus

    static let eight: [Grip] = [.box(-1, -1), .box(0, -1), .box(1, -1), .box(1, 0), .box(1, 1), .box(0, 1), .box(-1, 1), .box(-1, 0)]
    static let corners: [Grip] = [.box(-1, -1), .box(1, -1), .box(1, 1), .box(-1, 1)]

    /// How far the frame round a picked mark sits off it, in the capture's points: far enough that a drag on a shape's
    /// edge moves it and only the dots resize it.
    static let frameGap: CGFloat = 6
    /// How near a press must be to a handle, in screen points.
    static let reach: CGFloat = 6

    /// Where this grip sits on `r`.
    func point(on r: CGRect) -> CGPoint {
        guard case .box(let x, let y) = self else { return .zero }
        return CGPoint(x: x < 0 ? r.minX : x > 0 ? r.maxX : r.midX, y: y < 0 ? r.minY : y > 0 ? r.maxY : r.midY)
    }

    /// The frame drawn round a picked mark, the handles on it.
    static func frame(of mark: Mark) -> CGRect { mark.bounds.insetBy(dx: -frameGap, dy: -frameGap) }

    /// The picked mark's handles and where they are: a box's eight, a line's two ends (an arrow's middle too), a text's
    /// four corners, a magnifier's lens's corners and its detail; none for a pen, a highlight, a step or a Text only
    /// blur, which only move.
    static func grips(of mark: Mark) -> [(grip: Grip, at: CGPoint)] {
        switch mark.kind {
        case .arrow(let a, let b, _): return [(.start, a), (.end, b), (.bend, mark.arrowMiddle)]
        case .measure(let a, let b, _): return [(.start, a), (.end, b)]
        case .magnify(let lens, let focus):
            let f = lens.insetBy(dx: -frameGap, dy: -frameGap)
            // The detail's handle shows once the lens is off it: on it, a drag on the lens moves the lens.
            return corners.map { ($0, $0.point(on: f)) } + (mark.magnifierApart ? [(.focus, focus)] : [])
        case .rect, .ellipse, .blur, .box, .spotlight: let f = frame(of: mark); return eight.map { ($0, $0.point(on: f)) }
        case .text: let f = frame(of: mark); return corners.map { ($0, $0.point(on: f)) }
        case .pen, .highlight, .step, .blurText: return []
        }
    }

    /// The crop's handles, on its edge.
    static func grips(ofCrop r: CGRect) -> [(grip: Grip, at: CGPoint)] { eight.map { ($0, $0.point(on: r)) } }

    /// The grip in `grips` nearest `p` within `reach` capture points.
    static func nearest(_ grips: [(grip: Grip, at: CGPoint)], to p: CGPoint, reach: CGFloat) -> Grip? {
        grips.map { ($0.grip, hypot($0.at.x - p.x, $0.at.y - p.y)) }.filter { $0.1 <= reach }.min { $0.1 < $1.1 }?.0
    }

    /// `r` with this grip's edges moved by `d`: Shift keeps a corner's proportions, Option moves the opposite edge too.
    func resize(_ r: CGRect, by d: CGPoint, keepRatio: Bool = false, fromCentre: Bool = false) -> CGRect {
        guard case .box(let x, let y) = self else { return r }
        if x == 0 && y == 0 { return r.offsetBy(dx: d.x, dy: d.y) }
        let k: CGFloat = fromCentre ? 1 : 0
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if x < 0 { minX += d.x; maxX -= d.x * k } else if x > 0 { maxX += d.x; minX -= d.x * k }
        if y < 0 { minY += d.y; maxY -= d.y * k } else if y > 0 { maxY += d.y; minY -= d.y * k }
        let out = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        guard keepRatio, x != 0, y != 0, r.width > 0, r.height > 0 else { return out }
        let s = max(out.width / r.width, out.height / r.height), w = r.width * s, h = r.height * s
        if fromCentre { return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h) }
        return CGRect(x: x > 0 ? r.minX : r.maxX - w, y: y > 0 ? r.minY : r.maxY - h, width: w, height: h)
    }

    /// The pointer over this grip: a resize arrow along the edges it moves, a grab hand on a line's end.
    var pointer: PointerStyle {
        switch self {
        case .start, .end, .bend, .focus: .grabIdle
        case .box(let x, let y): .frameResize(position: Self.position(x, y))
        }
    }

    private static func position(_ x: Int, _ y: Int) -> FrameResizePosition {
        switch (x, y) {
        case (-1, -1): .topLeading
        case (0, -1): .top
        case (1, -1): .topTrailing
        case (1, 0): .trailing
        case (1, 1): .bottomTrailing
        case (0, 1): .bottom
        case (-1, 1): .bottomLeading
        default: .leading
        }
    }
}

extension Mark {
    /// The tool that draws this kind of mark, for the footer's options while it is picked.
    var tool: MarkTool {
        switch kind {
        case .arrow: .arrow
        case .rect: .rect
        case .ellipse: .ellipse
        case .text: .text
        case .pen: .pen
        case .highlight: .highlighter
        case .blur, .blurText: .blur
        case .box: .box
        case .step: .step
        case .spotlight: .spotlight
        case .measure: .ruler
        case .magnify: .spotlight
        }
    }

    /// Where an arrow's curve passes half way, the bend handle's place: the middle of a straight one.
    var arrowMiddle: CGPoint {
        guard case .arrow(let a, let b, _) = kind else { return .zero }
        let c = control ?? CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return CGPoint(x: 0.25 * a.x + 0.5 * c.x + 0.25 * b.x, y: 0.25 * a.y + 0.5 * c.y + 0.25 * b.y)
    }

    /// What guides line up (C7): a shape's own box, a line's two ends, a magnifier's lens, a text's or a step's box;
    /// nil for a pen or a highlight, whose shape has no edge to line up.
    var guideFrame: CGRect? {
        switch kind {
        case .arrow(let a, let b, _), .measure(let a, let b, _): CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .rect(let r, _), .ellipse(let r, _), .blur(let r, _), .box(let r, _), .spotlight(let r), .blurText(let r, _, _), .magnify(let r, _): r
        case .text, .step: bounds
        case .pen, .highlight: nil
        }
    }

    var isText: Bool { if case .text = kind { true } else { false } }

    /// The mark with `grip` dragged by `d`: a box's edges move, a line's end moves, and a text's corner scales its points
    /// with the opposite corner kept where it was.
    func resized(_ grip: Grip, by d: CGPoint, keepRatio: Bool = false, fromCentre: Bool = false) -> Mark {
        var m = self
        func r(_ x: CGRect) -> CGRect { grip.resize(x, by: d, keepRatio: keepRatio, fromCentre: fromCentre) }
        func moved(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        switch (kind, grip) {
        case (.arrow(let a, let b, let c), .start): m.kind = .arrow(from: moved(a), to: b, curved: c)
        case (.arrow(let a, let b, let c), .end): m.kind = .arrow(from: a, to: moved(b), curved: c)
        case (.measure(let a, let b, let p), .start): m.kind = .measure(from: moved(a), to: b, points: p)
        case (.measure(let a, let b, let p), .end): m.kind = .measure(from: a, to: moved(b), points: p)
        case (.arrow(let a, let b, _), .bend):
            // The curve's middle follows the pointer: its control sits twice as far off the ends' middle. Brought back
            // near the straight line, the arrow is straight again.
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), at = moved(arrowMiddle)
            let bend = CGPoint(x: 2 * (at.x - mid.x), y: 2 * (at.y - mid.y))
            let straight = hypot(bend.x, bend.y) < 4
            m.kind = .arrow(from: a, to: b, curved: !straight)
            m.bend = straight ? nil : bend
        case (.magnify(let lens, let focus), .box(let gx, let gy)) where gx != 0 && gy != 0:
            // The lens stays round: its corners scale it.
            m.kind = .magnify(grip.resize(lens, by: d, keepRatio: true, fromCentre: fromCentre), focus: focus)
        case (.magnify(let lens, let focus), .focus): m.kind = .magnify(lens, focus: moved(focus))
        case (.rect(let x, let f), .box): m.kind = .rect(r(x), filled: f)
        case (.ellipse(let x, let f), .box): m.kind = .ellipse(r(x), filled: f)
        case (.blur(let x, let p), .box): m.kind = .blur(r(x), pixelate: p)
        case (.box(let x, let e), .box): m.kind = .box(r(x), erase: e)
        case (.spotlight(let x), .box): m.kind = .spotlight(r(x))
        case (.text(let s, _, let pill), .box(let gx, let gy)) where gx != 0 && gy != 0:
            let b = bounds
            guard b.width > 0, b.height > 0 else { return self }
            // The axis dragged further sets the scale, so a sideways drag grows the text too.
            let kw = (b.width + CGFloat(gx) * d.x) / b.width, kh = (b.height + CGFloat(gy) * d.y) / b.height
            let k = max(0.05, abs(kw - 1) > abs(kh - 1) ? kw : kh)
            m.face.points = TextFace.held(fontSize * k)
            let grown = m.bounds.size
            m.kind = .text(s, at: CGPoint(x: gx > 0 ? b.minX : b.maxX - grown.width, y: gy > 0 ? b.minY : b.maxY - grown.height), pill: pill)
        default: break
        }
        return m
    }
}
