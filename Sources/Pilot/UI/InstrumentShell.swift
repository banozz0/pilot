import AppKit
import PilotCore
import SwiftUI

/// The app window's frame in Instrument: the floating panel (pilot-ui-redesign T3, round 2's shot 7c). The tab bar across
/// the top (PanelTabBar), the window's search in it; under it the open tab's pages listed by name down the left, the
/// tab's name over them; beside the list the page under its bar, which holds its name and its parts. An area of one page
/// takes the whole width (Home, Keys, Launcher, AI, Pilot). More's card and what the search finds drop over the page.
/// Binds draws its own bar (InstrumentBindsPage). What names the page is each kept part's own (PartFrame); the window
/// draws the search, the Hyper cap and More's card over them.
struct InstrumentFrame: View {
    @Environment(Engine.self) private var engine
    @Environment(\.homeSources) private var sources
    @Bindable var model: AppWindowModel
    var more = PanelMore()
    /// What the search finds for the window's words, read once a keystroke for Home's results and the drop alike (T6).
    @State private var hits = SearchHitsModel()
    /// The page open now and its settings' values as it opened, for Jump back in (HomeVisit); none on Home.
    @State private var visit: HomeVisit?

    var body: some View {
        // Each kept part draws the frame that names its page (PartFrame), so a switch shows the new page, its tab's mark,
        // its list and its bar in one frame (page-frame); the window keeps what is the same on every page over them.
        PageView(model: model, more: more)
            .overlay(alignment: .top) { PanelTabTop(model: model, more: more) }
        // What the top bar's search finds, under it; Home lists the same results in its own place.
        .overlay(alignment: .topTrailing) {
            if model.page != .home && !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                WindowSearchDrop(model: model).padding(.top, PanelTabBar.height - 8).padding(.trailing, PanelTabBar.searchTrailing)
            }
        }
        .overlay {
            if more.open {
                // A click beside the card closes it.
                Color.clear.contentShape(.rect).onTapGesture { more.open = false }.accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if more.open { PanelMoreMenu(model: model, more: more).padding(.top, PanelTabBar.height - 6).padding(.trailing, 40) }
        }
        .environment(model)
        .environment(\.searchHits, hits)
        .onChange(of: model.query, initial: true) { hits.refresh(model.query, engine: engine, schema: sources.schema) }
        .onChange(of: model.page) { more.open = false }
        // Jump back in: what the page left changed, then the page entered read (T6, Open question 5).
        .onChange(of: model.page, initial: true) { _, page in
            if let visit { sources.remember(visit.changed(schema: sources.schema)) }
            visit = HomeVisit.opening(page, schema: sources.schema)
        }
        .onDisappear {
            if let visit { sources.remember(visit.changed(schema: sources.schema)) }
            visit = nil
        }
    }

    /// The page list's width, as drawn: Tools' six pages by name without scrolling.
    static let listWidth: CGFloat = 156
}

extension InstrumentFrame {
    /// Binds draws its own bar in Instrument: its tabs and controls are the page's state. Binds › Mouse and More are plain pages
    /// under the frame's bar, whose tabs lead back to the keyboard (story 56).
    static func pageOwnsBar(_ page: AppPage, section: AppSection? = nil) -> Bool {
        page == .binds && section?.isPlainBindsPage != true
    }

    /// Whether the page list shows beside `page` and the toolbar over it; Home draws its own head and search
    /// (pilot-ui-redesign T6, shot 7c-home): no bar over it.
    static func frame(_ page: AppPage, section: AppSection?) -> (listed: Bool, barred: Bool) {
        (!RailLayout.fullWidth(page.area), !pageOwnsBar(page, section: section) && page != .home)
    }
}

