import PilotCore
import SwiftUI

/// Trigger › Emoji's grid (P39; design launcher-ideas-2026-10-18, frames 1 and 2): each block under its eyebrow with its
/// count, the selected emoji's name at that heading's right, so the cells need no labels; ten 60 pt cells across in
/// Apple's colour emoji at 31 pt, the selected one on the accent's soft fill. Each cell is a navigator row, so the
/// pointer and Return act on it as on the list (MenuBody draws this in its place).
struct EmojiGridView: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    let pointer: PointerTrack

    static let cell: CGFloat = 60

    var body: some View {
        let nav = model.nav, rows = nav.rows, pointing = model.pointedRows(pointer)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: EmojiGrid.columns)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(EmojiGrid.blocks(rows.map(\.section)), id: \.lowerBound) { block in
                        heading(block, rows: rows, selection: nav.selection)
                        LazyVGrid(columns: columns, spacing: 0) {
                            ForEach(block, id: \.self) { i in
                                cell(rows[i], on: i == nav.selection).id(i).pointerRow(pointing, i)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .scrollsToSelection(pointing) { _, new in if let new { proxy.scrollTo(new) } }
        }
        .allowsHitTesting(nav.actions == nil && model.chip == nil)
    }

    /// "SMILEYS & EMOTION 166", and the selected emoji's name at the right of its own block's heading.
    private func heading(_ block: Range<Int>, rows: [MenuEntry], selection: Int) -> some View {
        HStack(spacing: 8) {
            InstrumentEyebrow(text: rows[block.lowerBound].section ?? "")
            Text("\(block.count)").styleText(\.mono).foregroundStyle(style.color(\.text3))
            Spacer(minLength: 12)
            if block.contains(selection), let name = Self.name(of: rows[selection]) {
                Text(name).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).padding(.bottom, 6)
        .frame(maxWidth: .infinity, minHeight: MenuPanelSize.instrumentHeading, alignment: .bottomLeading)
    }

    private func cell(_ row: MenuEntry, on: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Text(Self.glyph(of: row)).font(.system(size: 31 / style.scale))
            .frame(maxWidth: .infinity).frame(height: Self.cell)
            .background(on ? style.color(\.accentSoft) : .clear, in: shape)
            .overlay { if on { shape.strokeBorder(style.color(\.accentLine), lineWidth: 1.5) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.name(of: row) ?? row.title)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    static func glyph(of row: MenuEntry) -> String { if case .emoji(let e) = row.target { e } else { row.title } }

    /// "party popper" from the row "🎉  party popper".
    static func name(of row: MenuEntry) -> String? {
        guard case .emoji(let e) = row.target, row.title.hasPrefix(e) else { return nil }
        return row.title.dropFirst(e.count).trimmingCharacters(in: .whitespaces)
    }

    /// The grid's height: its lines of cells and a heading over each block.
    static func height(_ rows: [MenuEntry]) -> CGFloat {
        let blocks = EmojiGrid.blocks(rows.map(\.section))
        return CGFloat(EmojiGrid.lines(blocks)) * cell + CGFloat(blocks.count) * MenuPanelSize.instrumentHeading
    }
}
