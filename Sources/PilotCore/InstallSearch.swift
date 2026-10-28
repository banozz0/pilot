import Foundation
import Synchronization

/// Install's one search (N9, Sven 2026-10-09: "Install finds anything"): what is typed is asked of every source at once
/// and the answers come back grouped by source, always in this order: Homebrew's casks and formulae (`brew search` and
/// `brew info`, on the Mac); the Mac App Store (Apple's iTunes Search API, no key), iPhone and iPad apps that run on Apple
/// silicon included; GitHub's repositories with their latest release; the package tools that are installed (npm's
/// registry, PyPI for uv or pipx, crates.io, the Go module proxy); and last, Search the web. Setapp is not a source: it
/// has no public catalogue API (its site's search is drawn in the browser from an internal one), so it is left out.
///
/// Pure but for the two closures the app hands in: `brew` runs Homebrew, `fetch` asks the network (through a Cache, so a
/// search typed again, or a repo's release seen by an earlier search, asks nothing). Each result says how it installs and
/// installs that way: a package's own command after the confirm step, a GitHub release's .dmg, .pkg or .zip downloaded
/// and opened, or a page (the App Store's, a repo's releases, the web search) opened.
public enum InstallSearch {
    /// Where a result comes from, in the order the groups are listed.
    public enum Source: String, CaseIterable, Sendable {
        case homebrew, appStore, github, tools, web

        public var title: String {
            switch self {
            case .homebrew: "Homebrew"
            case .appStore: "App Store"
            case .github: "GitHub"
            case .tools: "Package tools"
            case .web: "Web"
            }
        }

        /// The glyph its heading and its rows that open a page wear.
        public var icon: MenuIcon {
            switch self {
            case .homebrew: .glyph("mug", .amber)
            case .appStore: .appStore
            case .github: .github
            case .tools: .formula
            case .web: .webApp
            }
        }

        public var symbol: String { icon.symbol }
    }

    // MARK: What was typed

    /// What is typed, read once: two characters or more, spaces collapsed, never a leading `-`.
    public struct Query: Equatable, Sendable {
        public let text: String

        public init?(_ raw: String) {
            let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard text.count >= MenuNavigator.minimumQuery, text.count <= 100, !text.hasPrefix("-") else { return nil }
            self.text = text
        }

        /// Homebrew's name for it, lowercased with hyphens for spaces ("Visual Studio Code" is visual-studio-code); nil
        /// when it holds anything brew could read as more than a name.
        public var brewName: String? {
            let name = text.lowercased().replacingOccurrences(of: " ", with: "-")
            return Package.isName(name) ? name : nil
        }

        /// One word a registry can hold as a package's name (npm's `@scope/name` too); nil for words with spaces.
        public var packageName: String? { Package.isName(text) ? text : nil }