/// A kept part in the frame that names its page: its tab marked in the bar, its area's pages down the left with it
/// raised, its bar over it (page-frame; Sven, 2026-11-22: "theres like a small frame lag when switching pages makes the app
/// look cheap"). All of it is the part's own and reads the part's page, never the window's, so a part kept hidden stays as
/// it was left and a switch flips the whole picture at once (PageDeck.picture).
struct PartFrame<Content: View>: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    let more: PanelMore
    let page: AppPage
    let section: AppSection?
    let extensionPage: String?
    @ViewBuilder var content: Content

    var body: some View {
        let (list, bar) = InstrumentFrame.frame(page, section: section)
        // Built a piece a turn while the part is built ahead (Staged): the bar, the list, the toolbar, the page. In view all
        // in its first frame, so a first visit's first frame names the page (page-instant).
        VStack(spacing: 0) { Staged(inView: false) {
            PanelTabBar(model: model, more: more, open: page.area)
            HStack(spacing: 0) { Staged(inView: false) {
                if list {
                    InstrumentPageList(model: model, page: page, extensionPage: extensionPage)
                        .frame(width: InstrumentFrame.listWidth).background(style.color(\.sidebar))
                    InstrumentRule(vertical: true)
                }
                VStack(spacing: 0) { Staged(inView: false) {
                    if bar {
                        InstrumentToolbar(model: model, page: page, extensionPage: extensionPage, listed: list)
                        InstrumentRule()
                    }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } }
                // The ground draws once: whole when solid, else at its strength over Tinted's blur, Glass's tint carrying it.
                .background(Theme.windowFill(style.color(\.canvas)))
            } }
        } }
    }
}

/// The bar over a page in Instrument: its title, then what the page keeps there, 52 pt high (the frame's toolbar and
/// Binds' own).
struct InstrumentPageBar<Content: View>: View {
    @Environment(\.style) private var style
    let title: String
    /// Its sides; the style's page margin unless the page narrows its own.
    var side: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title).styleText(\.pageTitle).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
            content
        }
        .lineLimit(1)
        .padding(.horizontal, side ?? style.density.page).frame(height: style.points(52))
    }
}

// MARK: - Page list

/// The Hyper key's cap: lit while Hyper is on; a click turns it on or off (the tab bar's right end).
struct InstrumentHyperCap: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    /// Its side: 28 pt in the panel's tab bar.
    var side: CGFloat = 44

    var body: some View {
        let on = engine.hyperSwitch.isOn
        let shape = RoundedRectangle(cornerRadius: side < 44 ? style.radii.control + 1 : style.radii.control + 3, style: .continuous)
        return Button { engine.hyperSwitch.set(!on) } label: {
            Image(systemName: "arrowshape.up").font(style.font(\.icon))
                .foregroundStyle(style.color(on ? \.accent : \.text3))
                .frame(width: side, height: side)
                .background(style.color(on ? \.accentSoft : \.raised), in: shape)
                .overlay { shape.strokeBorder(style.color(on ? \.accent : \.line)) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(on ? "Hyper is on (\(engine.settings.layerKeys.label)): turn it off" : "Hyper is off: turn it on")
        .accessibilityLabel("Hyper key").accessibilityValue(on ? "On" : "Off")
    }
}

/// The open tab's pages down the left, by name (S3 B's grouping): the tab's name and its key over them in small capitals,
/// the open page raised with a hairline, no accent. Extensions lists each extension's page under its own.
private struct InstrumentPageList: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    /// The part's page and extension page, raised; its area's pages listed.
    let page: AppPage
    let extensionPage: String?
    var extensionPages = ExtensionPages.shared

    var body: some View {
        let area = page.area
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(area.title).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text(area.keyHint).accessibilityHidden(true)
            }
            .styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).lineLimit(1)
            .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { pages(area) }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 10).padding(.top, 14)
    }

    @ViewBuilder private func pages(_ area: AppArea) -> some View {
        ForEach(area.shown, id: \.self) { row in
            InstrumentPageRow(model: model, page: row, on: row == page && extensionPage == nil)
            // Extension pages under Extensions (story 161): pages of their own, so they stay rows (P36), the part's raised.
            if row == .extensions {
                ForEach(extensionPages.entries) { link in
                    InstrumentExtensionRow(link: link, on: extensionPage == link.id) {
                        link.opens ? model.goExtensionPage(link.id) : model.focusExtension(link.id)
                    }
                }
            }
        }
    }
}

