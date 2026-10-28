import PilotCore
import SwiftUI

/// Launcher › Quicklinks (card agent-bo-95423030) as Configs draws its cards: each link a card with its keyword's key cap,
/// its name, and its URL in mono with {query} lit. A click opens the editor under the cards, as a config's preview opens
/// under its group; Add quicklink opens it empty. Save refuses, in one line, an empty name or keyword, a keyword other
/// than lowercase letters and digits or another link's, and a URL Pilot can not open. Remove asks nothing.
struct QuicklinksList: View {
    /// Where a render or a test starts: a card under the mouse, a link open in the editor as typed, and whether Save was
    /// pressed on it.
    struct Start {
        var hovered: UUID?
        var editing: Quicklink?
        var saved = false
    }

    let book: QuicklinkBook
    /// The link open in the editor, as typed: one of the book's, or a new one.
    @State private var draft: Quicklink?
    /// The draft as Save last refused it.
    @State private var refused: Quicklink?
    private let start: Start

    init(book: QuicklinkBook, start: Start = .init()) {
        self.book = book
        self.start = start
        _draft = State(initialValue: start.editing)
        _refused = State(initialValue: start.saved ? start.editing : nil)
    }

    /// Why Save refused the draft, while it is still what was refused; any change to it clears the line.
    private var refusal: Quicklink.Refusal? { refused == draft ? draft.flatMap(book.refusal(for:)) : nil }

    /// The section's one line saying what a quicklink is (Sven 2026-10-10: "what are quicklinks"), the first link taking
    /// words its example.
    private static func note(_ links: [Quicklink]) -> String {
        let what = "A quicklink opens a site from Hyper+Space by its keyword"
        guard let link = links.first(where: \.takesQuery) else { return what + "." }
        return what + ": type \(link.keyword) pilot to search \(link.name) for pilot."
    }

    var body: some View {
        let links = book.links
        DefaultsSection(title: "Quicklinks", note: Self.note(links) + (links.isEmpty ? "" : " Click one to edit it.")) {
            AccentLink(title: "Add quicklink", chevron: "plus", action: add)
        } content: {
            if links.isEmpty && draft == nil {
                EmptyState(title: "No quicklinks", line: "Add one, and its keyword opens it from Hyper+Space.")
            } else {
                CardGrid(minimum: 300, fit: true, stretch: true) {
                    ForEach(links) { link in
                        QuicklinkCard(link: link, editing: draft?.id == link.id, hovered: start.hovered == link.id,
                                      edit: { toggle(link) }, remove: { remove(link.id) })
                    }
                }
            }
            if let open = Binding(unwrapping: $draft) {
                let saved = book.link(open.wrappedValue.id)
                QuicklinkEditor(draft: open, title: saved?.name, refusal: refusal, save: save, cancel: close,
                                remove: saved.map { link in { remove(link.id) } })
                    .padding(.top, 8)
            }
        }
    }

    // MARK: Doing

    private func add() {
        if let draft, book.link(draft.id) == nil { return }
        withAnimation(Kit.change) { draft = Quicklink(name: "", keyword: "", url: "") }
    }

    /// Opens `link` in the editor, or closes the editor when it is open on it.
    private func toggle(_ link: Quicklink) {
        withAnimation(Kit.change) { draft = draft?.id == link.id ? nil : link }
    }

    private func save() {
        guard let draft else { return }
        if book.save(draft) != nil { refused = draft } else { close() }
    }

    private func close() {
        withAnimation(Kit.change) { draft = nil }
    }

    private func remove(_ id: UUID) {
        withAnimation(Kit.change) {
            book.remove(id)
            if draft?.id == id { draft = nil }
        }
    }
}

/// One link's card: its keyword's key cap and its name, its URL under them. The mouse over it firms its edge and shows
/// Edit and Remove; a click anywhere on it opens it in the editor, which its focus border then marks.
private struct QuicklinkCard: View {
    @Environment(\.ink) private var ink
    let link: Quicklink
    let editing: Bool
    @State private var hovered: Bool
    let edit: () -> Void
    let remove: () -> Void

    /// `hovered` starts a render with the mouse over it.
    init(link: Quicklink, editing: Bool, hovered: Bool, edit: @escaping () -> Void, remove: @escaping () -> Void) {
        self.link = link
        self.editing = editing
        _hovered = State(initialValue: hovered)
        self.edit = edit
        self.remove = remove
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        Button(action: edit) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Kbd(text: link.keyword)
                    Text(link.name).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                        // Clear of Edit and Remove.
                        .padding(.trailing, 50)
                }
                QuicklinkURL(url: link.url)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxHeight: .infinity, alignment: .top)
            .blockSurface()
            .overlay { if hovered { shape.strokeBorder(ink.line2, lineWidth: 0.5) } }
            .focusBorder(on: editing, radius: ink.blockRadius)
            .contentShape(shape)
        }
        .buttonStyle(.kitPress)
        .accessibilityLabel("\(link.name), keyword \(link.keyword), \(link.url)")
        .accessibilityHint(editing ? "Closes the editor" : "Edits it")
        .accessibilityAction(named: "Remove \(link.name)", remove)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                IconButton(symbol: "pencil", label: "Edit \(link.name)", action: edit)
                IconButton(symbol: "trash", label: "Remove \(link.name)", action: remove)
            }
            .padding(6)
            .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).accessibilityHidden(!hovered)
        }
        .onHover { inside in withAnimation(Kit.change) { hovered = inside } }
    }
}

