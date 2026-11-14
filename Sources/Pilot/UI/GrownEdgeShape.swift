import SwiftUI

/// Attached's outline, the dock's and the top bar islands' (Sven on build 2479, 2026-11-14, W52 Q220: the straight join
/// read as a box glued to the edge; his references flare into it): a pill that grows out of a screen edge. Its corners
/// away from the edge are round (`radius`); where its sides meet the edge they flare out through concave fillets
/// (`flare`, inverted radii) and run into the edge, so the ground and the edge are one surface. The pill's body is the
/// rect less `flare` on each side: a view drawing it gives it that much room past its content. With no edge it is a
/// plain rounded rectangle, Floating's.
struct GrownEdgeShape: InsettableShape {
    enum Edge: Sendable { case top, bottom }

    var edge: Edge?
    var radius: CGFloat
    var flare: CGFloat
    var style: RoundedCornerStyle = .continuous
    private var inset: CGFloat = 0

    init(edge: Edge?, radius: CGFloat, flare: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.edge = edge; self.radius = radius; self.flare = edge == nil ? 0 : flare; self.style = style
    }

    /// The flare for a pill of corner `radius` with `room` free beside it: as round as its corners, 16 at most, never into
    /// a neighbour.
    static func flare(radius: CGFloat, room: CGFloat = .infinity) -> CGFloat { max(0, min(radius, 16, room)) }

    func inset(by amount: CGFloat) -> GrownEdgeShape {
        var shape = self
        shape.inset += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        guard let edge else {
            return RoundedRectangle(cornerRadius: max(0, radius - inset), style: style).path(in: rect.insetBy(dx: inset, dy: inset))
        }
        // Drawn against the bottom edge, y down, then turned over for the top edge. The edge side is never inset: its
        // ring is the screen's, cut away by the views that stroke it.
        let w = rect.width, h = rect.height, a = inset, f = flare
        let r = max(0, min(radius - a, (w - 2 * (f + a)) / 2, h - a))
        let k: CGFloat = 0.5523   // a quarter circle as one cubic
        var p = Path()
        let left = f + a, right = w - f - a, top = a
        p.move(to: CGPoint(x: a, y: h))
        if f > 0 {
            // The left fillet: from the edge up into the body's side, scooped (its centre outside the shape).
            p.addCurve(to: CGPoint(x: left, y: h - f), control1: CGPoint(x: a + k * f, y: h), control2: CGPoint(x: left, y: h - f + k * f))
        }
        p.addLine(to: CGPoint(x: left, y: top + r))
        p.addCurve(to: CGPoint(x: left + r, y: top), control1: CGPoint(x: left, y: top + r - k * r), control2: CGPoint(x: left + r - k * r, y: top))
        p.addLine(to: CGPoint(x: right - r, y: top))
        p.addCurve(to: CGPoint(x: right, y: top + r), control1: CGPoint(x: right - r + k * r, y: top), control2: CGPoint(x: right, y: top + r - k * r))
        p.addLine(to: CGPoint(x: right, y: h - f))
        if f > 0 {
            p.addCurve(to: CGPoint(x: w - a, y: h), control1: CGPoint(x: right, y: h - f + k * f), control2: CGPoint(x: w - a - k * f, y: h))
        }
        p.closeSubpath()
        let turned = edge == .top ? p.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)) : p
        return turned.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

extension View {
    /// An attached outline's ring leaves out the edge it grows from: that edge is the screen's.
    @ViewBuilder func edgeRingCut(_ edge: GrownEdgeShape.Edge?, width: CGFloat) -> some View {
        switch edge {
        case nil: self
        case .top: mask { VStack(spacing: 0) { Color.clear.frame(height: max(1, width) + 0.5); Color.black } }
        case .bottom: mask { VStack(spacing: 0) { Color.black; Color.clear.frame(height: max(1, width) + 0.5) } }
        }
    }
}
