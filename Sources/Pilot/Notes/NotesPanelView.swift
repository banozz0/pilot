import PilotCore
import SwiftUI

/// The notes panel, direction B, "note first" (P60, Sven Q307, 2026-10-18; design-refs/notes-directions-2026-10-18.html
/// section 03): the panel is the note. A 34 pt head (the list's key, where the note is listed, its words and time, ⌘K
/// and +) over the note at a 560 pt measure, no foot. Escape slides the list over the note's left edge as a drawer, its
/// search focused (180 ms, no slide under Reduce Motion); a format bar rises over a selection; ⌘K holds the rest. The
/// shared shape, drawn in the picked style by its pieces (InstrumentNotes, ToyNotes); the Notes page docks the same list
/// beside the same head and note (NotesPage).
struct NotesPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: NotesModel

    static let drawerWidth: CGFloat = 300

    var body: some View {
        let drawer = model.listing
        VStack(spacing: 0) {
            NotesHead(model: model, listKey: true)
            NotesNote(model: model, measure: NotesMeasure.panel, beside: drawer ? Self.drawerWidth : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        if drawer {
                            NotesList(model: model)
                                .frame(width: Self.drawerWidth)
                                .transition(reduceMotion ? .identity : .move(edge: .leading))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: drawer)
                }
                .clipped()
        }
        // Cmd+K's actions over the note's corner, as the menu's float over its list's.
        .overlay(alignment: .bottomTrailing) { NotesActionsView(model: model).padding(12) }
    }
}

/// The note's measure (direction B): the widest its words run, centred, the margins growing past it.
enum NotesMeasure {
    static let panel: CGFloat = 560
    static let page: CGFloat = 620

    /// The room either side of words at most `measure` wide in `width`, never under `least`.
    static func side(width: CGFloat, measure: CGFloat, least: CGFloat) -> CGFloat {
        max(least, ((width - measure) / 2).rounded(.down))
    }
}

/// The head over the note (34 pt): the list's key (the panel's; the page docks it), the note's section and title, its
/// words and when it was edited ("preview" while the list shows another), ⌘K and +. Its own view, so a keystroke
/// redraws only it and the note.
struct NotesHead: View {
    @Environment(\.style) private var style
    let model: NotesModel
    var listKey = false

    var body: some View {
        let preview = model.previewNote
        let shown = preview ?? model.note
        HStack(spacing: 8) {
            if listKey {
                NotesHeadButton(symbol: "list.bullet", label: model.listFocused ? "Hide your notes" : "Your notes") {
                    model.listFocused ? model.leaveList() : model.focusList()
                }
            }
            if let shown { crumb(shown, title: preview == nil && !shown.isScratch ? Notes.title(of: model.text) : shown.title) }
            Spacer(minLength: 8)
            if let status = status(shown, preview: preview != nil) {
                Text(status).font(mono).monospacedDigit().foregroundStyle(style.color(\.text3)).lineLimit(1).fixedSize()
            }
            NotesHeadButton(key: "⌘K", label: "Actions") { model.perform(.actions) }
            NotesHeadButton(symbol: "plus", label: "New note") { model.new() }
        }
        .padding(.horizontal, 8).frame(height: 34)
        .overlay(alignment: .bottom) { NotesRule() }
    }

    /// "Today › Ship the notes panel"; Scratch's section is its own, so it is named once.
    private func crumb(_ note: Note, title: String) -> some View {
        return HStack(spacing: 5) {
            if !note.isScratch {
                Text(Notes.section(of: note, now: .now).title).foregroundStyle(style.color(\.text3))
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(style.color(\.text3))
            }
            Text(title).foregroundStyle(style.color(\.text2)).truncationMode(.tail)
        }
        .font(crumbFont).lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// "49 words · 14:20" for the open note, "preview" for another, nothing for Scratch.
    private func status(_ note: Note?, preview: Bool) -> String? {
        if preview { return "preview" }
        guard let note, !note.isScratch else { return nil }
        return "\(NotesText.count(NotesText.words(model.text))) · \(NotesText.stamp(note.edited, clock: false))"
    }

    private var crumbFont: Font { style.font(\.caption) }
    private var mono: Font { style.font(\.mono) }
}

/// The note under the head: the editor at the measure (the format bar rising over a selection), the row the list
/// previews, the Trash question, an emptied note's Delete and empty Scratch's invitation, each at the words' edge.
/// `beside`: the drawer's width while it covers the note's left edge, so the words sit to its right.
struct NotesNote: View {
    @Environment(\.style) private var style
    @Bindable var model: NotesModel
    let measure: CGFloat
    var beside: CGFloat = 0

