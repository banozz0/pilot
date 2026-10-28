import AppKit
import PilotCore
import SwiftUI

/// An extension's bar item as one small picture (Surfaces v2, CodexBar's style): each gauge a provider's glyph, a letter
/// or two, its one or two thin meters stacked (AI usage: the session over the week) and its text ("66%"), then the item's
/// text. Without a tone anywhere it is a template, so macOS colours it for the menu bar as it does every other item; with
/// one, each toned gauge and the text draw in their tone over the menu bar's own label colour, resolved as macOS draws the
/// item, light or dark.
@MainActor
enum ExtensionGaugeIcon {
    static let height: CGFloat = 18
    /// A gauge's glyph and meters, the gap after its label, after its glyph or meters, between two gauges, before the text.
    static let glyphSize: CGFloat = 14, meterWidth: CGFloat = 16, meterHeight: CGFloat = 3, meterGap: CGFloat = 2, labelGap: CGFloat = 2,
               partGap: CGFloat = 3, gaugeGap: CGFloat = 8, textGap: CGFloat = 4, padding: CGFloat = 2

    /// One part of a gauge, drawn left to right in this order.
    enum Part { case glyph(Extension.Gauge.Icon), label(String), meters([Double]), text(String) }

    /// A gauge's parts: its glyph, label, meters and text, each it has.
    static func parts(_ gauge: Extension.Gauge) -> [Part] {
        [gauge.icon.map(Part.glyph), gauge.label.isEmpty ? nil : .label(gauge.label), gauge.meters.isEmpty ? nil : .meters(gauge.meters),
         gauge.text.isEmpty ? nil : .text(gauge.text)].compactMap { $0 }
    }

    /// The room after `part` when another follows.
    static func gap(after part: Part) -> CGFloat { if case .label = part { labelGap } else { partGap } }

    nonisolated(unsafe) private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    nonisolated(unsafe) private static let textFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// The picture, or nil with nothing to draw.
    static func image(_ face: ExtensionBarFace) -> NSImage? {
        let inner = width(face)
        guard inner > 0 else { return nil }
        let size = NSSize(width: (inner + padding * 2).rounded(.up), height: height)
        let toned = face.tone != nil || face.gauges.contains { $0.tone != nil }
        let image = NSImage(size: size, flipped: false) { _ in
            draw(face, at: padding, colour: { toned ? colour($0) : .black })
            return true
        }
        image.isTemplate = !toned
        image.accessibilityDescription = face.tooltip
        return image
    }

    /// A tone's colour in the menu bar; none is the bar's own label colour.
    static func colour(_ tone: Extension.Tone?) -> NSColor {
        switch tone {
        case .fine: .systemGreen
        case .warn: NSColor(Theme.yellow)
        case .alert: NSColor(Theme.red)
        case nil: .labelColor
        }
    }

    /// Its width in points without the picture's padding: the gauges, then the text.
    static func width(_ face: ExtensionBarFace) -> CGFloat {
        let gauges = face.gauges.map(gaugeWidth)
        var total = gauges.reduce(0, +) + gaugeGap * CGFloat(max(gauges.count - 1, 0))
        if !face.text.isEmpty { total += (total > 0 ? textGap : 0) + measure(face.text, textFont) }
        return total
    }

    private static func gaugeWidth(_ gauge: Extension.Gauge) -> CGFloat {
        let parts = parts(gauge)
        return parts.map(width).reduce(0, +) + parts.dropLast().map(gap).reduce(0, +)
    }

    private static func width(_ part: Part) -> CGFloat {
        switch part {
        case .glyph: glyphSize
        case .label(let s): measure(s, labelFont)
        case .meters: meterWidth
        case .text(let s): measure(s, textFont)
        }
    }

