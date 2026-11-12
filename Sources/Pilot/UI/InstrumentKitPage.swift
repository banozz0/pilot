import PilotCore
import SwiftUI

// The Kit's Instrument branches for a settings page (card agent-bo-95423181, batch 4; ADR 0008): the page's column level
// with the toolbar's inset, a panel with its title on a 44 pt header over a hairline, a heading over a group, a glyph on
// a raised tile, the on/off card, a block's title and the notice row. The Kit's parts (KitPage, PageBody, Tile, KitBlock,
// CalmHeading, SwitchCard, StatsTitle) call these when the surface draws in Instrument.

/// A page's column under the frame's toolbar: its intro line, then the blocks `spacing` apart, 28 pt in at each side as
/// the toolbar's title.
struct InstrumentPage<Content: View>: View {
    @Environment(\.style) private var style
    var intro: String?
    /// The intro's ⓘ: what its one line leaves out.
    var info: String?
    var spacing: CGFloat = 0
    /// The blocks in columns once the page is wide (PageFlow); else one stack.
    var flow = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                if let intro {
                    IntroLine(info: info) {
                        Text(intro).styleText(\.body).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if flow {
                    PageFlow(column: KitPage<EmptyView>.column(.instrument), gap: style.density.padding, spacing: spacing) { content }
                } else {
                    content
                }
            }
            .padding(.horizontal, style.density.page).padding(.top, style.density.padding).padding(.bottom, style.density.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // What a part leaves to the page (a row's title, a field's words, a system control's tint) in the style, not the
        // theme pilotTheme() put at the window's root; the tint quiet, since the signal colour means Hyper.
        .foregroundStyle(style.color(\.text))
        .font(style.font(\.body))
        .tint(style.color(\.text2))
    }
}

/// A block: InstrumentPanel (its glyph, title and what sits at its right on a 44 pt header over a hairline), its note,
/// then its content inset as the header; without a title, the content alone on the panel.
struct InstrumentBlock<Trailing: View, Content: View>: View {
    @Environment(\.style) private var style
    var title: String?
    var symbol: String?
    var note: String?
    /// Takes the height its row gives it, so blocks side by side end level.
    var fill = false
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        if let title {
            InstrumentPanel(title: title, symbol: symbol, stretch: fill) {
                trailing.font(style.font(\.caption)).foregroundStyle(style.color(\.text3))
            } content: { inner }
        } else {
            inner.frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading).styleSurface(\.card)
        }
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note {
                Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
            content
        }
        .padding(.horizontal, style.density.padding).padding(.vertical, InstrumentKitPage.blockPadding)
        .frame(maxHeight: fill ? .infinity : nil, alignment: .top)
    }
}

/// A heading over a group of blocks: the panel title's face, its note quiet under it.
struct InstrumentHeading<Trailing: View>: View {
    @Environment(\.style) private var style
    let title: String
    var note: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                Spacer()
                trailing.font(style.font(\.caption)).foregroundStyle(style.color(\.text3))
            }
            if let note { Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.top, 22).padding(.bottom, 10)
    }
}

/// A block's title beside its glyph, with a quiet note: Stats' blocks and the Menu bar page's Readings.
struct InstrumentTitle: View {
    @Environment(\.style) private var style
    let title: String
    let symbol: String
    var note: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(style.font(\.icon)).foregroundStyle(style.color(\.text3))
            Text(title).styleText(\.title).foregroundStyle(style.color(\.text))
            if let note { Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
        }
        .lineLimit(1).fixedSize()
        .frame(minHeight: InstrumentKitPage.titleHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A page's on/off card (the Menu bar page's top bar): its glyph, whether it is on as the title, what it does, and the
/// switch's button.
struct InstrumentSwitchCard: View {
    @Environment(\.style) private var style
    let symbol: String
    let title: String
    let isOn: Bool
    let busy: Bool
    let detail: String
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            InstrumentAppIcon(bundle: nil, symbol: symbol, size: InstrumentKitPage.tile)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).styleText(\.title).foregroundStyle(style.color(\.text))
                Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(isOn ? "Switch off" : "Switch on", action: toggle).buttonStyle(InstrumentButtonStyle()).disabled(busy)
        }
        .padding(style.density.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .styleSurface(\.card)
    }
}

