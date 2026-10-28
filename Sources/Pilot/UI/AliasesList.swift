import PilotCore
import SwiftUI

/// Launcher › Aliases (card agent-bo-95423037) as Quicklinks draws its cards: each alias a card with its key cap, the
/// row's title and its kind; a click opens the editor under the cards, as a config's preview opens under its group.
/// Aliases come from the menu, a row's ⌘K › Set alias…, which opens this page with the editor on that row
/// (`asked`, AppWindowModel.editAlias) and brings it into view on `page`, the page's scroll; so there is no Add here. Save refuses, in one
/// line under the field, what AliasBook refuses; an empty alias removes it, as Remove does.
struct AliasesList: View {
    /// Where a render or a test starts: a card under the mouse, an alias open in the editor as typed, and whether Save was
    /// pressed on it.
    struct Start {
        var hovered: String?
        var editing: Alias?
        var saved = false
    }

    /// Why Save refused the draft, kept while the draft is still what was refused.
    private struct Refusal: Equatable {
        let draft: Alias
        let line: String
    }

    let book: AliasBook
    /// The row the menu's Set alias… asked for: the editor opens on it and clears it.
    private let asked: Binding<Alias?>
    /// The page's scroll, which brings the asked row's editor into view; nil draws the section alone.
    private let page: ScrollViewProxy?
    /// The row open in the editor, its alias as typed.
    @State private var draft: Alias?
    @State private var refused: Refusal?
    /// The menu asked for the open row: the editor is brought into view as it shows.
    @State private var reveal = false
    private let start: Start

    /// The editor's id, which the page scrolls to when the menu asked for a row.
    private static let editorID = "alias-editor"

    init(book: AliasBook = .shared, asked: Binding<Alias?> = .constant(nil), page: ScrollViewProxy? = nil, start: Start = .init()) {
        self.book = book
        self.asked = asked
        self.page = page
        self.start = start
        _draft = State(initialValue: start.editing)
        // Save pressed on the draft: the line Save gets, from a copy of the aliases, so a render writes nothing.
        if start.saved, let draft = start.editing {
            var aliases = book.aliases
            _refused = State(initialValue: aliases.set(draft.alias, for: draft.key, title: draft.title).map { Refusal(draft: draft, line: $0) })
        }
    }

    /// The line under the field: Save's refusal while the draft is what it refused; any change to it clears the line.
    private var refusal: String? { refused.flatMap { $0.draft == draft ? $0.line : nil } }

    /// The section's one line saying what an alias is (Sven 2026-10-10), the first alias its example.
    private func note(_ aliases: [Alias]) -> String {
        let what = "An alias is a short name for a Hyper+Space row: type it and that row comes first"
        guard let first = aliases.first else { return what + "." }
        return what + ", as \(first.alias) for \(first.title). Click one to edit it."
    }

    var body: some View {
        let aliases = Self.sorted(book.aliases.all)
        DefaultsSection(title: "Aliases", note: note(aliases)) {
            if !aliases.isEmpty {
                let slot = Self.slot(aliases)
                CardGrid(minimum: 230) {
                    ForEach(aliases) { alias in
                        AliasCard(alias: alias, slot: slot, editing: draft?.key == alias.key, hovered: start.hovered == alias.key,
                                  edit: { toggle(alias) }, remove: { remove(alias) })
                    }
                }
            } else if draft == nil {
                empty
            }
            if let open = Binding(unwrapping: $draft) {
                AliasEditor(draft: open, isNew: book.aliases.alias(for: open.wrappedValue.key) == nil, refusal: refusal,
                            save: save, cancel: close, remove: { remove(open.wrappedValue) })
                    .id(Self.editorID)
                    .padding(.top, aliases.isEmpty ? 0 : 8)
                    // Once the editor is in the page, not before: a scroll to a view not laid out yet goes nowhere.
                    .onChange(of: reveal, initial: true) { revealEditor() }
            }
            if !aliases.isEmpty {
                FinePrint(text: "Add one from Hyper+Space: ⌘K on a row, then Set alias…").padding(.top, 8)
            }
        }
        .onChange(of: asked.wrappedValue, initial: true) { take() }
    }

