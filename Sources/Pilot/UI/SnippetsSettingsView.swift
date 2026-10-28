import PilotCore
import SwiftUI

/// Snippets, its own page since 2026-10-10 (card agent-bo-95423044; Raycast's Snippets the reference, no code): the snippets on the left,
/// the picked one on the right with its name, keyword and text, the placeholders that go in at the caret, and what it
/// pastes as. Every edit is saved as it is typed (SnippetLibrary); nothing here reads the pasteboard.
struct SnippetsSettingsView: View {
    @Environment(\.ink) private var ink
    @State private var editor: SnippetsEditor
    /// The caret or selection in the text, where a placeholder goes in.
    @State private var selection: TextSelection?
    @State private var confirmingDelete = false
    @FocusState private var focus: Field?

    private enum Field { case name, keyword, text }

    static let intro = "Saved text you paste by typing its keyword in any app."
    /// One line of either field, so Name (system face) and Keyword (mono, taller) stand level.
    private static let fieldLine: CGFloat = 17

    /// `library` is a temp file's in tests; `selected` the snippet picked as the page opens, else the first.
    init(library: SnippetLibrary = .shared, selected: UUID? = nil) {
        _editor = State(initialValue: SnippetsEditor(library: library, selected: selected))
    }

    var body: some View {
        KitPage(intro: Self.intro) {
            if let failed = editor.library.failed { FinePrint(text: failed, color: ink.red).padding(.top, 12) }
            if let current = editor.current { filled(current) } else { empty }
        }
        .onChange(of: editor.selected) { selection = nil }
        .confirmationDialog(Text("Delete “\(editor.current.map { SnippetsEditor.title($0) } ?? "")”?"),
                            isPresented: $confirmingDelete, presenting: editor.current) { snippet in
            Button("Delete snippet", role: .destructive) { editor.delete(snippet.id) }
        } message: { snippet in
            Text(snippet.keyword.isEmpty ? "It leaves Hyper+Space at once." : "\(snippet.keyword) stops expanding at once.")
        }
    }

    private func add() {
        editor.add()
        // The name field is drawn on the next pass; it takes the keys then.
        Task { focus = .name }
    }

    // MARK: Empty

    /// No snippets: what one does, with New snippet, beside what its text can hold.
    @ViewBuilder private var empty: some View {
        let state = EmptyState(title: "No snippets yet", line: "Type ;cm anywhere and your saved text takes its place.",
                               action: ("New snippet", add))
        if ink.isInstrument {
            InstrumentPair {
                KitBlock(title: "Snippets", symbol: "text.quote", fill: true) { state.padding(.vertical, 6) }
            } right: {
                KitBlock(title: "What the text can hold", symbol: "curlybraces", fill: true) { legend }
            }
        } else {
            KitBlock(title: "Snippets", symbol: "text.quote") { state.padding(.vertical, 14) }
            KitBlock(title: "What the text can hold", symbol: "curlybraces") { legend }
        }
    }

    /// Each placeholder and what it becomes, one to a row.
    @ViewBuilder private var legend: some View {
        ForEach(Array(SnippetsEditor.placeholders(now: Date()).enumerated()), id: \.element.token) { i, placeholder in
            BlockRow(first: i == 0) {
                PlaceholderToken(token: placeholder.token).frame(width: PlaceholderToken.column, alignment: .leading)
                Text(placeholder.line).foregroundStyle(ink.text2).lineLimit(1)
            }
        }
    }

    // MARK: List and editor

