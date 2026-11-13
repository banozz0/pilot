import AppKit
import PilotCore
import SwiftUI

/// Look › Catalogue (public-repo-catalogue T22, Sven's variant C of T21's round): every theme pack in Pilot's catalogue as
/// a gallery of desks, each its palette over its wallpaper (LookDesk), its name in its own face and who made it, acting
/// from its own tile: Get, Update, Apply, Remove. All, Installed, Updates and From others filter it, a search narrows it.
/// The themes Pilot ships show Built in and apply only; Remove takes only a pack you downloaded, never the one in use
/// (apply another or Restore default first, `theme delete`'s rule). Nothing is fetched before the tab shows: the index as it
/// opens, each tile's picture as the tile scrolls in.
struct ThemeCataloguePage: View {
    @Environment(\.ink) private var ink
    let model: ThemeCatalogueModel
    let look: Look

    init(model: ThemeCatalogueModel = .shared, look: Look = .shared) { self.model = model; self.look = look }

    var body: some View {
        ThemeCatalogueGallery(tiles: tiles, load: model.load, actions: .init(
            get: { id in run(id) { await model.get($0) } },
            apply: { id in run(id) { await model.apply($0.id) } },
            remove: { id in run(id) { await model.remove($0) } },
            retry: { Task { await model.open(refresh: true) } },
            appear: { id in if let theme = model.themes.first(where: { $0.id == id }) { Task { await model.picture(for: theme) } } }))
        .task { await model.open() }
        .onDisappear { model.close() }
    }

    /// The catalogue's themes this style can wear, as tiles.
    private var tiles: [ThemeCatalogueTile] {
        let style = look.style.rawValue
        return model.themes.compactMap { theme in
            let pack = ThemePack(id: theme.id, title: theme.title, dark: theme.dark, palette: theme.palette, styles: theme.styles)
            guard pack.compatible(with: style) else { return nil }
            return ThemeCatalogueTile(id: theme.id, theme: PilotTheme.named(theme.id) ?? pack.appearance(keeping: .standard), author: theme.author,
                                      standing: model.standing(of: theme), applied: model.applied == theme.id,
                                      toyboxOnly: theme.styles == ["toybox"] || ["toybox", "toybox-night"].contains(theme.id),
                                      busy: model.busy[theme.id], failure: model.failures[theme.id], picture: model.pictures[theme.id])
        }
    }

    private func run(_ id: String, _ work: @escaping (ExtensionCatalogue.Theme) async -> String) {
        guard let theme = model.themes.first(where: { $0.id == id }) else { return }
        Task { HUD.tip(await work(theme)) }
    }
}

/// One tile: what the gallery draws, from the model in Pilot and from a fixture in a render.
struct ThemeCatalogueTile: Identifiable {
    let id: String
    /// Its colours and display face.
    let theme: PilotTheme
    /// Who made it, a GitHub handle; nil for Pilot's own.
    let author: String?
    let standing: ThemeCatalogueModel.Standing
    var applied = false
    var toyboxOnly = false
    /// What it is doing now ("Getting 2 of 5…"), and why its last press failed.
    var busy: String?
    var failure: String?
    var picture: NSImage?

    /// In your themes from the catalogue: what Remove takes.
    var downloaded: Bool { standing == .installed || standing == .update }
}

/// The gallery under Look's bar: its filters and search, then the tiles, or a line while the index is read, out of reach
/// or empty.
struct ThemeCatalogueGallery: View {
    @Environment(\.ink) private var ink
    let tiles: [ThemeCatalogueTile]
    let load: ExtensionCatalogueModel.Load
    var actions = Actions()
    @State private var filter = Filter.all
    @State private var query = ""
    /// The tile Remove asks about.
    @State private var removing: ThemeCatalogueTile?

    struct Actions {
        var get: (String) -> Void = { _ in }
        var apply: (String) -> Void = { _ in }
        var remove: (String) -> Void = { _ in }
        var retry: () -> Void = {}
        /// A tile scrolled in: its picture is wanted.
        var appear: (String) -> Void = { _ in }
    }

    enum Filter: CaseIterable {
        case all, installed, updates, others

        var title: String {
            switch self {
            case .all: "All"
            case .installed: "Installed"
            case .updates: "Updates"
            case .others: "From others"
            }
        }

        func holds(_ tile: ThemeCatalogueTile) -> Bool {
            switch self {
            case .all: true
            case .installed: tile.downloaded
            case .updates: tile.standing == .update
            case .others: tile.author != nil
            }
        }
    }

