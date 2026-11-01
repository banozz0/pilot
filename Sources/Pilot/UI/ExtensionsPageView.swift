import AppKit
import PilotCore
import SwiftUI

/// The Extensions page (card agent-bo-95423247, story 141; pilot-1-1 T7, Q600 and Q601): one list, the installed
/// extensions A to Z, then the catalogue's others as it sorts them, filtered by All, Installed or Updates and a search;
/// the picked row's detail beside it. A row the catalogue has newer wears an Update button that updates it in place, and
/// Update all heads the list while any does. An installed one's detail is its version and where it shows, Open page and ⋯
/// (Update, Uninstall), then its Settings (the form its page shows too, Q637), its Keys and what it touches; a catalogue
/// one's is Get, what you get, its commands and what it will touch, nothing installed before Get. The catalogue is read
/// from GitHub only while the page shows (kept ten minutes); while it is read three quiet rows stand in, and when it is
/// out of reach one line says so with Try again, the installed rows untouched. A link or a stopped run lands on one row:
/// it is picked, scrolled to and wears the focus border a moment. Drawn in Instrument or Toybox from the Ink (ADR 0008).
struct ExtensionsPageView: View {
    @Environment(\.ink) private var ink
    /// The app window shows: the folder is read again as it does, and the catalogue read (kept ten minutes).
    let onScreen: Bool
    /// The extension a link or a stopped run asked for: the page lands on it once it is read, and clears it.
    @Binding var focus: String?
    /// A link asked for the catalogue (`tab=catalogue`, Browse catalogue): its first row is picked once it is read.
    var toCatalogue = false
    /// Called once the catalogue was landed on, so the window forgets the ask.
    var landedCatalogue: () -> Void = {}
    /// Opens Binds' editor on a command's action.
    let editBind: (String) -> Void
    /// Opens an extension's own page (story 161).
    var openPage: (String) -> Void = { _ in }
    @State private var settings: ExtensionsSettings
    @State private var filter = ExtensionsPage.Filter.all
    @State private var query = ""
    @State private var picked: String?
    /// The row the page just landed on, lit for a moment.
    @State private var lit: String?
    /// Measured, never assumed: starting wide would hold the side column open and the page past a narrow window.
    @State private var wide = false

    /// The page's state; a render points it at a folder of its own.
    static var make: () -> ExtensionsSettings = { ExtensionsSettings() }
    /// What an extension is and where it goes, said by the empty folder.
    static let empty = "An extension is a folder with an extension.json whose commands join Hyper+Space.\nPut one in \(folderPath)."
    /// How long the row a link landed on keeps the focus border.
    static let litFor = Duration.seconds(2.4)
    static var folderPath: String { (Extension.folder.path as NSString).abbreviatingWithTildeInPath }
    /// The list's width; the detail takes the rest.
    static let listWidth: CGFloat = 276
    /// From this page width the detail puts Keys and It touches beside Settings; narrower, they stack under it.
    static func halves(width: CGFloat) -> Bool { width >= 860 }

    /// `pick` the row picked first (a render's); the first row otherwise.
    init(onScreen: Bool = true, focus: Binding<String?> = .constant(nil), toCatalogue: Bool = false, landedCatalogue: @escaping () -> Void = {},
         settings: ExtensionsSettings? = nil, pick: String? = nil, editBind: @escaping (String) -> Void = { _ in },
         openPage: @escaping (String) -> Void = { _ in }) {
        self.onScreen = onScreen
        _focus = focus
        self.toCatalogue = toCatalogue
        self.landedCatalogue = landedCatalogue
        self.editBind = editBind
        self.openPage = openPage
        _settings = State(initialValue: settings ?? Self.make())
        _picked = State(initialValue: pick)
    }

    private var catalogue: ExtensionCatalogueModel { settings.catalogue }

    private var listing: ExtensionsPage.Listing {
        ExtensionsPage.listing(settings.rows, catalogue: catalogue.load == .loaded ? catalogue.index?.entries : nil, filter: filter, query: query)
    }