    private func filled(_ current: Snippet) -> some View {
        // Side by side while the editor keeps room for its fields; stacked in a narrow window.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                list(current).frame(width: 250)
                edit(current)
            }
            .frame(minWidth: 640, idealWidth: 640, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) { list(current); edit(current) }
        }
    }

    private func list(_ current: Snippet) -> some View {
        let snippets = editor.library.snippets
        let new = Button(action: add) { Label("New snippet", systemImage: "plus") }.buttonStyle(.pilot)
        return KitBlock(title: "Snippets", symbol: "text.quote", fill: true) {
            Text("\(snippets.count)").font(ink.mono(11)).foregroundStyle(ink.muted)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(snippets) { row($0, selected: $0.id == current.id) }
            }
            // The rows' words on the block's own edge; their selection reaches past it.
            .padding(.horizontal, -8).padding(.vertical, 6)
            BlockRow { new; Spacer() }
        }
    }

    /// A snippet in the list: its name over its first line, its keyword on the right, marked when another has it too.
    private func row(_ snippet: Snippet, selected: Bool) -> some View {
        let clash = editor.clash(for: snippet) != nil
        return Button { editor.selected = snippet.id } label: {
            KitRow(selected: selected) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SnippetsEditor.title(snippet)).font(ink.ui(13, .medium))
                    Text(Snippet.firstLine(snippet.text) ?? "No text yet").font(ink.mono(11))
                        .foregroundStyle(ink.rowQuiet(selected))
                }
                Spacer(minLength: 8)
                if clash {
                    Image(systemName: "exclamationmark.triangle.fill").font(ink.ui(10.5))
                        .foregroundStyle(ink.rowLit(selected, ink.yellow))
                }
                Text(snippet.keyword).font(ink.mono(11.5)).foregroundStyle(ink.rowLit(selected, ink.text2))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel([SnippetsEditor.title(snippet), snippet.keyword.isEmpty ? "no keyword" : "keyword \(snippet.keyword)",
                             clash ? "keyword clashes" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func edit(_ snippet: Snippet) -> some View {
        let saved = editor.library.failed == nil
        let footer = HStack(spacing: 10) {
            Button("Delete snippet…") { confirmingDelete = true }.buttonStyle(.pilotDestructive)
            InfoMark(text: "Asks first; its keyword stops expanding and it leaves Hyper+Space › Snippets.")
            Spacer()
            Text("Also in Hyper+Space › Snippets").font(ink.ui(11.5)).foregroundStyle(ink.muted)
        }
        return KitBlock(title: "Snippet", symbol: "character.cursor.ibeam", focused: true, fill: true) {
            Text(saved ? "Saved as you type" : "Not saved").font(ink.ui(11.5)).foregroundStyle(saved ? ink.muted : ink.red)
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                fields(snippet)
                text(snippet)
                placeholders
                preview(snippet)
            }
            .padding(.vertical, 14)
            BlockRow { footer }
        }
    }

    // MARK: Fields

    private func fields(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
                labelled("Name") {
                    TextField("Name", text: binding(snippet.id, \.name), prompt: Text(verbatim: "Name").foregroundStyle(ink.muted))
                        .frame(height: Self.fieldLine).pilotField().focused($focus, equals: .name).focusEdge(focus == .name)
                }
                labelled("Keyword") {
                    TextField("Keyword", text: binding(snippet.id, \.keyword), prompt: Text(verbatim: "e.g. ;cm").foregroundStyle(ink.muted))
                        .font(ink.mono(12.5)).frame(height: Self.fieldLine).pilotField().focused($focus, equals: .keyword).focusEdge(focus == .keyword)
                }
                .frame(width: 150)
            }
            keywordNote(snippet)
        }
    }

    /// What typing the keyword does: expands anywhere, at a word's start, never (a higher snippet has it), or nothing.
    private func keywordNote(_ snippet: Snippet) -> some View {
        let note = editor.note(for: snippet)
        let (symbol, words): (String, String) = switch note {
        case .menuOnly: ("command", "Only from Hyper+Space › Snippets: it has no keyword")
        case .anywhere: ("bolt", "Expands the moment you type it, in any app")
        case .wordStart: ("textformat", "Expands when you type it at the start of a word")
        case .clash(let other, let wins) where wins:
            ("exclamationmark.triangle.fill", "“\(other)” has \(snippet.keyword) too. This one is higher in the list, so it expands.")
        case .clash(let other, _):
            ("exclamationmark.triangle.fill", "“\(other)” has \(snippet.keyword) too and is higher in the list, so this one never expands.")
        }
        let warns = if case .clash = note { true } else { false }
        return Label { Text(words).foregroundStyle(warns ? ink.text2 : ink.muted) } icon: {
            Image(systemName: symbol).foregroundStyle(warns ? ink.yellow : ink.muted)
        }
        .font(ink.ui(11.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func text(_ snippet: Snippet) -> some View {
        labelled("Text") {
            TextEditor(text: binding(snippet.id, \.text), selection: $selection)
                .font(ink.mono(12.5)).foregroundStyle(ink.text).scrollContentBackground(.hidden)
                .focused($focus, equals: .text)
                .padding(.horizontal, 4).padding(.vertical, 6)
                .frame(height: 132)
                .background(ink.background, in: .rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ink.line2) }
                .focusEdge(focus == .text)
                // Its own undo for each snippet.
                .id(snippet.id)
                .accessibilityLabel("Text")
        }
    }

    // MARK: Placeholders and preview

    /// Each placeholder as a button that puts it at the caret (after the end when the text has none), with its line.
    private var placeholders: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Placeholders")
                Spacer()
                Text("Click one to put it at the caret").font(ink.ui(11)).foregroundStyle(ink.muted)
            }
            CardGrid(minimum: 250, spacing: 4) {
                ForEach(SnippetsEditor.placeholders(now: Date()), id: \.token) { placeholder in
                    PlaceholderButton(placeholder: placeholder) { insert(placeholder.token) }
                }
            }
        }
    }

    private func insert(_ token: String) {
        guard let id = editor.current?.id else { return }
        let done = SnippetsEditor.inserting(token, into: editor.current?.text ?? "", at: selection)
        editor.edit(id) { $0.text = done.text }
        selection = TextSelection(insertionPoint: done.caret)
        focus = .text
    }

    /// The text as it pastes: today's date and time, samples for the clipboard and the argument, the caret marked.
    private func preview(_ snippet: Snippet) -> some View {
        let filled = snippet.expanded(now: Date(), clipboard: SnippetsEditor.sampleClipboard, argument: SnippetsEditor.sampleArgument)
        let samples = snippet.text.contains("{clipboard}") || snippet.needsArgument
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                fieldLabel("Pastes as")
                Spacer()
                if samples { Text("Clipboard and argument are samples").font(ink.ui(11)).foregroundStyle(ink.muted) }
            }
            Group {
                if filled.text.isEmpty {
                    Text("Nothing to paste yet").foregroundStyle(ink.muted)
                } else {
                    Text(Self.marked(filled, cursor: snippet.text.contains("{cursor}"), caret: ink.accent)).font(ink.mono(12.5)).foregroundStyle(ink.text).lineSpacing(2)
                        .lineLimit(8).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(ink.ui(12.5))
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .innerCard()
            .accessibilityElement(children: .combine)
        }
    }

    /// `filled` with a bar in the accent where {cursor} leaves the caret, when `cursor`.
    private static func marked(_ filled: SnippetText, cursor: Bool, caret colour: Color) -> AttributedString {
        guard cursor else { return AttributedString(filled.text) }
        let at = filled.text.index(filled.text.endIndex, offsetBy: -filled.caretBack)
        var caret = AttributedString("│")
        caret.foregroundColor = colour
        return AttributedString(String(filled.text[..<at])) + caret + AttributedString(String(filled.text[at...]))
    }

    // MARK: Parts

    private func binding(_ id: UUID, _ key: WritableKeyPath<Snippet, String>) -> Binding<String> {
        Binding(get: { editor.library.snippet(id)?[keyPath: key] ?? "" }, set: { value in editor.edit(id) { $0[keyPath: key] = value } })
    }

    private func labelled(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(title)
            content()
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(ink.ui(11.5, .medium)).foregroundStyle(ink.muted).accessibilityHidden(true)
    }
}

