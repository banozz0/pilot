import PilotCore
import SwiftUI
import WebApps

/// Install › Catalogue (design round 4 section 7, card agent-bo-95422897; stories 81 and 97 to 100): the shipped catalogue
/// with its categories and search, every category as its own section. The catalogue is the recommendations (Sven
/// 2026-10-09): with Recommend apps off (its switch under the search, in What Pilot lists, C5; on Install's More from
/// simplify-pages T16 until pages round 4) the page is its search and that block alone, no preset picks. A pick goes through Install's confirm step, which shows the exact command first (nothing runs
/// without it); a download opens its vendor's page. The same catalogue is the Hyper+Space menu's Install branch. Typing also searches every
/// source at once (N9, InstallSearcher): the catalogue's matches first, then Homebrew, the App Store, GitHub, the package
/// tools and the web, each source's block as it answers, each result saying how it installs.
struct CataloguePage: View {
    @Environment(\.ink) private var ink
    let entries: [CatalogueEntry]
    @State private var query: String
    @State private var category: String?
    /// Entry ids found installed when the page opened.
    @State private var installed: Set<String> = []
    /// The search so far and the text it answers; nil before one.
    @State private var found: (query: String, progress: InstallSearch.Progress)?
    private let recommendations = Recommendations.shared

    /// Every source for a text, each answer to the closure as it lands (InstallSearcher.search); nil in the renders,
    /// which never reach the network.
    typealias Search = @Sendable (String, @escaping @Sendable (InstallSearch.Progress) async -> Void) async
        -> (query: InstallSearch.Query, groups: [InstallSearch.Group])?
    private let search: Search?

    /// `found` and `waiting` stand in for a search part-way in the renders.
    init(entries: [CatalogueEntry] = InstallModule.catalogue, query: String = "", category: String? = nil,
         found: [InstallSearch.Group]? = nil, waiting: [InstallSearch.Source] = [], search: Search? = nil) {
        self.entries = entries
        self.search = search
        _query = State(initialValue: query)
        _category = State(initialValue: category)
        _found = State(initialValue: found.map { (InstallSearch.Query(query)?.text ?? query, InstallSearch.Progress(groups: $0, waiting: waiting)) })
    }

    static let intro = "Apps and tools Pilot installs for you, each only after you confirm the command."
    static let introInfo = "Search finds anything else too."
    /// The category Fonts' Get more fonts opens on.
    static let fonts = "Fonts"

    /// One block of the catalogue: a category, or a search's matches.
    struct Section: Equatable {
        let title: String
        let symbol: String
        let entries: [CatalogueEntry]
    }

    /// What the page lists (card agent-bo-95423004: the whole catalogue, not a short list and an empty half): a search
    /// its matches; a chip its category; else every category as its own section. Nothing with Recommend apps off: the
    /// catalogue is the recommendations (Sven 2026-10-09).
    static func sections(_ entries: [CatalogueEntry], query: String, category: String?, recommend: Bool = true) -> [Section] {
        guard recommend else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let inCategory = entries.filter { category == nil || $0.category == category }
        if !trimmed.isEmpty {
            let found = FuzzyRanker.Filter(trimmed).filter(inCategory) { [$0.name, $0.category, $0.id] }
            return [Section(title: "In the catalogue", symbol: "magnifyingglass", entries: found)]
        }
        let section = { (name: String) in Section(title: name, symbol: MenuIcon.category(name).symbol, entries: entries.filter { $0.category == name }) }
        if let category { return [section(category)] }
        return InstallCatalogue.categories(entries).map(section)
    }