    var body: some View {
        let listing = listing
        let rows = listing.installed + listing.catalogue
        let current = rows.first { $0.id == picked } ?? rows.first
        VStack(spacing: 0) {
            toolbar(listing)
            ink.line.frame(height: 1)
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    list(listing, current: current?.id)
                        .onChange(of: lit) { if let lit { withAnimation(Kit.change) { proxy.scrollTo(lit, anchor: .center) } } }
                        .onChange(of: toCatalogue ? catalogue.load : nil, initial: true) { landCatalogue(proxy) }
                }
                .frame(width: Self.listWidth)
                ink.line.frame(width: 1)
                detail(current).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Bool.self) { Self.halves(width: $0.size.width) } action: { wide = $0 }
        // The folder is read again as the page shows and as a link asks, so an extension added since is found; the
        // catalogue only while the page shows, as its tab was. Keyed apart from `focus`, which land() clears.
        .task(id: onScreen) {
            guard onScreen else { return }
            await settings.load()
            land()
            await catalogue.open()
            land()
        }
        .onChange(of: focus, initial: true) {
            guard focus != nil else { return }
            Task { await settings.load(); land() }
        }
        .task(id: lit) {
            guard lit != nil, (try? await Task.sleep(for: Self.litFor)) != nil else { return }
            withAnimation(Kit.change) { lit = nil }
        }
    }

    /// Picks, lights and scrolls to the row asked for once it is read, and clears the ask; an id neither the folder nor
    /// the catalogue has is dropped, once the catalogue has answered or will not be read.
    private func land() {
        guard let id = focus else { return }
        let known = settings.rows.contains { $0.id == id } || (catalogue.load == .loaded && catalogue.index?.entry(id) != nil)
        guard known || !(onScreen && [.idle, .loading].contains(catalogue.load)) else { return }
        focus = nil
        guard known else { return }
        (filter, query) = (.all, "")
        picked = id
        lit = id
    }

    /// `tab=catalogue`: once the catalogue is read, its first row is picked and scrolled to.
    private func landCatalogue(_ proxy: ScrollViewProxy) {
        guard toCatalogue, focus == nil, catalogue.load != .loading, catalogue.load != .idle else { return }
        (filter, query) = (.all, "")
        if let first = listing.catalogue.first { picked = first.id }
        withAnimation(Kit.change) { proxy.scrollTo(Self.catalogueAnchor, anchor: .top) }
        landedCatalogue()
    }

    static let catalogueAnchor = "catalogue"

    // MARK: The toolbar

    /// All, Installed and Updates with their counts, the search over both, and the Extensions folder.
    private func toolbar(_ listing: ExtensionsPage.Listing) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(ExtensionsPage.Filter.allCases, id: \.self) { f in
                    Button { withAnimation(Kit.change) { filter = f } } label: { Chip(text: f.title, on: filter == f, count: "\(listing.count(f))") }
                        .buttonStyle(.kitPress)
                        .accessibilityLabel("\(f.title), \(listing.count(f))")
                        .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
            }
            Spacer(minLength: 12)
            SearchBox(prompt: "Search \(ExtensionsPageView.plural(listing.total, "extension"))", text: $query).frame(maxWidth: 220)
            Button { ScriptsModule.openFolder(Extension.folder) } label: { Label("Folder", systemImage: "folder") }
                .buttonStyle(.pilot)
                .help("Opens \(Self.folderPath)")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    // MARK: The list

    private func list(_ listing: ExtensionsPage.Listing, current: String?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack {
                    PartHeading(text: "Installed · \(listing.installedCount)")
                    Spacer(minLength: 6)
                    if listing.updates > 0, catalogue.load == .loaded { updateAll(listing) }
                }
                .padding(.horizontal, 10)
                if settings.loaded, settings.rows.isEmpty {
                    Text("None yet. Get one below, or put one in the Extensions folder.").font(ink.ui(12)).foregroundStyle(ink.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.vertical, 6)
                }
                ForEach(listing.installed) { entry in row(entry, current: current) }
                if filter == .all { catalogueRows(listing, current: current) }
                if !settings.broken.isEmpty, filter == .all, query.isEmpty { broken }
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 14)
        }
    }

    /// The catalogue's heading, then its rows, three quiet rows while it is read, or why it is out of reach.
    @ViewBuilder private func catalogueRows(_ listing: ExtensionsPage.Listing, current: String?) -> some View {
        switch catalogue.load {
        case .idle, .loading:
            eyebrow("Catalogue", trailing: "Reading…").id(Self.catalogueAnchor)
            ForEach(0..<3, id: \.self) { _ in skeleton }
        case .failed(let why):
            eyebrow("Catalogue").id(Self.catalogueAnchor)
            VStack(alignment: .leading, spacing: 8) {
                Text("The catalogue is out of reach.").font(ink.ui(13, .medium)).foregroundStyle(ink.text)
                Text((settings.rows.isEmpty ? "" : "Your \(Self.plural(settings.rows.count, "extension")) still work. ") + "Pilot tries again when you come back here.")
                    .font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                FinePrint(text: Self.why(why))
                Button("Try again") { Task { await catalogue.refresh() } }.buttonStyle(.pilot)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        case .loaded:
            eyebrow("Catalogue · \(listing.total - listing.installedCount)").id(Self.catalogueAnchor)
            ForEach(listing.catalogue) { entry in row(entry, current: current) }
            if listing.catalogue.isEmpty {
                Text(query.isEmpty ? "You have every extension it lists." : "Nothing in the catalogue matches.")
                    .font(ink.ui(12)).foregroundStyle(ink.muted).padding(.horizontal, 10).padding(.vertical, 6)
            }
            FinePrint(text: "Read from github.com/\(ExtensionCatalogue.repo) only while this page shows.")
                .padding(.horizontal, 10).padding(.top, 10)
        }
    }

    /// Why the read failed, under a title that already says it is out of reach: "The catalogue is private; …".
    static func why(_ reason: String) -> String {
        let said = "Pilot's catalogue could not be reached: "
        guard reason.hasPrefix(said) else { return reason }
        let rest = reason.dropFirst(said.count)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// A group's mono capitals, a count or a state at its right.
    private func eyebrow(_ text: String, trailing: String? = nil) -> some View {
        HStack {
            PartHeading(text: text)
            Spacer(minLength: 6)
            if let trailing { PartHeading(text: trailing) }
        }
        .padding(.horizontal, 10)
    }

    /// One row: its tile, name and one line; ✓, Update or Get at its right. The picked row takes the theme's selection.
    /// Update is its own button over the row's right, never inside the row's: a button in a button's label fires either.
    private func row(_ entry: ExtensionsPage.Entry, current: String?) -> some View {
        let on = entry.id == current
        return Button { picked = entry.id } label: {
            KitRow(selected: on) {
                EmojiTile(emoji: entry.icon, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(ink.ui(13, .semibold))
                    if !entry.line.isEmpty { Text(entry.line).font(ink.ui(11.5)).foregroundStyle(ink.rowQuiet(on)) }
                }
                Spacer(minLength: 6)
                switch entry.mark {
                case .installed: Image(systemName: "checkmark").font(ink.ui(10, .semibold)).foregroundStyle(ink.rowQuiet(on)).accessibilityLabel("Installed")
                case .update: Chip(text: "Update", tag: true).hidden().accessibilityHidden(true)
                case .get: Text("Get").font(ink.mono(11, weight: .medium)).foregroundStyle(ink.rowLit(on, ink.text))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { if entry.mark == .update { updateButton(entry).padding(.trailing, 10) } }
        .focusBorder(on: lit == entry.id, radius: ink.style.radii.control)
        .id(entry.id)
    }

    /// Update all, at the list's top while the catalogue has any installed one newer: each in turn, one HUD line after.
    private func updateAll(_ listing: ExtensionsPage.Listing) -> some View {
        let entries = listing.updatable.compactMap { catalogue.index?.entry($0) }
        return Button { Task { if let line = await settings.updateAll(entries) { HUD.tip(line) } } } label: {
            Chip(text: settings.updatingAll ? "Updating…" : "Update all", count: settings.updatingAll ? nil : "\(listing.updates)", tag: true)
        }
        .buttonStyle(.kitPress)
        .disabled(settings.updatingAll)
        .help("Updates \(Self.plural(listing.updates, "extension")) from Pilot's catalogue, one after another")
        .accessibilityLabel("Update all \(Self.plural(listing.updates, "extension"))")
    }

    /// A row's Update: that extension updated in place from the catalogue, a spinner while it runs.
    @ViewBuilder private func updateButton(_ entry: ExtensionsPage.Entry) -> some View {
        if catalogue.busy[entry.id] != nil {
            ProgressView().controlSize(.small).accessibilityLabel("Updating \(entry.title)")
        } else if let offered = catalogue.index?.entry(entry.id) {
            Button { Task { if let line = await settings.install(offered) { HUD.tip(line) } } } label: {
                Chip(text: "Update", tag: true)
            }
            .buttonStyle(.kitPress)
            .disabled(settings.updatingAll)
            .help("Updates \(entry.title) to \(offered.version)")
            .accessibilityLabel("Update \(entry.title) to \(offered.version)")
        }
    }

    /// A quiet stand-in row while the catalogue is read.
    private var skeleton: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7).fill(ink.line).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(ink.line).frame(width: 96, height: 7)
                Capsule().fill(ink.line).frame(width: 136, height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    /// The folders Pilot could not read, each with why.
    private var broken: some View {
        VStack(alignment: .leading, spacing: 2) {
            eyebrow("Not read · \(settings.broken.count)")
            ForEach(settings.broken, id: \.folder) { folder in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(ink.ui(10)).foregroundStyle(ink.yellow).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.folder).font(ink.mono(12)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
                        Text(folder.problem.reason).font(ink.ui(11.5)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 8)
    }

    // MARK: The detail

    @ViewBuilder private func detail(_ entry: ExtensionsPage.Entry?) -> some View {
        if let entry, entry.kind == .installed, let row = settings.rows.first(where: { $0.id == entry.id }) {
            InstalledDetail(row: row, settings: settings, offered: catalogue.index?.entry(row.id).flatMap { entry.mark == .update ? $0 : nil },
                            wide: wide, editBind: editBind, openPage: openPage).id(row.id)
        } else if let entry, let offered = catalogue.index?.entry(entry.id) {
            CatalogueDetail(entry: offered, settings: settings).id(offered.id)
        } else if settings.loaded, settings.rows.isEmpty {
            EmptyState(title: "No extensions yet", line: Self.empty, action: ("Open Extensions folder", { ScriptsModule.openFolder(Extension.folder) }))
                .padding(24)
        }
    }
}

// MARK: - An installed extension's detail

/// Its header (tile, name, "3.3.3 · installed · in the menu bar, Hyper+Space and a page", Open page when it has one, ⋯
/// for Update and Uninstall), then Settings, Keys and It touches; wide, Keys and It touches beside Settings.
private struct InstalledDetail: View {
    @Environment(\.ink) private var ink
    let row: ExtensionsPage.Row
    let settings: ExtensionsSettings
    /// The catalogue's newer version, when it has one.
    let offered: ExtensionCatalogue.Entry?
    let wide: Bool
    let editBind: (String) -> Void
    let openPage: (String) -> Void
    @State private var confirming = false

    /// The side column's width beside Settings.
    static let sideWidth: CGFloat = 260

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let failure = settings.catalogue.failures[row.id] { FinePrint(text: failure, color: ink.red) }
                if wide, !row.fields.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        settingsPanel.frame(maxWidth: .infinity)
                        VStack(spacing: 14) { keys; touches }.frame(width: Self.sideWidth)
                    }
                } else {
                    if !row.fields.isEmpty { settingsPanel }
                    keys
                    touches
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        let busy = settings.catalogue.busy[row.id]
        let line = [row.version, "installed", ExtensionsPage.whereItShows(row.surfaces)].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 14) {
            EmojiTile(emoji: row.ext.icon, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.ext.title).font(ink.ui(18, .semibold)).foregroundStyle(ink.text).lineLimit(1).accessibilityAddTraits(.isHeader)
                Text(busy ?? line).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(2)
            }
            Spacer(minLength: 8)
            if busy != nil { ProgressView().controlSize(.small) }
            if row.ext.page != nil { Button("Open page") { openPage(row.id) }.buttonStyle(.pilot) }
            Menu {
                if let offered {
                    Button("Update to \(offered.version)") { Task { if let line = await settings.install(offered) { HUD.tip(line) } } }
                }
                Button("Uninstall…", role: .destructive) { confirming = true }
            } label: {
                Image(systemName: "ellipsis").font(ink.ui(12, .semibold)).frame(width: 28, height: 28)
            }
            .menuStyle(.button).buttonStyle(.pilot).menuIndicator(.hidden).fixedSize()
            .disabled(busy != nil)
            .accessibilityLabel("More for \(row.ext.title)")
        }
        // On the header, not the menu's item: a dialog never anchors on a menu item.
        .confirmationDialog(ExtensionCatalogue.uninstallQuestion(row.ext.title), isPresented: $confirming) {
            Button("Uninstall", role: .destructive) { Task { if let line = await settings.uninstall(row) { HUD.tip(line) } } }
        } message: {
            Text(ExtensionCatalogue.uninstallNote)
        }
    }

    private var settingsPanel: some View {
        TitledPanel(title: "Settings") { ExtensionSettingsForm(row: row, settings: settings) }
    }

    /// Each listed command, Run on a click of its name, its key with ×, or Set key, which opens Binds' editor on it.
    private var keys: some View {
        TitledPanel(title: "Keys") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(row.ext.listed.enumerated()), id: \.element.actionID) { i, command in
                    BlockRow(first: i == 0) { CommandKey(command: command, editBind: editBind) }
                }
                if row.hiddenCommands > 0 {
                    FinePrint(text: "And \(ExtensionsPageView.plural(row.hiddenCommands, "command")) only its own views reach.").padding(.top, 6)
                }
            }
        }
    }

    /// What it says it touches, a line each with its kind's symbol, then that this is shown, not enforced.
    private var touches: some View {
        TitledPanel(title: "It touches") { PermissionLines(permissions: row.permissions) }
    }
}

