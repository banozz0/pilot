import PilotCore
import SwiftUI

/// The notes panel's pieces in Toybox (card agent-bo-95423182, batch 5; direction B, P60), the window sidebar's idiom:
/// the list on the sunk fill left of an ink rule, under a search well; each row its title over its words, the open one
/// a white keycap and the list's highlight (Escape from the note) the sun's, as the menu's current row; the menu's
/// keycaps in the head and the hints; the format bar one white well with the ink outline. NotesPanelView lays them out.
extension NotesRow {
    var toybox: some View {
        let sun = on && highlight
        let ink = sun ? style.color(\.onAccent) : style.color(struck ? \.text3 : open ? \.text : \.text2)
        return HStack(alignment: line == nil ? .center : .top, spacing: 8) {
            Group {
                if let glyph { Image(systemName: glyph).font(.system(size: 12, weight: .bold)) }
            }
            .frame(width: 14).foregroundStyle(sun ? ink : style.color(\.text3)).padding(.top, line == nil ? 0 : 3)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                title.font(Toy.nunito(open || sun ? 800 : 700, 13.5)).strikethrough(struck, color: style.color(\.text3)).foregroundStyle(ink)
                if let line { line.font(Toy.nunito(600, 12)).foregroundStyle(sun ? ink.opacity(0.75) : style.color(\.text3)) }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let time {
                Text(time).font(Toy.mono(11)).foregroundStyle(sun ? ink.opacity(0.75) : style.color(\.text3)).fixedSize()
                    .padding(.top, line == nil ? 0 : 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(EdgeInsets(top: 4, leading: 2, bottom: 6, trailing: 2))
        .frame(minHeight: line == nil ? 38 : 50)
        .background {
            if on { Toy.block(style, fill: style.color(sun ? \.accent : \.panel), radius: 12, edge: 4) }
        }
        .contentShape(.rect)
    }

}

extension NotesField {
    var toybox: some View {
        HStack(spacing: 8) {
            Image(systemName: confirming ? "trash" : "magnifyingglass").font(.system(size: 14, weight: .bold))
                .foregroundStyle(style.color(\.text2)).accessibilityHidden(true)
            // The prompt is the field's own, so the Notes page's keys know the field (NotesField.holds).
            TextField("", text: $model.queryField, prompt: Text(prompt).foregroundStyle(style.color(confirming ? \.text2 : \.text3)))
                .textFieldStyle(.plain).font(face).lineLimit(1)
                .foregroundStyle(style.color(\.text)).tint(style.color(\.accentText)).focused(focused).accessibilityLabel(prompt)
            if let count {
                Text(ExtensionsPageView.plural(count, "note")).font(Toy.mono(11)).foregroundStyle(style.color(\.text3)).fixedSize()
            } else if docked {
                ToyMenuCap(label: "esc", height: 22)
            }
        }
        .padding(.horizontal, 12).frame(height: docked ? 38 : 44)
        .toyWell(model.listFocused && !confirming ? \.accentSoft : \.panel, radius: 12)
        .padding(10)
    }

    private var face: Font { Toy.nunito(700, docked ? 14 : 17) }
}

extension NotesHeadButton {
    var toybox: some View {
        Group {
            if let key { ToyMenuCap(label: key, height: 22) } else if let symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(style.color(\.text))
                    .frame(width: 26, height: 24)
                    .background { if hovered { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(style.color(\.accentSoft)) } }
            }
        }
        .contentShape(.rect)
    }
}

extension NotesFormatBar {
    var toybox: some View {
        HStack(spacing: 0) {
            ForEach(MarkdownFormat.allCases) { format in
                Button { handle.apply(format) } label: {
                    Image(systemName: format.symbol).font(.system(size: 12, weight: .bold))
                        .foregroundStyle(style.color(\.text))
                        .frame(width: 26, height: 24)
                        .background {
                            if hovered == format { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(style.color(\.accentSoft)) }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain).focusable(false)
                .onHover { hovered = $0 ? format : hovered == format ? nil : hovered }
                .help(help(format)).accessibilityLabel(format.title)
                if format == .code { style.color(\.line2).frame(width: 1.5, height: 14).padding(.horizontal, 3) }
            }
        }
        .padding(3)
        .toyWell(\.panel, radius: 10)
    }
}

extension NotesTrashQuestion {
    /// The trash on a coral tile, the note's title, what goes (its keys under it, NotesTrashQuestion).
    var toybox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ToyTile(symbol: "trash", color: Toy.module(3, style), size: 30).accessibilityHidden(true)
                ToyEyebrow(text: "Move to Trash").accessibilityAddTraits(.isHeader)
            }
            Text(note.title).font(Font(markdown.h1.font)).foregroundStyle(style.color(\.text)).lineLimit(2).padding(.top, 12)
            Text(detail).font(Toy.nunito(600, 15)).lineSpacing(5).foregroundStyle(style.color(\.text2))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }
}
