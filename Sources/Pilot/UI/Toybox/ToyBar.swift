import AppKit
import PilotCore
import SwiftUI

/// Toybox's top bar (card agent-bo-95423182, mockup B: pilot-redesign-B/src/scene.js topbar(), common.css `.isl`, `.tb-*`):
/// Waybar-style islands on the canvas, each slot one chunky toy (a 2 pt ink outline and a 4 pt edge), its parts in Nunito
/// with candy marks (spark bars, a meter, a tomato for the timer), the workspaces as chips with the current one sun, the
/// clock the inverted ink pill and the Pilot mark where Capsy sat. Every item keeps its data, order, targets, hover and
/// popover; only the drawing changes. The bar is the menu bar strip's height (30 pt on Sven's screen, the tiler's gap
/// under it), so the islands fill it less 2 pt above and below rather than the mockup's 36 pt in a 50 pt bar.
enum ToyBar {
    /// The bar's words and numbers (`.isl`: Nunito 800 13, a step down for the strip's height).
    @MainActor static var font: Font { ToyFace.nunito(800, 12.5) }
    /// Every glyph (lucide at 2.5 stroke beside heavy words).
    static let glyph = Font.system(size: 12, weight: .bold)
    /// Between two islands.
    static let spacing: CGFloat = 6
}


/// Toybox's faces at a size, made from their bundled files (ADR 0008): Nunito for words, Fredoka for display, JetBrains
/// Mono for numbers and ids.
@MainActor
enum ToyFace {
    static func nunito(_ weight: Int, _ size: CGFloat) -> Font { Font(DisplayFaces.font(StyleTokens.nunito(weight), size: size)) }
    static func fredoka(_ size: CGFloat) -> Font { Font(DisplayFaces.font(StyleTokens.fredoka(600), size: size)) }
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font { Font(DisplayFaces.font(StyleTokens.jetBrainsMono(bold ? 700 : 500), size: size)) }
}

/// An outlined chip that picks something (`.chip`): the panel colour, inverted while picked.
struct ToyChip<Label: View>: View {
    @Environment(\.style) private var style
    let on: Bool
    var height: CGFloat = 32
    var radius: CGFloat = 11
    let pick: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: pick) {
            label
                .foregroundStyle(on ? style.color(\.onInverse) : style.color(\.text)).lineLimit(1).fixedSize()
                .padding(.horizontal, height > 30 ? 11 : 10).frame(height: height)
                .background(on ? style.color(\.inverse) : style.color(\.panel), in: shape)
                .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension View {
    /// A top bar slot as its Toybox island; anything else as it is.
    func toyIsland(_ kind: BarKind) -> some View { modifier(ToyIsland(inverted: kind == .clock)) }
}

/// One island (`.isl`): the panel colour (the clock's the inverted ink), a 2 pt ink outline and a 4 pt edge, 2 pt off the
/// strip's top and bottom.
private struct ToyIsland: ViewModifier {
    @Environment(\.style) private var style
    let inverted: Bool

    func body(content: Content) -> some View {
        if style.kind == .toybox {
            content
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity)
                .foregroundStyle(inverted ? style.color(\.onInverse) : style.color(\.text))
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
                .background(Toy.block(style, fill: inverted ? style.color(\.inverse) : style.color(\.panel), radius: 10, edge: 4))
                .padding(.vertical, 2)
        } else {
            content
        }
    }
}

