import PilotCore
import SwiftUI

/// The notes panel's pieces in Instrument (card agent-bo-95423181, ADR 0008; direction B, P60): the window sidebar's
/// idiom. Rows two lines, the title over its words in the third text colour, the time in mono; the picked row raised on
/// a hairline ring with the signal's tick. The drawer's field at the search size (18 pt), the docked one 15 pt with its
/// esc cap; the head's buttons and the format bar raised on a hairline under the pointer. NotesPanelView lays them out.
extension NotesRow {
    var instrument: some View {
        HStack(alignment: line == nil ? .center : .top, spacing: 6) {
            Group {
                if let glyph { Image(systemName: glyph).font(.system(size: 11, weight: .medium)) }
            }
            .frame(width: 14).foregroundStyle(style.color(on ? \.text2 : \.text3)).padding(.top, line == nil ? 0 : 2)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                title.styleText(\.strong).strikethrough(struck, color: style.color(\.text3))
                    .foregroundStyle(style.color(struck ? \.text3 : on || open ? \.text : \.text2))
                if let line { line.styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let time { Text(time).styleText(\.mono).foregroundStyle(style.color(\.text3)).fixedSize().padding(.top, line == nil ? 0 : 2) }
        }
        .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 5)
        .frame(minHeight: line == nil ? 30 : 44)
        .instrumentPicked(on)
        .contentShape(.rect)
    }
}

extension NotesField {
    var instrument: some View {
        HStack(spacing: 10) {
            Image(systemName: confirming ? "trash" : "magnifyingglass").font(.system(size: docked ? 13 : 15, weight: .regular))
                .foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            // The prompt is the field's own, so the Notes page's keys know the field (NotesField.holds).
            TextField("", text: $model.queryField, prompt: Text(prompt).foregroundStyle(style.color(confirming ? \.text2 : \.text3)))
                .textFieldStyle(.plain).font(face).foregroundStyle(style.color(\.text)).lineLimit(1)
                .tint(style.color(\.accent)).focused(focused).accessibilityLabel(prompt)
            if let count {
                Text(ExtensionsPageView.plural(count, "note")).styleText(\.mono).foregroundStyle(style.color(\.text3)).fixedSize()
            } else if docked {
                InstrumentKey(text: "esc")
            }
        }
        .padding(.horizontal, 14).frame(height: docked ? 40 : 46)
        .overlay(alignment: .bottom) { InstrumentRule() }
    }

    /// The search size in the drawer (menu.html's .q), the body's 15 docked.
    private var face: Font { docked ? style.font(\.search, size: 15) : style.font(\.search) }
}

extension NotesHeadButton {
    var instrument: some View {
        Group {
            if let key { InstrumentKey(text: key) } else if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(style.color(hovered ? \.text : \.text2))
            }
        }
        .frame(minWidth: 24, minHeight: 24)
        .instrumentRaised(hovered, radius: 6)
        .contentShape(.rect)
    }
}

extension NotesFormatBar {
    var instrument: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownFormat.allCases) { format in
                Button { handle.apply(format) } label: {
                    Image(systemName: format.symbol).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(style.color(hovered == format ? \.text : \.text2))
                        .frame(width: 26, height: 24)
                        .instrumentRaised(hovered == format, radius: style.radii.chip)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain).focusable(false)
                .onHover { hovered = $0 ? format : hovered == format ? nil : hovered }
                .help(help(format)).accessibilityLabel(format.title)
                if format == .code { InstrumentRule(vertical: true, length: 14).padding(.horizontal, 3) }
            }
        }
        .padding(3)
        .background(style.color(\.panel), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(style.color(\.line2)) }
    }
}

extension NotesTrashQuestion {
    /// Attention's tick before the eyebrow, the note's title, what goes (its keys under it, NotesTrashQuestion).
    var instrument: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                InstrumentTick()
                InstrumentEyebrow(text: "Move to Trash", role: \.text2)
            }
            .frame(height: markdown.h1.line, alignment: .leading)
            Text(note.title).font(Font(markdown.h1.font)).tracking(markdown.h1.tracking).foregroundStyle(style.color(\.text))
                .lineLimit(2).padding(.top, 6)
            Text(detail).styleText(\.body).lineSpacing(5).foregroundStyle(style.color(\.text2))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }
}