/// A command's row on Keys: its icon and title (a click runs it, Sven on build 31), its key with its ×, or Set key.
private struct CommandKey: View {
    @Environment(\.ink) private var ink
    @Environment(Engine.self) private var engine: Engine?
    let command: Extension.Command
    let editBind: (String) -> Void

    var body: some View {
        let bound = engine?.binds.store.trigger(for: command.actionID) != nil
        Button { engine?.action(command.actionID)?.run() } label: {
            HStack(spacing: 7) {
                Text(command.icon ?? "").font(.system(size: 13)).frame(width: 16).accessibilityHidden(true)
                Text(command.title).foregroundStyle(ink.text).lineLimit(1).truncationMode(.tail)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Runs it. \(command.mode.help).")
        .accessibilityLabel("Run \(command.title)")
        Spacer(minLength: 6)
        if bound {
            Button { editBind(command.actionID) } label: { BindKey(action: command.actionID) }
                .buttonStyle(.plain).help("Change the key")
            IconButton(symbol: "xmark", label: "Clear the key of \(command.title)", size: 20, glyph: 9) { engine?.clearKey(command.actionID) }
        } else {
            Button { editBind(command.actionID) } label: { Chip(text: "Set key", tag: true) }
                .buttonStyle(.kitPress)
                .help("Opens Binds' editor on \(command.title)")
                .accessibilityLabel("Set a key for \(command.title)")
        }
    }
}

/// What an extension says it touches, a line each with its kind's symbol, then that this is shown, not enforced.
private struct PermissionLines: View {
    @Environment(\.ink) private var ink
    let permissions: [ExtensionsPage.Permission]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(permissions, id: \.text) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.kind.symbol).font(ink.ui(11)).foregroundStyle(ink.muted).frame(width: 16).accessibilityHidden(true)
                    Text(line.text).font(ink.ui(12.5)).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            FinePrint(text: ExtensionsPage.notEnforced).padding(.top, 2)
        }
        .textSelection(.enabled)
    }
}