    var body: some View {
        let markdown = MarkdownStyle(style: style, measure: measure)
        let confirming = model.confirmingTrash
        let preview = model.previewNote
        GeometryReader { g in
            let edge = NotesMeasure.side(width: g.size.width - beside, measure: measure, least: markdown.inset.width)
            let width = min(measure, g.size.width - beside - 2 * markdown.inset.width)
            ZStack(alignment: .topLeading) {
                // Kept under the preview and the question, so the caret, the scroll and Undo are where they were after.
                let shown = preview == nil && !confirming
                NotesEditor(text: $model.text, style: markdown, editable: !confirming, focused: !model.listFocused && !confirming,
                            folder: model.store.folder, handle: model.editor, bar: shown && model.actions == nil) {
                    // A click in the note, or the window handing it the keyboard, takes it from the list.
                    if model.listFocused { model.leaveList() }
                }
                    .opacity(shown ? 1 : 0).allowsHitTesting(shown)
                if let preview {
                    MarkdownEditor(text: .constant(preview.text), style: markdown, editable: false, folder: model.store.folder)
                }
                Group {
                    if confirming, let note = model.note {
                        NotesTrashQuestion(note: note, words: NotesText.words(model.text), markdown: markdown)
                    } else if preview == nil, model.isEmptyNote {
                        NotesEmptyNote(model: model, markdown: markdown)
                    } else if preview == nil, model.note?.isScratch == true, model.text.isEmpty {
                        NotesScratchInvite(markdown: markdown).allowsHitTesting(false)
                    }
                }
                .frame(width: max(width, 0), alignment: .leading)
                .padding(.leading, edge).padding(.top, markdown.inset.height)
            }
            .padding(.leading, beside)
            .overlay(alignment: .top) {
                if let problem = model.problem { NotesProblem(text: problem).padding(.horizontal, edge + beside).padding(.top, 4) }
            }
        }
    }
}

/// The editor with its format bar (direction B): the bar rises over the selection's first line while something is
/// picked, under it when there is no room above.
struct NotesEditor: View {
    @Binding var text: String
    let style: MarkdownStyle
    var editable = true
    var focused = false
    var folder: URL?
    var handle: NotesEditorHandle?
    /// The bar may show: the note is being written in, not previewed, asked about or under Cmd+K.
    var bar = true
    var onFocus: (() -> Void)?
    @State private var selection: CGRect?
    /// The bar's own hold on this editor.
    @State private var own = NotesEditorHandle()

    var body: some View {
        MarkdownEditor(text: $text, style: style, editable: editable, focused: focused, folder: folder, handle: handle, bar: own,
                       onFocus: onFocus, selection: $selection)
            .overlay(alignment: .topLeading) {
                if bar, editable, let selection {
                    GeometryReader { g in
                        let size = NotesFormatBar.size
                        let x = min(max(selection.minX - 8, 4), max(g.size.width - size.width - 4, 4))
                        let above = selection.minY - size.height - 6
                        NotesFormatBar(handle: own)
                            .offset(x: x, y: above >= 2 ? above : selection.maxY + 6)
                    }
                }
            }
    }
}

/// The list: the drawer over the panel's note, or docked on the Notes page. Its search field (18 pt in the drawer, the
/// search type's size; 15 pt docked), then the notes: Scratch alone on top, then Pinned, Today, Yesterday and Earlier,
/// each row its title over its line of words (Q306); with words typed the matches, titles first, each showing the line
/// that matched. ↑↓ (the panel's keys) move the highlight, which the note behind previews; Return opens it.
struct NotesList: View {
    @Environment(\.style) private var style
    @Bindable var model: NotesModel
    /// On the Notes page: always shown, the field smaller, the folder's line (this folder, and one picked waiting for
    /// the move question) at the foot instead of the keys.
    var folder: (url: URL, picked: URL?)?
    @FocusState private var searchFocused: Bool

