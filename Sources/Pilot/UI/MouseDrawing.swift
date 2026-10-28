import PilotCore
import SwiftUI

/// Binds › Mouse's mouse (Q223, Q257): a generic mouse drawn from the top and from its left side, as NGenuity's Buttons tab
/// shows one, with no maker's art. Every button Pilot binds (3 to 5) carries a label with a line to it, saying what it
/// runs, so the drawing reads like the mouse app's own button map; a click on the button or its label starts the page's
/// one flow. The main clicks are drawn but stay the clicks: the button tap hears only buttons 3 and up, and the keyboard
/// tap's mask never gains the mouse (typing-lag rule).
struct MouseDrawing: View {
    @Environment(\.ink) private var ink
    /// What a drawn button's label says: its action (nil: not bound) and what it sends when that is a key (a media key, Esc).
    struct Label: Equatable {
        var action: String?, sends: String?
    }
    /// Each drawn button's label, by number (3 the wheel click).
    let labels: [Int: Label]
    /// The button the catch waits on: it pulses and its label says Press it now.
    var waiting: Int?
    /// The button picked, lit.
    var lit: Int?
    let click: (Int) -> Void
    @State private var hovered: Int?

    static let top = CGSize(width: 150, height: 232), side = CGSize(width: 270, height: 138)
    /// The drawing's own space: the top view on the left, the side view lower right, the labels above it.
    static let canvas = CGSize(width: 520, height: 302)
    static let topAt = CGPoint(x: 0, y: 50), sideAt = CGPoint(x: 240, y: 140)

