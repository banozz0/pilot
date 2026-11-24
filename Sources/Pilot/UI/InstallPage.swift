import PilotCore
import SwiftUI
import WebApps

/// Install's front (design round 4 section 7, card agent-bo-95422897; stories 81 and 97 to 100): its search, which asks
/// every source at once (N9, InstallSearcher) — Homebrew, the App Store, GitHub, the package tools and the web — each
/// source's block as it answers, each result saying how it installs. A pick goes through Install's confirm step, which
/// shows the exact command first (nothing runs without it). Pilot lists no apps of its own: the recommended apps, the
/// shipped catalogue, went for good (tester's feedback 2026-11-18, Sven Q243); Web apps keeps its recommended web apps
/// (Q249).
struct CataloguePage: View {
    @Environment(\.ink) private var ink
    @State private var query: String
    /// The search so far and the text it answers; nil before one.
    @State private var found: (query: String, progress: InstallSearch.Progress)?

    /// Every source for a text, each answer to the closure as it lands (InstallSearcher.search); nil in the renders,
    /// which never reach the network.
    typealias Search = @Sendable (String, @escaping @Sendable (InstallSearch.Progress) async -> Void) async
        -> (query: InstallSearch.Query, groups: [InstallSearch.Group])?
    private let search: Search?

    /// `found` and `waiting` stand in for a search part-way in the renders.
    init(query: String = "", found: [InstallSearch.Group]? = nil, waiting: [InstallSearch.Source] = [], search: Search? = nil) {
        self.search = search
        _query = State(initialValue: query)
        _found = State(initialValue: found.map { (InstallSearch.Query(query)?.text ?? query, InstallSearch.Progress(groups: $0, waiting: waiting)) })
    }

    static let intro = "Search Homebrew, the App Store, GitHub and the package tools; Pilot installs each only after you confirm the command."
    static let introInfo = "Web apps lists sites to make into apps."

    var body: some View {
        KitLanding { KitPage(intro: Self.intro, info: Self.introInfo) {
            SearchBox(prompt: "Search Homebrew, the App Store, GitHub and more", text: $query).padding(.top, 16)
            // Back from More (pages round 4, Sven's Q104).
            InstallListsBlock().id(AppSection.installLists)
            if let searched { results(searched) }
            else {
                EmptyState(title: "Search for anything to install", line: "Homebrew, the App Store, GitHub and the package tools.")
                    .padding(.vertical, 24)
            }
        } }
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
                    CardGrid(minimum: 230, spacing: 8, stretch: true) {
                        ForEach(group.results) { card($0) }
                    }
                    .padding(.vertical, 10)
                }
            }
            .pageWide()
        }
        if !progress.done {
            KitBlock(title: "Searching", symbol: "magnifyingglass") {
                FinePrint(text: "\(InstallSearch.searchingLine(progress.waiting)) for “\(q.text)”").padding(.vertical, 8)
            }
        }
    }

    /// A search result as a card: its picture (artwork, avatar, site icon) or its kind's glyph, its name, how it installs,
    /// and Install, or Open for a page; the exact command in its tooltip. An app's card follows Apps show as (story 154);
    /// a tool's or a font's keeps its glyph and name.
    private func card(_ result: InstallSearch.Result) -> some View {
        let page = if case .page = result.method { true } else { false }
        let shows = AppsShowAs.current.shows(result.icon.namesApp ? .app : nil)
        return HStack(spacing: 11) {
            if shows.icon { IconTile(icon: result.icon, size: 32).appTip(result.title, when: !shows.title) }
            VStack(alignment: .leading, spacing: 2) {
                if shows.title { Text(result.title).font(ink.ui(13, .semibold)).foregroundStyle(ink.text).lineLimit(1) }
                Text(result.via).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if result.installed {
                Chip(text: "installed", color: ink.green)
            } else {
                Button(page ? "Open" : "Install") { InstallModule.pick(result.key) }.buttonStyle(.pilot)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .innerCard()
        .help([result.detail, result.method.command ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

/// What Pilot lists, on Install's front (on its More from simplify-pages T16 until pages round 4): Update's
/// self-updating casks (the Update branch's).
struct InstallListsBlock: View {
    /// Update's self-updating casks switch (page map, Sven 2026-10-17: until then only inside the Hyper+Space Update
    /// branch), read once as the tab opens: the setting sits in Pilot's defaults, which nothing observes.
    @State private var selfUpdating = Engine.shared?.settings.updateSelfUpdatingCasks ?? false

    /// The self-updating casks switch's words, the same as `pilot set update.selfUpdatingCasks` says them.
    static let selfUpdatingTitle = "Update lists casks that update themselves"

    var body: some View {
        KitBlock(title: AppSection.installLists.title, symbol: "list.star") {
            BlockRow(first: true) {
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
