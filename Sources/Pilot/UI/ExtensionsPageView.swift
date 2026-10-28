import AppKit
import PilotCore
import SwiftUI

/// The Extensions page (card agent-bo-95423247, story 141): the Extensions folder and how many it holds, then one card
/// per extension (its icon, title and folder; its commands each with its mode, its key and a way to Binds' editor; its
/// preferences as fields, saved as they change; what it says it touches in plain words), then the folders Pilot could
/// not read, each with why. A wide card puts the preferences beside the commands, split by a hairline. A link or a stopped run opens the page at one extension: it scrolls there and wears the focus border a
/// moment. Drawn in Instrument (card agent-bo-95423181, batch 6) or Toybox (card agent-bo-95423182), from the Ink (ADR 0008).
struct ExtensionsPageView: View {
    @Environment(\.ink) private var ink
    /// The app window shows: the folder is read again as it does, each time the page opens and each time a link asks.
    let onScreen: Bool
    /// The extension a link or a stopped run asked for: the page lands on it once the folder is read, and clears it.
    @Binding var focus: String?
    /// Opens Binds' editor on a command's action.
    let editBind: (String) -> Void
    /// Opens an extension's own page (story 161).
    var openPage: (String) -> Void = { _ in }
    @State private var settings: ExtensionsSettings
    /// The extension the page just landed on, lit for a moment.
    @State private var lit: String?

    /// The page's state; a render points it at a folder of its own.
    static var make: () -> ExtensionsSettings = { ExtensionsSettings() }
    static let intro = "Small programs in the Extensions folder whose commands join Hyper+Space. Set their keys and preferences here."
    /// What an extension is and where it goes, said by the empty folder.
    static let empty = "An extension is a folder with an extension.json whose commands join Hyper+Space.\nPut one in \(folderPath)."
    /// How long the extension a link landed on keeps the focus border.
    static let litFor = Duration.seconds(2.4)
    static var folderPath: String { (Extension.folder.path as NSString).abbreviatingWithTildeInPath }
    /// A card puts its preferences beside its commands from this width up; narrower, a preference's words and its field
    /// would crowd a half, so its parts stack.
    static func halves(width: CGFloat) -> Bool { width >= 860 }

    init(onScreen: Bool = true, focus: Binding<String?> = .constant(nil), settings: ExtensionsSettings? = nil,
         editBind: @escaping (String) -> Void = { _ in }, openPage: @escaping (String) -> Void = { _ in }) {
        self.onScreen = onScreen
        _focus = focus
        self.editBind = editBind
        self.openPage = openPage
        _settings = State(initialValue: settings ?? Self.make())
    }