// MARK: - A catalogue entry's detail

/// Get in its header (nothing installs before it), what you get (its words and examples: the index carries no sample
/// answer), its commands each with a key after you get it, and what it will touch.
private struct CatalogueDetail: View {
    @Environment(\.ink) private var ink
    let entry: ExtensionCatalogue.Entry
    let settings: ExtensionsSettings

    private var model: ExtensionCatalogueModel { settings.catalogue }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let failure = model.failures[entry.id] { FinePrint(text: failure, color: ink.red) }
                TitledPanel(title: "What you get") {
                    VStack(alignment: .leading, spacing: 8) {
                        ExtensionPurpose(description: entry.description, examples: entry.examples)
                        if let needs = ExtensionCatalogue.needs(entry) { FinePrint(text: needs) }
                    }
                }
                if !entry.commands.isEmpty {
                    TitledPanel(title: "Commands") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(entry.commands.enumerated()), id: \.element.name) { i, command in
                                BlockRow(first: i == 0) {
                                    Text(command.title).foregroundStyle(ink.text).lineLimit(1)
                                    Chip(text: command.mode.words, tag: true).help(command.mode.help)
                                    Spacer(minLength: 8)
                                    Text("a key after you get it").font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                TitledPanel(title: "It will touch") { PermissionLines(permissions: ExtensionsPage.permissions(entry.permissions)) }
            }
            .padding(20)
        }
    }

    private var header: some View {
        let busy = model.busy[entry.id]
        return HStack(spacing: 14) {
            EmojiTile(emoji: entry.icon, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(ink.ui(18, .semibold)).foregroundStyle(ink.text).lineLimit(1).accessibilityAddTraits(.isHeader)
                Text(busy ?? "\(entry.version) · Pilot's catalogue · not installed").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if busy != nil { ProgressView().controlSize(.small) }
            Button("Get") { Task { if let line = await settings.install(entry) { HUD.tip(line) } } }
            .buttonStyle(.pilotPrimary).disabled(busy != nil)
            .accessibilityLabel("Get \(entry.title)")
        }
    }
}

