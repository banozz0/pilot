import PilotCore
import SwiftUI

/// Open with (C3, Sven 2026-10-10: Defaults' settings were good but too hidden, so each job got a page named for it;
/// Configs is its own page, and Aliases, Quicklinks, File search and the menu's rows went to Menu). Mockup D's Opens with
/// (card agent-bo-95422980): a card per main kind (the editor with its key, web links, plain text, Markdown), each with a
/// picker showing the chosen app's icon, changed on Sven's pick as Finder's Open With › Change All does (cards
/// agent-bo-95422840 and 842); every other kind folds under All kinds.
struct OpenWithPage: View {
    @Environment(\.ink) private var ink
    @State private var choices: [(name: String, bundle: String)] = []
    @State private var kinds: DefaultAppsModel
    /// All kinds, folded until asked for.
    @State private var allKinds: Bool
    private let editor: EditorChoice

    /// A render or a test may fold All kinds out and pass its own defaults and editor.
    init(allKinds: Bool = false, kinds: DefaultAppsModel = DefaultAppsModel(), editor: EditorChoice = .shared) {
        _allKinds = State(initialValue: allKinds)
        _kinds = State(initialValue: kinds)
        self.editor = editor
    }

    static let intro = "The app each kind of file and link opens in. Pilot changes nothing until you pick."
    /// Browser, text and Markdown: the kinds with a card of their own after the editor, with each card's tile and ⓘ.
    private static let mainCards: [(kind: FileKind, symbol: String, colour: TileColour, info: String)] = [
        ("web", "globe", TileColour.third, "Every link you click outside a browser opens in this one."),
        ("public.plain-text", "doc.text", .neutral, "A .txt file you double-click in Finder opens in this app."),
        ("net.daringfireball.markdown", "number", .second, "A .md file you double-click in Finder opens in this app."),
    ].compactMap { id, symbol, colour, info in FileKinds.groups.flatMap(\.kinds).first { $0.id == id }.map { ($0, symbol, colour, info) } }
    /// Every other kind, by group.
    private static let otherGroups = FileKinds.groups.map { group in
        (name: group.name, kinds: group.kinds.filter { kind in !mainCards.contains { $0.kind.id == kind.id } })
    }
        .filter { !$0.kinds.isEmpty }

    var body: some View {
        KitPage(intro: Self.intro) {
            DefaultsSection(title: "Opens with",
                            note: "Your editor, browser and text apps first; every other kind under All kinds.") {
                AccentLink(title: allKinds ? "Fewer kinds" : "All kinds", chevron: allKinds ? "chevron.up" : "chevron.down") {
                    withAnimation(Kit.change) { allKinds.toggle() }
                }
            } content: {
                CardGrid(fit: true, stretch: true) {
                    editorCard
                    ForEach(Self.mainCards, id: \.kind.id) { KindCard(kind: $0.kind, symbol: $0.symbol, colour: $0.colour, info: $0.info, model: kinds) }
                }
                FinePrint(text: "Web links: macOS asks you once to confirm a new browser.").padding(.top, 8)
                if allKinds { others.padding(.top, 10) }
            }
            // Story 160's Apps for keys: the app or site each role key opens (Q462, Q463).
            AppRolesBlock()
        }
        .onAppear {
            kinds.load()
            choices = EditorChoice.choices()
        }
    }

    /// The main editor, which its key opens and Configs open files in.
    private var editorCard: some View {
        @Bindable var editor = editor
        let app = editor.app, automatic = editor.automatic
        return KindCardFrame(title: "Editor", detail: editor.pick == nil ? "automatic" : "your pick", symbol: "pencil", colour: .accent,
                             info: "The app the editor key opens, and the one Configs open their files in.") {
            BindKey(action: "apps.editor")
        } picker: {
            AppPickerField(bundle: app, name: AppsModule.appName(app) ?? app, label: "Editor") {
                Picker("Editor", selection: $editor.pick) {
                    Text("Automatic (\(AppsModule.appName(automatic) ?? automatic))").tag(String?.none)
                    ForEach(choices, id: \.bundle) { AppMenuItem(name: $0.name, bundle: $0.bundle).tag(String?.some($0.bundle)) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
            .help("Automatic is the Mac's default app for text files, then for source code, when it is an editor (Xcode and TextEdit claim them as they install, so they do not count); else VS Code, Cursor, Zed or Sublime Text when installed; else TextEdit.")
        }
    }

    /// Every other kind, by group. One grid holds them, so every picker starts on one line and each kind's whole name
    /// shows.
    private var others: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(Self.otherGroups, id: \.name) { group in
                GridRow {
                    Text(group.name).font(ink.ui(11.5, .semibold)).foregroundStyle(ink.muted)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 10)
                        .gridCellColumns(2)
                }
                ForEach(group.kinds, id: \.id) { kind in
                    GridRow {
                        KindName(kind: kind, model: kinds)
                        KindPicker(kind: kind, model: kinds, compact: true).frame(maxWidth: 320)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .blockSurface()
    }
}

/// One section of a page (Open with's, Configs', Menu's Aliases and Quicklinks): a heading on the page that says in
/// one line what it is for, `link` at its right, then the content.
struct DefaultsSection<Link: View, Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder var link: Link
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalmHeading(title: title, note: note) { link }
            content
        }
    }
}

extension DefaultsSection where Link == EmptyView {
    init(title: String, note: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, note: note, link: { EmptyView() }, content: content)
    }
}

