import PilotCore
import SwiftUI

/// The Kit's Toybox branches for a settings page (card agent-bo-95423182, batch 2): the page's column, a titled card, a
/// heading over a group, a chip, an empty state and a slider, each a keycap with the ink outline and a solid bottom edge.
/// The Kit's parts call these when the surface draws in Toybox.

/// A page's column under the frame's header: the intro line, then the blocks, level with the header's 32 pt inset.
struct ToyPage<Content: View>: View {
    @Environment(\.style) private var style
    var intro: String?
    /// The intro's ⓘ: what its one line leaves out.
    var info: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let intro {
                    IntroLine(info: info) {
                        Text(intro).font(style.toyNunito(700, 14.5)).foregroundStyle(style.color(\.text2))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 2)
                }
                content
            }
            .padding(.horizontal, Toy.gutter).padding(.bottom, 32)
        }
    }
}

/// A titled card (`.chunk` with `.h-card`): Fredoka's card title and its trailing words in the second ink, a note under
/// it, then the block's rows.
struct ToyBlock<Trailing: View, Content: View>: View {
    @Environment(\.style) private var style
    var title: String?
    var note: String?
    var fill = false
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(style.toyFredoka(19)).foregroundStyle(style.color(\.text)).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    trailing.font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2))
                }
                .padding(.bottom, note == nil ? 10 : 2)
            }
            if let note {
                Text(note).font(style.toyNunito(600, 13.5)).foregroundStyle(style.color(\.text2))
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
            content
        }
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .styleSurface(\.card)
    }
}

/// A heading over a group of cards: Fredoka at a card title's size, its note under it.
struct ToyHeading<Trailing: View>: View {
    @Environment(\.style) private var style
    let title: String
    var note: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(style.toyFredoka(21)).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                Spacer()
                trailing.font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2))
            }
            if let note {
                Text(note).font(style.toyNunito(600, 13.5)).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 26).padding(.bottom, 12)
    }
}

/// A chip (`.kc`'s small sibling): Nunito 800 on the cap colour inside the ink outline, a coloured one on its soft fill
/// with a dot; a picked filter is the sun.
struct ToyPageChip: View {
    @Environment(\.style) private var style
    let text: String
    var color: Color?
    var on = false
    var count: String?
    var symbol: String?
    var remove: (() -> Void)?

    var body: some View {
        let fill = on ? style.color(\.accent) : color.map { $0.opacity(style.dark ? 0.3 : 0.24) } ?? style.color(\.raised)
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .heavy)) }
            else if let color, !on { ToyDot(color: color, size: 8) }
            Text(text)
            if let count { Text(count).font(style.toyMono(11)) }
            if let remove {
                IconButton(symbol: "xmark", label: "Remove \(text)", size: 16, glyph: 8.5, action: remove).padding(.trailing, -5)
            }
        }
        .font(style.toyNunito(800, 12)).lineLimit(1).fixedSize()
        .foregroundStyle(on ? style.color(\.onAccent) : style.color(\.text))
        .padding(.horizontal, 9).frame(height: style.points(24))
        .background {
            let shape = RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous)
            shape.fill(style.color(\.panel)).overlay { shape.fill(fill) }.overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
        }
    }
}

/// Nothing yet: the Pilot logo, a Fredoka line, the keys that fix it and one action, on a dashed sunk well.
struct ToyEmpty: View {
    @Environment(\.style) private var style
    let title: String
    var line: String?
    var keys: [String] = []
    var action: (title: String, run: () -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        HStack(spacing: 14) {
            PilotMark(size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(style.toyFredoka(17)).foregroundStyle(style.color(\.text))
                if line != nil || !keys.isEmpty {
                    HStack(spacing: 5) {
                        if !keys.isEmpty { ToyKeys(keys: keys, hyper: false, small: true) }
                        if let line { Text(line).font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)) }
                    }
                }
                if let action { Button(action.title, action: action.run).buttonStyle(.pilotPrimary).padding(.top, 6) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color(\.sunken), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line3), style: StrokeStyle(lineWidth: 2, dash: [5, 4])) }
    }
}

/// A slider's face: the sunk track in the ink outline filled with the sun to the knob, a white knob outlined.
struct ToySliderFace: View {
    @Environment(\.style) private var style
    let fraction: CGFloat
    let width: CGFloat

    var body: some View {
        let x = max(0, min(1, fraction)) * width
        ZStack(alignment: .leading) {
            Capsule().fill(style.color(\.sunken)).overlay { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) }.frame(height: 12)
            Capsule().fill(style.color(\.accent)).frame(width: max(12, x), height: 12)
                .overlay { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) }
            Circle().fill(style.color(\.knob)).overlay { Circle().strokeBorder(style.color(\.outline), lineWidth: 2) }
                .frame(width: 22, height: 22).offset(x: min(max(x - 11, 0), width - 22))
        }
    }
}

extension Toy {
    /// The room over a block in a page's column.
    static let blockGap: CGFloat = 18
    /// A page column's side inset, level with the frame's title.
    static let gutter: CGFloat = 32

    /// A Kit tile's colour in Toybox's candy: the accent the sun, the theme's second and third grape and mint, a state its
    /// own, neutral the cloud.
    static func tile(_ colour: TileColour, _ style: StyleTokens) -> Color {
        switch colour {
        case .accent: style.color(\.accent)
        case .second: module(1, style)
        case .third: module(2, style)
        case .good: module(2, style)
        case .amber: style.color(\.accent)
        case .problem: module(3, style)
        case .neutral: Toy.pageTile(.notes, style)
        }
    }
}

extension View {
    /// Toybox's chunk round a block that lays and clips its own fill (the workspace editor): the ink outline over its
    /// edge and the solid edge under it.
    func toyEdge(radius: CGFloat) -> some View { modifier(ToyEdge(radius: radius)) }

    /// Toybox's words for whatever under a page sets none of its own.
    func styleLayout() -> some View { modifier(StyleLayout()) }
}

private struct StyleLayout: ViewModifier {
    @Environment(\.style) private var style
    func body(content: Content) -> some View {
        if style.kind == .toybox {
            // pilotTheme()'s words for whatever sets none of its own: Toybox's ink in Nunito, its sun as the tint.
            content
                .foregroundStyle(style.color(\.text)).font(style.toyNunito(600, 13.5)).tint(style.color(\.accentText))
        } else { content }
    }
}

private struct ToyEdge: ViewModifier {
    @Environment(\.style) private var style
    let radius: CGFloat
    func body(content: Content) -> some View {
        if style.kind == .toybox {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous), edge = style.depth.card.edge
            content
                .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: style.depth.card.outline) }
                .background { shape.fill(style.color(\.outline)).offset(y: edge - style.depth.card.outline) }
                .padding(.bottom, edge - style.depth.card.outline)
        } else { content }
    }
}
