import AppKit
import PilotCore
import SwiftUI

// Mockup D's parts (card agent-bo-95422980, Sven approved 2026-10-07): a coloured tile with a symbol, an app's own icon
// with a tile when it is not installed, a picker that shows the chosen app, and cards that wrap into as many columns as
// fit.

/// A tile's colour: one of the theme's roles, or neutral for a kind with none (Plain text).
enum TileColour: String {
    case accent, second, third, good, amber, problem, neutral
}

extension TileColour {
    init(_ tint: MenuIcon.Tint) { self.init(rawValue: tint.rawValue)! }
}

extension MenuIcon {
    /// The app's own icon: at its path once that bundle is on disk, else by its bundle id once installed; a script's
    /// emoji drawn as one (card agent-bo-95423029); else a catalogue entry's shipped picture (C5), one of Your designs
    /// (P55) or a search result's picture once it arrives (N9); nil for a glyph.
    @MainActor func appImage(exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> NSImage? {
        if let appPath, exists(appPath) { return AppsModule.icon(file: appPath) }
        if let emoji { return Self.image(emoji) }
        if let installed = bundle.flatMap(AppsModule.icon(bundle:)) { return installed }
        if let bundled, let image = CatalogueIcons.image(bundled) { return image }
        if let picture, let image = FolderDesigns.rowIcon(picture) { return image }
        return remote.flatMap(RemoteIcons.shared.image)
    }

    /// An emoji as a square image, drawn at whatever size the row gives it.
    private static func image(_ emoji: String) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: rect.height * 0.8)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }
}

/// A MenuIcon on a page: the app at its path or with its bundle id once that app is on the Mac, else its glyph's tile.
struct IconTile: View {
    let icon: MenuIcon
    let size: CGFloat
    /// Shown in place of the glyph when there is no app icon (KitTile's letter).
    var letter: String?

    var body: some View {
        if let image = icon.appImage() {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            KitTile(symbol: icon.symbol, colour: TileColour(icon.tint), size: size, letter: letter)
        }
    }
}

extension View {
    /// A card inside a block (an app in the catalogue, a site in Ideas).
    func innerCard() -> some View { modifier(InnerCard()) }
}

/// An inner card in the style: Toybox's sunk chip with its ink outline and a short edge, Instrument's hairline.
private struct InnerCard: ViewModifier {
    @Environment(\.style) private var style
    func body(content: Content) -> some View {
        if style.kind == .toybox {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .styleSurface(\.key, fill: \.sunken, radius: \.control)
                .contentShape(RoundedRectangle(cornerRadius: style.radii.control, style: .continuous))
        } else {
            // A card on a panel by its hairline alone, as mockup A organises by rules, not fills.
            let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlay { shape.strokeBorder(style.color(\.line2)) }
                .contentShape(shape)
        }
    }
}

/// A symbol on a coloured tile: Toybox's tile in its colour; Instrument's glyph on the raised fill.
struct KitTile: View {
    @Environment(\.style) private var style
    let symbol: String
    let colour: TileColour
    let size: CGFloat
    /// A name's first letter in place of the symbol: an app not on the Mac yet, among others of its kind.
    var letter: String?

    var body: some View {
        if style.kind == .toybox {
            ToyTile(symbol: symbol, color: Toy.tile(colour, style), size: size, letter: letter).accessibilityHidden(true)
        } else {
            // No module colours in Instrument: the glyph or letter in the second text colour on the raised fill.
            InstrumentAppIcon(bundle: nil, symbol: symbol, size: size, letter: letter)
        }
    }
}

/// The first installed app's own icon among `bundles`, else its tile.
struct AppGlyph: View {
    let bundles: [String]
    let symbol: String
    var colour = TileColour.neutral
    let size: CGFloat

    var body: some View {
        if let icon = bundles.lazy.compactMap(AppsModule.icon(bundle:)).first {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            KitTile(symbol: symbol, colour: colour, size: size)
        }
    }
}