/// A slot's parts in Toybox: values heavy and in the island's ink, glyphs and words a step quieter, a reading past its
/// threshold in the sun's dark edge; the Pilot item's mark the Pilot logo.
struct ToyBarParts: View {
    @Environment(\.style) private var style
    @Environment(\.barItemColours) private var itemColours
    let items: [[BarPart]]
    var appIcon: NSImage?

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let warn = item.contains(.warn), level = BarLevelInk.colour(item, on: itemColours)
                HStack(spacing: 6) {
                    ForEach(Array(item.enumerated()), id: \.offset) { _, part in view(part, warn: warn, level: level) }
                }
            }
        }
        .font(ToyBar.font)
        .fixedSize()
    }

    /// A part; `level` is its reading's Item colour (BarLevelInk), over the sun's edge past the threshold.
    @ViewBuilder private func view(_ part: BarPart, warn: Bool, level: Color?) -> some View {
        let quiet = level.map { AnyShapeStyle($0) } ?? (warn ? AnyShapeStyle(style.color(\.accentText)) : AnyShapeStyle(.secondary))
        let primary = level.map { AnyShapeStyle($0) } ?? (warn ? AnyShapeStyle(style.color(\.accentText)) : AnyShapeStyle(.primary))
        switch part {
        case .label(let s): Text(s).font(ToyFace.nunito(800, 9.5)).foregroundStyle(.secondary)
        case .reading(let stat):
            Image(systemName: BarKind(stat).symbol).font(ToyBar.glyph).foregroundStyle(quiet).accessibilityLabel(stat.title)
        case .value(let s, let widest):
            ZStack(alignment: .leading) {
                if let widest { Text(widest).hidden() }
                Text(s)
            }
            .monospacedDigit().foregroundStyle(primary)
        case .text(let s): Text(s).font(ToyFace.nunito(700, 12.5)).foregroundStyle(.secondary).lineLimit(1)
        case .date(let s): Text(s).font(ToyFace.nunito(700, 12.5)).opacity(0.75).lineLimit(1)
        case .time(let s): Text(s).font(ToyFace.fredoka(14.5)).monospacedDigit().lineLimit(1)
        case .graph(let points): ToySparkBars(points: points)
        case .bar(let share): ToyMeter(share: share, warn: warn)
        case .symbol(let name): Image(systemName: name).font(ToyBar.glyph).foregroundStyle(quiet)
        case .mark: InstrumentMark(size: 14).foregroundStyle(primary)
        case .ring(let left): ToyTomato(left: left)
        case .badge(let s): ToyBadge(text: s)
        case .workspaces(let names, let current, let app):
            HStack(spacing: 3) {
                ForEach(names, id: \.self) { name in
                    ToyWorkspaceChip(label: BarParts.workspaceLabel(name, app: name == current ? app : nil), current: name == current, focused: true)
                }
            }
        case .dots(let count, let current):
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { i in
                    Circle().fill(i == current ? style.color(\.accent) : style.color(\.sunken))
                        .overlay { Circle().strokeBorder(style.color(\.outline), lineWidth: 1.5) }.frame(width: 8, height: 8)
                }
            }
        case .app(let name, let showsName):
            HStack(spacing: 6) {
                if let appIcon { Image(nsImage: appIcon).resizable().frame(width: 17, height: 17) }
                if showsName || appIcon == nil { Text(name).lineLimit(1) }
            }
        case .strength(let bars):
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(BarParts.strengthHeights.enumerated()), id: \.offset) { i, h in
                    RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(i < bars ? 1 : 0.25)).frame(width: 3, height: h)
                }
            }
        case .space(let points): Color.clear.frame(width: points, height: 1)
        case .divider: Capsule().fill(style.color(\.outline).opacity(0.3)).frame(width: 2, height: 14)
        case .warn, .level: EmptyView()
        case .extensionItem(let face):
            ExtensionBarGlyph(face: face, ink: style.color(\.text), font: ToyFace.nunito(800, 12.5)) { tone in
                switch tone { case .fine: style.color(\.text); case .warn: Theme.yellow; case .alert: Theme.red }
            }
        }
    }
}

/// A reading's mini graph as the mockup's bars (`.mini`): its last seven points, sky with an ink outline, oldest left.
private struct ToySparkBars: View {
    @Environment(\.style) private var style
    let points: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(points.suffix(7).enumerated()), id: \.offset) { _, p in
                let shape = UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                shape.fill(Toy.module(0, style)).overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 1.5) }
                    .frame(width: 5, height: max(3, 14 * min(max(p, 0), 1)))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// A meter (`.tb-batt .cell`): the sunk track outlined in the ink, filled mint to its share, the sun's edge past its threshold.
private struct ToyMeter: View {
    @Environment(\.style) private var style
    let share: Double
    let warn: Bool

    var body: some View {
        Capsule().fill(style.color(\.sunken))
            .overlay(alignment: .leading) {
                Capsule().fill(warn ? style.color(\.accentEdge) : Toy.module(2, style)).frame(width: 26 * min(max(share, 0), 1))
            }
            .clipShape(Capsule())
            .overlay { Capsule().strokeBorder(style.color(\.outline), lineWidth: 2) }
            .frame(width: 26, height: 10)
    }
}

/// The timer's ring as the mockup's tomato: coral for the share of its time left, from the top, on the sunk fill,
/// outlined in the ink, a mint leaf on top.
private struct ToyTomato: View {
    @Environment(\.style) private var style
    let left: Double

