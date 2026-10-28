import Foundation

/// The bind editor's one search (design A, Sven 2026-10-12, Q64, Q65, Q74): one field over everything a key can run.
/// Empty, it lists the kinds; typed, it searches every source at once, grouped, each group ranked by FuzzyRanker, with
/// typed intents as rows: a site opens in your browser or one browser, another `scheme://` is an App URL, a leading
/// `$ ` or `> ` is a shell command, and any text ends on "Run … as a shell command". With an AI ready, a "Suggest with AI"
/// row sits above the shell row, first when nothing else matched (BindAI). Picking a kind scopes the search to its groups.
/// Pure: the editor reads its sources and passes them in.
public enum BindSearch {
    /// What a key can do, as the empty field lists it; the last three sit under More.
    public enum Kind: CaseIterable, Sendable {
        case app, action, web, shell, menu, keys, shortcut, picker, appURL

        public var title: String {
            switch self {
            case .app: "Open an app"
            case .action: "Run a Pilot action"
            case .web: "Open a website"
            case .shell: "Run a shell command"
            case .menu: "Press a menu item"
            case .keys: "Send keys to the app in front"
            case .shortcut: "Shortcut"
            case .picker: "Pick from a list"
            case .appURL: "App URL"
            }
        }

        public var example: String {
            switch self {
            case .app: "Ghostty, Zen, Notes…"
            case .action: "Snap left, go to workspace 3, lock…"
            case .web: "chatgpt.com, or a page in one browser"
            case .shell: "open -g ~/Downloads"
            case .menu: "File › New Window in any app"
            case .keys: "⌘⇧T, ⌘W…"
            case .shortcut: "A Shortcut by name"
            case .picker: "Rows from one command, the pick run by another"
            case .appURL: "obsidian://new"
            }
        }

        /// The groups a search scoped to this kind lists; a menu item starts from its app. Send keys and Pick from a list
        /// are forms with nothing to search.
        public var groups: [Group] {
            switch self {
            case .app, .menu: [.apps]
            case .action: [.actions, .scripts, .extensions, .quicklinks, .configs, .soundOutputs, .focusPresets]
            case .web: [.website]
            case .shell: [.shell]
            case .shortcut: [.shortcuts]
            case .appURL: [.appURL]
            case .keys, .picker: []
            }
        }

        static let more: [Kind] = [.shortcut, .picker, .appURL]
        /// The kinds the empty field shows a count on.
        static let counted: [Kind] = [.app, .action]
    }

    /// A heading in the results, in the order they list: typed intents first, the shell row last.
    public enum Group: CaseIterable, Sendable {
        case website, appURL, apps, actions, scripts, extensions, quicklinks, configs, soundOutputs, focusPresets, shortcuts, suggest, shell

        public var title: String {
            switch self {
            case .website: "Website"
            case .appURL: "App URL"
            case .apps: "Apps"
            case .actions: "Pilot actions"
            case .scripts: "Your scripts"
            case .extensions: "Extension commands"
            case .quicklinks: "Quicklinks"
            case .configs: "Configs"
            case .soundOutputs: "Sound outputs"
            case .focusPresets: "Focus presets"
            case .shortcuts: "Shortcuts"
            case .suggest: "AI"
            case .shell: "Or"
            }
        }
    }

    /// Everything the search reads, read by the editor as it opens. `actions` are the engine's bind actions (optional
    /// abilities not added stay out); a bound script, config or app among them lists once, as its own source's row.
    /// `focusPresets` takes `focus.session:` or `system.focus:` rows; nothing on main makes them while both are parked
    /// (parked/pomodoro, parked/pilot-focus).
    public struct Sources: Sendable {
        public var apps: [(name: String, bundle: String)], browsers: [(name: String, bundle: String)]
        public var actions: [BindsPage.ActionInfo], catalogue: DriveCatalogue
        public var scripts: [BindsPage.ActionInfo], extensions: [BindsPage.ActionInfo], quicklinks: [BindsPage.ActionInfo]
        public var configs: [BindsPage.ActionInfo], soundOutputs: [BindsPage.ActionInfo], focusPresets: [BindsPage.ActionInfo]
        /// The Shortcuts app's names, from `shortcuts list` in a child.
        public var shortcuts: [String]