/// A picker as a field: the chosen app's icon and name with the up-down chevron; the apps in its menu.
struct AppPickerField<Items: View>: View {
    @Environment(\.ink) private var ink
    let bundle: String?
    let name: String
    /// What VoiceOver calls the picker: "Web links".
    let label: String
    /// 28 pt in a row, 32 pt in a card.
    var compact = false
    /// The glyph while no app is picked.
    var symbol = "questionmark"
    @ViewBuilder var items: Items

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(9), style: .continuous)
        Menu { items.menuRows() } label: {
            HStack(spacing: 8) {
                AppLabel(name: name, bundle: bundle, size: compact ? 16 : 18, symbol: symbol)
                    .lineLimit(1).truncationMode(.tail).foregroundStyle(ink.text)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(ink.system(10, weight: .semibold)).foregroundStyle(ink.muted)
            }
            .font(ink.ui(compact ? 12.5 : 13))
            .padding(.leading, 7).padding(.trailing, 9)
            .frame(maxWidth: .infinity, minHeight: compact ? 28 : 32, maxHeight: compact ? 28 : 32, alignment: .leading)
            .background(ink.selected, in: shape)
            .overlay { shape.strokeBorder(ink.outline, lineWidth: ink.stroke) }
            .contentShape(shape)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(label).accessibilityValue(name)
    }
}

/// Cards in as many columns as fit, each at least `minimum` wide, as CSS grid's auto-fill (a column stays empty when
/// there are fewer cards) or, with `fit`, auto-fit (fewer cards than columns share the row). `stretch` makes each card
/// as tall as the tallest in its row; else each keeps its own height, from the top. `most` caps the columns (Stats' three).
struct CardGrid: Layout {
    var minimum: CGFloat = 220
    var spacing: CGFloat = 8
    var most = Int.max
    var fit = false
    var stretch = false
    /// Taller than the cards need when proposed more: the rows share the extra height (with `stretch`, the cards fill it).
    var grow = false
    /// As few rows as the columns allow, the cards shared out evenly, each row filling the width: seven at four across as
    /// four over three, not four over one (Stats' Overview).
    var balance = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(proposal, subviews.count)
        let height = height(rows(width, subviews))
        if grow, let proposed = proposal.height, proposed.isFinite { return CGSize(width: width, height: max(height, proposed)) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(bounds.width, subviews)
        let extra = grow && !rows.isEmpty ? max(0, bounds.height - height(rows)) / CGFloat(rows.count) : 0
        var y = bounds.minY
        for row in rows {
            let height = row.height + extra
            for (column, i) in row.indices.enumerated() {
                let x = bounds.minX + CGFloat(column) * (row.column + spacing)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: row.column, height: stretch ? height : nil))
            }
            y += height + spacing
        }
    }

    private func height(_ rows: [(indices: Range<Int>, column: CGFloat, height: CGFloat)]) -> CGFloat {
        rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
    }

    /// The proposed width, or every card side by side at the least width when none is proposed.
    private func width(_ proposal: ProposedViewSize, _ count: Int) -> CGFloat {
        if let width = proposal.width, width.isFinite { return width }
        return CGFloat(count) * minimum + CGFloat(max(0, count - 1)) * spacing
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(indices: Range<Int>, column: CGFloat, height: CGFloat)] {
        let fits = max(1, min(most, Int((width + spacing) / (minimum + spacing))))
        let columns = fit ? max(1, min(fits, subviews.count)) : fits
        let column = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        if balance, !subviews.isEmpty {
            let count = (subviews.count + columns - 1) / columns
            var start = 0
            return (0..<count).map { row in
                let size = subviews.count / count + (row < subviews.count % count ? 1 : 0)
                let indices = start..<(start + size)
                start += size
                let column = (width - spacing * CGFloat(size - 1)) / CGFloat(size)
                let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
                return (indices, column, height)
            }
        }
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            let indices = start..<min(start + columns, subviews.count)
            let height = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
            return (indices, column, height)
        }
    }
}