    private var docked: Bool { folder != nil }
    private var listing: Bool { model.listing }
    private var searching: Bool { listing && !model.query.isEmpty }

    var body: some View {
        let matches = searching ? model.rows : []
        VStack(spacing: 0) {
            NotesField(model: model, focused: $searchFocused, docked: docked, count: searching ? matches.count : nil)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: style.kind == .toybox ? 2 : 1) {
                        if searching { matchRows(matches) } else { groupedRows }
                    }
                    .padding(.horizontal, style.kind == .toybox ? 10 : 6).padding(.top, 4).padding(.bottom, 10)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                // The drawer comes in on the open note, wherever it is in the list.
                .onAppear { if let id = model.selection { proxy.scrollTo(id) } }
            }
            if let folder { NotesFolderLine(folder: folder.url, picked: folder.picked) } else { foot }
        }
        // The field takes the keyboard with the list: once the update that turns it on is drawn, and as the drawer comes in.
        .onAppear { if model.listFocused { Task { searchFocused = true } } }
        // Only given, never taken back here: the editor takes the keyboard when the list closes (its `focused`), and a
        // field told to let go after it already had would hand the window the keyboard instead.
        .onChange(of: model.listFocused) { _, open in
            if open { Task { searchFocused = true } }
        }
        // The keyboard gone to another field (⌘F, a click elsewhere): the list lets go too, so its keys (Return, ↑↓,
        // Escape, ⌘⌫) never act behind the field that has it.
        .onChange(of: searchFocused) { had, has in
            if had, !has, model.listFocused { model.leaveList() }
        }
        .frame(maxHeight: .infinity)
        .background(style.color(style.kind == .toybox ? \.sunken : docked ? \.sidebar : \.panel))
        .overlay(alignment: .trailing) { NotesRule(vertical: true, strong: !docked) }
    }

    @ViewBuilder private var groupedRows: some View {
        ForEach(Array(model.groups.enumerated()), id: \.element.title) { index, group in
            if group.section != .scratch && group.section != .welcome {
                NotesEyebrow(text: group.title).padding(.horizontal, 10).padding(.top, index == 0 ? 8 : 16).padding(.bottom, 6)
            }
            ForEach(group.notes) { note in
                let line = Notes.line(of: note.text)
                row(note, title: Text(note.title), line: note.isScratch ? nil : Text(line.isEmpty ? " " : line), time: time(note, in: group.section))
            }
        }
    }

    /// The list filtered by what is typed in its field, best match on top; a match in a note's words shows that line.
    @ViewBuilder private func matchRows(_ rows: [Note]) -> some View {
        if rows.isEmpty {
            Text("No note matches").styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(.horizontal, 10).frame(minHeight: 30)
        }
        ForEach(rows) { note in
            let line = Notes.line(of: note.text, query: model.query)
            row(note, title: NotesText.marked(note.title, model.query, style: style),
                line: Text(NotesText.underlined(line.isEmpty ? " " : line, model.query, style: style)), time: NotesText.stamp(note.edited, clock: false))
        }
    }

    /// When a row says it was edited (the mockup's): the clock under Today, the day under Earlier, none under Pinned and
    /// Yesterday nor on the welcome note; Scratch says it is empty.
    private func time(_ note: Note, in section: Notes.Section) -> String? {
        switch section {
        case .scratch: "empty"
        case .today: NotesText.stamp(note.edited, clock: true)
        case .earlier: NotesText.stamp(note.edited, clock: false)
        case .welcome, .pinned, .yesterday: nil
        }
    }

    private func row(_ note: Note, title: Text, line: Text?, time: String?) -> some View {
        let on = listing ? note.id == model.selection : note.id == model.current
        return Button { model.open(note.id) } label: {
            NotesRow(note: note, title: title, line: line, time: time, on: on, open: note.id == model.current,
                     struck: model.confirmingTrash && note.id == model.current, highlight: listing)
        }
        .buttonStyle(.plain).focusable(false)
        .id(note.id)
        .accessibilityAddTraits(note.id == model.current ? .isSelected : [])
        .contextMenu { NotesRowMenu(model: model, note: note) }
    }

    /// The drawer's keys (the mockup's): ↵ Open, ⌘K Actions, esc Hide.
    private var foot: some View {
        NotesKeyHints(hints: NotesText.listKeys)
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .overlay(alignment: .top) { NotesRule() }
    }
}