    var body: some View {
        let recommend = recommendations.show
        let sections = Self.sections(entries, query: query, category: category, recommend: recommend)
        KitLanding { KitPage(intro: Self.intro, info: Self.introInfo) {
            finder(recommend).padding(.top, 16)
            // Back from More (pages round 4, Sven's Q104).
            InstallListsBlock().id(AppSection.installLists)
            // While a search answers, the catalogue's empty match is left out: the sources below say what they found.
            ForEach(sections.filter { !($0.entries.isEmpty && searched != nil) }, id: \.title) { section in
                KitBlock(title: section.title, symbol: section.symbol) {
                    Text(count(section)).font(ink.mono(11.5))
                } content: {
                    if section.entries.isEmpty {
                        EmptyState(title: "Nothing matches", line: "Try another word, or clear the search to see every category.").padding(.vertical, 8)
                    } else {
                        // Toybox's chunkier Install button needs a wider cell to keep its word whole.
                        CardGrid(minimum: ink.style.kind == .toybox ? 290 : 230, spacing: 8, stretch: true) {
                            ForEach(section.entries, id: \.id) { card($0) }
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
            if let searched { results(searched) }
            else if !recommend {
                EmptyState(title: "Search for anything to install",
                           line: "Homebrew, the App Store, GitHub and the package tools. Recommend apps is off, so Pilot lists no picks of its own.")
                    .padding(.vertical, 24)
            }
        } }
        .onAppear { installed = Set(entries.filter(InstallModule.isInstalled).map(\.id)) }
        .task(id: query) { await ask() }
    }

    /// The query being searched; nil while the text is too short to search.
    private var searched: InstallSearch.Query? { search == nil && found == nil ? nil : InstallSearch.Query(query) }

    /// Searching shows at once; the sources are asked once typing pauses for 0.3 s, each one's block landing as it
    /// answers; a newer keystroke cancels this one, its requests and its brew processes.
    private func ask() async {
        guard let search, let q = InstallSearch.Query(query) else { return }
        found = (q.text, InstallSearch.Progress(waiting: InstallSearcher.sources))
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let (answers, landed) = AsyncStream<InstallSearch.Progress>.makeStream()
        let asking = Task { _ = await search(q.text) { landed.yield($0) }; landed.finish() }
        landed.onTermination = { _ in asking.cancel() }
        for await progress in answers { found = (q.text, progress) }
    }

    /// Each source's block in its order as it answers, then Searching naming the sources still asked; once all answered
    /// empty, a line says so above the web row.
    @ViewBuilder private func results(_ q: InstallSearch.Query) -> some View {
        let progress = found.flatMap { $0.query == q.text ? $0.progress : nil } ?? InstallSearch.Progress(waiting: InstallSearcher.sources)
        if progress.done, InstallSearch.nothingFound(progress.groups) {
            EmptyState(title: "Nothing matches", line: "\(InstallSearch.nothingLine). Search the web below, or try another word.").padding(.vertical, 12)
        }
        ForEach(InstallSearch.shown(progress.groups), id: \.source) { group in
            KitBlock(title: group.source.title, symbol: group.source.symbol) {
                Text("\(group.results.count)").font(ink.mono(11.5))
            } content: {
                if let trouble = group.trouble { FinePrint(text: trouble.line(group.source)).padding(.vertical, 6) }
                if !group.results.isEmpty {
                    CardGrid(minimum: ink.style.kind == .toybox ? 290 : 230, spacing: 8, stretch: true) {
                        ForEach(group.results) { card($0) }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        if !progress.done {
            KitBlock(title: "Searching", symbol: "magnifyingglass") {
                FinePrint(text: "\(InstallSearch.searchingLine(progress.waiting)) for “\(q.text)”").padding(.vertical, 8)
            }
        }
    }

    /// A search result as a card: its picture (artwork, avatar, site icon) or its kind's glyph, its name, how it installs,
    /// and Install, or Open for a page; the exact command in its tooltip.
    private func card(_ result: InstallSearch.Result) -> some View {
        let page = if case .page = result.method { true } else { false }
        return cardRow(icon: result.icon, title: result.title, line: result.via, installed: result.installed,
                       button: page ? "Open" : "Install", key: result.key)
            .help([result.detail, result.method.command ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// One card's row, a catalogue entry's or a search result's: icon, name, a muted line, and installed or its button.
    private func cardRow(icon: MenuIcon, letter: String? = nil, title: String, line: String, installed: Bool, button: String, key: String,
                         help: String? = nil) -> some View {
        // An app's card follows Apps show as (story 154); a tool's or a font's keeps its glyph and name.
        let shows = AppsShowAs.current.shows(icon.namesApp ? .app : nil)
        return HStack(spacing: 11) {
            if shows.icon { IconTile(icon: icon, size: 32, letter: letter).appTip(title, when: !shows.title) }
            VStack(alignment: .leading, spacing: 2) {
                if shows.title { Text(title).font(ink.ui(13, .semibold)).foregroundStyle(ink.text).lineLimit(1) }
                Text(line).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if installed {
                Chip(text: "installed", color: ink.green)
            } else {
                Button(button) { InstallModule.pick(key) }.buttonStyle(.pilot).help(help ?? "")
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .innerCard()
    }

    /// "5 · 2 installed".
    private func count(_ section: Section) -> String {
        let have = section.entries.filter { installed.contains($0.id) }.count
        return have == 0 ? "\(section.entries.count)" : "\(section.entries.count) · \(have) installed"
    }

    private var categories: [String] { InstallCatalogue.categories(entries) }

    /// The search and the category chips ("All" first); Recommend apps and the self-updating casks are under them.
    private func finder(_ recommend: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchBox(prompt: "Search Homebrew, the App Store, GitHub and more", text: $query)
            if recommend {
                Flow(spacing: 6, lineSpacing: 6) {
                    chip("All", on: category == nil) { category = nil }
                    ForEach(categories, id: \.self) { name in chip(name, on: category == name) { category = category == name ? nil : name } }
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) { Chip(text: title, on: on) }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    /// How an entry arrives: "Homebrew app", "Homebrew tool", "uv tool", or the vendor's site.
    private func how(_ entry: CatalogueEntry) -> String {
        if entry.method.scriptCommand != nil { return "install script" }
        guard let p = entry.method.package else { return URL(string: entry.vendor)?.host().map(SameSite.normalized) ?? "Download" }
        return p.kind == .cask && entry.category == "Fonts" ? "Homebrew font" : p.via
    }

    /// The initial an entry's tile wears in place of its glyph, when it has no picture of its own: only when that glyph
    /// is its category heading's, so an app is not the same glyph five times; a tool keeps its terminal and a font its
    /// glyph (Moody: every card drew a letter).
    static func letter(_ entry: CatalogueEntry) -> String? {
        // A tool's glyph is never a category's; a font's is the Fonts heading's own.
        let symbol = MenuIcon.catalogue(entry).symbol
        guard symbol == MenuIcon.category(entry.category).symbol, symbol != MenuIcon.font.symbol else { return nil }
        return String(entry.name.prefix(1))
    }

    /// An entry as a card: its own icon once installed (else its shipped picture, else its kind's or its category's
    /// glyph), its name, how it arrives, and Install, Get or installed.
    private func card(_ entry: CatalogueEntry) -> some View {
        let download = if case .download = entry.method { true } else { false }
        return cardRow(icon: MenuIcon.catalogue(entry), letter: Self.letter(entry), title: entry.name, line: how(entry),
                       installed: installed.contains(entry.id), button: download ? "Get" : "Install",
                       key: entry.key, help: download ? "Opens \(entry.vendor)'s download page" : nil)
    }
}

/// What Pilot lists, on the Catalogue (on Install's More from simplify-pages T16 until pages round 4): Recommend apps
/// (C5, the same switch as onboarding's) and Update's self-updating casks (the Update branch's).
struct InstallListsBlock: View {
    private let recommendations = Recommendations.shared
    /// Update's self-updating casks switch (page map, Sven 2026-10-17: until then only inside the Hyper+Space Update
    /// branch), read once as the tab opens: the setting sits in Pilot's defaults, which nothing observes.
    @State private var selfUpdating = Engine.shared?.settings.updateSelfUpdatingCasks ?? false

    /// The self-updating casks switch's words, the same as `pilot set update.selfUpdatingCasks` says them.
    static let selfUpdatingTitle = "Update lists casks that update themselves"

    var body: some View {
        @Bindable var recommendations = recommendations
        KitBlock(title: AppSection.installLists.title, symbol: "list.star") {
            BlockRow(first: true) {
                Toggle("Recommend apps", isOn: $recommendations.show)
                    .toggleStyle(.pilotSwitchRow(info: "Off: no catalogue of picks on Install or in the menu, and no install suggestions anywhere in Pilot. Search still finds everything."))
            }
            BlockRow {
                Toggle(Self.selfUpdatingTitle, isOn: Binding(get: { selfUpdating }, set: { on in
                    selfUpdating = on
                    Engine.shared?.settings.updateSelfUpdatingCasks = on
                }))
                .toggleStyle(.pilotSwitchRow(info: "Apps such as Chrome or Zed update themselves; on, Hyper+Space › Update lists them too and updates them with Homebrew."))
            }
        }
    }
}

/// Install's More (simplify-pages T16): the command-line tools and the hidden apps, each a place a link or the search lands
/// on; What Pilot lists went to the Catalogue (pages round 4).
struct InstallMorePage: View {
    /// More's index. A row added to or moved off a block changes its count here; the tools and the hidden apps are a list
    /// each.
    static let entries = [
        MoreEntry(id: .helpers, symbol: "terminal", controls: 1),
        MoreEntry(id: .hiddenApps, symbol: "eye.slash", controls: 1),
    ]

    var body: some View {
        KitMore(entries: Self.entries) {
            HelpersBlock().moreBlock(.helpers)
            HiddenAppsBlock().moreBlock(.hiddenApps)
        }
    }
}