    var body: some View {
        ScrollViewReader { proxy in
            KitPage(intro: Self.intro) {
                folder
                if !settings.rows.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(settings.rows) { row in
                            ExtensionCard(row: row, settings: settings, lit: lit == row.id, editBind: editBind, openPage: openPage).id(row.id)
                        }
                    }
                }
                if !settings.broken.isEmpty { broken }
            }
            // The folder is read again as the page shows and as a link asks (one read when both come at once), so an
            // extension added since is found.
            .task(id: [onScreen ? "shown" : "", focus ?? ""]) { if onScreen || focus != nil { await settings.load(); land(proxy) } }
        }
        .task(id: lit) {
            guard lit != nil, (try? await Task.sleep(for: Self.litFor)) != nil else { return }
            withAnimation(Kit.change) { lit = nil }
        }
    }

    /// After a read of the folder: scrolls to the extension asked for, lights it and clears the ask; an id not in the
    /// folder is dropped.
    private func land(_ proxy: ScrollViewProxy) {
        guard let id = focus else { return }
        focus = nil
        guard settings.rows.contains(where: { $0.id == id }) else { return }
        lit = id
        // A turn later, so a card the load just added is laid out before the scroll looks for it.
        Task { @MainActor in proxy.scrollTo(id, anchor: .top) }
    }

    // MARK: The folder

    /// The count as a heading over the cards with the path under it and Open as its link; empty, it says what an
    /// extension is and where it goes.
    @ViewBuilder private var folder: some View {
        let open = { ScriptsModule.openFolder(Extension.folder) }
        let empty = settings.loaded && settings.rows.isEmpty
        let emptyState = EmptyState(title: "No extensions yet", line: Self.empty, action: ("Open Extensions folder", open))
        if empty {
            emptyState
                .padding(.horizontal, 18).padding(.vertical, 16)
                .blockSurface()
                .padding(.top, 22)
        } else {
            CalmHeading(title: settings.loaded ? count : "Extensions", note: Self.folderPath) {
                AccentLink(title: "Open Extensions folder", chevron: "arrow.up.right", action: open)
            }
        }
    }

    /// "3 extensions · 7 commands".
    private var count: String {
        let commands = settings.rows.reduce(0) { $0 + $1.ext.listed.count }
        return [Self.plural(settings.rows.count, "extension"), Self.plural(commands, "command")].joined(separator: " · ")
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    // MARK: Folders not read

    private var broken: some View {
        KitBlock(title: "Folders not read", symbol: "exclamationmark.triangle",
                 note: "Pilot skips these until they read as extensions; each says why.") {
            ForEach(Array(settings.broken.enumerated()), id: \.element.folder) { i, folder in
                BlockRow(first: i == 0) {
                    Image(systemName: "exclamationmark.triangle.fill").font(ink.ui(11)).foregroundStyle(ink.yellow)
                        .frame(width: 16).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.folder).font(ink.mono(12.5)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
                        Text(folder.problem.reason).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 7)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - An extension

/// One extension's card: its icon, title and folder (and how many preferences it still needs), then its commands, its
/// preferences and what it touches; wide, the preferences take the right half.
private struct ExtensionCard: View {
    @Environment(\.ink) private var ink
    let row: ExtensionsPage.Row
    let settings: ExtensionsSettings
    /// Just landed on: the theme's focus border.
    let lit: Bool
    let editBind: (String) -> Void
    let openPage: (String) -> Void
    @State private var wide = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if wide {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) { commands; if !row.fields.isEmpty { touches } }
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.trailing, 20)
                    ink.line.frame(width: 1).padding(.top, 12)
                    VStack(alignment: .leading, spacing: 0) { if row.fields.isEmpty { touches } else { preferences } }
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.leading, 20)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                commands
                if !row.fields.isEmpty { preferences }
                touches
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 16)
        .blockSurface()
        .focusBorder(on: lit, radius: ink.blockRadius)
        .onGeometryChange(for: Bool.self) { ExtensionsPageView.halves(width: $0.size.width) } action: { wide = $0 }
    }

    /// The icon on its tile, the folder under the title, the preferences still to set and Uninstall at the right; what it
    /// is for and its examples under it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleLine
            ExtensionPurpose(description: row.ext.description, examples: row.ext.examples)
        }
    }

    private var titleLine: some View {
        let needed = row.fields.filter(\.isMissing).count
        let folder = Text(row.ext.folder.lastPathComponent).font(ink.mono(11)).foregroundStyle(ink.muted).lineLimit(1)
        return HStack(spacing: 12) {
            EmojiTile(emoji: row.ext.icon, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.ext.title).font(ink.ui(14, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                folder
            }
            Spacer(minLength: 8)
            if needed > 0 {
                Chip(text: "Needs \(ExtensionsPageView.plural(needed, "preference"))", color: ink.yellow, tag: true)
            }
            let busy = settings.catalogue.busy[row.id] != nil
            if busy { ProgressView().controlSize(.small) }
            // Its page, when it declares one (story 161); the card keeps its keys, settings and Uninstall.
            if row.ext.page != nil { Button("Open page") { openPage(row.id) }.buttonStyle(.pilot) }
            UninstallButton(title: row.ext.title, busy: busy) { if let line = await settings.uninstall(row) { HUD.tip(line) } }
        }
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 0) {
            PartHeading(text: "Commands")
            ForEach(Array(row.ext.listed.enumerated()), id: \.element.actionID) { i, command in
                BlockRow(first: i == 0) { CommandLine(command: command, editBind: editBind) }
            }
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 0) {
            PartHeading(text: "Preferences")
            ForEach(Array(row.fields.enumerated()), id: \.element.id) { i, field in
                PreferenceRow(row: row, field: field, settings: settings, first: i == 0)
            }
        }
    }

    /// What it says it touches, a line each with its kind's symbol, then that this is shown, not enforced.
    private var touches: some View {
        VStack(alignment: .leading, spacing: 0) {
            PartHeading(text: "Says it touches")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(row.permissions, id: \.text) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: line.kind.symbol).font(ink.ui(11)).foregroundStyle(ink.muted)
                            .frame(width: 16).accessibilityHidden(true)
                        Text(line.text).font(ink.ui(12.5)).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                FinePrint(text: ExtensionsPage.notEnforced).padding(.top, 2)
            }
            .padding(.top, 4).padding(.bottom, 4)
        }
    }
}

