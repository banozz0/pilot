import PilotCore
import SwiftUI

/// Extensions › Catalogue (2026-10-10): the extensions in Pilot's catalogue, read from GitHub only while this tab shows
/// (as it opens, then kept ten minutes) or on Refresh. A search, then one card per entry: its icon, title, version and
/// what it needs; what it is for and its examples; its commands; what it says it touches; and Install, Update or
/// Installed, with Uninstall for one installed. A card says how far its install got and, when it failed, why. While the index is read the page says
/// so; when it could not be, why, with Try again. Drawn in Instrument or Toybox from the Ink (ADR 0008), as the
/// Installed tab is.
struct ExtensionCataloguePage: View {
    @Environment(\.ink) private var ink
    /// The app window shows: the catalogue is read as the tab opens, never while it is hidden.
    let onScreen: Bool
    /// An entry a link asked for: the page scrolls to it and lights it once the index is read, and clears it.
    @Binding var focus: String?
    /// Opens an installed extension on the Installed tab, where its preferences are.
    let showInstalled: (String) -> Void
    @State private var model: ExtensionCatalogueModel
    @State private var query = ""
    @State private var lit: String?

    /// The page's state; a render points it at a model on a fixture.
    static var make: () -> ExtensionCatalogueModel = { .shared }
    static let intro = "Extensions from Pilot's catalogue. Pilot connects to GitHub only while this tab is open."

    init(onScreen: Bool = true, focus: Binding<String?> = .constant(nil), model: ExtensionCatalogueModel? = nil,
         showInstalled: @escaping (String) -> Void = { _ in }) {
        self.onScreen = onScreen
        _focus = focus
        self.showInstalled = showInstalled
        _model = State(initialValue: model ?? Self.make())
    }

    var body: some View {
        ScrollViewReader { proxy in
            KitPage(intro: Self.intro) {
                finder
                content
            }
            .task(id: onScreen) {
                guard onScreen else { return }
                await model.open()
                land(proxy)
            }
            .onChange(of: focus) { land(proxy) }
        }
        .task(id: lit) {
            guard lit != nil, (try? await Task.sleep(for: ExtensionsPageView.litFor)) != nil else { return }
            withAnimation(Kit.change) { lit = nil }
        }
    }

    /// Once the index is read: scrolls to the entry asked for and lights it; an id it does not list is dropped.
    private func land(_ proxy: ScrollViewProxy) {
        guard let id = focus, model.load == .loaded else { return }
        focus = nil
        guard model.index?.entry(id) != nil else { return }
        query = ""
        lit = id
        Task { @MainActor in proxy.scrollTo(id, anchor: .top) }
    }

    // MARK: Search and Refresh

    /// The search and Refresh over the cards, then the count.
    @ViewBuilder private var finder: some View {
        HStack(spacing: 8) {
            SearchBox(prompt: "Search the catalogue", text: $query)
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.pilot).disabled(model.load == .loading)
                .help("Reads the catalogue from GitHub again")
        }
        .padding(.top, 16)
        if let count { CalmHeading(title: count, note: "github.com/\(ExtensionCatalogue.repo)") }
    }

    /// Why the read failed, under a title that already says it could not be reached: "The catalogue is private; …".
    static func why(_ reason: String) -> String {
        let said = "Pilot's catalogue could not be reached: "
        guard reason.hasPrefix(said) else { return reason }
        let rest = reason.dropFirst(said.count)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// "5 extensions · 2 installed"; nil before the index is read.
    private var count: String? {
        guard model.load == .loaded, let entries = model.index?.entries else { return nil }
        let have = entries.filter { model.installed[$0.id] != nil }.count
        return [ExtensionsPageView.plural(entries.count, "extension"), have > 0 ? "\(have) installed" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: The cards, or where the read stands

    @ViewBuilder private var content: some View {
        switch model.load {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading Pilot's catalogue from GitHub…").font(ink.ui(12.5)).foregroundStyle(ink.text2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .blockSurface()
            .padding(.top, 12)
        case .failed(let why):
            EmptyState(title: "The catalogue could not be reached", line: Self.why(why), action: ("Try again", { Task { await model.refresh() } }))
                .padding(.top, 12)
        case .loaded:
            let entries = model.entries(query)
            if entries.isEmpty {
                EmptyState(title: "Nothing matches", line: model.index?.entries.isEmpty == true
                           ? "Pilot's catalogue lists no extensions yet." : "Try another word, or clear the search.")
                    .padding(.top, 12)
            } else {
                CardGrid(minimum: 400, spacing: 12, stretch: true) {
                    ForEach(entries) { entry in
                        CatalogueCard(entry: entry, model: model, lit: lit == entry.id, showInstalled: showInstalled).id(entry.id)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - An entry

/// One entry's card: icon, title, version and what it needs, with where it stands at the right; its words; its commands;
/// what it says it touches; then its install's progress or failure and its buttons.
private struct CatalogueCard: View {
    @Environment(\.ink) private var ink
    let entry: ExtensionCatalogue.Entry
    let model: ExtensionCatalogueModel
    /// Just landed on: the theme's focus border.
    let lit: Bool
    let showInstalled: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            ExtensionPurpose(description: entry.description, examples: entry.examples)
            if !entry.commands.isEmpty { commands }
            touches
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .blockSurface()
        .focusBorder(on: lit, radius: ink.blockRadius)
    }

    private var standing: ExtensionCatalogue.Standing { model.standing(of: entry) }

    private var header: some View {
        HStack(spacing: 12) {
            EmojiTile(emoji: entry.icon, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(entry.title).font(ink.ui(14, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(entry.version).font(ink.mono(11)).foregroundStyle(ink.muted).lineLimit(1)
                }
                if let needs = ExtensionCatalogue.needs(entry) {
                    Text(needs).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            switch standing {
            case .installed: Chip(text: "Installed", color: ink.green, tag: true)
            case .update: Chip(text: model.installed[entry.id]?.version.map { "\($0) installed" } ?? "Older installed", color: ink.yellow, tag: true)
            case .install: EmptyView()
            }
        }
    }

    /// Its commands as tags, each saying what it opens.
    private var commands: some View {
        Flow(spacing: 6, lineSpacing: 6) {
            ForEach(entry.commands, id: \.name) { command in
                Chip(text: command.title, tag: true).help(command.mode.help)
            }
        }
    }

    /// What it says it touches, a line each with its kind's symbol.
    private var touches: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ExtensionsPage.permissions(entry.permissions), id: \.text) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.kind.symbol).font(ink.ui(11)).foregroundStyle(ink.muted).frame(width: 16).accessibilityHidden(true)
                    Text(line.text).font(ink.ui(12)).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// How far its install got, or why it failed, then Show in Installed, Uninstall (confirmed) and its button.
    private var footer: some View {
        let busy = model.busy[entry.id]
        return VStack(alignment: .leading, spacing: 6) {
            if let failure = model.failures[entry.id] { FinePrint(text: failure, color: ink.red) }
            HStack(spacing: 8) {
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
                } else if standing != .install {
                    AccentLink(title: "Show in Installed") { showInstalled(entry.id) }
                        .help("Its commands, keys and preferences")
                }
                Spacer(minLength: 8)
                if standing != .install {
                    UninstallButton(title: entry.title, busy: busy != nil) { if let line = await model.remove(entry.id) { HUD.tip(line) } }
                }
                if standing != .installed {
                    Button(ExtensionCatalogue.button(entry, standing)) { Task { await model.install(entry) } }
                        .buttonStyle(.pilotPrimary).disabled(busy != nil)
                }
            }
        }
    }
}