/// A row's context menu: Pin or Unpin, Reveal in Finder and Move to Trash…; Scratch, never pinned or trashed, says so.
private struct NotesRowMenu: View {
    let model: NotesModel
    let note: Note

    var body: some View {
        if note.isScratch {
            // Said, not hidden, so a right-click on Scratch never looks broken.
            Button(NotesText.scratchStays) {}.disabled(true)
            Divider()
            Button("Reveal in Finder") { model.reveal(note.id) }
        } else {
            Button(note.pinned ? "Unpin" : "Pin") { model.pin(note.id, !note.pinned) }.keyboardShortcut("p", modifiers: .command)
            Button("Reveal in Finder") { model.reveal(note.id) }
            Divider()
            Button("Move to Trash…", role: .destructive) { model.open(note.id); model.askTrash() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }
}

// MARK: Pieces, drawn by each style (InstrumentNotes, ToyNotes)

/// A note's row: its glyph (Scratch's scribble, a pin), its title over its line of words, when it was edited; `on` (the
/// open note, or the highlighted one while the list has the keyboard) picked.
struct NotesRow: View {
    @Environment(\.style) var style
    let note: Note
    let title: Text
    let line: Text?
    let time: String?
    let on: Bool
    let open: Bool
    var struck = false
    /// `on` is the list's highlight while it has the keyboard, not the open note: Toybox's sun, not its white cap.
    var highlight = false

    var glyph: String? { note.isScratch ? "scribble" : note.pinned ? "pin" : nil }

    var body: some View {
        switch style.kind {
        case .instrument: instrument
        case .toybox: toybox
        }
    }
}

/// The list's search field: a click on it gives the list the keyboard, as Escape does; it filters while the list has
/// it. Under the Trash question it asks instead.
struct NotesField: View {
    @Environment(\.style) var style
    @Bindable var model: NotesModel
    var focused: FocusState<Bool>.Binding
    let docked: Bool
    /// The matches while words are typed.
    let count: Int?

    var confirming: Bool { model.confirmingTrash }
    var prompt: String { confirming ? Self.prompts[1] : Self.prompts[0] }

    /// What the field says while empty, its own prompt in AppKit too: the one way to tell it from the window's other
    /// fields, as SwiftUI gives a field no name AppKit can read (HUD.isActionsFilter tells Cmd+K's filter the same way).
    static let prompts = ["Find a note", "Trash it?"]

    /// Whether `responder` is this field's editor: the list's own field has the keyboard.
    static func holds(_ responder: NSResponder?) -> Bool {
        guard let field = (responder as? NSTextView)?.delegate as? NSTextField else { return false }
        return prompts.contains(field.placeholderAttributedString?.string ?? field.placeholderString ?? "")
    }

    var body: some View {
        Group {
            switch style.kind {
            case .instrument: instrument
            case .toybox: toybox
            }
        }
        // Off while the note has the keyboard, so nothing hands the field focus behind the list's back.
        .disabled(!model.listFocused)
        .overlay {
            if !model.listFocused && !confirming {
                Button { model.focusList() } label: { Color.clear.contentShape(.rect) }
                    .buttonStyle(.plain).focusable(false).accessibilityLabel("Find a note")
            }
        }
    }
}

/// A button in the head: a glyph, or ⌘K's cap.
struct NotesHeadButton: View {
    @Environment(\.style) var style
    var symbol: String?
    var key: String?
    let label: String
    let action: () -> Void
    @State var hovered = false

    var body: some View {
        Button(action: action) {
            switch style.kind {
            case .instrument: instrument
            case .toybox: toybox
            }
        }
        .buttonStyle(.plain).focusable(false)
        .onHover { hovered = $0 }
        .help(key.map { "\(label)  \($0)" } ?? label).accessibilityLabel(label)
    }
}

/// The format bar over a selection: heading, bold, italic, link, code, then the two lists, each typing its Markdown.
struct NotesFormatBar: View {
    @Environment(\.style) var style
    let handle: NotesEditorHandle
    @State var hovered: MarkdownFormat?

    /// Its size, to keep it inside the note.
    static let size = CGSize(width: 216, height: 32)

    var body: some View {
        switch style.kind {
        case .instrument: instrument
        case .toybox: toybox
        }
    }

    func help(_ format: MarkdownFormat) -> String { format.key.map { "\(format.title)  \($0)" } ?? format.title }
}

/// Cmd+Backspace's question: the note's title, what goes and that Finder can put it back, and its two keys.
struct NotesTrashQuestion: View {
    @Environment(\.style) var style
    let note: Note
    let words: Int
    let markdown: MarkdownStyle

    var detail: String { "\(NotesText.count(words)), edited \(NotesText.when(note.edited)). It goes to the Mac’s Trash, so Finder can put it back." }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch style.kind {
            case .instrument: instrument
            case .toybox: toybox
            }
            NotesKeyHints(hints: NotesText.trashKeys)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Empty Scratch's invitation (direction B): a big quiet "Write anything.", what Scratch is, and its keys.
struct NotesScratchInvite: View {
    let markdown: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Write anything.").font(Font(markdown.h1.font)).tracking(markdown.h1.tracking).foregroundStyle(Color(markdown.muted))
                .frame(height: markdown.h1.line, alignment: .leading).padding(.bottom, 4)
            Text("The first words become a note of their own; Scratch stays empty for the next one.")
                .font(Font(markdown.body)).lineSpacing(markdown.line - markdown.body.pointSize * 1.2).foregroundStyle(Color(markdown.muted))
                .frame(maxWidth: 460, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            NotesKeyHints(hints: NotesText.scratchKeys).padding(.top, 16)
        }
    }
}

/// Keys and what each does, the caps first (the mockup's .hint), in a row.
struct NotesKeyHints: View {
    @Environment(\.style) private var style
    let hints: [KeyHint]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 6) {
                    NotesCaps(key: hint.key)
                    if !hint.label.isEmpty {
                        Text(hint.label).font(style.kind == .toybox ? style.toyNunito(700, 12.5) : style.font(\.caption))
                            .foregroundStyle(style.color(style.kind == .toybox ? \.text2 : \.text3))
                    }
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("\(hint.key) \(hint.label)")
            }
        }
        .lineLimit(1).fixedSize()
    }
}