    /// Each bound button's label: where it sits, and the point on its button the line runs to.
    static let chips: [(button: Int, frame: CGRect, anchor: CGPoint)] = [
        (3, CGRect(x: 172, y: 6, width: 150, height: 40), CGPoint(x: topAt.x + 0.56 * top.width, y: topAt.y + 0.2 * top.height)),
        (5, CGRect(x: 172, y: 76, width: 166, height: 40), CGPoint(x: sideAt.x + 0.335 * side.width, y: sideAt.y + 0.36 * side.height)),
        (4, CGRect(x: 346, y: 76, width: 172, height: 40), CGPoint(x: sideAt.x + 0.545 * side.width, y: sideAt.y + 0.33 * side.height)),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.chips, id: \.button) { leader($0.button, from: $0.frame, to: $0.anchor) }
            views
            ForEach(Self.chips, id: \.button) { chip($0.button, at: $0.frame) }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
    }

    /// The mouse from the top and from its left side.
    @ViewBuilder private var views: some View {
        VStack(spacing: 8) {
            ZStack {
                Self.outline(in: CGRect(origin: .zero, size: Self.top)).fill(ink.surface)
                Self.outline(in: CGRect(origin: .zero, size: Self.top)).stroke(ink.line2, lineWidth: ink.stroke)
                mainClick(1); mainClick(2); spot(3)
            }
            .frame(width: Self.top.width, height: Self.top.height)
            caption("Top")
        }
        .offset(x: Self.topAt.x, y: Self.topAt.y)
        VStack(spacing: 8) {
            ZStack {
                Self.profile(in: CGRect(origin: .zero, size: Self.side)).fill(ink.surface)
                Self.profile(in: CGRect(origin: .zero, size: Self.side)).stroke(ink.line2, lineWidth: ink.stroke)
                Self.thumbRest(in: CGRect(origin: .zero, size: Self.side)).stroke(ink.line, lineWidth: ink.stroke)
                spot(5); spot(4)
            }
            .frame(width: Self.side.width, height: Self.side.height)
            caption("Left side")
        }
        .offset(x: Self.sideAt.x, y: Self.sideAt.y)
    }

    // MARK: Buttons

    private enum State { case idle, bound, lit, waiting }

    private func state(_ n: Int) -> State {
        if waiting == n { return .waiting }
        if lit == n || hovered == n { return .lit }
        return labels[n]?.action != nil ? .bound : .idle
    }

    /// A state's line colour: the drawn button's edge, its leader and its label's border.
    private func tint(_ state: State) -> Color {
        switch state {
        case .idle: ink.line2
        case .bound: ink.accent.opacity(0.6)
        case .lit, .waiting: ink.accent
        }
    }

    /// A main click: drawn, never clickable, so clicking always works.
    private func mainClick(_ n: Int) -> some View {
        Spot(number: n).fill(ink.tile.opacity(0.55))
            .accessibilityElement().accessibilityLabel(n == 1 ? "Left click" : "Right click")
            .accessibilityValue("The main click; Pilot leaves it alone")
    }

    private func spot(_ n: Int) -> some View {
        let shape = Spot(number: n)
        let frame = n == 3 ? Self.top : Self.side
        let badge = shape.path(in: CGRect(origin: .zero, size: frame)).boundingRect
        let state = state(n)
        return Button { click(n) } label: {
            ZStack {
                switch state {
                case .idle, .bound:
                    shape.fill(state == .idle ? ink.tile : ink.accent.opacity(0.22))
                    shape.stroke(tint(state), lineWidth: ink.stroke)
                case .lit, .waiting:
                    shape.fill(ink.accent.opacity(0.34))
                    shape.stroke(tint(state), lineWidth: ink.stroke + 1.5).modifier(Pulse(on: state == .waiting))
                }
                Text("\(n)").font(ink.mono(9, weight: .semibold)).foregroundStyle(state == .idle ? ink.muted : ink.text)
                    .position(x: badge.midX, y: badge.midY)
            }
            .frame(width: frame.width, height: frame.height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .contentShape(shape)   // hover and click both hit the drawn button only, never its whole view
        .onHover { hover(n, $0) }
        .accessibilityLabel(MouseKeys.buttonName(n))
        .accessibilityValue(Self.spoken(labels[n]))
    }

    private func leader(_ n: Int, from frame: CGRect, to anchor: CGPoint) -> some View {
        let end = n == 3 ? CGPoint(x: frame.minX, y: frame.midY) : CGPoint(x: frame.midX, y: frame.maxY)
        let state = state(n)
        return ZStack {
            Path { p in p.move(to: anchor); p.addLine(to: end) }.stroke(tint(state), lineWidth: 1.2)
            Circle().fill(state == .idle ? ink.line2 : ink.accent).frame(width: 5.2, height: 5.2).position(anchor)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .allowsHitTesting(false)
    }

    /// A drawn button's label: its action, or its name and Not bound; Press it now while the catch waits on it.
    private func chip(_ n: Int, at frame: CGRect) -> some View {
        let label = labels[n]
        let state = state(n)
        let name = MouseKeys.buttonName(n)
        let (line1, line2): (String, String) = if state == .waiting { ("Press it now…", name) }
            else if let action = label?.action { (action, name + (label?.sends.map { " · sends \($0)" } ?? "")) }
            else { (name, state == .lit ? "Picked" : "Not bound") }
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let filled = state == .waiting || label?.action != nil
        return Button { click(n) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(line1).font(ink.ui(12.5, .semibold))
                    .foregroundStyle(state == .waiting ? ink.accentText : filled ? ink.text : ink.text2)
                Text(line2).font(ink.ui(10.5)).foregroundStyle(ink.muted)
            }
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(width: frame.width, height: frame.height, alignment: .leading)
            .background(shape.fill(filled ? ink.accent.opacity(0.12) : ink.raised))
            .overlay {
                shape.strokeBorder(tint(state), style: StrokeStyle(lineWidth: state == .lit ? 2 : state == .waiting ? 1.5 : 1,
                                                                   dash: state == .waiting ? [4, 3] : []))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover(n, $0) }
        .offset(x: frame.minX, y: frame.minY)
        .accessibilityHidden(true)   // the drawn button says the same
    }

    private func hover(_ n: Int, _ inside: Bool) { hovered = inside ? n : (hovered == n ? nil : hovered) }

    private func caption(_ text: String) -> some View {
        Text(text).font(ink.ui(11)).foregroundStyle(ink.muted)
    }

    /// What VoiceOver reads for a drawn button.
    static func spoken(_ label: Label?) -> String {
        guard let action = label?.action else { return "Not bound" }
        return (label?.sends.map { "Sends \($0), runs " } ?? "Runs ") + action
    }

    /// The waiting button's stroke, fading in and out.
    private struct Pulse: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on {
                content.phaseAnimator([1.0, 0.35]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.6) }
            } else {
                content
            }
        }
    }

    // MARK: Shapes

    /// The body from the top, its front up: narrower at the front, round at the palm.
    static func outline(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: 0.5 * w, y: 0))
        p.addCurve(to: CGPoint(x: w, y: 0.44 * h), control1: CGPoint(x: 0.84 * w, y: 0), control2: CGPoint(x: w, y: 0.16 * h))
        p.addCurve(to: CGPoint(x: 0.5 * w, y: h), control1: CGPoint(x: w, y: 0.84 * h), control2: CGPoint(x: 0.8 * w, y: h))
        p.addCurve(to: CGPoint(x: 0, y: 0.44 * h), control1: CGPoint(x: 0.2 * w, y: h), control2: CGPoint(x: 0, y: 0.84 * h))
        p.addCurve(to: CGPoint(x: 0.5 * w, y: 0), control1: CGPoint(x: 0, y: 0.16 * h), control2: CGPoint(x: 0.16 * w, y: 0))
        p.closeSubpath()
        return p
    }

    /// The body from its left side, its front to the left: low at the nose, highest behind the middle.
    static func profile(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: 0.03 * w, y: 0.8 * h))
        p.addCurve(to: CGPoint(x: 0.62 * w, y: 0.05 * h), control1: CGPoint(x: 0.08 * w, y: 0.36 * h), control2: CGPoint(x: 0.36 * w, y: 0.03 * h))
        p.addCurve(to: CGPoint(x: 0.99 * w, y: 0.74 * h), control1: CGPoint(x: 0.86 * w, y: 0.07 * h), control2: CGPoint(x: w, y: 0.42 * h))
        p.addLine(to: CGPoint(x: 0.95 * w, y: 0.94 * h))
        p.addLine(to: CGPoint(x: 0.07 * w, y: 0.94 * h))
        p.addQuadCurve(to: CGPoint(x: 0.03 * w, y: 0.8 * h), control: CGPoint(x: 0.02 * w, y: 0.92 * h))
        p.closeSubpath()
        return p
    }

    /// The thumb's groove under the side buttons.
    static func thumbRest(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: 0.14 * w, y: 0.66 * h))
        p.addCurve(to: CGPoint(x: 0.82 * w, y: 0.66 * h), control1: CGPoint(x: 0.36 * w, y: 0.8 * h), control2: CGPoint(x: 0.62 * w, y: 0.8 * h))
        return p
    }

    /// One button's region on the drawing, in the frame of its view (the top view for 1 to 3, the side view for 4 and 5).
    struct Spot: Shape {
        let number: Int

        func path(in r: CGRect) -> Path {
            let w = r.width, h = r.height, gap = 3.0
            switch number {
            case 1, 2:
                // A main button: the body's front, one side of the split, short of the wheel.
                let half = number == 1 ? CGRect(x: 0, y: 0, width: 0.5 * w - gap, height: 0.42 * h)
                                       : CGRect(x: 0.5 * w + gap, y: 0, width: 0.5 * w - gap, height: 0.42 * h)
                let wheel = Path(roundedRect: Self.wheel(w, h).insetBy(dx: -gap, dy: -gap), cornerRadius: 0.07 * w)
                return MouseDrawing.outline(in: r.insetBy(dx: gap, dy: gap)).intersection(Path(half)).subtracting(wheel)
            case 3: return Path(roundedRect: Self.wheel(w, h), cornerRadius: 0.06 * w)
            case 4: return Path(roundedRect: CGRect(x: 0.45 * w, y: 0.33 * h, width: 0.19 * w, height: 0.15 * h), cornerRadius: 0.07 * h)
            default: return Path(roundedRect: CGRect(x: 0.24 * w, y: 0.36 * h, width: 0.19 * w, height: 0.15 * h), cornerRadius: 0.07 * h)
            }
        }

        static func wheel(_ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: 0.44 * w, y: 0.1 * h, width: 0.12 * w, height: 0.2 * h) }
    }
}