/// Uninstall on an installed extension's card and its catalogue card (story 158): asks first, saying the folder goes to
/// the Trash and its settings stay, then runs `uninstall`.
struct UninstallButton: View {
    let title: String
    let busy: Bool
    let uninstall: () async -> Void
    @State private var confirming = false

    var body: some View {
        Button("Uninstall") { confirming = true }
            .buttonStyle(.pilot).disabled(busy)
            .help("Moves it to the Trash; its settings are kept")
            .accessibilityLabel("Uninstall \(title)")
            .confirmationDialog(ExtensionCatalogue.uninstallQuestion(title), isPresented: $confirming) {
                Button("Uninstall", role: .destructive) { Task { await uninstall() } }
            } message: {
                Text(ExtensionCatalogue.uninstallNote)
            }
    }
}

/// What an extension is for, in its own plain words, then its examples, each a line with an arrow: on the Installed
/// card and the catalogue's (story 158). Nothing when the manifest says neither.
struct ExtensionPurpose: View {
    @Environment(\.ink) private var ink
    let description: String
    let examples: [String]

    var body: some View {
        if !description.isEmpty || !examples.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !description.isEmpty {
                    Text(description).font(ink.ui(12.5)).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(examples, id: \.self) { example in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(ink.ui(10)).foregroundStyle(ink.muted).accessibilityHidden(true)
                        Text(example).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("For example: \(example)")
                }
            }
            .textSelection(.enabled)
        }
    }
}

extension ExtensionsPage.Permission.Kind {
    /// Each kind's symbol: hosts, the clipboard, files, Pilot actions; a shield for one that names nothing. The page's
    /// cards and the catalogue's draw it.
    var symbol: String {
        switch self {
        case .network: "network"
        case .clipboard: "doc.on.clipboard"
        case .files: "folder"
        case .actions: "bolt"
        case .nothing: "checkmark.shield"
        }
    }
}

/// An extension's emoji on a key-cap tile, the puzzle piece when it has none. The catalogue's cards wear it too.
struct EmojiTile: View {
    @Environment(\.ink) private var ink
    let emoji: String?
    let size: CGFloat

    var body: some View {
        if ink.isInstrument {
            glyph.instrumentTile(size)
        } else {
            // Toybox's keycap: the emoji on the raised fill in the ink outline, a solid edge under it.
            glyph.frame(width: size - 4, height: size - 6)
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
                .background(Toy.block(ink.style, fill: ink.style.color(\.raised), radius: size * 0.3, edge: 4))
                .accessibilityHidden(true)
        }
    }

