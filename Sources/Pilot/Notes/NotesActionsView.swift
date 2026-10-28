import PilotCore
import SwiftUI

/// Cmd+K's actions on a note (Sven 2026-10-15) in the menu's Cmd+K look, searchable as Raycast's action panel
/// (direction B): what is typed over the actions, then those that match in groups split by rules, each with its key
/// (the formats', ⌘N, ⌘⌫), the Trash in the problem colour, ↵ on the highlighted one; typing, ↑↓ and Return from the
/// panel's keys (NotesKey), a click runs one. Over the note's corner, on the style's pop face.
struct NotesActionsView: View {
    @Environment(\.style) private var style
    @Bindable var model: NotesModel

    var body: some View {
        if let menu = model.actions {
            switch style.kind {
            case .instrument: instrument(menu)
            case .toybox: toybox(menu)
            }
        }
    }

    private func rows<Rule: View, Row: View>(_ menu: NoteActions, @ViewBuilder rule: @escaping () -> Rule,
                                             @ViewBuilder row: @escaping (NoteAction, Bool) -> Row) -> some View {
        let shown = menu.visible
        return VStack(alignment: .leading, spacing: 0) {
            if shown.isEmpty {
                Text("No action called “\(menu.query)”").styleText(\.caption).foregroundStyle(style.color(\.text3))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { index, action in
                if index > 0, action.group != shown[index - 1].group { rule() }
                Button { model.runAction(at: index) } label: { row(action, index == menu.index).contentShape(.rect) }
                    .buttonStyle(.plain).focusable(false)
                    .accessibilityAddTraits(index == menu.index ? .isSelected : [])
            }
        }
    }

    /// The search line: what is typed after the glyph, its caret in the signal colour, or the prompt.
    private func search(_ menu: NoteActions, face: Font, caret: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(style.color(\.text3))
                .accessibilityHidden(true)
            HStack(spacing: 1) {
                if !menu.query.isEmpty { Text(menu.query).foregroundStyle(style.color(\.text)) }
                caret.frame(width: 1.5, height: 15)
                if menu.query.isEmpty { Text("Search actions…").foregroundStyle(style.color(\.text3)).padding(.leading, 1) }
            }
            .font(face).lineLimit(1)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Search actions on \(menu.title): \(menu.query)")
    }

    /// The actions whole when the panel has the room, else scrolling (the smallest panel).
    private func fitted(@ViewBuilder _ list: () -> some View) -> some View {
        let list = list()
        return ViewThatFits(in: .vertical) {
            list
            ScrollView { list }.scrollIndicators(.never)
        }
    }

    // MARK: Instrument

    private func instrument(_ menu: NoteActions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            search(menu, face: style.font(\.body), caret: style.color(\.accent))
                .padding(.horizontal, 12).frame(height: 38, alignment: .leading)
            InstrumentRule()
            fitted {
                rows(menu, rule: { InstrumentRule().padding(.horizontal, 6).padding(.vertical, 4) }) { action, on in
                    let ink: KeyPath<StyleColors, Paint> = action.danger ? \.problem : \.text
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol).font(style.font(\.icon)).frame(width: 18)
                            .foregroundStyle(style.color(on || action.danger ? ink : \.text3)).accessibilityHidden(true)
                        Text(action.title).styleText(\.body).foregroundStyle(style.color(ink))
                        Spacer(minLength: 8)
                        if on { InstrumentKey(text: "↵") } else if let key = action.key { NotesCaps(key: key) }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .instrumentRaised(on)
                }
                .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 6)
            }
        }
        .frame(width: 290)
        .styleSurface(\.pop, fill: \.panel, radius: \.card)
    }

    // MARK: Toybox

    private func toybox(_ menu: NoteActions) -> some View {
        KitPopover(width: 290, inset: 0, arrow: false) {
            search(menu, face: style.toyNunito(700, 13.5), caret: style.color(\.accentText))
                .padding(.horizontal, 14).frame(height: 40, alignment: .leading)
            ToyRule()
            fitted {
                rows(menu, rule: { style.color(\.line2).frame(height: 2).padding(.horizontal, 8).padding(.vertical, 4) }) { action, on in
                    let ink = on ? style.color(\.onAccent) : action.danger ? style.color(\.problem) : style.color(\.text)
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol).font(.system(size: 13, weight: .bold)).frame(width: 20)
                            .foregroundStyle(on || action.danger ? ink : style.color(\.text2)).accessibilityHidden(true)
                        Text(action.title).font(style.toyNunito(800, 13.5)).foregroundStyle(ink).lineLimit(1)
                        Spacer(minLength: 8)
                        if on { ToyMenuCap(label: "↵", onSun: true, height: 24) } else if let key = action.key { NotesCaps(key: key) }
                    }
                    .padding(.horizontal, 10)
                    .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .background { if on { Toy.block(style, fill: style.color(\.accent), radius: 12, edge: 4) } }
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
            }
        }
    }
}

/// A note with no words in it (Sven 2026-10-15): one line under the caret says so, with Delete, which moves the file to
/// the Trash at once, no second question (⌘⌫ does the same). At the words' edge (NotesNote).
struct NotesEmptyNote: View {
    let model: NotesModel
    let markdown: MarkdownStyle

    var body: some View {
        HStack(spacing: 10) {
            Text("This note is empty.").font(Font(markdown.body)).foregroundStyle(Color(markdown.muted))
            Button("Delete") { model.trash(model.current) }
                .buttonStyle(PilotButtonStyle(destructive: true)).controlSize(.small).focusable(false)
                .help("Moves the note’s file to the Trash")
            NotesCaps(key: "⌘⌫")
        }
        .padding(.top, markdown.line + 12)
    }
}