/// The editor's state apart from its view, so a test drives it: the library, the snippet picked, and what each keyword does.
@Observable @MainActor
final class SnippetsEditor {
    let library: SnippetLibrary
    var selected: UUID?

    /// What the preview fills {clipboard} and {argument} with: never the real pasteboard.
    static let sampleClipboard = "copied text"
    static let sampleArgument = "argument"

    init(library: SnippetLibrary, selected: UUID? = nil) {
        self.library = library
        self.selected = selected ?? library.snippets.first?.id
    }

    /// The picked snippet, else the first; nil when there are none.
    var current: Snippet? { library.snippets.first { $0.id == selected } ?? library.snippets.first }

    /// A new snippet at the end of the list, so its keyword never takes over one above it; picked.
    @discardableResult func add() -> UUID {
        let snippet = Snippet(name: "New snippet", keyword: "", text: "")
        library.snippets.append(snippet)
        selected = snippet.id
        return snippet.id
    }

    /// Removes it; the one after it is picked, else the one before.
    func delete(_ id: UUID) {
        guard let i = library.snippets.firstIndex(where: { $0.id == id }) else { return }
        let picked = current?.id == id
        library.snippets.remove(at: i)
        if picked { selected = library.snippets.indices.contains(i) ? library.snippets[i].id : library.snippets.last?.id }
    }

    /// Changes one snippet; the library saves only a real change.
    func edit(_ id: UUID, _ change: (inout Snippet) -> Void) {
        guard let i = library.snippets.firstIndex(where: { $0.id == id }) else { return }
        var snippet = library.snippets[i]
        change(&snippet)
        if snippet != library.snippets[i] { library.snippets[i] = snippet }
    }