    private var glyph: some View {
        Group {
            if let emoji { Text(emoji).font(.system(size: size * 0.6)) }
            else { Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(ink.muted) }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - A command

/// A command: its icon, title and mode; its key and its × when it has one, Run (Sven on build 31: Add Codex account
/// here did nothing), and Set key or Change key, which opens Binds' editor on it.
private struct CommandLine: View {
    @Environment(\.ink) private var ink
    @Environment(Engine.self) private var engine: Engine?
    let command: Extension.Command
    let editBind: (String) -> Void

    /// The link's room, so every bound row's key ends at one edge whichever words it says.
    static let linkWidth: CGFloat = 82

    var body: some View {
        let bound = engine?.binds.store.trigger(for: command.actionID) != nil
        Text(command.icon ?? "").font(.system(size: 14)).frame(width: 18).accessibilityHidden(true)
        Text(command.title).foregroundStyle(ink.text).lineLimit(1).truncationMode(.tail)
        Chip(text: command.mode.words, tag: true).help(command.mode.help)
        Spacer(minLength: 8)
        if bound {
            BindKey(action: command.actionID)
            IconButton(symbol: "xmark", label: "Clear the key of \(command.title)", size: 20, glyph: 9) { engine?.clearKey(command.actionID) }
        }
        AccentLink(title: "Run") { engine?.action(command.actionID)?.run() }.help(command.mode.help).accessibilityLabel("Run \(command.title)")
        AccentLink(title: bound ? "Change key" : "Set key") { editBind(command.actionID) }
            .frame(width: Self.linkWidth, alignment: .trailing)
            .help("Opens Binds' editor on \(command.title)")
            .accessibilityLabel(bound ? "Change the key for \(command.title)" : "Set a key for \(command.title)")
    }
}

extension Extension.Mode {
    /// The manifest's own words for it, so its author knows the row.
    var words: String {
        switch self {
        case .noView: "No view"
        case .list: "List"
        case .detail: "Detail"
        }
    }

    /// What a command of this mode does, on its tag's tooltip here and in the catalogue.
    var help: String {
        switch self {
        case .noView: "Runs and shows one line"
        case .list: "Opens a list in Hyper+Space"
        case .detail: "Opens a detail in Hyper+Space"
        }
    }
}

// MARK: - A preference

/// A preference: its title (Needed while a required one has no value) with the manifest's description as its ⓘ (none
/// when the manifest gives none; page map ⓘ sweep, Sven 2026-10-17) on the left, its field on the right; a save that
/// failed says why under it.
private struct PreferenceRow: View {
    @Environment(\.ink) private var ink
    let row: ExtensionsPage.Row
    let field: ExtensionsPage.Field
    let settings: ExtensionsSettings
    let first: Bool

    private var preference: Extension.Preference { field.preference }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if preference.kind == .checkbox {
                BlockRow(first: first) {
                    Toggle(isOn: Binding(get: { field.value == .bool(true) }, set: { settings.set(.bool($0), for: field, of: row) })) { words }
                        .toggleStyle(.pilotSwitchRow)
                }
            } else {
                BlockRow(first: first) {
                    words
                    Spacer(minLength: 12)
                    control.frame(width: PreferenceRow.fieldWidth)
                }
            }
            if let failure = settings.failure(of: field, in: row) {
                FinePrint(text: failure, color: ink.red).padding(.bottom, 8)
            }
        }
    }

    /// Every field's width, so a row's fields line up down the card.
    static let fieldWidth: CGFloat = 240

    private var words: some View {
        HStack(spacing: 7) {
            Text(preference.title).foregroundStyle(ink.text)
            if let detail, !detail.isEmpty { InfoMark(text: detail) }
            if field.isMissing { Chip(text: "Needed", color: ink.yellow, tag: true) }
        }
        .padding(.vertical, 7)
    }

    /// The manifest's description; a password adds where it is kept.
    private var detail: String? {
        guard preference.kind == .password else { return preference.description }
        return [preference.description, "Kept in your Keychain."].compactMap { $0 }.joined(separator: " ")
    }

    @ViewBuilder private var control: some View {
        switch preference.kind {
        case .text: TextPreference(row: row, field: field, settings: settings, secure: false)
        case .password: TextPreference(row: row, field: field, settings: settings, secure: true)
        case .dropdown(let options): DropdownPreference(row: row, field: field, settings: settings, options: options)
        case .app, .file, .folder: PathPreference(row: row, field: field, settings: settings)
        case .checkbox: EmptyView()
        }
    }
}

/// A text or password preference as the kit's field. Text is saved as it is typed, an empty one going back to its
/// default; a password only on Return or on leaving the field, so the Keychain is not written per keystroke. Leaving the
/// field shows the value a run gets.
private struct TextPreference: View {
    @Environment(\.ink) private var ink
    let row: ExtensionsPage.Row
    let field: ExtensionsPage.Field
    let settings: ExtensionsSettings
    let secure: Bool
    @State private var draft: String
    @FocusState private var typing: Bool