/// A key as the style's caps: "⌘⇧L" is ⌘, ⇧ and L.
struct NotesCaps: View {
    @Environment(\.style) private var style
    let key: String
    /// Toybox's on the sun's row.
    var onSun = false

    var body: some View {
        switch style.kind {
        case .instrument: InstrumentKeys(caps: InstrumentHint.caps(key), hyper: false)
        case .toybox:
            HStack(spacing: 3) { ForEach(Array(ToyCaps.hint(key).enumerated()), id: \.offset) { ToyMenuCap(label: $1, onSun: onSun, height: 22) } }
        }
    }
}

/// A group's small capitals.
struct NotesEyebrow: View {
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        switch style.kind {
        case .instrument: InstrumentEyebrow(text: text)
        case .toybox: ToyEyebrow(text: text).accessibilityAddTraits(.isHeader)
        }
    }
}

/// A hairline in Instrument, the ink's 2 pt rule in Toybox; `strong` the drawer's edge over the note.
struct NotesRule: View {
    @Environment(\.style) private var style
    var vertical = false
    var strong = false

    var body: some View {
        switch style.kind {
        case .instrument: InstrumentRule(vertical: vertical, role: strong ? \.line2 : \.line)
        case .toybox: ToyRule(vertical: vertical)
        }
    }
}

/// A failed read or write, over the note.
private struct NotesProblem: View {
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        switch style.kind {
        case .instrument: InstrumentAttention(text: text)
        case .toybox: FinePrint(text: text, color: style.color(\.problem))
        }
    }
}