/// The page parts' measures.
enum InstrumentKitPage {
    /// A notice row's least height (a panel header's), a block's inset above and below its content, a title's least
    /// height, and a big glyph tile.
    static let header: CGFloat = 44, blockPadding: CGFloat = 14, titleHeight: CGFloat = 24, tile: CGFloat = 30
    /// The least column width two blocks share a row at (Setup's two columns').
    static let pairWidth: CGFloat = 880
}

/// Two blocks side by side once the page is `InstrumentKitPage.pairWidth` wide, ending level (a block with `fill` takes
/// the row's height); one over the other narrower (card agent-bo-95423181, batch 6: no page a column of half-empty rows).
/// `level` false lays two columns that each keep their own height, for blocks too unlike to share rows.
struct InstrumentPair<Left: View, Right: View>: View {
    @Environment(\.style) private var style
    var level = true
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right
    @State private var wide = true

    var body: some View {
        // One layout that switches, so the columns keep their identity as the page crosses the width.
        let side = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: style.density.padding)) : AnyLayout(VStackLayout(spacing: 0))
        let stretch = level && wide
        // Level, each column takes the row's height (the pair is as tall as the taller); else each keeps its own, so a
        // block with `fill` does not stretch to the other column's foot.
        side {
            VStack(spacing: 0) { left }.fixedSize(horizontal: false, vertical: !level)
                .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .top)
            VStack(spacing: 0) { right }.fixedSize(horizontal: false, vertical: !level)
                .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: stretch)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width >= InstrumentKitPage.pairWidth } action: { wide = $0 }
    }
}

extension View {
    /// A notice row (Home's problems, the Menu bar page's hidden items): its eyebrow, line and fix inset on the panel
    /// colour under a hairline, the signal's 2 pt tick at its left edge, the card's corner.
    func instrumentNotice() -> some View { modifier(InstrumentNoticeFace()) }
}

private struct InstrumentNoticeFace: ViewModifier {
    @Environment(\.style) private var style

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.card, style: .continuous)
        content
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .frame(minHeight: InstrumentKitPage.header)
            .background(style.color(\.panel), in: shape)
            .overlay(alignment: .leading) { style.color(\.accent).frame(width: 2) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(style.color(\.line)) }
    }
}

/// The Kit's slider in Instrument: InstrumentMeter's track and share (the signal is Hyper's), a knob on its ring; `x` is
/// the value's place along the track `width` long.
struct InstrumentSliderFace: View {
    @Environment(\.style) private var style
    let x: CGFloat
    let width: CGFloat

    var body: some View {
        InstrumentMeter(share: x / width)
        Circle().fill(style.color(\.knob)).frame(width: 14, height: 14)
            .overlay { Circle().strokeBorder(style.color(\.line2)) }
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .offset(x: x - 7)
    }
}

/// Nothing yet, in Instrument: what is missing in the title face, the line that fixes it quiet under it with its keys,
/// and the one action as the inverse button; no picture, as mockup A decorates nothing.
struct InstrumentEmpty: View {
    @Environment(\.style) private var style
    let title: String
    var line: String?
    var keys: [String] = []
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).styleText(\.title).foregroundStyle(style.color(\.text))
            if line != nil || !keys.isEmpty {
                HStack(spacing: 5) {
                    ForEach(keys, id: \.self) { Kbd(text: $0) }
                    if let line { Text(line).styleText(\.body).foregroundStyle(style.color(\.text3)).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if let action { Button(action.title, action: action.run).buttonStyle(InstrumentButtonStyle(kind: .primary)).padding(.top, 7) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