    /// No alias yet: how to set one.
    private var empty: some View {
        EmptyState(title: "No aliases", line: "Press ⌘K on a row in Hyper+Space, then Set alias…")
    }

    /// By alias, as a keymap reads.
    static func sorted(_ aliases: [Alias]) -> [Alias] {
        aliases.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    /// The key cap every card makes room for, so the titles start on one edge: the longest alias, up to six letters (a
    /// longer one takes its own room).
    static func slot(_ aliases: [Alias]) -> String {
        String(aliases.map(\.alias).max { $0.count < $1.count }?.prefix(6) ?? "")
    }

    // MARK: Doing

    /// Opens the editor on the row the menu's Set alias asked for, with its alias as saved, once (the ask is cleared),
    /// brought into view as it shows: the menu sent Sven here for it. No slide: the window comes forward on it, so he was
    /// not watching the page.
    private func take() {
        guard let row = asked.wrappedValue else { return }
        asked.wrappedValue = nil
        refused = nil
        draft = Alias(key: row.key, alias: book.aliases.alias(for: row.key) ?? "", title: row.title)
        reveal = true
    }

    private func revealEditor() {
        guard reveal else { return }
        reveal = false
        page?.scrollTo(Self.editorID, anchor: .center)
    }

    /// Opens `alias` in the editor, or closes the editor when it is open on it.
    private func toggle(_ alias: Alias) {
        refused = nil
        withAnimation(Kit.change) { draft = draft?.key == alias.key ? nil : alias }
    }

    private func save() {
        guard let draft else { return }
        if let line = book.set(draft.alias, for: draft.key, title: draft.title) { refused = Refusal(draft: draft, line: line) } else { close() }
    }

    private func close() {
        withAnimation(Kit.change) { draft = nil }
    }

    /// Removes the row's alias; when the book refuses (its file unreadable), the editor opens on it with the line.
    private func remove(_ alias: Alias) {
        guard let saved = book.aliases.all.first(where: { $0.key == alias.key }) else { return close() }
        if let line = book.set("", for: saved.key, title: saved.title) {
            refused = Refusal(draft: saved, line: line)
            withAnimation(Kit.change) { draft = saved }
        } else if draft?.key == saved.key {
            close()
        }
    }
}

extension Alias {
    /// The field's placeholder: the title's initials ("Web app picker" wap), or a one-word title's first two letters, in
    /// the lowercase letters and digits an alias takes.
    static func suggestion(for title: String) -> String {
        let words = title.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let suggestion = words.count > 1 ? String(words.prefix(4).compactMap(\.first)) : String(words.first?.prefix(2) ?? "")
        return suggestion.isEmpty ? "wp" : suggestion
    }
}

/// One alias's card: its key cap, the row's title, the row's kind at its right. The mouse over it firms its edge and
/// swaps the kind for Edit and Remove; a click anywhere on it opens it in the editor, which its focus border then marks.
private struct AliasCard: View {
    @Environment(\.ink) private var ink
    let alias: Alias
    /// The key cap the card makes room for (AliasesList.slot).
    let slot: String
    let editing: Bool
    @State private var hovered: Bool
    let edit: () -> Void
    let remove: () -> Void