/// A page in the list: its name, raised when open. A view of its own, so a change of the open page redraws only its row.
private struct InstrumentPageRow: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    let page: AppPage
    let on: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 1, style: .continuous)
        Button { model.go(AppPlace(page)) } label: {
            Text(page.title).styleText(\.body).foregroundStyle(style.color(on ? \.text : \.text2))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { if on { shape.fill(style.color(\.raised)) } }
                .overlay { if on { shape.strokeBorder(style.color(\.line)) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Search

/// The window's search field in the top bar: Pilot's settings, pages and binds and System Settings' panes, the search
/// Home's field runs; Cmd+F focuses it, the arrows pick a result, Return opens the picked one, Escape empties it and
/// gives the keyboard back to what had it before Cmd+F. Home draws its own, larger (InstrumentHome).
struct InstrumentSearchField: View {
    @Environment(\.style) private var style
    @Environment(\.searchHits) private var hits
    @Bindable var model: AppWindowModel
    /// False while a page draws its own search (Home): Cmd+F and the open search are the page's then.
    var takesKey = true
    @FocusState private var searching: Bool
    /// What had the keyboard as Cmd+F came, which Escape gives it back to.
    @State private var before = Before()
    private final class Before { weak var view: NSView? }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 1, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(style.font(\.icon)).foregroundStyle(style.color(\.text3)).accessibilityHidden(true)
            TextField("Search settings", text: $model.query, prompt: Text("Search settings").foregroundStyle(style.color(\.text3)))
                .textFieldStyle(.plain).styleText(\.body).foregroundStyle(style.color(\.text)).focused($searching)
                .onSubmit { open() }
                .searchKeys(hits)
                .onExitCommand { model.query = ""; model.searchOpen = false; searching = false; giveBack() }
            if model.query.isEmpty {
                Text("⌘F").styleText(\.key).foregroundStyle(style.color(\.text3))
            } else {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(style.color(\.text3)).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9).frame(height: style.points(30))
        .background(style.color(\.raised), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line)) }
        .onChange(of: model.searchRequests) {
            guard takesKey else { return }
            before.view = NSApp.keyWindow?.firstResponder as? NSView
            searching = true
        }
        .onAppear { if takesKey && model.searchOpen { searching = true } }
        // Off Home with the search open it takes the keyboard; on Home, Home's field does.
        .onChange(of: takesKey) { searching = takesKey && model.searchOpen }
        .onChange(of: searching) { if !searching && takesKey && model.query.isEmpty { model.searchOpen = false } }
    }

    /// The keyboard back where it was before Cmd+F, unless that view has gone or hides behind another page.
    private func giveBack() {
        guard let view = before.view else { return }
        before.view = nil
        DispatchQueue.main.async {
            guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return }
            window.makeFirstResponder(view)
        }
    }

    /// Return: the picked result, else the window's first place as before.
    private func open() {
        if let hit = hits?.picked { model.open(hit) } else { model.goToFirstResult() }
    }
}

/// What the search finds, in the drop under a page's field: the same groups as Home's results, narrower.
struct InstrumentSearchResults: View {
    @Environment(\.searchHits) private var hits
    let model: AppWindowModel

    var body: some View {
        SearchResultsList(hits: hits ?? SearchHitsModel(), compact: true) { model.open($0) }
    }
}

/// The search's results (pilot-ui-redesign T6, S2 B; shot 7c-search): grouped by tab path and page, each setting with its
/// value, a part or a page by name, then the binds the words find and System Settings' panes. The picked row is raised
/// with a hairline, no accent, and carries Return's cap; a click opens a row as Return does.
struct SearchResultsList: View {
    @Environment(\.style) private var style
    let hits: SearchHitsModel
    /// The page's drop (340 pt): tighter rows and no foot.
    var compact = false
    let open: (SearchHits.Hit) -> Void