        public init(apps: [(name: String, bundle: String)] = [], browsers: [(name: String, bundle: String)] = [],
                    actions: [BindsPage.ActionInfo] = [], catalogue: DriveCatalogue = DriveCatalogue(),
                    scripts: [BindsPage.ActionInfo] = [], extensions: [BindsPage.ActionInfo] = [], quicklinks: [BindsPage.ActionInfo] = [],
                    configs: [BindsPage.ActionInfo] = [], soundOutputs: [BindsPage.ActionInfo] = [],
                    focusPresets: [BindsPage.ActionInfo] = [], shortcuts: [String] = []) {
            self.apps = apps; self.browsers = browsers; self.actions = actions; self.catalogue = catalogue
            self.scripts = scripts; self.extensions = extensions; self.quicklinks = quicklinks
            self.configs = configs; self.soundOutputs = soundOutputs; self.focusPresets = focusPresets; self.shortcuts = shortcuts
        }
    }

    /// One result: `id` is the action id Save binds.
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String, title: String, subtitle: String
        public var group: Group
        public var icon: MenuIcon?
        /// The app whose icon the row wears.
        public var bundle: String?
        /// The key the action holds now, shown on the right so a move is seen before picking.
        public var key: Key?
        /// More words the search matches (an extension command's extension, a quicklink's keyword).
        var keywords: String?
    }

    /// A row of the empty field: one kind, or More holding three.
    public struct KindRow: Equatable, Sendable {
        public var title: String, example: String
        public var kinds: [Kind]
        /// How many it holds, for the kinds that list ("64 apps").
        public var count: Int?
    }

    public enum Listing: Equatable, Sendable {
        case kinds([KindRow])
        case rows([Row])
    }

    /// The field's content: the kinds while nothing is typed or picked, else the rows, grouped in Group's order.
    /// `trigger` is the key an action holds now; `suggest` names the AI provider when one is ready, nil hides its row.
    public static func list(_ query: String, scope: Kind? = nil, in sources: Sources, suggest provider: String? = nil,
                            trigger: (String) -> Key? = { _ in nil }) -> Listing {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || scope != nil else { return .kinds(kinds(sources)) }
        let allowed = Set(scope?.groups ?? Group.allCases)
        // An explicit command is only that; otherwise the sources' rows go between the intents and the shell row.
        let rows: [Row]
        if let command = command(text) {
            rows = [shell(command)]
        } else {
            let byGroup = Dictionary(grouping: all(in: sources).filter { allowed.contains($0.group) }, by: \.group)
            let ranked = Group.allCases.flatMap { group in
                FuzzyRanker.rank(byGroup[group] ?? [], query: text) { [$0.title, $0.keywords].compactMap(\.self).joined(separator: " ") }
            }
            let ai = provider.map { [suggestion(text, provider: $0)] } ?? []
            rows = intents(text, sources) + ranked + (text.isEmpty ? [] : ai + [shell(text)])
        }
        return .rows(rows.filter { allowed.contains($0.group) }.map { var row = $0; row.key = trigger(row.id); return row })
    }

    /// Quicklinks as the search's source.
    public static func quicklinks(_ links: [Quicklink]) -> [BindsPage.ActionInfo] {
        links.map { .init(id: $0.actionID, label: $0.name, module: "links", keywords: $0.keyword) }
    }

    private static func kinds(_ sources: Sources) -> [KindRow] {
        let rows = all(in: sources)
        let shown = Kind.allCases.filter { !Kind.more.contains($0) }.map { kind in
            KindRow(title: kind.title, example: kind.example, kinds: [kind],
                    count: Kind.counted.contains(kind) ? rows.filter { kind.groups.contains($0.group) }.count : nil)
        }
        return shown + [KindRow(title: "More", example: Kind.more.map(\.title).joined(separator: ", "), kinds: Kind.more)]
    }

    /// Every source's rows, once each: an id a source of its own lists leaves `actions`.
    static func all(in s: Sources) -> [Row] {
        func info(_ list: [BindsPage.ActionInfo], _ group: Group, subtitle: String? = nil) -> [Row] {
            list.map {
                Row(id: $0.id, title: $0.label, subtitle: subtitle ?? Abilities.what($0.id, label: $0.label), group: group,
                    icon: $0.icon, keywords: $0.keywords)
            }
        }
        let apps = s.apps.map { app($0.name, bundle: $0.bundle) }
        let catalogue = s.catalogue.apps.flatMap { app in
            app.actions.map {
                Row(id: $0.route, title: "\(app.name): \($0.label)", subtitle: "App action · \(app.name)", group: .actions, bundle: app.bundle)
            }
        }
        let own = info(s.scripts, .scripts) + info(s.extensions, .extensions) + info(s.quicklinks, .quicklinks)
            + info(s.configs, .configs) + info(s.soundOutputs, .soundOutputs, subtitle: "Sound output")
            + info(s.focusPresets, .focusPresets, subtitle: "Focus preset")
            + s.shortcuts.map { Row(id: DriveRoute.shortcut($0).id, title: $0, subtitle: "Shortcut", group: .shortcuts) }
        let listed = Set((apps + catalogue + own).map(\.id))
        return apps + info(s.actions.filter { !listed.contains($0.id) }, .actions) + catalogue + own
    }

    /// The rows the text itself names: a site, in your browser and in each browser, or an App URL; for a sentence, a site
    /// in a named browser.
    private static func intents(_ text: String, _ sources: Sources) -> [Row] {
        guard !text.isEmpty else { return [] }
        if text.contains(where: \.isWhitespace) { return siteInBrowser(text, sources).map { [$0] } ?? [] }
        if let url = website(text) {
            return [site(url, shown: text)] + sources.browsers.map { site(url, shown: text, in: $0) }
        }
        guard text.contains("://"), let route = appURL(text) else { return [] }
        return [route]
    }

    /// "open youtube in chrome": the site in that browser, at once, before any AI. The site is a host, or one word read
    /// as `<word>.com`; the browser one of the Mac's, by its name or any word of it.
    private static func siteInBrowser(_ text: String, _ sources: Sources) -> Row? {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 4, words[0] == "open", words[2] == "in" else { return nil }
        let named = words[3...].joined(separator: " "), target = words[1]
        guard let browser = sources.browsers.first(where: { b in
            let name = b.name.lowercased()
            return name == named || name.split(separator: " ").contains { $0 == named }
        }) else { return nil }
        let word = target.allSatisfy { $0.isLetter || $0.isNumber } && target.count >= 2
        guard let page = website(target) ?? (word ? website(target + ".com") : nil), let host = URL(string: page)?.host else { return nil }
        return site(page, shown: host, in: browser)
    }

    /// An app's row.
    static func app(_ name: String, bundle: String) -> Row {
        Row(id: AppLink.open(bundle: bundle).id, title: name, subtitle: "Open app", group: .apps, bundle: bundle)
    }

    /// A page's row, `shown` as its words: in your browser, or in one browser.
    static func site(_ url: String, shown: String, in browser: (name: String, bundle: String)? = nil) -> Row {
        guard let browser else { return Row(id: AppLink.web(url: url).id, title: "Open \(shown)", subtitle: "in your browser", group: .website) }
        return Row(id: AppLink.url(bundle: browser.bundle, url: url).id, title: "Open \(shown) in \(browser.name)", subtitle: "",
                   group: .website, bundle: browser.bundle)
    }

    /// An App URL's row, nil when the route has nothing to run.
    static func appURL(_ url: String) -> Row? {
        DriveRoute.url(url).checked.map { Row(id: $0.id, title: $0.label(appName: nil), subtitle: "App URL", group: .appURL) }
    }

    /// The row whose pick asks the AI for the words' action; its id is BindAI's, never an action Save can bind. Binds ›
    /// Mouse's picker shows the same row.
    public static func suggestion(_ text: String, provider: String) -> Row {
        Row(id: BindAI.rowID, title: "Suggest with AI: \(text)", subtitle: "Sends these words and your app names to \(provider)",
            group: .suggest)
    }

    private static func shell(_ command: String) -> Row {
        Row(id: DriveRoute.shell(command).id, title: "Run \(command) as a shell command", subtitle: "", group: .shell)
    }

    /// The command after a leading `$ ` or `> `.
    private static func command(_ text: String) -> String? {
        guard text.hasPrefix("$ ") || text.hasPrefix("> ") else { return nil }
        let command = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? nil : command
    }

    /// The web page text with no spaces names: an http(s) URL, or a bare host with a dot and a letters-only last label
    /// (`chatgpt.com`, not `gho` or `1.5`), given https; nil for another scheme.
    static func website(_ text: String) -> String? {
        let lower = text.lowercased()
        let url: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { url = text }
        else if lower.contains("://") { return nil }
        else { url = "https://" + text }
        guard let host = URL(string: url)?.host, host.contains("."),
              let tld = host.split(separator: ".", omittingEmptySubsequences: false).last, tld.count >= 2, tld.allSatisfy(\.isLetter)
        else { return nil }
        return url
    }
}