    init(row: ExtensionsPage.Row, field: ExtensionsPage.Field, settings: ExtensionsSettings, secure: Bool) {
        self.row = row; self.field = field; self.settings = settings; self.secure = secure
        _draft = State(initialValue: Self.text(field.value))
    }

    static func text(_ value: JSONValue?) -> String { if case .string(let s)? = value { s } else { "" } }

    var body: some View {
        let prompt = Text(field.preference.default.map(Self.text).flatMap { $0.isEmpty ? nil : "Default: \($0)" } ?? (secure ? "Not set" : "Type it"))
            .foregroundStyle(ink.muted)
        Group {
            if secure { SecureField("", text: $draft, prompt: prompt) } else { TextField("", text: $draft, prompt: prompt) }
        }
        .frame(minHeight: 24)
        .pilotField()
        .overlay { if field.isMissing { RoundedRectangle(cornerRadius: 6).strokeBorder(ink.yellow) } }
        .focused($typing)
        .onSubmit { if secure { save() } }
        .onChange(of: draft) { if !secure, draft != Self.text(field.value) { save() } }
        .onChange(of: typing) {
            guard !typing else { return }
            if secure, draft != Self.text(field.value) { save() }
            draft = Self.text(field.value)
        }
        .onChange(of: field.value) { if !typing { draft = Self.text(field.value) } }
        // A password typed but never submitted is still saved when the page goes away mid-edit.
        .onDisappear { if secure, draft != Self.text(field.value) { save() } }
        .accessibilityLabel(field.preference.title)
    }

    private func save() { settings.set(draft.isEmpty ? nil : .string(draft), for: field, of: row) }
}

/// A dropdown preference as a field naming the option picked, its options in a menu with the picked one ticked.
private struct DropdownPreference: View {
    let row: ExtensionsPage.Row
    let field: ExtensionsPage.Field
    let settings: ExtensionsSettings
    let options: [Extension.Preference.Option]

    var body: some View {
        DropdownField(label: field.preference.title, options: options.map { ($0.value, $0.title) }, picked: TextPreference.text(field.value),
                      missing: field.isMissing) { settings.set(.string($0), for: field, of: row) }
    }
}

/// A pick as the kit's field: the picked option's title with the up-down chevron, the options in a menu with the picked
/// one ticked; "Pick one" while none is (an extension's dropdown, a workspace's Monitor).
struct DropdownField<Value: Hashable>: View {
    @Environment(\.ink) private var ink
    let label: String
    let options: [(value: Value, title: String)]
    let picked: Value
    var missing = false
    let pick: (Value) -> Void