    var body: some View {
        let groups = hits.hits.groups, words = hits.hits.words
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            ForEach(groups) { group in
                HStack(spacing: 0) {
                    Text(group.title)
                    Text(" · \(group.rows.count)")
                }
                .styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).lineLimit(1)
                .padding(.horizontal, compact ? 10 : 12).padding(.top, group.id == groups.first?.id ? 2 : (compact ? 8 : 12)).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
                ForEach(group.rows) { hit in
                    SearchResultRow(hit: hit, words: words, picked: hits.picked?.id == hit.id, compact: compact) { open(hit) }
                }
            }
            if groups.isEmpty {
                Text("Nothing matches").styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(compact ? 10 : 12)
            } else if !compact {
                HStack(spacing: 18) {
                    hint("↑↓", "move")
                    hint("↵", "open and ring the row")
                    hint("esc", "clear")
                }
                .padding(.horizontal, 12).padding(.top, 10)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Search results")
    }

    private func hint(_ key: String, _ words: String) -> some View {
        HStack(spacing: 6) {
            InstrumentKey(text: key)
            Text(words).styleText(\.caption).foregroundStyle(style.color(\.text3))
        }
        .accessibilityElement(children: .combine)
    }
}

/// One result: its title, the typed words marked in it, its value in mono or its keys as caps; picked, raised with a
/// hairline and Return's cap.
private struct SearchResultRow: View {
    @Environment(\.style) private var style
    let hit: SearchHits.Hit
    let words: [String]
    let picked: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                Text(SearchHits.marked(hit.title, words: words, mark: style.color(\.line)))
                    .styleText(\.body).foregroundStyle(style.color(\.text)).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                switch hit.value {
                case .none: EmptyView()
                case .text(let text):
                    Text(text).styleText(\.mono).foregroundStyle(style.color(\.text2)).lineLimit(1).truncationMode(.middle)
                case .keys(let keys): Kbd(text: keys)
                }
                if picked && !compact { InstrumentKey(text: "↵") }
            }
            .padding(.horizontal, compact ? 10 : 12)
            .frame(maxWidth: .infinity, minHeight: style.points(compact ? 28 : 32), alignment: .leading)
            .background { if picked { shape.fill(style.color(\.raised)) } }
            .overlay { if picked { shape.strokeBorder(style.color(\.line)) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// What the search finds for a query (pilot-ui-redesign T6, S2 B): SettingsSearch.grouped's pages under their tab
/// paths, each setting with its value read now (the 30 at most it lists), the parts and pages it found, then the binds
/// the words find (Keys › Binds) and System Settings' panes. One list for Home and the drop, so ↑↓ and Return agree.
@MainActor
struct SearchHits {
    enum Value: Equatable { case none, text(String), keys(String) }
    /// A setting's page and key (its row is rung), a part or a page, a bind's editor, or a System Settings pane.
    enum Target: Equatable { case setting(String, AppPlace), place(AppPlace), bind(String), pane(SystemPane) }

    struct Hit: Identifiable, Equatable {
        let id: String
        let title: String
        let value: Value
        let target: Target
    }

    struct Group: Identifiable {
        let id: String
        let title: String
        let rows: [Hit]
    }

    var groups: [Group] = []
    /// The typed words, folded, that the rows mark.
    var words: [String] = []

    static let empty = SearchHits()
    /// The most binds the Binds group lists.
    static let binds = 5

    var rows: [Hit] { groups.flatMap(\.rows) }
    /// "5 settings match": the rows, System Settings' panes aside.
    var matches: Int { groups.filter { $0.id != Self.panesID }.reduce(0) { $0 + $1.rows.count } }

    static let panesID = "panes"

    init() {}

    init(_ query: String, engine: Engine, schema: SettingsSchema) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        words = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for found in SettingsSearch.grouped(trimmed, settings: schema.sorted) {
            let page = found.page
            var rows = found.settings.map { setting in
                let place = AppPlace.named(setting.page) ?? AppPlace(page)
                return Hit(id: "setting:" + setting.key, title: setting.label,
                           value: (try? schema.get(setting.key)).map { .text(Self.words($0, kind: setting.kind)) } ?? .none,
                           target: .setting(setting.key, place))
            }
            rows += found.parts.map { Hit(id: "part:" + $0.rawValue, title: $0.title, value: .none, target: .place(AppPlace(page, $0))) }
            if rows.isEmpty { rows = [Hit(id: "page:" + page.rawValue, title: page.title, value: .none, target: .place(AppPlace(page)))] }
            groups.append(Group(id: page.rawValue, title: found.path(count: PanelTabs.count), rows: rows))
        }
        let sections = BindsPage.sections(store: engine.binds.store, actions: engine.bindActions, search: trimmed)
        let bound = sections.flatMap(\.rows).filter { $0.key != nil }
        if !bound.isEmpty {
            groups.append(Group(id: "binds", title: AppPlace(.binds).tabPath(count: PanelTabs.count),
                                rows: bound.prefix(Self.binds).map { Hit(id: "bind:" + $0.id, title: $0.label, value: $0.key.map(Value.keys) ?? .none, target: .bind($0.id)) }))
        }
        let panes = SettingsSearch.panes(trimmed)
        if !panes.isEmpty {
            groups.append(Group(id: Self.panesID, title: "System Settings",
                                rows: panes.map { Hit(id: "pane:" + $0.id, title: $0.path.replacingOccurrences(of: "System Settings › ", with: ""),
                                                      value: .none, target: .pane($0)) }))
        }
    }

    /// A setting's value as its row shows it: on or off, a number without a needless ".0", a list joined, a word as is.
    static func words(_ value: JSONValue, kind: SettingKey.Kind) -> String {
        switch value {
        case .null: "none"
        case .bool(let on): on ? "on" : "off"
        case .number(let n): n.rounded() == n ? String(Int(n)) : String(format: "%.2f", n).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        case .string(let s): s.isEmpty ? "none" : s
        case .array(let items): items.map { words($0, kind: kind) }.joined(separator: ", ")
        case .object: "set"
        }
    }

    /// `text` with each of its words that a typed word starts marked by `mark`, as Ghostex's settings search marks them.
    static func marked(_ text: String, words: [String], mark: Color) -> AttributedString {
        var out = AttributedString(text)
        guard !words.isEmpty else { return out }
        var start = text.startIndex
        while start < text.endIndex {
            guard let from = text[start...].firstIndex(where: { $0.isLetter || $0.isNumber }) else { break }
            let to = text[from...].firstIndex(where: { !($0.isLetter || $0.isNumber) }) ?? text.endIndex
            let word = text[from..<to].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if words.contains(where: word.hasPrefix), let lower = AttributedString.Index(from, within: out),
               let upper = AttributedString.Index(to, within: out) {
                out[lower..<upper].backgroundColor = mark
            }
            start = to
        }
        return out
    }
}

/// The search's results for the window's words, read again once a keystroke, and the one ↑↓ picked.
@Observable @MainActor
final class SearchHitsModel {
    private(set) var hits = SearchHits.empty
    private(set) var index = 0
    @ObservationIgnored private var query: String?

    var picked: SearchHits.Hit? {
        let rows = hits.rows
        return rows.indices.contains(index) ? rows[index] : nil
    }

    func refresh(_ query: String, engine: Engine, schema: () -> SettingsSchema) {
        guard query != self.query else { return }
        self.query = query
        hits = query.trimmingCharacters(in: .whitespaces).isEmpty ? .empty : SearchHits(query, engine: engine, schema: schema())
        index = 0
    }

    /// ↑ or ↓: the row before or after, held at the ends.
    func step(_ by: Int) {
        index = max(0, min(hits.rows.count - 1, index + by))
    }
}

extension EnvironmentValues {
    /// The window's search results (InstrumentFrame's); nil outside a window, where Home keeps its own.
    @Entry var searchHits: SearchHitsModel? = nil
}

extension View {
    /// ↑ and ↓ in a search field pick the result before or after.
    func searchKeys(_ hits: SearchHitsModel?) -> some View {
        onKeyPress(.downArrow) {
            guard let hits, !hits.hits.groups.isEmpty else { return .ignored }
            hits.step(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard let hits, !hits.hits.groups.isEmpty else { return .ignored }
            hits.step(-1)
            return .handled
        }
    }
}

extension AppWindowModel {
    /// A result's Return or click: a setting's page with its row rung for 2 s, a part's page (the window lands on its
    /// block), the bind's editor on Binds, or the System Settings pane; the words go.
    func open(_ hit: SearchHits.Hit) {
        switch hit.target {
        case .setting(let key, let place): go(place); ring(key)
        case .place(let place): go(place)
        case .bind(let action): editBind = action; go(AppPlace(.binds))
        case .pane(let pane): openPane(pane)
        }
        query = ""
    }
}

// MARK: - Toolbar

struct InstrumentToolbar: View {
    @Environment(\.style) private var style
    @Bindable var model: AppWindowModel
    /// The page it names: its part's (PartFrame).
    let page: AppPage
    let extensionPage: String?
    /// The page list shows beside: the area's pages are there, not here. The page's parts are here at every width.
    let listed: Bool

    var body: some View {
        let tabs = AppWindowModel.tabs(page, extensionPage: extensionPage)
        // The window's search is the top bar's (PanelTabBar).
        InstrumentPageBar(title: AppWindowModel.title(page, extensionPage: extensionPage)) {
            if !listed, page.area.shown.count > 1 { areaPages(page.area).padding(.leading, 8) }
            if !tabs.isEmpty { self.tabs(page).padding(.leading, 8) }
            Spacer(minLength: 0)
        }
        // The pages' measure, so the title starts over the page's blocks in a big window (wide-pages); a page that is
        // panes of its own across the window keeps its title at the window's edge.
        .frame(maxWidth: Self.fullPane(page, extensionPage: extensionPage, section: model.section(of: page)) ? .infinity : PageMeasure.most + style.density.page * 2,
               alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// Pages drawn as panes across the whole window rather than a column of blocks: Extensions (its list beside the one
    /// picked), an extension's own page, Notes (its notes beside the one open) and Look's Catalogue (a grid that fills
    /// the width). Binds draws its own bar.
    static func fullPane(_ page: AppPage, extensionPage: String?, section: AppSection?) -> Bool {
        page == .extensions || extensionPage != nil || page == .notes || (page == .look && section == .themeCatalogue)
    }

    /// A merged page's parts as a segmented control on a sunk track, the picked one raised, with ⌘⇧]'s hint beside it
    /// while it fits (P36); tighter where the bar is too narrow for them whole, never cut.
    private func tabs(_ page: AppPage) -> some View {
        let options = page.tabs.map { ($0.value, $0.title) }
        let selection = Binding(get: { model.section(of: page) }, set: { model.pick($0, of: page) })
        func segments(tight: Bool = false) -> InstrumentSegments<AppSection?> {
            InstrumentSegments(options: options, selection: selection, tight: tight)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                segments().fixedSize()
                Text(RailLayout.partsHint).styleText(\.key).foregroundStyle(style.color(\.text3)).fixedSize().accessibilityHidden(true)
            }
            segments().fixedSize()
            segments(tight: true).fixedSize()
            segments(tight: true)
        }
        .accessibilityLabel("\(page.title) parts")
    }

    /// Folded (no list beside): the area's pages as a segmented control, so every page stays a click away.
    private func areaPages(_ area: AppArea) -> some View {
        let options = area.shown.map { (value: $0, title: $0.title) }
        let selection = Binding(get: { page }, set: { model.go(AppPlace($0)) })
        return ViewThatFits(in: .horizontal) {
            InstrumentSegments(options: options, selection: selection).fixedSize()
            InstrumentSegments(options: options, selection: selection, tight: true)
        }
        .accessibilityLabel("\(area.title) pages")
    }
}