    /// Draws it from `x` in the current context, `height` tall; `colour` gives each tone's ink (black for a template).
    static func draw(_ face: ExtensionBarFace, at x: CGFloat, colour: (Extension.Tone?) -> NSColor) {
        var x = x
        for gauge in face.gauges {
            let ink = colour(gauge.tone ?? (face.gauges.count == 1 ? face.tone : nil))
            let parts = parts(gauge)
            for (i, part) in parts.enumerated() {
                switch part {
                case .glyph(let icon):
                    colour(nil).setFill()
                    NSBezierPath(cgPath: glyph(icon, in: CGRect(x: x, y: (height - glyphSize) / 2, width: glyphSize, height: glyphSize), yUp: true).cgPath).fill()
                case .label(let s): write(s, labelFont, colour(nil), at: x)
                case .text(let s): write(s, textFont, ink, at: x)
                case .meters(let meters):
                    let stack = CGFloat(meters.count) * meterHeight + CGFloat(meters.count - 1) * meterGap
                    // The first meter on top.
                    var y = (height + stack) / 2 - meterHeight
                    for share in meters {
                        let track = NSRect(x: x, y: y, width: meterWidth, height: meterHeight)
                        colour(nil).withAlphaComponent(0.28).setFill()
                        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                        ink.setFill()
                        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: meterWidth * share / 100, height: meterHeight), xRadius: 1.5, yRadius: 1.5).fill()
                        y -= meterHeight + meterGap
                    }
                }
                x += width(part) + (i < parts.count - 1 ? gap(after: part) : gaugeGap)
            }
        }
        guard !face.text.isEmpty else { return }
        if !face.gauges.isEmpty { x += textGap - gaugeGap }
        write(face.text, textFont, colour(face.tone), at: x)
    }

    /// `s` drawn from `x`, centred in the height.
    private static func write(_ s: String, _ font: NSFont, _ colour: NSColor, at x: CGFloat) {
        let drawn = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: colour])
        drawn.draw(at: NSPoint(x: x, y: (height - drawn.size().height) / 2))
    }

    private static func measure(_ s: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: s, attributes: [.font: font]).size().width.rounded(.up)
    }

    /// A provider glyph filling `rect`, one path to fill in AppKit or SwiftUI: Claude its mark, CodexBar's outline of it;
    /// OpenAI six rounded loops turned 60° apart around a hexagon, drawn as strokes. `yUp` for AppKit's unflipped
    /// drawing, so Claude's mark stands upright there too.
    nonisolated static func glyph(_ icon: Extension.Gauge.Icon, in rect: CGRect, yUp: Bool = false) -> Path {
        let r = min(rect.width, rect.height) / 2, c = CGPoint(x: rect.midX, y: rect.midY)
        switch icon {
        case .claude:
            return claudeUnit.applying(CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: 2 * r, y: yUp ? -2 * r : 2 * r))
        case .openai:
            var loops = Path()
            let line = r * 0.16, w = r * 0.55, l = r * 1.2, d = r * 0.6
            for i in 0..<6 {
                loops.addPath(Path(roundedRect: CGRect(x: -w / 2, y: d - w / 2, width: l, height: w), cornerRadius: w / 2),
                              transform: CGAffineTransform(rotationAngle: Double(i) * .pi / 3))
            }
            // Fitted inside `rect` with its stroke.
            let box = loops.boundingRect, k = (2 * r - line) / max(box.width, box.height)
            loops = loops.applying(CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: k, y: k).translatedBy(x: -box.midX, y: -box.midY))
            return loops.strokedPath(StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        }
    }

    /// Claude's mark, y down in a square 1000 wide: each a point the outline runs to, or a curve's two controls and its end.
    /// From CodexBar's ProviderIcon-claude.svg (MIT, © 2026 Peter Steinberger).
    /// The mark built once, centred on the origin and one wide at its widest; each glyph only scales and moves it.
    nonisolated private static let claudeUnit: Path = {
        var mark = Path()
        for (i, op) in claudeMark.enumerated() {
            let p = { CGPoint(x: op[$0], y: op[$0 + 1]) }
            if i == 0 { mark.move(to: p(0)) } else if op.count == 6 { mark.addCurve(to: p(4), control1: p(0), control2: p(2)) } else { mark.addLine(to: p(0)) }
        }
        mark.closeSubpath()
        let box = mark.boundingRect, k = 1 / max(box.width, box.height)
        return mark.applying(CGAffineTransform(scaleX: k, y: k).translatedBy(x: -box.midX, y: -box.midY))
    }()

    nonisolated private static let claudeMark: [[CGFloat]] = [
        [257, 632], [414, 544], [417, 536], [414, 532], [407, 532], [380, 530], [291, 528], [213, 525], [137, 521], [118, 517],
        [100, 493], [102, 481], [118, 471], [141, 473], [192, 476], [267, 481], [323, 485], [404, 493], [417, 493], [419, 488],
        [414, 485], [411, 481], [332, 428], [247, 372], [203, 340], [179, 323], [167, 308], [161, 274], [183, 250], [213, 252],
        [220, 254], [250, 277], [313, 326], [396, 387], [409, 397], [413, 394], [414, 392], [409, 382], [363, 301], [315, 218],
        [294, 183], [288, 163], [286, 154, 285, 147, 285, 139], [310, 105], [323, 100], [357, 105], [370, 117], [391, 164],
        [425, 238], [476, 339], [491, 369], [500, 397], [503, 405], [508, 405], [508, 401], [512, 344], [520, 274], [528, 184],
        [530, 159], [543, 128], [568, 112], [587, 121], [603, 144], [601, 159], [591, 221], [573, 317], [561, 382], [568, 382],
        [576, 374], [609, 331], [664, 262], [688, 234], [716, 204], [735, 190], [769, 190], [794, 228], [783, 266], [748, 311],
        [718, 349], [676, 406], [650, 451], [652, 455], [658, 454], [754, 434], [805, 425], [866, 414], [894, 427], [897, 441],
        [886, 467], [821, 484], [744, 499], [629, 526], [628, 527], [629, 529], [681, 534], [703, 535], [757, 535], [858, 543],
        [884, 560], [900, 581], [897, 598], [857, 618], [802, 605], [674, 575], [631, 564], [625, 564], [625, 568], [661, 603],
        [728, 664], [811, 741], [816, 760], [805, 776], [794, 774], [720, 719], [692, 694], [628, 640], [623, 640], [623, 646],
        [638, 667], [716, 785], [720, 821], [715, 832], [694, 839], [672, 835], [626, 771], [579, 699], [541, 634], [537, 637],
        [514, 879], [504, 891], [479, 900], [459, 885], [448, 860], [459, 811], [472, 747], [483, 696], [492, 632], [498, 611],
        [497, 610], [493, 610], [445, 676], [372, 774], [315, 836], [301, 841], [277, 829], [279, 807], [293, 787], [372, 686],
        [420, 623], [451, 587], [451, 582], [449, 582], [238, 719], [200, 724], [184, 709], [186, 684], [194, 676]
    ]
}