    var body: some View {
        let title = options.first { $0.value == picked }?.title
        Menu {
            Picker(label, selection: Binding(get: { picked }, set: pick)) {
                ForEach(options.indices, id: \.self) { Text(options[$0].title).tag(options[$0].value) }
            }
            .pickerStyle(.inline).labelsHidden().menuRows()
        } label: {
            HStack(spacing: 6) {
                Text(title ?? "Pick one").foregroundStyle(title == nil ? ink.muted : ink.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(ink.ui(10, .semibold)).foregroundStyle(ink.muted)
            }
            .font(ink.ui(12.5))
            .fieldFace(missing: missing)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(label).accessibilityValue(title ?? "none")
    }
}

/// An app, file or folder preference as a field showing what is picked with its icon; a click opens the Mac's picker
/// (an app starting in /Applications, any app allowed), the × inside it puts the default back.
private struct PathPreference: View {
    @Environment(\.ink) private var ink
    let row: ExtensionsPage.Row
    let field: ExtensionsPage.Field
    let settings: ExtensionsSettings

    var body: some View {
        let path = TextPreference.text(field.value)
        let saved = field.value != nil && field.value != field.preference.default
        Button(action: choose) {
            HStack(spacing: 7) {
                if path.isEmpty {
                    Image(systemName: placeholder.symbol).font(ink.ui(12)).foregroundStyle(ink.muted).frame(width: 16)
                    Text(placeholder.text).foregroundStyle(ink.muted).lineLimit(1)
                } else {
                    Image(nsImage: AppsModule.icon(file: path)).resizable().interpolation(.high).frame(width: 16, height: 16)
                    Text(name(path)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .font(ink.ui(12.5))
            // Room for the × over the field's end.
            .padding(.trailing, saved ? 18 : 0)
            .fieldFace(missing: field.isMissing)
        }
        .buttonStyle(.kitPress)
        .help(path.isEmpty ? placeholder.text : path)
        .accessibilityLabel(field.preference.title).accessibilityValue(path.isEmpty ? "none" : name(path))
        .overlay(alignment: .trailing) {
            if saved {
                IconButton(symbol: "xmark", label: "Clear \(field.preference.title)", size: 20, glyph: 9) { settings.set(nil, for: field, of: row) }
                    .padding(.trailing, 4)
            }
        }
    }

    /// What an empty field says, and its symbol.
    private var placeholder: (text: String, symbol: String) {
        switch field.preference.kind {
        case .app: ("Choose an app…", "app.dashed")
        case .folder: ("Choose a folder…", "folder")
        default: ("Choose a file…", "doc")
        }
    }

    /// An app by its name, a file or folder by its path from home.
    private func name(_ path: String) -> String {
        field.preference.kind == .app ? AppsModule.appName(at: URL(fileURLWithPath: path)) : (path as NSString).abbreviatingWithTildeInPath
    }

    private func choose() {
        let panel = NSOpenPanel()
        let kind = field.preference.kind
        let current = TextPreference.text(field.value)
        switch kind {
        case .app:
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.prompt = "Use app"
        case .folder:
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use folder"
        default:
            panel.prompt = "Use file"
        }
        if kind != .app, !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent() }
        panel.message = field.preference.title
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        settings.set(.string(picked.path), for: field, of: row)
    }
}

private extension View {
    /// A control drawn as the kit's field (pilotField's fill, edge and corner) at the field's height, 32; edged while a
    /// required preference has no value.
    func fieldFace(missing: Bool) -> some View { modifier(FieldFace(missing: missing)) }
}

private struct FieldFace: ViewModifier {
    @Environment(\.ink) private var ink
    let missing: Bool

    func body(content: Content) -> some View {
        let sized = content.padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
        if ink.style.kind == .toybox {
            // Toybox's typed field: a white well in the ink outline, a needed one on the sun's soft fill.
            sized.toyWell(missing ? \.accentSoft : \.panel, radius: 10).contentShape(.rect)
        } else {
            // pilotField's Instrument well, so every field in a list matches; a needed one edged in the signal (attention).
            sized.instrumentWell()
                .overlay { if missing { RoundedRectangle(cornerRadius: ink.style.radii.control, style: .continuous).strokeBorder(ink.accent) } }
                .contentShape(.rect)
        }
    }
}
