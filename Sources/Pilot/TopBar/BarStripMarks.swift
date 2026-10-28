import AppKit
import PilotCore
import SwiftUI

/// A drag over the Menu bar page's top bar strip (Q185; drawn on the bar itself by the parked edit mode, design
/// JJPiA9o30SA version 1, "Editing"): every side a dashed zone in the dim accent, the one the drop lands on brighter with
/// its name in a small caps chip beside it, and a caret where the item will land. Never takes a click.
struct BarDropMarks: View {
    @Environment(\.style) private var style
    /// The strip's slots as drawn.
    let drop: BarDrop
    /// Where the item would land now; nil draws the zones alone.
    let target: BarDrop.Target?

    var body: some View {
        let marks = Marks(style)
        GeometryReader { geometry in
            let size = geometry.size
            ForEach(TopBarSide.allCases, id: \.self) { side in
                zone(drop.zone(side), lit: target?.side == side, height: size.height, marks: marks)
            }
            if let target {
                BarCaret(x: target.caret, height: size.height)
                label(target.side, zone: drop.zone(target.side), width: size.width, marks: marks)
            }
        }
        .allowsHitTesting(false)
    }

    private func zone(_ span: ClosedRange<Double>, lit: Bool, height: CGFloat, marks: Marks) -> some View {
        let shape = RoundedRectangle(cornerRadius: marks.zoneRadius, style: .continuous)
        return shape.fill(lit ? marks.zoneFill : .clear)
            .overlay { shape.strokeBorder(lit ? marks.zoneLit : marks.zoneDim, style: StrokeStyle(lineWidth: marks.zoneWidth, dash: [4, 3])) }
            .frame(width: span.upperBound - span.lowerBound, height: height - 4)
            .position(x: (span.lowerBound + span.upperBound) / 2, y: height / 2)
    }

    /// LEFT, CENTRE or RIGHT outside its zone: right of the left side's, left of the others'.
    private func label(_ side: TopBarSide, zone: ClosedRange<Double>, width: CGFloat, marks: Marks) -> some View {
        let lead = side == .left
        let shape = RoundedRectangle(cornerRadius: marks.labelRadius, style: .continuous)
        return Group {
            if style.kind == .instrument {
                Text(side.rawValue).styleText(\.eyebrow)
            } else {
                Text(side.rawValue.uppercased()).font(style.kind == .toybox ? ToyFace.nunito(800, 10) : .system(size: 10, weight: .semibold))
                    .tracking(style.kind == .toybox ? 1 : 1.4)
            }
        }
            .foregroundStyle(marks.labelInk)
            .padding(.horizontal, 7).frame(height: 18)
            .background(marks.labelFill, in: shape)
            .overlay { if let outline = marks.labelOutline { shape.strokeBorder(outline.color, lineWidth: outline.width) } }
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: lead ? .leading : .trailing)
            .padding(lead ? .leading : .trailing, lead ? zone.upperBound + 8 : width - zone.lowerBound + 8)
    }

    /// The drag's marks in each style: the caret, the zones and the side's label. Toybox's
    /// the ink and the sun's dark edge; Instrument's the signal (the zone under the pointer and the caret are what is
    /// picked), the other zones a quiet hairline.
    struct Marks {
        var caret: Color, caretWidth: CGFloat
        var zoneRadius: CGFloat, zoneFill: Color, zoneLit: Color, zoneDim: Color, zoneWidth: CGFloat
        var labelRadius: CGFloat, labelInk: Color, labelFill: Color, labelOutline: (color: Color, width: CGFloat)?

        @MainActor init(_ style: StyleTokens) {
            switch style.kind {
            case .instrument:
                let accent = style.color(\.accent)
                (caret, caretWidth) = (accent, 2)
                (zoneRadius, zoneFill, zoneLit, zoneDim, zoneWidth) = (style.radii.control, style.color(\.accentSoft), style.color(\.accentLine), style.color(\.line3), 1)
                (labelRadius, labelInk, labelFill) = (style.radii.chip, style.color(\.accentText), style.color(\.accentSoft))
                labelOutline = (style.color(\.accentLine), 1)
            case .toybox:
                // Toybox's: the sun's soft fill under the pointer, its dark edge dashed.
                let mark = style.color(\.accentEdge)
                (caret, caretWidth) = (style.color(\.outline), 3)
                (zoneRadius, zoneFill, zoneLit, zoneDim, zoneWidth) = (12, style.color(\.accentSoft).opacity(0.35), mark.opacity(0.9), mark.opacity(0.45), 2)
                (labelRadius, labelInk, labelFill) = (6, style.color(\.onAccent), style.color(\.accent))
                labelOutline = (style.color(\.outline), 2)
            }
        }
    }
}

/// The dragged item under the pointer: a raised chip, drawing the slot as the bar does, or for an item from the tray its
/// symbol and name (an extension's its emoji and title).
struct BarDragChip: View {
    @Environment(\.style) private var style
    let kind: BarKind
    let slot: BarSlot?
    /// The tiler's monitor name for the bar it left, for the workspaces item.
    let screen: String
    let sources: BarSources
    let store: BarItemsStore
    /// An extension's item: its emoji and title in place of the kind's symbol and name.
    var extensionItem: (icon: String, title: String)?

    var body: some View {
        switch style.kind {
        case .toybox: toybox
        case .instrument: instrument
        }
    }

    /// Instrument's: the slot on a raised key, its hairline ring and the key's edge under it.
    private var instrument: some View {
        label
            .styleText(\.caption).foregroundStyle(style.color(\.text)).lineLimit(1)
            .padding(.horizontal, InstrumentBar.pillInset).frame(height: style.density.control)
            .styleSurface(\.key, fill: \.raised, radius: \.control)
            .padding(BarDragChip.margin)
            .fixedSize()
    }

    /// Toybox's: the slot as an island lifted off the bar, outlined with its edge, no blur.
    private var toybox: some View {
        label
            .font(ToyFace.nunito(800, 12.5)).foregroundStyle(style.color(\.text)).lineLimit(1)
            .padding(.horizontal, 10).frame(height: 26)
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
            .background(Toy.block(style, fill: style.color(\.raised), radius: 10, edge: 4))
            .rotationEffect(.degrees(-2))
            .padding(BarDragChip.margin)
            .fixedSize()
    }

    private var label: some View {
        Group {
            if let slot {
                TopBarSlotView(slot: slot, screen: screen, sources: sources, store: store).allowsHitTesting(false)
            } else if let extensionItem {
                HStack(spacing: 6) { Text(extensionItem.icon); Text(extensionItem.title) }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol).foregroundStyle(BarInk(style: style).text2)
                    Text(kind.title)
                }
            }
        }
    }

    static let margin: CGFloat = 14
}

/// Where a dragged item lands along a strip: the style's caret, a bar's height less its margins, centred on `x`.
struct BarCaret: View {
    @Environment(\.style) private var style
    let x: CGFloat
    let height: CGFloat

    var body: some View {
        let marks = BarDropMarks.Marks(style)
        Capsule().fill(marks.caret).frame(width: marks.caretWidth, height: max(height - 8, 4))
            .position(x: x, y: height / 2)
            .allowsHitTesting(false)
    }
}
