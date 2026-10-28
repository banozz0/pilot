import PilotCore
import SwiftUI

/// Halo (P74, Sven's pick): one glass disc cut into eight wedges, the answer in the hub under the pointer. The aimed wedge
/// is lit in the accent's soft fill with an accent rim; a switch shows ON or OFF under its glyph; a group's wedge carries a
/// short mark on its rim. Entering a group turns the disc into the group's own ring in the same place, a quick crossfade
/// (Sven, 2026-10-20), its name in the hub with the way back up. The top bar's glass and tint while Look's Glass is on, the
/// panel's fill on Solid; no shadow.
struct RingView: View {
    @Environment(\.ink) private var ink
    @Environment(\.glassFace) private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: RingModel

    private typealias G = RingGeometry
    private var side: CGFloat { G.side }
    private var c: CGPoint { CGPoint(x: side / 2, y: side / 2) }

    var body: some View {
        let session = model.session
        ZStack {
            disc
            // The level's wedges, made anew when the level or its page changes, so the old crossfades into the new.
            ZStack {
                Canvas { context, _ in draw(&context, session) }
                ForEach(0..<Ring.places, id: \.self) { p in
                    if let face = model.faces[safe: p] ?? nil { wedge(face, at: p, lit: session.aim == p) }
                }
            }
            .id(levelKey(session))
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            rim
            hub(session)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: levelKey(session))
        .frame(width: side, height: side)
        .scaleEffect(model.shown || reduceMotion ? 1 : 0.92)
        .opacity(model.shown ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.shown)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(session))
    }

    /// The ring, the level and the page showing.
    private func levelKey(_ s: RingSession) -> String { "\(s.index)/\(s.crumbs.joined(separator: "/"))/\(s.level?.page ?? 0)" }

    // MARK: the disc

    @ViewBuilder private var disc: some View {
        let d = 2 * G.disc
        if let glass {
            GlassFace(tint: glass, cornerRadius: G.disc).frame(width: d, height: d).clipShape(Circle())
        } else {
            Circle().fill(ink.raised).frame(width: d, height: d)
        }
    }

    private func draw(_ context: inout GraphicsContext, _ session: RingSession) {
        let half = 180 / Double(Ring.places)
        if let p = session.aim {
            let a = G.angle(of: p)
            context.fill(sector(G.hub, G.disc, a - half, a + half), with: .color(ink.selection))
            context.stroke(arc(G.disc - 1.5, a - half, a + half), with: .color(ink.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        // The eight dividers, hub to rim.
        var dividers = Path()
        for p in 0..<Ring.places {
            let a = G.angle(of: p) + half
            dividers.move(to: point(G.hub, a)); dividers.addLine(to: point(G.disc, a))
        }
        context.stroke(dividers, with: .color(ink.line2), lineWidth: 1)
        // A group's mark: a short arc on its rim, clockwise of its glyph.
        for (p, face) in model.faces.enumerated() where face?.isGroup == true {
            let a = G.angle(of: p)
            context.stroke(arc(G.disc - 8, a + 8, a + 18), with: .color(ink.muted), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }

    /// The rim and the hub's well, the same on every level.
    private var rim: some View {
        Canvas { context, _ in
            context.stroke(Path(ellipseIn: CGRect(x: c.x - G.disc + 0.5, y: c.y - G.disc + 0.5, width: 2 * G.disc - 1, height: 2 * G.disc - 1)),
                           with: .color(ink.line2), lineWidth: 1)
            let hub = CGRect(x: c.x - G.hub, y: c.y - G.hub, width: 2 * G.hub, height: 2 * G.hub)
            context.fill(Path(ellipseIn: hub), with: .color(ink.background.opacity(glass == nil ? 0.7 : 0.45)))
            context.stroke(Path(ellipseIn: hub.insetBy(dx: 0.5, dy: 0.5)), with: .color(ink.line2), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    // MARK: wedges

    @ViewBuilder private func wedge(_ face: RingFace, at p: Int, lit: Bool) -> some View {
        let at = point((G.hub + G.disc) / 2, G.angle(of: p))
        VStack(spacing: 3) {
            glyph(face, size: 19, lit: lit)
            if let on = face.isOn {
                Text(on ? "ON" : "OFF").font(ink.mono(8.5, weight: .medium)).tracking(0.8)
                    .foregroundStyle(on ? ink.accentText : ink.muted)
            }
        }
        .position(x: at.x, y: at.y + (face.isOn == nil ? 0 : 5))
    }

    @ViewBuilder private func glyph(_ face: RingFace, size: CGFloat, lit: Bool) -> some View {
        if let image = face.image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size + 9, height: size + 9)
        } else {
            Image(systemName: face.symbol).font(.system(size: size, weight: .light))
                .foregroundStyle(lit ? ink.accent : ink.text2).frame(width: size + 9, height: size + 9)
        }
    }

    // MARK: the hub

    @ViewBuilder private func hub(_ session: RingSession) -> some View {
        let face: RingFace? = session.aim.flatMap { model.faces[safe: $0] ?? nil }
        VStack(spacing: 4) {
            if let face {
                Text(session.level?.name ?? "").font(ink.mono(9.5, weight: .medium)).tracking(1).textCase(.uppercase).foregroundStyle(ink.muted)
                    .lineLimit(1)
                if !model.hideNames || session.aimed == .more {
                    Text(face.label).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                }
                if session.aimed == .more {
                    Text("Page \(session.level.map { $0.page + 1 } ?? 1) of \(session.pages)").font(ink.mono(9.5)).tracking(0.6).textCase(.uppercase)
                        .foregroundStyle(ink.muted)
                } else if let on = face.isOn {
                    Text("\(on ? "On" : "Off") · \(model.flickRuns ? "let go" : "click"): \(on ? "off" : "on")")
                        .font(ink.mono(9.5, weight: .medium)).tracking(0.6).textCase(.uppercase).foregroundStyle(ink.accentText)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else if let keys = face.keys, !model.hideNames {
                    Kbd(text: keys, small: true)
                } else if face.isGroup {
                    Text("Open").font(ink.mono(9.5)).tracking(0.6).textCase(.uppercase).foregroundStyle(ink.muted)
                }
            } else if let level = session.level {
                if session.depth > 0 {
                    // Inside a group: where it sits, and the way back up.
                    Text(session.crumbs.dropLast().last ?? "").font(ink.mono(9.5, weight: .medium)).tracking(1).textCase(.uppercase)
                        .foregroundStyle(ink.muted).lineLimit(1)
                }
                Text(level.name).font(ink.ui(15, .semibold)).foregroundStyle(ink.text).lineLimit(1).minimumScaleFactor(0.7)
                if session.depth > 0 {
                    Text("‹ Back · esc").font(ink.mono(9.5, weight: .medium)).tracking(0.6).textCase(.uppercase).foregroundStyle(ink.accentText)
                } else {
                    Text("\(model.faces.count { $0 != nil }) actions").font(ink.mono(9.5, weight: .medium)).tracking(1).textCase(.uppercase)
                        .foregroundStyle(ink.muted)
                    if session.wheel.count > 1 { dots(session) }
                }
            }
        }
        .frame(width: 2 * G.hub - 12)
        .position(c)
    }

    /// One dot a ring, the one showing a pill: scroll steps along them.
    private func dots(_ session: RingSession) -> some View {
        HStack(spacing: 4) {
            ForEach(session.wheel.indices, id: \.self) { i in
                Capsule().fill(i == session.index ? ink.accent : ink.line3).frame(width: i == session.index ? 12 : 4, height: 4)
            }
        }
        .padding(.top, 2)
    }

    private func accessibility(_ session: RingSession) -> String {
        let where_ = session.crumbs.joined(separator: ", ")
        guard let aim = session.aim, let face = model.faces[safe: aim] ?? nil else { return "\(where_) ring" }
        return "\(where_) ring, \(face.label)"
    }

    // MARK: geometry

    /// The point `r` from the centre at `bearing` degrees clockwise from north (SwiftUI's y down).
    private func point(_ r: Double, _ bearing: Double) -> CGPoint {
        let a = bearing * .pi / 180
        return CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
    }

    /// An arc of radius `r` from bearing `a` to `b`, clockwise on screen. A bearing is from north; SwiftUI's angles from
    /// east, and with y down its `clockwise: false` turns clockwise on screen.
    private func arc(_ r: Double, _ a: Double, _ b: Double) -> Path {
        var path = Path()
        path.addArc(center: c, radius: r, startAngle: .degrees(a - 90), endAngle: .degrees(b - 90), clockwise: false)
        return path
    }

    /// The ring's slice between radii `r1` and `r2`, bearings `a` to `b`.
    private func sector(_ r1: Double, _ r2: Double, _ a: Double, _ b: Double) -> Path {
        var path = arc(r2, a, b)
        path.addArc(center: c, radius: r1, startAngle: .degrees(b - 90), endAngle: .degrees(a - 90), clockwise: true)
        path.closeSubpath()
        return path
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