    /// `hovered` starts a render with the mouse over it.
    init(alias: Alias, slot: String, editing: Bool, hovered: Bool, edit: @escaping () -> Void, remove: @escaping () -> Void) {
        self.alias = alias
        self.slot = slot
        self.editing = editing
        _hovered = State(initialValue: hovered)
        self.edit = edit
        self.remove = remove
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        Button(action: edit) {
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    Kbd(text: slot).hidden().accessibilityHidden(true)
                    Kbd(text: alias.alias)
                }
                Text(alias.title).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(alias.title)
                // The kind and the mouse's Edit and Remove share one place, so the title never re-cuts under them.
                Text(alias.kindWord ?? "").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).fixedSize()
                    .frame(minWidth: 50, alignment: .trailing).opacity(hovered ? 0 : 1)
            }
            .padding(.leading, 11).padding(.trailing, 12).padding(.vertical, 10)
            .frame(maxHeight: .infinity)
            .blockSurface()
            .overlay { if hovered { shape.strokeBorder(ink.line2, lineWidth: 0.5) } }
            .focusBorder(on: editing, radius: ink.blockRadius)
            .contentShape(shape)
        }
        .buttonStyle(.kitPress)
        .accessibilityLabel("\(alias.title), alias \(alias.alias)" + (alias.kindWord.map { ", \($0)" } ?? ""))
        .accessibilityHint(editing ? "Closes the editor" : "Edits it")
        .accessibilityAction(named: "Remove the alias", remove)
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) {
                IconButton(symbol: "pencil", label: "Edit \(alias.title)’s alias", action: edit)
                IconButton(symbol: "trash", label: "Remove \(alias.title)’s alias", action: remove)
            }
            .padding(.trailing, 7)
            .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).accessibilityHidden(!hovered)
        }
        .onHover { inside in withAnimation(Kit.change) { hovered = inside } }
    }
}

/// The open row, under the cards as Configs' preview: its title and kind with Remove, Cancel and Save, then the alias
/// field and under it what typing the alias does, or why Save refused it. Return saves, Escape cancels.
private struct AliasEditor: View {
    @Environment(\.ink) private var ink
    @Binding var draft: Alias
    /// The row has no alias saved yet.
    let isNew: Bool
    let refusal: String?
    let save: () -> Void
    let cancel: () -> Void
    let remove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                KitTile(symbol: "character.cursor.ibeam", colour: .accent, size: 18)
                Text(draft.title).font(ink.ui(13, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                if let kind = draft.kindWord { Text(kind).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).fixedSize() }
                Spacer(minLength: 8)
                if !isNew { Button("Remove", action: remove).buttonStyle(.pilotDestructive).fixedSize() }
                Button("Cancel", action: cancel).buttonStyle(.pilot).fixedSize()
                Button(action: save) { Text(isNew ? "Add" : "Save") }
                    .buttonStyle(.pilotPrimary).fixedSize()
                    .accessibilityLabel("\(isNew ? "Add" : "Save") \(draft.title)’s alias")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            ink.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Alias").font(ink.ui(11.5, .semibold)).foregroundStyle(ink.muted).accessibilityHidden(true)
                        InfoMark(text: "The short name you type in Hyper+Space to list this row first: lowercase letters and digits.")
                    }
                    TextField("Alias", text: $draft.alias, prompt: Text(verbatim: Alias.suggestion(for: draft.title)).foregroundStyle(ink.muted))
                        .font(ink.mono(12))
                        .autocorrectionDisabled()
                        .focused($focused)
                        .pilotField()
                        .frame(width: 180)
                }
                if let refusal { FinePrint(text: refusal, color: ink.yellow) } else { example }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        }
        .blockSurface()
        .clipShape(shape)
        .onSubmit(save)
        .onExitCommand(perform: cancel)
        .onAppear { focused = true }
    }

    /// What typing the alias does; with nothing typed, what an alias is, or that saving it empty removes it.
    private var example: some View {
        let typed = draft.alias.trimmingCharacters(in: .whitespaces)
        let mono = ink.mono(11.5)
        return Group {
            if !typed.isEmpty {
                Text("Hyper+Space \(Text(verbatim: typed).font(mono).foregroundStyle(ink.text2)) lists \(draft.title) first.")
            } else if !isNew {
                Text("Save it empty to remove the alias.")
            } else {
                Text("Lowercase letters and digits. Typed alone in Hyper+Space, it lists this row first.")
            }
        }
        .font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.tail).padding(.horizontal, 2)
    }
}