// MARK: - A titled panel

/// A panel with its title on its border (pilot-1-1 T5's drawings): Instrument's hairline broken where its mono title
/// sits, Toybox's card with its title inside. The Extensions list's detail and an extension's page draw it.
struct TitledPanel<Content: View>: View {
    @Environment(\.ink) private var ink
    /// Nil for an untitled panel, whose edge runs whole.
    let title: String?
    @ViewBuilder var content: Content
    @State private var titleWidth: CGFloat = 0

    /// Where the title starts along the top edge, and the room left each side of it.
    static var inset: CGFloat { 14 }
    static var gap: CGFloat { 6 }

    var body: some View {
        if ink.isInstrument {
            content
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .overlay {
                    GapBorder(radius: ink.blockRadius, from: Self.inset - Self.gap, to: title == nil ? 0 : Self.inset + titleWidth + Self.gap)
                        .stroke(ink.line, lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if let title {
                        InstrumentEyebrow(text: title)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                            .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                            .padding(.leading, Self.inset)
                    }
                }
                .padding(.top, 6)
        } else {
            ToyBlock(title: title, trailing: { EmptyView() }, content: { content })
        }
    }
}

/// A rounded rectangle's edge with its top broken between `from` and `to` (a titled panel's title).
private struct GapBorder: Shape {
    let radius: CGFloat, from: CGFloat, to: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + max(to, r), y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        if to <= from { p.closeSubpath() } else { p.addLine(to: CGPoint(x: rect.minX + max(from, r), y: rect.minY)) }
        return p
    }
}

/// What an extension is for, in its own plain words, then its examples, each a line with an arrow: a catalogue entry's
/// What you get (story 158). Nothing when the manifest says neither.
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
    /// Each kind's symbol: hosts, the clipboard, files, Pilot actions; a shield for one that names nothing. The list's
    /// detail draws it.
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

/// An extension's emoji on a key-cap tile, the puzzle piece when it has none: the list's rows and the detail's header.
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

extension Extension.Mode {
    /// The manifest's own words for it, so its author knows the row.
    var words: String {
        switch self {
        case .noView: "No view"
        case .list: "List"
        case .detail: "Detail"
        }
    }

    /// What a command of this mode does, on its tag's tooltip in the list's detail.
    var help: String {
        switch self {
        case .noView: "Runs and shows one line"
        case .list: "Opens a list in Hyper+Space"
        case .detail: "Opens a detail in Hyper+Space"
        }
    }
}