/// A kind's card: its tile, title and what it covers, what sits at its right (the editor's key), then its picker.
private struct KindCardFrame<Trailing: View, Picker: View>: View {
    @Environment(\.ink) private var ink
    let title: String
    let detail: String?
    let symbol: String
    let colour: TileColour
    /// The ⓘ after the title.
    var info: String?
    var message: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var picker: Picker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                KitTile(symbol: symbol, colour: colour, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(ink.ui(13, .semibold)).foregroundStyle(ink.text)
                        if let info { InfoMark(text: info) }
                    }
                    if let detail { Text(detail).font(ink.ui(11.5)).foregroundStyle(ink.muted) }
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                trailing
            }
            picker
            if let message { Text(message).font(ink.ui(11.5)).foregroundStyle(ink.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .blockSurface()
    }
}

extension KindCardFrame where Trailing == EmptyView {
    init(title: String, detail: String?, symbol: String, colour: TileColour, info: String?, message: String?, @ViewBuilder picker: () -> Picker) {
        self.init(title: title, detail: detail, symbol: symbol, colour: colour, info: info, message: message, trailing: { EmptyView() }, picker: picker)
    }
}

/// A main kind's card: Web links, Plain text, Markdown.
private struct KindCard: View {
    let kind: FileKind
    let symbol: String
    let colour: TileColour
    let info: String
    let model: DefaultAppsModel

    var body: some View {
        let row = model.rows[kind.id]
        KindCardFrame(title: kind.title, detail: kind.detail, symbol: symbol, colour: colour, info: info, message: row?.message) {
            KindPicker(kind: kind, model: model)
        }
    }
}

/// A kind's picker: the app it opens in, and every app macOS says can open it.
private struct KindPicker: View {
    let kind: FileKind
    let model: DefaultAppsModel
    var compact = false

    var body: some View {
        let row = model.rows[kind.id]
        let current = row?.current
        let name = current.map { bundle in row?.choices.first { $0.bundle == bundle }?.name ?? AppsModule.appName(bundle) ?? bundle } ?? "None"
        AppPickerField(bundle: current, name: name, label: kind.title, compact: compact) {
            Picker(kind.title, selection: Binding(get: { current ?? "" }, set: { bundle in Task { await model.change(kind, to: bundle) } })) {
                if current == nil { Text("None").tag("") }
                ForEach(row?.choices ?? [], id: \.bundle) { AppMenuItem(name: $0.name, bundle: $0.bundle).tag($0.bundle) }
            }
            .pickerStyle(.inline).labelsHidden()
        }
    }
}

/// One kind under All kinds: its name, and what macOS will ask or why the last change did not take.
private struct KindName: View {
    @Environment(\.ink) private var ink
    let kind: FileKind
    let model: DefaultAppsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(kind.name).lineLimit(1).fixedSize()
            if let note = model.rows[kind.id]?.message ?? kind.confirmNote {
                Text(note).font(ink.ui(11)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Configs (C3, was Defaults' second section): the app configs on this Mac as cards (ConfigsList, card agent-bo-95422841),
/// each opened in the main editor Open with picks.
struct ConfigsPage: View {
    var editor: EditorChoice = .shared
    var configs: ConfigsList.Start = .init()

    /// No intro of its own: the list's heading and note say what it is, once.
    var body: some View {
        KitPage { ConfigsList(editor: editor, start: configs) }
    }
}

/// Configs › Agents (Sven 2026-10-10, 2026-10-19): the agents' settings, CLAUDE.md, AGENTS.md and the Hermes souls as
/// Configs' cards, opened the same way.
struct InstructionsPage: View {
    var editor: EditorChoice = .shared
    var start: ConfigsList.Start = .init()

    var body: some View {
        KitPage { ConfigsList(editor: editor, kind: .instructions, start: start) }
    }
}
