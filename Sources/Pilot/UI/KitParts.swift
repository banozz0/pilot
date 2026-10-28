import AppKit
import SwiftUI

// Parts several pages share, moved out of Home (card agent-bo-95422992) so Home's rewrite leaves them where Stats, Menu
// bar, Install, Defaults and the dropdown find them.

/// An app's own icon by its bundle id when given, else the running app's by its name, else its first letter on the raised
/// colour, or `glyph` (a process with no app, on Stats' Busiest apps).
struct AppIcon: View {
    let name: String
    var bundle: String?
    var size: CGFloat = 16
    var glyph: String?

    var body: some View {
        if let icon = bundle.flatMap(AppsModule.icon(bundle:)) ?? AppsModule.icon(named: name) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else if let glyph {
            Image(systemName: glyph).font(.system(size: size * 0.55)).foregroundStyle(Theme.muted)
                .frame(width: size, height: size).background(Theme.text.opacity(0.08), in: .rect(cornerRadius: size * 0.25))
        } else {
            Text(name.prefix(1).uppercased()).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(Theme.text2)
                .frame(width: size, height: size).background(Theme.line2, in: .rect(cornerRadius: size * 0.27))
        }
    }
}

/// Lays its children in a row at their own widths against its trailing edge and, short of room, takes only as many as
/// fit from the trailing end: the leading ones go whole, as a crowded macOS menu bar hides its leftmost items, never part
/// of one. The ones that go sit past the leading edge, for the caller to clip.
struct TrailingRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let kept = sizes.suffix(Self.kept(sizes.map(\.width), spacing: spacing, room: proposal.width ?? .infinity))
        return CGSize(width: kept.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, kept.count - 1)),
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.maxX
        for view in subviews.reversed() {
            let size = view.sizeThatFits(.unspecified)
            x -= size.width
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            x -= spacing
        }
    }

    /// How many of `widths`, counted from the end, fit in `room` with `spacing` between them.
    static func kept(_ widths: [CGFloat], spacing: CGFloat, room: CGFloat) -> Int {
        var used = -spacing, count = 0
        for width in widths.reversed() {
            used += spacing + width
            if used > room { break }
            count += 1
        }
        return count
    }
}

/// Lays its children out in rows, wrapping to the next when one is full.
struct Flow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, $0.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY, i = 0
        for row in arrange(width: bounds.width, subviews) {
            let height = row.map(\.height).max() ?? 0
            var x = bounds.minX
            for size in row {
                subviews[i].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
                i += 1
            }
            y += height + lineSpacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]], used: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty, used + spacing + size.width > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(size)
        }
        return rows
    }
}

/// A small heading inside a part or a card: "Output", "Typing in"; an extension's "Commands" (Setup, ExtensionsPageView).
struct PartHeading: View {
    @Environment(\.ink) private var ink
    let text: String
    var body: some View {
        Group {
            // Instrument's group label: its mono capitals (mockup A's eyebrow).
            if ink.isInstrument { InstrumentEyebrow(text: text) } else {
                Text(text).font(ink.ui(11.5, .semibold)).foregroundStyle(ink.muted).textCase(.uppercase).kerning(0.4)
            }
        }
        .padding(.top, 12).padding(.bottom, 4).accessibilityAddTraits(.isHeader)
    }
}