/// A link's URL in mono and muted, {query} lit: without https://, which nearly every link starts with, and cut in the
/// middle when the card is too narrow, so the host and {query} both stay.
private struct QuicklinkURL: View {
    @Environment(\.ink) private var ink
    let url: String

    var body: some View {
        let shown = url.hasPrefix("https://") ? String(url.dropFirst(8)) : url
        Self.styled(shown, query: ink.mark(ink.accentText)).font(ink.mono(11.5)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.middle)
            .help(url)
    }

    /// `url` with each {query} in the accent.
    static func styled(_ url: String, query colour: Color) -> Text {
        let parts = url.components(separatedBy: Quicklink.placeholder)
        let query = Text(verbatim: Quicklink.placeholder).foregroundStyle(colour)
        return parts.dropFirst().reduce(Text(verbatim: parts[0])) { text, part in Text("\(text)\(query)\(Text(verbatim: part))") }
    }
}

/// The open link, under the cards as Configs' preview: its name with Remove, Cancel and Save, then its fields (name,
/// keyword and URL on one line when they fit), and under them what typing it in Hyper+Space opens, or the refusal.
/// Return saves, Escape cancels.
private struct QuicklinkEditor: View {
    @Environment(\.ink) private var ink
    @Binding var draft: Quicklink
    /// The saved link's name; nil for a new one.
    let title: String?
    let refusal: Quicklink.Refusal?
    let save: () -> Void
    let cancel: () -> Void
    let remove: (() -> Void)?
    @FocusState private var focus: Quicklink.Refusal.Field?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                KitTile(symbol: "link", colour: .accent, size: 18)
                Text(title ?? "New quicklink").font(ink.ui(13, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                Spacer(minLength: 8)
                if let remove { Button("Remove", action: remove).buttonStyle(.pilotDestructive).fixedSize() }
                Button("Cancel", action: cancel).buttonStyle(.pilot).fixedSize()
                Button(action: save) { Text(title == nil ? "Add" : "Save") }
                    .buttonStyle(.pilotPrimary).fixedSize()
                    .accessibilityLabel(title.map { "Save \($0)" } ?? "Add quicklink")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            ink.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) { name.frame(width: 220); keyword; url.frame(minWidth: 300) }
                    VStack(alignment: .leading, spacing: 10) { HStack(alignment: .top, spacing: 10) { name; keyword }; url }
                }
                if let refusal { FinePrint(text: refusal.line, color: ink.yellow) } else { example }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        }
        .blockSurface()
        .clipShape(shape)
        .onSubmit(save)
        .onExitCommand(perform: cancel)
        .onAppear { focus = refusal?.field ?? .name }
        .onChange(of: refusal) { _, refusal in if let refusal { focus = refusal.field } }
    }

    private var name: some View {
        field("Name", .name, prompt: "GitHub", info: "What the link is called in Hyper+Space and on its card.", text: $draft.name)
    }
    private var keyword: some View {
        field("Keyword", .keyword, prompt: "gh", info: "What you type in Hyper+Space to open it: lowercase letters and digits.",
              text: $draft.keyword).frame(width: 120)
    }
    private var url: some View {
        field("URL", .url, prompt: "https://github.com/search?q={query}",
              info: "The page it opens; {query} in it takes the words typed after the keyword.", text: $draft.url)
    }

    /// A field with its label and ⓘ over it; the keyword and URL in mono.
    private func field(_ label: String, _ id: Quicklink.Refusal.Field, prompt: String, info: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label).font(ink.ui(11.5, .semibold)).foregroundStyle(ink.muted).accessibilityHidden(true)
                InfoMark(text: info)
            }
            TextField(label, text: text, prompt: Text(verbatim: prompt).foregroundStyle(ink.muted))
                .font(id == .name ? .system(size: 12.5) : ink.mono(12))
                .autocorrectionDisabled(id != .name)
                .focused($focus, equals: id)
                .pilotField()
        }
    }

    /// What typing the link opens, with a word after its keyword when it takes some; until it opens, what {query} does.
    private var example: some View {
        let link = draft.trimmed
        let typed = link.takesQuery ? "\(link.keyword) pilot" : link.keyword
        let mono = ink.mono(11.5)
        return Group {
            if !link.keyword.isEmpty, let opens = link.url(query: "pilot") {
                Text("Hyper+Space \(Text(verbatim: typed).font(mono).foregroundStyle(ink.text2)) opens \(Text(verbatim: opens.absoluteString).font(mono))")
            } else {
                Text("\(Text(verbatim: Quicklink.placeholder).font(mono).foregroundStyle(ink.mark(ink.accentText))) in the URL takes the words typed after the keyword.")
            }
        }
        .font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.middle).padding(.horizontal, 2)
    }
}