    static let others = "From others: packs not made by Pilot, sent as pull requests. Each was checked as data before it joined: no scripts, links or templates."

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ink.line.frame(height: 1)
            if !tiles.isEmpty {
                if shown.isEmpty { line(query.isEmpty ? "None here yet." : "No theme matches.") } else { grid }
            } else if case .failed(let why) = load {
                line("The catalogue is out of reach.", detail: "Your themes still work. Pilot tries again when you come back here.", why: why, retry: true)
            } else if load == .loaded {
                line("Pilot's catalogue lists no themes for this style yet.")
            } else {
                line("Reading Pilot's catalogue…")
            }
        }
        .confirmationDialog("Remove \(removing?.theme.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let id = removing?.id { actions.remove(id) }; removing = nil }
        } message: { Text("Its folder and pictures leave your themes. Get brings it back from the catalogue.") }
    }

    private var shown: [ThemeCatalogueTile] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return tiles.filter { filter.holds($0) }.filter { tile in
            words.isEmpty || [tile.theme.name, tile.id, tile.author ?? "pilot"].contains { $0.lowercased().contains(words) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Filter.allCases, id: \.self) { f in
                    let count = tiles.filter(f.holds).count
                    Button { withAnimation(Kit.change) { filter = f } } label: { Chip(text: f.title, on: filter == f, count: "\(count)") }
                        .buttonStyle(.kitPress)
                        .accessibilityLabel("\(f.title), \(count)")
                        .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
                InfoMark(text: Self.others)
            }
            Spacer(minLength: 12)
            SearchBox(prompt: "Search \(tiles.count) themes", text: $query).frame(maxWidth: 220)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(shown) { tile in
                    ThemeTile(tile: tile, actions: actions) { removing = tile }.onAppear { actions.appear(tile.id) }
                }
            }
            .padding(18)
        }
    }

    private func line(_ text: String, detail: String? = nil, why: String? = nil, retry: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(ink.ui(13, .medium)).foregroundStyle(ink.text)
            if let detail { Text(detail).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true) }
            if let why { FinePrint(text: why) }
            if retry { Button("Try again", action: actions.retry).buttonStyle(.pilot) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A pack's tile: its desk, its name in its own face, who made it, and what it can do now.
private struct ThemeTile: View {
    @Environment(\.ink) private var ink
    let tile: ThemeCatalogueTile
    let actions: ThemeCatalogueGallery.Actions
    let askRemove: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            desk.frame(height: 150).padding(6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tile.theme.name).display(16, face: tile.theme.face).foregroundStyle(ink.text).lineLimit(1)
                    Spacer(minLength: 6)
                    action
                }
                .frame(height: 28)
                HStack(spacing: 6) {
                    author
                    Text("· \(standingWords)").font(ink.ui(11.5)).foregroundStyle(ink.text2).lineLimit(1)
                    Spacer(minLength: 6)
                    if tile.busy == nil, !tile.applied, tile.downloaded { quiet("Remove", askRemove) }
                }
                if let failure = tile.failure { FinePrint(text: failure, color: ink.red).lineLimit(3) }
            }
            .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
        }
        .background(ink.raised, in: shape)
        .overlay { shape.strokeBorder(tile.applied ? ink.accent : ink.line, lineWidth: tile.applied ? 1.5 : 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tile.theme.name), \(standingWords)")
    }

    private var desk: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(6), style: .continuous)
        return LookDesk(colors: ThemeColors(tile.theme), picture: tile.picture.map { Image(nsImage: $0) })
            .clipShape(shape)
            .overlay { shape.strokeBorder(ink.line, lineWidth: 1) }
            .accessibilityHidden(true)
    }

    /// The tile's one button: Get, Update, Apply, or In use; what it is doing while it works.
    @ViewBuilder private var action: some View {
        if let busy = tile.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(busy).font(ink.ui(12)).foregroundStyle(ink.text2).lineLimit(1)
            }
        } else if tile.applied {
            Label("In use", systemImage: "checkmark").font(ink.ui(12)).foregroundStyle(ink.text2)
        } else {
            switch tile.standing {
            case .get: Button("Get") { actions.get(tile.id) }.buttonStyle(.pilot)
            case .update: Button("Update") { actions.get(tile.id) }.buttonStyle(.pilotPrimary)
            case .installed, .builtIn: Button("Apply") { actions.apply(tile.id) }.buttonStyle(.pilot)
            }
        }
    }

    private var standingWords: String {
        switch tile.standing {
        case .get: "Not installed"
        case .installed: "Installed"
        case .update: "Update out"
        case .builtIn: "Built in"
        }
    }

    /// "Pilot" for Pilot's own; "by <handle>" with a mark for someone else's, so only those carry one.
    private var author: some View {
        HStack(spacing: 4) {
            if let author = tile.author {
                Image(systemName: "person.crop.circle").font(ink.ui(11)).accessibilityHidden(true)
                Text("by \(author)").lineLimit(1)
            } else {
                Text("Pilot").lineLimit(1)
            }
            if tile.toyboxOnly { Text("· Toybox only").lineLimit(1) }
        }
        .font(ink.ui(11.5))
        .foregroundStyle(ink.text2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tile.author.map { "By \($0), not by Pilot" } ?? "By Pilot")
    }

    private func quiet(_ title: String, _ press: @escaping () -> Void) -> some View {
        Button(title, action: press).buttonStyle(.plain).font(ink.ui(11.5, .medium)).foregroundStyle(ink.text2)
    }
}