    var body: some View {
        ZStack {
            Circle().fill(style.color(\.sunken))
            Slice(share: min(max(left, 0), 1)).fill(Toy.module(3, style))
            Circle().strokeBorder(style.color(\.outline), lineWidth: 2)
        }
        .frame(width: 14, height: 14)
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 1.5).fill(Toy.module(2, style))
                .overlay { RoundedRectangle(cornerRadius: 1.5).strokeBorder(style.color(\.outline), lineWidth: 1.2) }
                .frame(width: 5, height: 5).offset(x: 2, y: -3)
        }
        .accessibilityHidden(true)
    }

    private struct Slice: Shape {
        let share: Double
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.midX, y: r.midY))
            p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: .degrees(-90),
                     endAngle: .degrees(-90 + 360 * share), clockwise: false)
            p.closeSubpath()
            return p
        }
    }
}

/// A code in a small outlined box (`.tb-kbd`): a keyboard layout's, the Pilot number's, the current workspace's.
private struct ToyBadge: View {
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(text).font(ToyFace.nunito(900, 10.5)).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
    }
}

/// A workspace (`.tb-ws`): its number (and its app or its apps' icons in those styles) on the sunk fill; the current
/// one sun with an ink outline while it has the focus, the surface outlined while another screen has it.
struct ToyWorkspaceChip: View {
    @Environment(\.style) private var style
    let label: String
    let current: Bool
    let focused: Bool
    var workspace: OccupiedWorkspace?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 5) {
            Text(label).font(ToyFace.nunito(800, 11.5)).monospacedDigit().lineLimit(1)
            if let workspace, !workspace.apps.isEmpty { WorkspaceAppIcons(workspace: workspace, lit: current) }
        }
        .foregroundStyle(current ? (focused ? style.color(\.onAccent) : style.color(\.text)) : style.color(\.text2))
        .padding(.horizontal, label.count > 1 || workspace != nil ? 5 : 0)
        .frame(minWidth: 18, minHeight: 18)
        .background(current ? (focused ? style.color(\.accent) : style.color(\.raised)) : style.color(\.sunken), in: shape)
        .overlay { if current { shape.strokeBorder(style.color(\.outline), lineWidth: 2) } }
        .fixedSize()
    }
}

/// The top bar's hover pill: the theme's raised fill, or in Toybox the sunk fill.
struct BarHoverPill: ViewModifier {
    @Environment(\.style) private var style
    let lit: Bool

    func body(content: Content) -> some View {
        if style.kind == .toybox {
            content.background { if lit { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(style.color(\.sunken)) } }
        } else {
            content.background { if lit { RoundedRectangle(cornerRadius: Theme.radius(5), style: .continuous).fill(style.inked ? style.color(\.raised) : Theme.selected) } }
        }
    }
}

/// The tooltip as a small toy: one line of Nunito on the panel colour, outlined, with a 3 pt edge.
struct ToyBarTooltip: View {
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        Text(text).font(ToyFace.nunito(800, 12)).foregroundStyle(style.color(\.text)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 3, trailing: 2))
            .background(Toy.block(style, fill: style.color(\.panel), radius: 9, edge: 3))
    }
}

/// The colours and faces a top bar popover or edit mode draws in: the style's tokens; the faces are Toybox's.
struct BarInk {
    let style: StyleTokens
    var toybox: Bool { style.kind == .toybox }

    @MainActor var text: Color { style.color(\.text) }
    @MainActor var text2: Color { style.color(\.text2) }
    @MainActor var muted: Color { style.color(\.text3) }
    /// The accent as a mark or words: Toybox's sun reads on its dark panel; on cream its dark edge does.
    @MainActor var accent: Color { style.color(\.accentText) }
    /// The accent as a fill, with the ink on it.
    @MainActor var accentFill: Color { style.color(\.accent) }
    @MainActor var selected: Color { style.color(\.sunken) }
    /// A popover's title: Toybox's Fredoka.
    @MainActor var headline: Font { toybox ? ToyFace.fredoka(17) : .headline }
    /// Numbers: Toybox's JetBrains Mono.
    @MainActor func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        toybox ? ToyFace.mono(size, bold: weight != .regular) : Theme.mono(size, weight: weight)
    }
    /// Small words under a heading.
    @MainActor var detail: Font { toybox ? ToyFace.nunito(700, 12) : Theme.detail }
}