/// A provider glyph as a SwiftUI shape: the same glyph the menu bar picture fills.
struct ProviderGlyph: Shape {
    let icon: Extension.Gauge.Icon
    nonisolated func path(in rect: CGRect) -> Path { ExtensionGaugeIcon.glyph(icon, in: rect) }
}

/// The same item in Pilot's top bar, drawn by SwiftUI in the bar's style: `ink` the plain colour, `tone` each tone's.
struct ExtensionBarGlyph: View {
    @Environment(\.barItemColours) private var itemColours
    let face: ExtensionBarFace
    let ink: Color
    let font: Font
    let tone: (Extension.Tone) -> Color

    var body: some View {
        HStack(spacing: ExtensionGaugeIcon.textGap) {
            if !face.gauges.isEmpty {
                HStack(spacing: ExtensionGaugeIcon.gaugeGap) {
                    ForEach(face.gauges.indices, id: \.self) { i in gauge(face.gauges[i]) }
                }
            }
            if !face.text.isEmpty { Text(face.text).font(font).monospacedDigit().foregroundStyle(face.tone.map(tone) ?? ink).lineLimit(1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(face.tooltip)
    }

    private func gauge(_ gauge: Extension.Gauge) -> some View {
        let fill = (gauge.tone ?? (face.gauges.count == 1 ? face.tone : nil)).map(tone) ?? ink
        let parts = ExtensionGaugeIcon.parts(gauge)
        return HStack(spacing: 0) {
            ForEach(parts.indices, id: \.self) { i in
                Group {
                    switch parts[i] {
                    case .glyph(let icon):
                        // Item colours: the provider's own colour (Sven, Q251: "claude looks orange").
                        ProviderGlyph(icon: icon).fill((itemColours ? icon.brand : nil) ?? ink)
                            .frame(width: ExtensionGaugeIcon.glyphSize, height: ExtensionGaugeIcon.glyphSize)
                    case .label(let s): Text(s).font(.system(size: 10, weight: .bold)).foregroundStyle(ink)
                    case .meters(let meters):
                        VStack(spacing: ExtensionGaugeIcon.meterGap) {
                            ForEach(meters.indices, id: \.self) { i in
                                Capsule().fill(ink.opacity(0.25)).frame(width: ExtensionGaugeIcon.meterWidth, height: ExtensionGaugeIcon.meterHeight)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(fill).frame(width: ExtensionGaugeIcon.meterWidth * meters[i] / 100)
                                    }
                            }
                        }
                    case .text(let s): Text(s).font(font).monospacedDigit().foregroundStyle(fill).lineLimit(1)
                    }
                }
                .padding(.trailing, i < parts.count - 1 ? ExtensionGaugeIcon.gap(after: parts[i]) : 0)
            }
        }
    }
}
