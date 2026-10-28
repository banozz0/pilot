import AppKit
import PilotCore
import SwiftUI

/// A key's outline: the theme's rounded rectangle, or with a notch ISO's Return, the full width for `upper` points, then
/// narrower by `step` on the left down to the foot.
struct KeyShape: InsettableShape {
    struct Notch {
        let step: CGFloat
        let upper: CGFloat
    }
    let radius: CGFloat
    var notch: Notch?
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        guard let notch else { return RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: inset).path(in: rect) }
        let r = rect.insetBy(dx: inset, dy: inset)
        let stepX = r.minX + notch.step, stepY = r.minY + notch.upper - inset * 2
        let rad = min(radius, notch.step / 2, notch.upper / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + rad), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: stepX + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: stepX, y: r.maxY - rad), control: CGPoint(x: stepX, y: r.maxY))
        p.addLine(to: CGPoint(x: stepX, y: stepY + rad))
        p.addQuadCurve(to: CGPoint(x: stepX - rad, y: stepY), control: CGPoint(x: stepX, y: stepY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: stepY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: stepY - rad), control: CGPoint(x: r.minX, y: stepY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> KeyShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}