/// The words the panel prints about a note.
@MainActor
enum NotesText {
    private static let clock = formatter("HH:mm")
    private static let day = formatter("d MMM")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }

    /// "14:20" with `clock` (a day's group) and for today; "7 Oct" otherwise.
    static func stamp(_ date: Date, clock: Bool) -> String {
        clock || Calendar.current.isDateInToday(date) ? self.clock.string(from: date) : day.string(from: date)
    }

    /// "today at 14:20", "yesterday at 21:40", "on 6 Oct at 16:22".
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(date) ? "today" : calendar.isDateInYesterday(date) ? "yesterday" : "on \(self.day.string(from: date))"
        return "\(day) at \(clock.string(from: date))"
    }

    /// Empty Scratch's keys, the drawer's, and the Trash question's (direction B: no foot, each where it applies).
    static let scratchKeys: [KeyHint] = [("esc", "your notes"), ("⌘K", "actions"), ("⌘N", "new note")]
    static let listKeys: [KeyHint] = [("↵", "Open"), ("⌘K", "Actions"), ("esc", "Hide")]
    static let trashKeys: [KeyHint] = [("↵", "Move to Trash"), ("esc", "Keep it")]

    static let scratchStays = "Scratch stays on top, empty, and never goes to the Trash"

    /// "1 word", "49 words".
    static func count(_ words: Int) -> String { "\(words) \(words == 1 ? "word" : "words")" }

    /// The words in a note: runs with a letter or digit in them, a task's `[x]` not counted.
    static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count { word in
            word.contains { $0.isLetter || $0.isNumber } && word.lowercased() != "[x]"
        }
    }

    /// The title with the typed letters in the text colour on an underline, as the menu marks what was typed (Toybox's in
    /// the sun's edge).
    static func marked(_ title: String, _ query: String, style: StyleTokens) -> Text {
        var text = AttributedString(title)
        let lit = lit(query, in: title)
        var at = text.startIndex
        for n in 0..<title.count {
            let next = text.characters.index(after: at)
            if lit.contains(n) { mark(&text[at..<next], style: style) }
            at = next
        }
        return Text(text)
    }

    /// A row's line with each typed word underlined where it shows.
    static func underlined(_ line: String, _ query: String, style: StyleTokens) -> AttributedString {
        var text = AttributedString(line)
        for word in query.split(whereSeparator: \.isWhitespace) {
            var from = text.startIndex
            while let found = text[from...].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                mark(&text[found], style: style)
                from = found.upperBound
            }
        }
        return text
    }

    private static func mark(_ run: inout AttributedSubstring, style: StyleTokens) {
        if style.kind == .instrument { run.foregroundColor = style.color(\.text) }
        run.underlineStyle = Text.LineStyle(pattern: .solid, color: style.color(style.kind == .toybox ? \.accentEdge : \.text3))
    }

    /// Which of `title`'s characters each typed word lights: a run of it (at a word's start first), else its letters at
    /// word starts ("sc" in Shippers Club), else its letters in order.
    static func lit(_ query: String, in title: String) -> Set<Int> {
        func fold(_ c: Character) -> Character { String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).first ?? c }
        let chars = Array(title), letters = chars.map(fold)
        let starts = chars.indices.map { j in
            j == 0 || !(chars[j - 1].isLetter || chars[j - 1].isNumber) || (chars[j].isUppercase && chars[j - 1].isLowercase)
        }
        var lit = Set<Int>()
        for word in query.split(whereSeparator: \.isWhitespace).map({ $0.map(fold) }) {
            func run() -> [Int]? {
                guard word.count <= letters.count else { return nil }
                let found = (0...(letters.count - word.count)).filter { Array(letters[$0..<($0 + word.count)]) == word }
                return (found.first { starts[$0] } ?? found.first).map { Array($0..<($0 + word.count)) }
            }
            func inOrder(startsOnly: Bool) -> [Int]? {
                var picked: [Int] = [], j = 0
                for c in word {
                    while j < letters.count, letters[j] != c || (startsOnly && !starts[j]) { j += 1 }
                    guard j < letters.count else { return nil }
                    picked.append(j); j += 1
                }
                return picked
            }
            lit.formUnion(run() ?? inOrder(startsOnly: true) ?? inOrder(startsOnly: false) ?? [])
        }
        return lit
    }
}