        /// `owner/repo`, from that or a github.com link; nil for anything else.
        public var repo: String? {
            var s = Substring(text)
            for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s = s.dropFirst(prefix.count) }
            let hosted = s.hasPrefix("github.com/")
            if hosted { s = s.dropFirst("github.com/".count) }
            let parts = s.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 || (hosted && parts.count > 2) else { return nil }
            let owner = parts[0], name = parts[1].hasSuffix(".git") ? parts[1].dropLast(4) : parts[1]
            func ok(_ p: Substring) -> Bool { !p.isEmpty && !p.hasPrefix(".") && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } }
            return ok(owner) && ok(name) ? "\(owner)/\(name)" : nil
        }

        /// A Go module path: a host with a dot, then at least one more part ("github.com/jesseduffield/lazygit").
        public var goModule: String? {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0].contains("."), Package.isName(text), !text.contains("@"),
                  parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return nil }
            return text
        }
    }

    // MARK: Results

    /// How a result installs.
    public enum Method: Equatable, Sendable {
        /// A package's own command after the confirm step: brew, mas get, npm, uv, pipx, cargo or go.
        case package(Package)
        /// A GitHub release's .dmg, .pkg or .zip: downloaded to Downloads and opened, after the confirm step.
        case download(URL)
        /// A page that opens, with nothing run: an App Store page, a repo's releases, a web search.
        case page(URL)

        /// The row's id, the menu's and the URL scheme's: the package's key, `asset:<url>` or `page:<url>`.
        public var key: String {
            switch self {
            case .package(let p): p.key
            case .download(let url): "asset:\(url.absoluteString)"
            case .page(let url): "page:\(url.absoluteString)"
            }
        }

        /// Nil for a key that is none of the three, or names a download or page off the hosts Install opens.
        public init?(key: String) {
            if key.hasPrefix("asset:") {
                guard let url = URL(string: String(key.dropFirst(6))), InstallSearch.isAsset(url) else { return nil }
                self = .download(url)
            } else if key.hasPrefix("page:") {
                guard let url = URL(string: String(key.dropFirst(5))), InstallSearch.isPage(url) else { return nil }
                self = .page(url)
            } else if let package = Package(key: key) {
                self = .package(package)
            } else { return nil }
        }

        /// What runs on yes; nil for a page, which only opens.
        public var command: String? {
            switch self {
            case .package(let p): p.install
            case .download(let url): InstallSearch.downloadCommand(url)
            case .page: nil
            }
        }
    }

    public struct Result: Equatable, Sendable, Identifiable {
        public var title: String
        /// How it installs, in a few words: "Homebrew app", "App Store · iPhone and iPad app", "GitHub release · Rectangle.dmg".
        public var via: String
        /// What it is: a description, a seller, a repo's stars.
        public var detail: String
        public var source: Source
        public var method: Method
        /// Its picture on the network (App Store artwork, a repo owner's avatar, a cask's site icon); nil for a glyph.
        public var image: String?
        public var installed = false

        public init(title: String, via: String, detail: String = "", source: Source, method: Method, image: String? = nil, installed: Bool = false) {
            self.title = title; self.via = via; self.detail = detail; self.source = source; self.method = method; self.image = image
            self.installed = installed
        }

        public var id: String { method.key }
        public var key: String { method.key }

        /// The row's icon: its kind's glyph, wearing its picture once it arrives.
        public var icon: MenuIcon {
            var icon: MenuIcon = switch method {
            case .package(let p): .package(p)
            case .download, .page: source.icon
            }
            icon.remote = image
            return icon
        }
    }

    /// Why a source has nothing to show.
    public enum Trouble: Equatable, Sendable {
        case offline
        /// Its limit for asks without an account is used up until then (GitHub's: ten searches a minute, sixty asks an hour).
        case limited(until: Date?)
        case failed

        public func line(_ source: Source, now: Date = .now) -> String {
            switch self {
            case .offline: return "Offline, so \(source.title) was not searched"
            case .failed: return "\(source.title) did not answer; try again in a moment"
            case .limited(let until):
                guard let until, until > now else { return "\(source.title) is busy; try again in a minute" }
                return "\(source.title)'s limit without an account is used up until \(until.formatted(date: .omitted, time: .shortened))"
            }
        }

        /// The worse of two: offline over a limit over a failure.
        func worse(_ other: Trouble?) -> Trouble {
            guard let other else { return self }
            func rank(_ t: Trouble) -> Int { switch t { case .offline: 2; case .limited: 1; case .failed: 0 } }
            return rank(other) > rank(self) ? other : self
        }
    }

    /// One source's answers, ranked, and why it has none when it could not be asked.
    public struct Group: Equatable, Sendable {
        public let source: Source
        public var results: [Result]
        public var trouble: Trouble?
    }

    // MARK: The search

    /// What the network said: the body, no such thing (404), or why it said nothing.
    public enum Response: Equatable, Sendable {
        case ok(Data), missing, trouble(Trouble)

        var trouble: Trouble? { if case .trouble(let t) = self { t } else { nil } }
    }

    /// A GET on the network.
    public typealias Fetch = @Sendable (URL) async -> Response

    /// An HTTP answer as the search reads it (header names lowercased): 2xx its body; 404 or 410 nothing there; a 403 or
    /// 429 that says its limit is used up (`x-ratelimit-remaining: 0`, GitHub's) a limit until `x-ratelimit-reset`, or
    /// `retry-after` seconds from now; anything else a failure.
    public static func response(status: Int, headers: [String: String], data: Data, now: Date = .now) -> Response {
        switch status {
        case 200..<300: return .ok(data)
        case 404, 410: return .missing
        case 403, 429:
            if headers["x-ratelimit-remaining"] == "0" {
                return .trouble(.limited(until: headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))))
            }
            if let wait = headers["retry-after"].flatMap(TimeInterval.init) { return .trouble(.limited(until: now.addingTimeInterval(wait))) }
            return .trouble(status == 429 ? .limited(until: nil) : .failed)
        default: return .trouble(.failed)
        }
    }
    /// brew's arguments → its output, "" on a failure (a search with no hits exits 1).
    public typealias Brew = @Sendable ([String]) async -> String

    /// The package tools on the Mac, by the kind each installs: a registry is asked only when its tool is there.
    public typealias Tools = Set<Package.Kind>

    /// mas and the tools found in the folders Homebrew and the vendors' installers put commands in
    /// (CatalogueEntry.Check.commandFolders), Go also in its own installer's /usr/local/go.
    public static func tools(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Tools {
        let found = Tools([.mas, .npm, .uv, .pipx, .cargo, .go].filter { !CatalogueEntry.Check.copies(of: $0.rawValue, isExecutable: isExecutable).isEmpty })
        return isExecutable("/usr/local/go/bin/go") ? found.union([.go]) : found
    }

    /// Results kept per source.
    public static let limit = 6
    /// GitHub repos whose latest release is asked for: one ask each, out of sixty an hour without an account.
    public static let releasesAsked = 3

    /// A search part-way: the groups that have answered, in the sources' order, and the sources still asked. The web
    /// group comes last, once every other source has answered.
    public struct Progress: Equatable, Sendable {
        public var groups: [Group]
        public var waiting: [Source]

        public init(groups: [Group] = [], waiting: [Source]) { self.groups = groups; self.waiting = waiting }

        public var done: Bool { waiting.isEmpty }
    }

    /// The sources a search asks besides the web: Homebrew while brew is there, the App Store, GitHub, and the package
    /// tools while one is installed.
    public static func sources(tools: Tools, brew: Bool) -> [Source] {
        Source.allCases.filter { s in
            switch s {
            case .homebrew: brew
            case .appStore, .github: true
            case .tools: !tools.isDisjoint(with: [.npm, .uv, .pipx, .cargo, .go])
            case .web: false
            }
        }
    }

    /// Every source at once; a source that cannot be asked (no brew, no tool) is left out, one that fails says why. Each
    /// source's answer goes to `progress` as it lands (Sven 2026-10-09: the menu showed nothing until the slowest
    /// answered), the web group last. The App Store is asked in `country`'s store (Sven's is MT). The titles are kept for
    /// Install's confirm step.
    public static func search(_ query: Query, tools: Tools, country: String = "us", brew: Brew?, fetch: @escaping Fetch,
                              progress: @escaping @Sendable (Progress) async -> Void = { _ in }) async -> [Group] {
        var waiting = sources(tools: tools, brew: brew != nil)
        var groups: [Group] = []
        await progress(Progress(waiting: waiting))
        await withTaskGroup(of: Group?.self) { asked in
            if let brew { asked.addTask { Group(source: .homebrew, results: rank(await homebrewResults(query, run: brew), query: query.text)) } }
            asked.addTask { await appStoreGroup(query, mas: tools.contains(.mas), country: country, fetch: fetch) }
            asked.addTask { await githubGroup(query, fetch: fetch) }
            asked.addTask { await toolsGroup(query, tools: tools, fetch: fetch) }
            for await answer in asked {
                guard let answer else { continue }
                groups = inOrder(groups + [answer])
                waiting.removeAll { $0 == answer.source }
                remember([answer])
                if !waiting.isEmpty { await progress(Progress(groups: groups, waiting: waiting)) }
            }
        }
        let offline = groups.contains { $0.trouble == .offline }
        groups.append(Group(source: .web, results: [web(query, offline: offline, nothing: nothingFound(groups))]))
        remember(groups)
        await progress(Progress(groups: groups, waiting: []))
        return groups
    }

    /// "Searching Homebrew, App Store, GitHub…": the sources still asked.
    public static func searchingLine(_ waiting: [Source]) -> String {
        "Searching \(waiting.map(\.title).joined(separator: ", "))…"
    }

    /// Groups in the sources' order, whatever order they answered in.
    static func inOrder(_ groups: [Group]) -> [Group] {
        groups.sorted { Source.allCases.firstIndex(of: $0.source)! < Source.allCases.firstIndex(of: $1.source)! }
    }

    /// The groups to show: those with results or trouble, in the sources' order.
    public static func shown(_ groups: [Group]) -> [Group] { groups.filter { !$0.results.isEmpty || $0.trouble != nil } }

    /// The titles searches showed, by key (a few hundred at most): Install's confirm names the app, not its id.
    static let titles = Mutex<[String: String]>([:])

    public static func title(_ key: String) -> String? { titles.withLock { $0[key] } }

    static func remember(_ groups: [Group]) {
        titles.withLock { titles in
            if titles.count > 500 { titles.removeAll() }
            for result in groups.flatMap(\.results) { titles[result.key] = result.title }
        }
    }

    // MARK: Ranking

    /// Within a source: the exact name first, then a name that starts with it, a word that does, one that holds it,
    /// then the rest in the source's own order (each source matched it its own way, on its description or keywords).
    public static func rank(_ results: [Result], query: String) -> [Result] {
        rank(results, query: query, title: \.title) { $0.method.packageName }
    }

    static func rank<T>(_ items: [T], query: String, title: (T) -> String, name: (T) -> String? = { _ in nil }) -> [T] {
        let q = folded(query)
        func score(_ item: T) -> Int {
            let t = folded(title(item)), n = name(item).map(folded)
            if t == q || n == q { return 0 }
            if t.hasPrefix(q) || n?.hasPrefix(q) == true { return 1 }
            if words(title(item)).contains(where: { $0.hasPrefix(q) }) { return 2 }
            return t.contains(q) ? 3 : 4
        }
        return items.enumerated().sorted { (score($0.element), $0.offset) < (score($1.element), $1.offset) }.map(\.element)
    }

    /// Lowercased, accents and anything but letters and digits dropped: "8-Ball Pool" and "8 ball pool" are one.
    static func folded(_ s: String) -> String {
        String(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    static func words(_ s: String) -> [String] { EmojiSearch.words(s.folding(options: .diacriticInsensitive, locale: nil)) }

    // MARK: Homebrew

    /// Names per kind given to `brew info`.
    static let brewNames = 10

    /// `brew search --formula` and `--cask` apart (piped, brew mixes them), each kind's names to one `brew info
    /// --json=v2`, plus `brew info` on the name itself, which finds a tap's package search misses (card
    /// agent-bo-95423304). Homebrew's local API cache is not read: its layout is Homebrew's internal business.
    static func homebrewResults(_ query: Query, run: @escaping Brew) async -> [Result] {
        guard let name = query.brewName else { return [] }
        @Sendable func lookup(_ kind: String) async -> [Result] {
            let found = names(await run(["search", kind, name]))
            guard !found.isEmpty, !Task.isCancelled else { return [] }
            return (try? brewResults(Data(await run(["info", "--json=v2", kind] + found).utf8))) ?? []
        }
        async let formulae = lookup("--formula")
        async let casks = lookup("--cask")
        async let exact = (try? brewResults(Data(await run(["info", "--json=v2", name]).utf8))) ?? []
        let searched = await formulae + casks
        let named = Set(searched.map(\.key))
        return searched + (await exact).filter { !named.contains($0.key) }
    }

    /// `brew search`'s output: one name per line; a line that is not a safe name is dropped.
    public static func names(_ output: String) -> [String] {
        Array(output.split(whereSeparator: \.isNewline).map(String.init).filter(Package.isName).prefix(brewNames))
    }

    /// `brew info --json=v2`: formulae, then casks, each wearing its homepage's icon (a font its glyph).
    public static func brewResults(_ info: Data) throws -> [Result] {
        struct Info: Decodable {
            struct Formula: Decodable { let full_name: String; let desc: String?; let installed: [Installed]; let homepage: String? }
            struct Installed: Decodable {}
            struct Cask: Decodable { let full_token: String; let name: [String]?; let desc: String?; let installed: String?; let homepage: String? }
            let formulae: [Formula]
            let casks: [Cask]
        }
        let json = try JSONDecoder().decode(Info.self, from: info)
        let formulae = json.formulae.compactMap { f in
            Package(.formula, f.full_name).map {
                Result(title: f.full_name, via: $0.via, detail: f.desc ?? "", source: .homebrew, method: .package($0),
                       image: f.homepage.flatMap(siteIcon), installed: !f.installed.isEmpty)
            }
        }
        let casks = json.casks.compactMap { c in
            Package(.cask, c.full_token).map { p in
                Result(title: c.full_token, via: p.via, detail: c.desc ?? c.name?.first ?? "", source: .homebrew, method: .package(p),
                       image: MenuIcon.package(p) == .font ? nil : c.homepage.flatMap(siteIcon), installed: c.installed != nil)
            }
        }
        return formulae + casks
    }

    /// A site's own icon: its apple-touch-icon at the root (the app falls back to its favicon).
    static func siteIcon(_ page: String) -> String? {
        guard let url = URL(string: page), url.scheme == "https", let host = url.host() else { return nil }
        return "https://\(host)/apple-touch-icon.png"
    }

    // MARK: App Store

    /// Apple's iTunes Search API over Mac software, which also lists the iPhone and iPad apps that run on Apple silicon.
    public static func appStoreURL(_ query: Query, country: String) -> URL {
        url("https://itunes.apple.com/search", ["term": query.text, "entity": "macSoftware", "limit": "10", "country": country.lowercased()])
    }

    /// `base` with its query items, in order.
    static func url(_ base: String, _ items: KeyValuePairs<String, String>) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }

    /// Mac apps, and iPhone and iPad apps whose devices include the Mac (`MacDesktop`; one without it, such as Miniclip's
    /// 8 Ball Pool, does not run on a Mac and is left out). A free Mac app installs with `mas get` while mas is there;
    /// a paid one, or an iPhone or iPad app (mas gets Mac apps only), opens its page in the App Store.
    public static func appStoreResults(_ data: Data, mas: Bool) -> [Result] {
        struct App: Decodable {
            let kind: String?, trackId: Int, trackName: String, sellerName: String?, price: Double?, formattedPrice: String?
            let artworkUrl100: String?, supportedDevices: [String]?
        }
        struct Found: Decodable { let results: [App] }
        guard let found = try? JSONDecoder().decode(Found.self, from: data) else { return [] }
        return found.results.compactMap { app in
            let mac = app.kind == "mac-software"
            guard mac || (app.kind == "software" && app.supportedDevices?.contains("MacDesktop-MacDesktop") == true) else { return nil }
            let free = app.price == 0
            let page = URL(string: "macappstore://apps.apple.com/app/id\(app.trackId)")!
            let method: Method = mac && free && mas ? Package(.mas, String(app.trackId)).map(Method.package) ?? .page(page) : .page(page)
            let price = free ? nil : app.formattedPrice
            let via = (["App Store", mac ? nil : "iPhone and iPad app", price]).compactMap(\.self).joined(separator: " · ")
            // The artwork at 128 px, sharp on a 64-point tile.
            let art = app.artworkUrl100?.replacingOccurrences(of: "/100x100bb.", with: "/128x128bb.")
            return Result(title: app.trackName, via: via, detail: app.sellerName ?? "", source: .appStore, method: method, image: art)
        }
    }

    static func appStoreGroup(_ query: Query, mas: Bool, country: String, fetch: Fetch) async -> Group {
        let response = await fetch(appStoreURL(query, country: country))
        guard case .ok(let data) = response else { return Group(source: .appStore, results: [], trouble: response.trouble) }
        return Group(source: .appStore, results: Array(rank(appStoreResults(data, mas: mas), query: query.text).prefix(limit)))
    }

    // MARK: GitHub

    public struct Repo: Equatable, Sendable {
        public let fullName: String, name: String, description: String, stars: Int, avatar: String?, page: URL
    }

    public struct Release: Equatable, Sendable {
        public let page: URL
        public let assets: [(name: String, url: URL)]

        public static func == (a: Release, b: Release) -> Bool { a.page == b.page && a.assets.map(\.url) == b.assets.map(\.url) }
    }

    public static func githubSearchURL(_ query: Query) -> URL {
        url("https://api.github.com/search/repositories", ["q": query.text, "per_page": "8"])
    }

    public static func repoURL(_ fullName: String) -> URL { URL(string: "https://api.github.com/repos/\(fullName)")! }
    public static func releaseURL(_ fullName: String) -> URL { URL(string: "https://api.github.com/repos/\(fullName)/releases/latest")! }

    private struct RepoJSON: Decodable {
        struct Owner: Decodable { let avatar_url: String? }
        let full_name: String, name: String, description: String?, stargazers_count: Int, html_url: String
        let fork: Bool?, archived: Bool?, owner: Owner?

        var repo: Repo? {
            guard fork != true, archived != true, let page = URL(string: html_url), page.host() == "github.com" else { return nil }
            return Repo(fullName: full_name, name: name, description: description ?? "", stars: stargazers_count,
                        avatar: owner?.avatar_url.map { $0 + ($0.contains("?") ? "&" : "?") + "s=128" }, page: page)
        }
    }

    /// The search's repos, no forks or archives.
    public static func githubRepos(_ data: Data) -> [Repo] {
        struct Found: Decodable { let items: [RepoJSON] }
        return ((try? JSONDecoder().decode(Found.self, from: data))?.items ?? []).compactMap(\.repo)
    }

    /// One repo, as `repos/<owner>/<name>` answers.
    public static func githubRepo(_ data: Data) -> Repo? { (try? JSONDecoder().decode(RepoJSON.self, from: data))?.repo }

    /// `releases/latest`: its page and assets; nil for a draft or a prerelease.
    public static func latestRelease(_ data: Data) -> Release? {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct JSON: Decodable { let html_url: String; let draft: Bool?; let prerelease: Bool?; let assets: [Asset] }
        guard let r = try? JSONDecoder().decode(JSON.self, from: data), r.draft != true, r.prerelease != true,
              let page = URL(string: r.html_url) else { return nil }
        return Release(page: page, assets: r.assets.compactMap { a in URL(string: a.browser_download_url).map { (a.name, $0) } })
    }

    /// The release's Mac installer: a .dmg over a .pkg over a .zip that names the Mac, Apple silicon or universal over
    /// Intel; never one for Linux or Windows. Nil when it has none.
    public static func macAsset(_ assets: [(name: String, url: URL)]) -> URL? {
        func score(_ name: String) -> Int? {
            let n = name.lowercased()
            let mac = ["mac", "darwin", "osx", "apple", "universal", ".app."].contains { n.contains($0) }
            guard !["linux", "windows", "win32", "win64", "-win", "_win", "android"].contains(where: { n.contains($0) }) else { return nil }
            var s: Int
            if n.hasSuffix(".dmg") { s = 30 } else if n.hasSuffix(".pkg") { s = 20 } else if n.hasSuffix(".zip"), mac { s = 10 } else { return nil }
            if ["arm64", "aarch64", "universal", "apple-silicon"].contains(where: { n.contains($0) }) { s += 2 }
            if ["x86_64", "x86-64", "amd64", "intel", "x64"].contains(where: { n.contains($0) }) { s -= 5 }
            return s
        }
        return assets.compactMap { a in score(a.name).map { (a.url, $0) } }.filter { isAsset($0.0) }.max { $0.1 < $1.1 }?.0
    }

    /// The repos worth a row: forks and archives already out, the exact name and `owner/repo` first, then ten stars or
    /// more in GitHub's order; three at most, each asked for its latest release (cached, so a longer query asks again
    /// for none it saw).
    static func githubGroup(_ query: Query, fetch: @escaping Fetch) async -> Group {
        async let named: Response? = query.repo == nil ? nil : fetch(repoURL(query.repo!))
        let response = await fetch(githubSearchURL(query))
        var trouble = response.trouble
        var typed: Repo?
        if case .ok(let data)? = await named { typed = githubRepo(data) }
        var found: [Repo] = []
        if case .ok(let data) = response { found = githubRepos(data).filter { $0.fullName != typed?.fullName } }
        let q = folded(query.text)
        let worth = found.filter { $0.stars >= 10 || folded($0.name) == q }
        let top = Array(((typed.map { [$0] } ?? []) + rank(worth, query: query.text, title: \.name)).prefix(releasesAsked))
        let results = await withTaskGroup(of: (Int, Result, Trouble?).self) { group in
            for (i, repo) in top.enumerated() {
                group.addTask {
                    let answer = await fetch(releaseURL(repo.fullName))
                    if case .ok(let data) = answer { return (i, githubResult(repo, release: latestRelease(data)), nil) }
                    return (i, githubResult(repo, release: nil), answer.trouble)
                }
            }
            var found: [(Int, Result)] = []
            for await (i, result, problem) in group {
                found.append((i, result))
                if let problem { trouble = problem.worse(trouble) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // A release that could not be read still lists its repo; only a source with nothing to show keeps a failure.
        if !results.isEmpty, trouble == .failed { trouble = nil }
        return Group(source: .github, results: results, trouble: trouble)
    }

    /// A repo as a row: its release's Mac installer, else its releases page, else (no release) the repo itself.
    static func githubResult(_ repo: Repo, release: Release?) -> Result {
        let asset = release.flatMap { macAsset($0.assets) }
        let method: Method, via: String
        if let asset { method = .download(asset); via = "GitHub release · \(asset.lastPathComponent)" }
        else if let release { method = .page(release.page); via = "GitHub · releases page" }
        else { method = .page(repo.page); via = "GitHub · opens the repo" }
        let stars = repo.stars >= 1000 ? String(format: "%.1fk", Double(repo.stars) / 1000) : "\(repo.stars)"
        let detail = ["\(repo.fullName) · ★ \(stars)", repo.description].filter { !$0.isEmpty }.joined(separator: " · ")
        return Result(title: repo.name, via: via, detail: detail, source: .github, method: method, image: repo.avatar)
    }

    // MARK: Package tools

    public static func npmURL(_ query: Query) -> URL { url("https://registry.npmjs.org/-/v1/search", ["text": query.text, "size": "5"]) }

    public static func cratesURL(_ query: Query) -> URL { url("https://crates.io/api/v1/crates", ["q": query.text, "per_page": "5"]) }

    /// PyPI's JSON API for one exact name (PyPI has no search API); nil for a name PyPI cannot hold.
    public static func pypiURL(_ query: Query) -> URL? {
        guard query.text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { return nil }
        return URL(string: "https://pypi.org/pypi/\(query.text)/json")
    }

    /// The Go module proxy's latest version of a module path, its capitals escaped as the proxy wants (`!b` for `B`).
    public static func goURL(_ module: String) -> URL? {
        let escaped = module.map { $0.isUppercase ? "!\($0.lowercased())" : String($0) }.joined()
        return URL(string: "https://proxy.golang.org/\(escaped)/@latest")
    }

    public static func npmResults(_ data: Data) -> [Result] {
        struct Found: Decodable { struct Object: Decodable { struct P: Decodable { let name: String; let description: String? }; let package: P }; let objects: [Object] }
        return ((try? JSONDecoder().decode(Found.self, from: data))?.objects ?? []).compactMap { o in
            Package(.npm, o.package.name).map { Result(title: o.package.name, via: $0.via, detail: o.package.description ?? "", source: .tools, method: .package($0)) }
        }
    }

    /// The project, installed with uv when it is there, else pipx.
    public static func pypiResults(_ data: Data, uv: Bool) -> [Result] {
        struct Project: Decodable { struct Info: Decodable { let name: String; let summary: String? }; let info: Info }
        guard let p = try? JSONDecoder().decode(Project.self, from: data), let package = Package(uv ? .uv : .pipx, p.info.name) else { return [] }
        return [Result(title: p.info.name, via: package.via, detail: p.info.summary ?? "", source: .tools, method: .package(package))]
    }

    public static func cratesResults(_ data: Data) -> [Result] {
        struct Found: Decodable { struct Crate: Decodable { let name: String; let description: String? }; let crates: [Crate] }
        return ((try? JSONDecoder().decode(Found.self, from: data))?.crates ?? []).compactMap { c in
            Package(.cargo, c.name).map {
                Result(title: c.name, via: $0.via, detail: (c.description ?? "").split(whereSeparator: \.isNewline).joined(separator: " "),
                       source: .tools, method: .package($0))
            }
        }
    }

    public static func goResults(_ data: Data, module: String) -> [Result] {
        struct Latest: Decodable { let Version: String }
        guard let latest = try? JSONDecoder().decode(Latest.self, from: data), let package = Package(.go, module) else { return [] }
        return [Result(title: module.split(separator: "/").last.map(String.init) ?? module, via: package.via, detail: "\(module) \(latest.Version)",
                       source: .tools, method: .package(package))]
    }

    /// Each installed tool's registry at once; nil when no tool is installed. Each answer is ranked and cut, then they
    /// follow each other: npm, PyPI, crates.io, Go.
    static func toolsGroup(_ query: Query, tools: Tools, fetch: @escaping Fetch) async -> Group? {
        let python = tools.contains(.uv) || tools.contains(.pipx)
        guard !tools.isDisjoint(with: [.npm, .uv, .pipx, .cargo, .go]) else { return nil }
        typealias Answer = (results: [Result], trouble: Trouble?)
        /// Nil `url`: not asked.
        @Sendable func ask(_ url: URL?, _ parse: @escaping @Sendable (Data) -> [Result]) async -> Answer {
            guard let url else { return ([], nil) }
            let response = await fetch(url)
            guard case .ok(let data) = response else { return ([], response.trouble) }
            return (Array(rank(parse(data), query: query.text).prefix(3)), nil)
        }
        let module = query.goModule
        let uv = tools.contains(.uv)
        async let npm = ask(tools.contains(.npm) ? npmURL(query) : nil, npmResults)
        async let pypi = ask(python && query.packageName != nil ? pypiURL(query) : nil) { pypiResults($0, uv: uv) }
        async let crates = ask(tools.contains(.cargo) ? cratesURL(query) : nil, cratesResults)
        async let go = ask(tools.contains(.go) ? module.flatMap(goURL) : nil) { goResults($0, module: module ?? "") }
        let all = [await npm, await pypi, await crates, await go]
        let results = all.flatMap(\.results)
        let trouble = results.isEmpty ? all.compactMap(\.trouble).reduce(nil as Trouble?) { $1.worse($0) } : nil
        return Group(source: .tools, results: results, trouble: trouble)
    }

    // MARK: The web

    public static func webURL(_ query: Query) -> URL { url("https://www.google.com/search", ["q": query.text]) }

    /// Search the web for what was typed, always last; offline, it says what was not searched.
    static func web(_ query: Query, offline: Bool, nothing: Bool = false) -> Result {
        let detail = offline ? "Offline: only Homebrew and this Mac were searched" : nothing ? nothingLine : ""
        return Result(title: "Search the web for “\(query.text)”", via: "Google", detail: detail, source: .web, method: .page(webURL(query)))
    }

    /// Said once every source has answered with nothing, never before.
    public static let nothingLine = "Nothing matches in Homebrew, the App Store, GitHub or the package tools"

    /// Every source but the web answered, and none with a result.
    public static func nothingFound(_ groups: [Group]) -> Bool { groups.allSatisfy { $0.source == .web || $0.results.isEmpty } }

    // MARK: Where things open

    /// A GitHub release download: https on github.com, `owner/repo/releases/download/<tag>/<file>`.
    public static func isAsset(_ url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" }
        return url.scheme == "https" && url.host() == "github.com" && parts.count == 6 && parts[2] == "releases" && parts[3] == "download"
    }

    /// The pages Install opens: GitHub, the App Store (in its app, or on the web) and the web search.
    public static func isPage(_ url: URL) -> Bool {
        switch (url.scheme, url.host()) {
        case ("https", "github.com"), ("https", "www.google.com"), ("https", "apps.apple.com"), ("macappstore", "apps.apple.com"): true
        default: false
        }
    }

    /// A release's file downloaded to Downloads and opened: a .dmg mounts in Finder for the drag to Applications, a .pkg
    /// opens Installer, a .zip unpacks. Nil for a file name with anything but letters, digits and `._+-@`.
    public static func downloadCommand(_ url: URL) -> String? {
        let file = url.lastPathComponent
        guard isAsset(url), Package.isName(file), !file.contains("/") else { return nil }
        return "curl -fL --progress-bar -o ~/Downloads/\(file) \(VisibleRun.quoted(url.absoluteString)) && open ~/Downloads/\(file)"
    }
}

extension InstallSearch.Method {
    /// The package's name, which ranking also matches on (a cask's token, an npm name).
    var packageName: String? { if case .package(let p) = self { p.name.split(separator: "/").last.map(String.init) } else { nil } }
}

// MARK: The cache

extension InstallSearch {
    /// What the network and brew said, kept for `ttl` (ten minutes) so a search typed again, or a repo's release an
    /// earlier search read, asks nothing; a source whose limit is used up is not asked until it lifts. Failures are not
    /// kept. Small, since answers are whole bodies (a few hundred KB a search): each keep drops what is out of date,
    /// and the oldest half goes once it holds `capacity` answers.
    public actor Cache {
        private struct Kept<Value: Sendable>: Sendable { let at: Date, value: Value }
        private var answers: [String: Kept<Response>] = [:]
        private var brewed: [[String]: Kept<String>] = [:]
        private var limited: [String: Date] = [:]
        private let ttl: TimeInterval, capacity: Int
        private let now: @Sendable () -> Date

        public init(ttl: TimeInterval = 600, capacity: Int = 60, now: @escaping @Sendable () -> Date = { Date() }) {
            self.ttl = ttl; self.capacity = capacity; self.now = now
        }

        /// GitHub counts its search apart from its other asks, so each is its own bucket.
        static func bucket(_ url: URL) -> String {
            (url.host() ?? "") + (url.path().hasPrefix("/search/") ? "/search" : "")
        }

        public func fetch(_ url: URL, via fetch: Fetch) async -> Response {
            let key = url.absoluteString, at = now()
            if let kept = answers[key], at.timeIntervalSince(kept.at) < ttl { return kept.value }
            let bucket = Self.bucket(url)
            if let until = limited[bucket] {
                if until > at { return .trouble(.limited(until: until)) }
                limited[bucket] = nil
            }
            let response = await fetch(url)
            switch response {
            case .ok, .missing: keep(response, at: at, for: key, in: &answers)
            case .trouble(.limited(let until)): limited[bucket] = until ?? at.addingTimeInterval(60)
            case .trouble: break
            }
            return response
        }

        public func brew(_ arguments: [String], via run: Brew) async -> String {
            let at = now()
            if let kept = brewed[arguments], at.timeIntervalSince(kept.at) < ttl { return kept.value }
            let output = await run(arguments)
            guard !Task.isCancelled else { return output }
            keep(output, at: at, for: arguments, in: &brewed)
            return output
        }

        private func keep<Key, Value>(_ value: Value, at: Date, for key: Key, in kept: inout [Key: Kept<Value>]) {
            kept = kept.filter { at.timeIntervalSince($0.value.at) < ttl }
            if kept.count >= capacity {
                for old in kept.sorted(by: { $0.value.at < $1.value.at }).prefix(kept.count / 2).map(\.key) { kept[old] = nil }
            }
            kept[key] = Kept(at: at, value: value)
        }
    }
}

extension MenuEntries {
    /// The search's rows for the menu's Install and Search packages (N9): each under its source's heading
    /// (MenuLayout.installSections), how it installs and what it is beside it, the query as its keywords so the menu's
    /// own ranking keeps a row its source matched on its description. A source that could not be searched says why on
    /// a row that searches it on the web. `hint`, a missing helper that would add a source (Helper.searchHint), is one
    /// more row that installs it, under the source it adds.
    public static func found(_ groups: [InstallSearch.Group], query: InstallSearch.Query, waiting: [InstallSearch.Source] = [],
                             hint: Helper? = nil, now: Date = .now) -> [MenuEntry] {
        searching(query, waiting: waiting) + InstallSearch.shown(groups).flatMap { group -> [MenuEntry] in
            let home = MenuLayout.installSection(group.source)
            var rows = group.results.map { r in
                MenuEntry(title: r.title, target: .package(r.key), home: home,
                          detail: [r.via, r.detail, r.installed ? "installed" : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                          inSearch: false, keywords: query.text, icon: r.icon, short: r.via)
            }
            if let trouble = group.trouble, group.source != .web, let page = troublePage(group.source, query) {
                rows.append(MenuEntry(title: "Search \(group.source.title) on the web", target: .package(InstallSearch.Method.page(page).key), home: home,
                                      detail: trouble.line(group.source, now: now), inSearch: false, keywords: query.text,
                                      icon: .webApp))
            }
            return rows
        } + (hint.map { [helperHint($0, query: query)] } ?? [])
    }

    /// "Add npm to search more": installs the helper through Install's confirm step.
    static func helperHint(_ helper: Helper, query: InstallSearch.Query) -> MenuEntry {
        MenuEntry(title: "Add \(helper.name)\(helperHintEnd)", target: .package(helper.key),
                  home: MenuLayout.installSection(helper.addsSource ?? .tools),
                  detail: "\(helper.unlocks) · \(helper.install)", inSearch: false, keywords: query.text, icon: .glyph("arrow.down.circle", .accent))
    }

    /// While sources are still asked (N9, Sven 2026-10-09): one row naming them, shown the moment a search starts, under
    /// the first one's heading, where its answers will land; Return searches the web meanwhile. None once all answered.
    public static func searching(_ query: InstallSearch.Query, waiting: [InstallSearch.Source]) -> [MenuEntry] {
        guard let first = waiting.first else { return [] }
        return [MenuEntry(title: InstallSearch.searchingLine(waiting), target: .package(InstallSearch.Method.page(InstallSearch.webURL(query)).key),
                          home: MenuLayout.installSection(first), detail: searchingDetail, inSearch: false, keywords: query.text,
                          icon: .glyph("magnifyingglass", .neutral))]
    }

    static let searchingDetail = "Return searches the web meanwhile"

    /// The Searching row, which only stands in until results land.
    public static func isSearching(_ row: MenuEntry) -> Bool { row.detail == searchingDetail }

    static let helperHintEnd = " to search more"
    /// An "Add npm to search more" row, which follows the results however few have landed.
    public static func isHelperHint(_ row: MenuEntry) -> Bool { row.title.hasPrefix("Add ") && row.title.hasSuffix(helperHintEnd) }

    /// Where a source that could not be asked is searched in the browser instead.
    static func troublePage(_ source: InstallSearch.Source, _ query: InstallSearch.Query) -> URL? {
        switch source {
        case .github: return InstallSearch.url("https://github.com/search", ["q": query.text, "type": "repositories"])
        case .appStore: return InstallSearch.webURL(InstallSearch.Query("\(query.text) site:apps.apple.com") ?? query)
        case .homebrew, .tools, .web: return nil
        }
    }
}