    /// Another snippet with the same keyword: the higher in the list expands (SnippetKeywords keeps the first).
    func clash(for snippet: Snippet) -> Snippet? {
        guard !snippet.keyword.isEmpty else { return nil }
        return library.snippets.first { $0.id != snippet.id && $0.keyword == snippet.keyword }
    }

    enum KeywordNote: Equatable {
        /// No keyword: Hyper+Space alone pastes it.
        case menuOnly
        /// Starts with a symbol (;cm): expands wherever it is typed.
        case anywhere
        /// Starts with a letter or digit (sig): only at a word's start, never inside design (SnippetTyping).
        case wordStart
        /// `other` has the keyword too; `wins` when this one is higher in the list.
        case clash(other: String, wins: Bool)
    }

    func note(for snippet: Snippet) -> KeywordNote {
        guard let first = snippet.keyword.first else { return .menuOnly }
        if let other = clash(for: snippet) {
            let wins = library.snippets.first { $0.keyword == snippet.keyword }?.id == snippet.id
            return .clash(other: Self.title(other), wins: wins)
        }
        return first.isLetter || first.isNumber ? .wordStart : .anywhere
    }

    /// Its name, or Untitled.
    static func title(_ snippet: Snippet) -> String { snippet.name.isEmpty ? "Untitled" : snippet.name }


    /// `text` with `token` in place of the selection (at the caret when nothing is selected), else after its end; and
    /// the caret just after the token.
    static func inserting(_ token: String, into text: String, at selection: TextSelection?) -> (text: String, caret: String.Index) {
        var text = text
        if case .selection(let range)? = selection?.indices, range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            text.replaceSubrange(range, with: token)
            return (text, text.index(text.startIndex, offsetBy: start + token.count))
        }
        text += token
        return (text, text.endIndex)
    }

    struct Placeholder {
        let token: String
        /// What it becomes, in plain words.
        let line: String
    }

    /// The five placeholders, the date and time shown as they would paste `now`.
    static func placeholders(now: Date) -> [Placeholder] {
        func filled(_ token: String) -> String { Snippet(name: "", keyword: "", text: token).expanded(now: now, clipboard: nil).text }
        return [
            Placeholder(token: "{date}", line: "Today’s date, e.g. \(filled("{date}"))"),
            Placeholder(token: "{time}", line: "The time, e.g. \(filled("{time}"))"),
            Placeholder(token: "{clipboard}", line: "What you copied last"),
            Placeholder(token: "{argument}", line: "Asked for as it pastes"),
            Placeholder(token: "{cursor}", line: "Where the caret ends up"),
        ]
    }
}

/// A placeholder's braces in mono: Instrument's key chip, else a soft accent fill (Chip's sizes).
private struct PlaceholderToken: View {
    @Environment(\.ink) private var ink
    let token: String
    /// The tokens' column, {clipboard} the widest, so the lines beside them start on one edge.
    static let column: CGFloat = 92

    var body: some View {
        if ink.isInstrument {
            // Instrument's: the id as a key chip, no signal.
            InstrumentKey(text: token)
        } else {
        Text(token).font(ink.mono(11.5)).foregroundStyle(ink.accentText).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).frame(height: 21)
            .background { Capsule().fill(ink.accent.opacity(0.15)) }
        }
    }
}

/// A placeholder that goes in on a click: its token and its line, lit under the mouse.
private struct PlaceholderButton: View {
    @Environment(\.ink) private var ink
    let placeholder: SnippetsEditor.Placeholder
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PlaceholderToken(token: placeholder.token).frame(width: PlaceholderToken.column, alignment: .leading)
                Text(placeholder.line).font(ink.ui(12)).foregroundStyle(hovered ? ink.text : ink.text2).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(ink.text.opacity(hovered ? 0.06 : 0), in: .rect(cornerRadius: ink.radius(5)))
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .onHover { hovered = $0 }
        .animation(Kit.change, value: hovered)
        .accessibilityLabel("Insert \(placeholder.token)")
        .accessibilityHint(placeholder.line)
        .help("Put \(placeholder.token) at the caret")
    }
}

private extension View {
    /// The field taking the keys, edged in the accent (pilotField draws no focus of its own).
    func focusEdge(_ on: Bool) -> some View { modifier(FocusEdge(on: on)) }
}

private struct FocusEdge: ViewModifier {
    @Environment(\.ink) private var ink
    let on: Bool
    func body(content: Content) -> some View {
        content.overlay { if on { RoundedRectangle(cornerRadius: 6).strokeBorder(ink.accent.opacity(0.7)) } }
    }
}
