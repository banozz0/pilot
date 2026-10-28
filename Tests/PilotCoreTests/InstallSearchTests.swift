import Foundation
import Testing
@testable import PilotCore

/// Install finds anything (N9, Sven 2026-10-09): one search over Homebrew, the App Store, GitHub, the package tools and
/// the web, grouped in that order, each result saying how it installs. Every answer here is a fixture recorded read-only
/// on 2026-10-09 (Fixtures/install-search, trimmed to the fields Pilot reads); nothing reaches the network or runs brew.
@Suite("Install search")
struct InstallSearchTests {
    static func fixture(_ name: String) -> Data {
        try! Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/install-search/\(name).json"))
    }

    typealias Q = InstallSearch.Query

    /// The network as recorded: each address its fixture, anything else 404.
    static let recorded: [String: String] = [
        InstallSearch.appStoreURL(Q("8 ball pool")!, country: "MT").absoluteString: "itunes-8-ball-pool",
        InstallSearch.githubSearchURL(Q("rectangle")!).absoluteString: "github-search-rectangle",
        InstallSearch.releaseURL("rxhanson/Rectangle").absoluteString: "github-release-rectangle",
        InstallSearch.npmURL(Q("cowsay")!).absoluteString: "npm-search-cowsay",
        "https://pypi.org/pypi/httpie/json": "pypi-httpie",
        InstallSearch.cratesURL(Q("ripgrep")!).absoluteString: "crates-ripgrep",
        "https://proxy.golang.org/github.com/jesseduffield/lazygit/@latest": "goproxy-lazygit",
    ]

    static let network: InstallSearch.Fetch = { url in recorded[url.absoluteString].map { .ok(fixture($0)) } ?? .missing }

    // MARK: What was typed

    @Test("A query is two characters or more with its spaces collapsed; it reads as a repo, a Go module or a registry name when it is one")
    func query() {
        #expect(Q("a") == nil && Q("  ") == nil && Q("-rf") == nil)
        #expect(Q("  8   ball pool ")?.text == "8 ball pool")
        #expect(Q("8 ball pool")?.packageName == nil)
        #expect(Q("@scope/cow")?.packageName == "@scope/cow")
        #expect(Q("TheOrcDev/videorc")?.repo == "TheOrcDev/videorc")
        #expect(Q("https://github.com/TheOrcDev/videorc.git")?.repo == "TheOrcDev/videorc")
        #expect(Q("github.com/TheOrcDev/videorc/releases")?.repo == "TheOrcDev/videorc")
        #expect(Q("videorc")?.repo == nil && Q("a/b/c")?.repo == nil && Q("../x")?.repo == nil)
        #expect(Q("github.com/jesseduffield/lazygit")?.goModule == "github.com/jesseduffield/lazygit")
        #expect(Q("TheOrcDev/videorc")?.goModule == nil, "a module path starts with a host")
    }

    // MARK: Sources

    /// Sven's example: Miniclip's 8 Ball Pool is an iPhone app that does not run on a Mac (no MacDesktop in its devices,
    /// and its App Store page offers no Mac), so it is left out; Billiards 8-Ball Pool Master does, so it is in.
    @Test("The App Store lists Mac apps and the iPhone and iPad apps that run on Apple silicon, never one that does not")
    func appStore() {
        let found = InstallSearch.appStoreResults(Self.fixture("itunes-8-ball-pool"), mas: true)
        // Apple's titles keep their non-breaking spaces; the row shows them as they are.
        #expect(found.map { $0.title.replacingOccurrences(of: "\u{a0}", with: " ") } == ["Billiards 8-Ball Pool Master ™", "Pool!", "Pro Snooker & Pool 2026+", "Vegas Pool Sharks Lite",
                                       "WhatsApp Messenger", "SNOK"])
        #expect(!found.map(\.title).contains("8 Ball Pool™"))
        let ipad = found[0], mac = found[1]
        #expect(ipad.via == "App Store · iPhone and iPad app")
        #expect(ipad.method == .page(URL(string: "macappstore://apps.apple.com/app/id6504484102")!), "mas gets Mac apps only")
        #expect(mac.method == .package(Package(.mas, "416970936")!))
        #expect(mac.via == "App Store")
        #expect(mac.image?.contains("/128x128bb.") == true)
        // No price in the answer is not free: its page opens.
        #expect(found[2].method == .page(URL(string: "macappstore://apps.apple.com/app/id1586517737")!))
        // Without mas every App Store row opens its page.
        #expect(InstallSearch.appStoreResults(Self.fixture("itunes-8-ball-pool"), mas: false).allSatisfy {
            if case .page = $0.method { true } else { false }
        })
    }

    @Test("GitHub's repos skip forks and archives; a release's Mac installer is a .dmg over a .pkg, never a delta")
    func github() throws {
        let repos = InstallSearch.githubRepos(Self.fixture("github-search-rectangle"))
        #expect(repos.first?.fullName == "rxhanson/Rectangle")
        #expect(repos.first?.avatar?.hasSuffix("&s=128") == true)
        let release = try #require(InstallSearch.latestRelease(Self.fixture("github-release-rectangle")))
        let asset = try #require(InstallSearch.macAsset(release.assets))
        #expect(asset.lastPathComponent == "Rectangle2.0.3.dmg")
        let row = InstallSearch.githubResult(repos[0], release: release)
        #expect(row.via == "GitHub release · Rectangle2.0.3.dmg")
        #expect(row.method == .download(asset))
        #expect(row.detail.hasPrefix("rxhanson/Rectangle · ★ 30.0k"))
    }

    @Test("A Mac installer prefers Apple silicon, takes a .zip only when it names the Mac, and never Linux or Windows")
    func macAsset() {
        func url(_ name: String) -> (name: String, url: URL) { (name, URL(string: "https://github.com/o/r/releases/download/v1/\(name)")!) }
        #expect(InstallSearch.macAsset([url("app-x86_64.dmg"), url("app-arm64.dmg")])?.lastPathComponent == "app-arm64.dmg")
        #expect(InstallSearch.macAsset([url("app-linux.zip"), url("app-windows.zip"), url("source.zip")]) == nil)
        #expect(InstallSearch.macAsset([url("app-darwin-universal.zip"), url("app.tar.gz")])?.lastPathComponent == "app-darwin-universal.zip")
        #expect(InstallSearch.macAsset([url("App.pkg"), url("App.dmg")])?.lastPathComponent == "App.dmg")
        let elsewhere = [(name: "App.dmg", url: URL(string: "https://example.com/App.dmg")!)]
        #expect(InstallSearch.macAsset(elsewhere) == nil, "only a GitHub release download")
    }

    @Test("A repo with no release opens itself, one whose release has no Mac installer opens its releases")
    func githubPages() throws {
        let repo = try #require(InstallSearch.githubRepos(Self.fixture("github-search-rectangle")).first)
        let none = InstallSearch.githubResult(repo, release: nil)
        #expect(none.method == .page(URL(string: "https://github.com/rxhanson/Rectangle")!))
        #expect(none.via == "GitHub · opens the repo")
        let page = URL(string: "https://github.com/rxhanson/Rectangle/releases/tag/v2.0.3")!
        let linuxOnly = InstallSearch.githubResult(repo, release: .init(page: page, assets: []))
        #expect(linuxOnly.method == .page(page))
        #expect(linuxOnly.via == "GitHub · releases page")
    }

    @Test("npm, PyPI, crates.io and the Go proxy each give their tool's own command")
    func tools() {
        let npm = InstallSearch.npmResults(Self.fixture("npm-search-cowsay"))
        #expect(npm.first?.method.command == "npm install -g cowsay")
        let uv = InstallSearch.pypiResults(Self.fixture("pypi-httpie"), uv: true), pipx = InstallSearch.pypiResults(Self.fixture("pypi-httpie"), uv: false)
        #expect(uv.map(\.method.command) == ["uv tool install httpie"])
        #expect(pipx.map(\.method.command) == ["pipx install httpie"])
        let crates = InstallSearch.cratesResults(Self.fixture("crates-ripgrep"))
        #expect(crates.first?.method.command == "cargo install ripgrep")
        #expect(crates.first?.detail.contains("\n") == false)
        let go = InstallSearch.goResults(Self.fixture("goproxy-lazygit"), module: "github.com/jesseduffield/lazygit")
        #expect(go.map(\.method.command) == ["go install github.com/jesseduffield/lazygit@latest"])
        #expect(go.map(\.title) == ["lazygit"])
        #expect(InstallSearch.goURL("github.com/BurntSushi/toml")?.absoluteString == "https://proxy.golang.org/github.com/!burnt!sushi/toml/@latest")
        #expect(InstallSearch.pypiURL(Q("8 ball")!) == nil, "PyPI is asked only for a name it can hold")
    }

    // MARK: Ranking and grouping

    @Test("Within a source the exact name leads, then a name starting with it, a word starting with it, one holding it, then the rest")
    func rank() {
        func r(_ title: String) -> InstallSearch.Result { .init(title: title, via: "", source: .tools, method: .page(URL(string: "https://github.com/o/r")!)) }
        let ranked = InstallSearch.rank([r("Pool!"), r("Billiards 8-Ball Pool Master"), r("pool-tools"), r("8 Ball Pool"), r("Super8ballpoolx")],
                                        query: "8 ball pool")
        #expect(ranked.map(\.title) == ["8 Ball Pool", "Billiards 8-Ball Pool Master", "Super8ballpoolx", "Pool!", "pool-tools"])
    }

    /// The fake cask is "rect", a short stand-in, so the commit guard does not read `full_token` as a credential.
    @Test("Every source is asked at once and grouped Homebrew, App Store, GitHub, package tools, web, whatever answers first")
    func grouped() async {
        let groups = await InstallSearch.search(Q("rectangle")!, tools: [.npm], brew: { arguments in
            switch arguments {
            case ["search", "--cask", "rectangle"]: "rect\n"
            case ["info", "--json=v2", "--cask", "rect"]: #"{"formulae": [], "casks": [{"full_token": "rect", "desc": "Move windows", "installed": null}]}"#
            default: ""
            }
        }, fetch: { url in
            // The fast answer arrives last: the order is the sources', not the network's.
            if url.host() == "api.github.com" { return await Self.network(url) }
            try? await Task.sleep(for: .milliseconds(50))
            return await Self.network(url)
        })
        #expect(groups.map(\.source) == [.homebrew, .appStore, .github, .tools, .web])
        #expect(groups[0].results.map(\.key) == ["cask:rect"])
        #expect(groups[2].results.first?.via == "GitHub release · Rectangle2.0.3.dmg")
        #expect(groups[4].results.map(\.title) == ["Search the web for “rectangle”"])
        #expect(InstallSearch.shown(groups).map(\.source) == [.homebrew, .github, .web], "a source with nothing to say is not shown")
        #expect(InstallSearch.title("cask:rect") == "rect", "Install's confirm names what the search showed")
    }

    @Test("A source is left out when it cannot be asked: no brew, no package tool, and PyPI only with uv or pipx")
    func leftOut() async {
        actor Asked { var hosts: Set<String> = []; func add(_ h: String?) { if let h { hosts.insert(h) } } }
        let asked = Asked()
        let groups = await InstallSearch.search(Q("httpie")!, tools: [], brew: nil) { url in await asked.add(url.host()); return .missing }
        #expect(groups.map(\.source) == [.appStore, .github, .web])
        #expect(await asked.hosts == ["itunes.apple.com", "api.github.com"])
        let pipx = await InstallSearch.search(Q("httpie")!, tools: [.pipx], brew: nil, fetch: Self.network)
        #expect(pipx.first { $0.source == .tools }?.results.map(\.method.command) == ["pipx install httpie"])
    }

    @Test("Offline, each network source says so and the web row says only Homebrew was searched; a limit names when it lifts")
    func trouble() async {
        let offline = await InstallSearch.search(Q("rectangle")!, tools: [.npm], brew: nil) { _ in .trouble(.offline) }
        #expect(offline.filter { $0.source != .web }.allSatisfy { $0.trouble == .offline && $0.results.isEmpty })
        #expect(offline.last?.results.first?.detail == "Offline: only Homebrew and this Mac were searched")
        let reset = Date(timeIntervalSince1970: 1_791_575_997)
        let limited = await InstallSearch.search(Q("rectangle")!, tools: [], brew: nil) { url in
            url.host() == "api.github.com" ? .trouble(.limited(until: reset)) : .missing
        }
        let github = limited.first { $0.source == .github }
        #expect(github?.trouble == .limited(until: reset))
        #expect(github?.trouble?.line(.github, now: reset.addingTimeInterval(-60)).hasPrefix("GitHub's limit without an account is used up until") == true)
        #expect(InstallSearch.Trouble.limited(until: nil).line(.github) == "GitHub is busy; try again in a minute")
    }

    @Test("GitHub's answers read as a limit: remaining 0 until its reset, Retry-After from now; a 404 is nothing there")
    func responses() {
        let now = Date(timeIntervalSince1970: 1000), body = Data("{}".utf8)
        #expect(InstallSearch.response(status: 200, headers: [:], data: body) == .ok(body))
        #expect(InstallSearch.response(status: 404, headers: [:], data: body) == .missing)
        #expect(InstallSearch.response(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "2000"], data: body)
                == .trouble(.limited(until: Date(timeIntervalSince1970: 2000))))
        #expect(InstallSearch.response(status: 429, headers: ["retry-after": "30"], data: body, now: now) == .trouble(.limited(until: now.addingTimeInterval(30))))
        #expect(InstallSearch.response(status: 403, headers: [:], data: body) == .trouble(.failed))
        #expect(InstallSearch.response(status: 500, headers: [:], data: body) == .trouble(.failed))
    }

    // MARK: As each source answers

    actor Seen { var all: [InstallSearch.Progress] = []; func add(_ p: InstallSearch.Progress) { all.append(p) } }

    /// Sven's test 2026-10-09: Install's menu said Nothing matches until the slowest source answered. Each answer now
    /// lands on its own, the rest still named, the web last.
    @Test("Each source's answer lands as it comes, in the sources' order, the ones still asked named; the web comes last")
    func progress() async throws {
        let seen = Seen()
        let groups = await InstallSearch.search(Q("rectangle")!, tools: [.npm], brew: { _ in "" }, fetch: { url in
            // The App Store answers first, the package tools next, GitHub last.
            let wait = url.host() == "itunes.apple.com" ? 0 : url.host() == "registry.npmjs.org" ? 80 : 200
            try? await Task.sleep(for: .milliseconds(wait))
            return await Self.network(url)
        }, progress: { await seen.add($0) })
        let all = await seen.all
        #expect(all.first == InstallSearch.Progress(waiting: [.homebrew, .appStore, .github, .tools]))
        let github = try #require(all.firstIndex { $0.groups.contains { $0.source == .github } })
        #expect(all[..<github].contains { $0.groups.contains { $0.source == .appStore } }, "the App Store did not wait for GitHub")
        #expect(all[github - 1].waiting == [.github])
        #expect(all.allSatisfy { p in p.groups.map(\.source) == InstallSearch.inOrder(p.groups).map(\.source) })
        #expect(all.dropLast().allSatisfy { !$0.groups.contains { $0.source == .web } })
        #expect(all.last?.done == true && all.last?.groups == groups && groups.last?.source == .web)
    }

    @Test("A missing helper that adds a source is one row under that source, installing it; none when nothing is missing")
    func helperHint() throws {
        let q = Q("ripgrep")!
        let groups = [InstallSearch.Group(source: .web, results: [InstallSearch.web(q, offline: false)])]
        let rows = MenuEntries.found(groups, query: q, hint: Helper.searchHint(installed: ["homebrew"]))
        let hint = try #require(rows.last)
        #expect(rows.count == 2)
        #expect(hint.title == "Add npm to search more")
        #expect(hint.target == .package("helper:npm"))
        #expect(hint.home == MenuLayout.installSection(.tools))
        #expect(hint.detail == "\(Helper.npm.unlocks) · brew install node")
        #expect(!MenuEntries.isSearching(hint))
        let brew = try #require(MenuEntries.found([], query: q, hint: Helper.searchHint(installed: [])).first)
        #expect(brew.title == "Add Homebrew to search more" && brew.home == MenuLayout.installSection(.homebrew))
        #expect(MenuEntries.found(groups, query: q, hint: Helper.searchHint(installed: ["homebrew", "npm", "cargo"])).count == 1)
        // It shows in Install's search with the rest, under Package tools.
        var nav = MenuNavigator(entries: [], branch: .install)
        nav.provide(.package, home: .homebrew, rows)
        nav.query = "ripgrep"
        #expect(nav.rows.map(\.title).contains("Add npm to search more"))
    }

    @Test("The menu's Searching row names the sources still asked, sits where their answers land, and goes once all answered")
    func searchingRow() throws {
        let q = Q("kilo")!
        let rows = MenuEntries.found([], query: q, waiting: [.appStore, .github])
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.title == "Searching App Store, GitHub…")
        #expect(row.home == MenuLayout.installSection(.appStore))
        #expect(row.target == .package("page:https://www.google.com/search?q=kilo"))
        #expect(MenuEntries.found([], query: q).isEmpty)
        // Shown in Install as soon as it is provided, whatever the catalogue holds.
        var nav = MenuNavigator(entries: [], branch: .install)
        nav.provide(.package, home: .homebrew, rows)
        nav.query = "kilo"
        #expect(nav.rows.map(\.title) == ["Searching App Store, GitHub…"])
    }

    /// One source's answer for `q`: a result per title, each its own download.
    static func group(_ source: InstallSearch.Source, _ titles: String...) -> InstallSearch.Group {
        InstallSearch.Group(source: source, results: titles.map {
            InstallSearch.Result(title: $0, via: source.title, source: source, method: .download(URL(string: "https://example.com/\($0).dmg")!))
        })
    }

    /// Install's rows as each answer lands, the way the panel provides them; the selected title after each.
    static func streamed(_ order: [InstallSearch.Group], move: (Int, Int)? = nil) -> [String?] {
        let q = Q("raycast")!
        var nav = MenuNavigator(entries: [], branch: .install)
        nav.query = "raycast"
        nav.provide(.package, home: .homebrew, MenuEntries.searching(q, waiting: InstallSearch.Source.allCases))
        var landed: [InstallSearch.Group] = [], picked: [String?] = []
        for (i, g) in order.enumerated() {
            landed.append(g)
            let waiting = InstallSearch.Source.allCases.filter { s in !landed.contains { $0.source == s } }
            nav.provide(.package, home: .homebrew, MenuEntries.found(InstallSearch.inOrder(landed), query: q, waiting: waiting))
            if let (after, steps) = move, after == i { for _ in 0..<steps { _ = nav.handle(.down) } }
            picked.append(nav.selected?.title)
        }
        return picked
    }

    @Test("Return takes the first result however the sources answer: the web row only when it is the only row (Sven 2026-10-12)")
    func selectionStaysFirst() {
        let web = Self.group(.web, "Search the web for “raycast”")
        let brew = Self.group(.homebrew, "raycast"), hub = Self.group(.github, "raycast/extensions")
        let tools = Self.group(.tools, "raycast-cli"), store = Self.group(.appStore)
        // Web first: the Searching row stays selected (it searches the web too), then the first result once one lands.
        let webFirst = Self.streamed([web, brew, hub, tools, store])
        #expect(webFirst.first == "Searching Homebrew, App Store, GitHub, Package tools…")
        #expect(Array(webFirst.dropFirst()) == ["raycast", "raycast", "raycast", "raycast"])
        // Web last, as Sven saw it: never the web row.
        #expect(Self.streamed([brew, hub, tools, store, web]) == ["raycast", "raycast", "raycast", "raycast", "raycast"])
        #expect(Self.streamed([hub, tools, store, web, brew]).last == "raycast")
        // Only the web answered anything: then it is the row.
        #expect(Self.streamed([store, web, Self.group(.homebrew), Self.group(.github), Self.group(.tools)]).last == "Search the web for “raycast”")
    }

    @Test("A row the user moved to stays selected as later sources land")
    func movedSelectionKept() {
        let web = Self.group(.web, "Search the web for “raycast”")
        let brew = Self.group(.homebrew, "raycast", "raycast-beta"), hub = Self.group(.github, "raycast/extensions")
        let picked = Self.streamed([brew, hub, web, Self.group(.tools, "raycast-cli"), Self.group(.appStore)], move: (0, 1))
        #expect(picked == ["raycast-beta", "raycast-beta", "raycast-beta", "raycast-beta", "raycast-beta"])
    }

    @Test("Nothing matches is said only once every source answered empty")
    func nothing() async {
        let empty = await InstallSearch.search(Q("zzqx")!, tools: [], brew: nil) { _ in .missing }
        #expect(InstallSearch.nothingFound(empty))
        #expect(empty.last?.results.first?.detail == InstallSearch.nothingLine)
        let found = await InstallSearch.search(Q("rectangle")!, tools: [], brew: nil, fetch: Self.network)
        #expect(!InstallSearch.nothingFound(found))
        #expect(found.last?.results.first?.detail == "")
    }

    // MARK: The cache

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
    actor Count { var n = 0; func add() { n += 1 } }

    @Test("The cache answers a repeat for ten minutes, keeps no failure, and asks a limited bucket nothing until it lifts")
    func cache() async {
        let clock = Clock(), count = Count()
        let cache = InstallSearch.Cache(now: { clock.now })
        let url = URL(string: "https://api.github.com/repos/o/r/releases/latest")!
        let ok: InstallSearch.Fetch = { _ in await count.add(); return .ok(Data()) }
        _ = await cache.fetch(url, via: ok)
        _ = await cache.fetch(url, via: ok)
        #expect(await count.n == 1)
        clock.now = clock.now.addingTimeInterval(601)
        _ = await cache.fetch(url, via: ok)
        #expect(await count.n == 2)

        let failing: InstallSearch.Fetch = { _ in await count.add(); return .trouble(.offline) }
        let other = URL(string: "https://registry.npmjs.org/-/v1/search?text=x")!
        _ = await cache.fetch(other, via: failing)
        _ = await cache.fetch(other, via: failing)
        #expect(await count.n == 4, "a failure is asked again")

        // The search bucket's limit holds back the next search, not the other asks.
        let until = clock.now.addingTimeInterval(120)
        let search = URL(string: "https://api.github.com/search/repositories?q=a")!, next = URL(string: "https://api.github.com/search/repositories?q=b")!
        _ = await cache.fetch(search, via: { _ in .trouble(.limited(until: until)) })
        #expect(await cache.fetch(next, via: ok) == .trouble(.limited(until: until)))
        #expect(await count.n == 4)
        #expect(await cache.fetch(URL(string: "https://api.github.com/repos/o/s/releases/latest")!, via: ok) == .ok(Data()))
        clock.now = until.addingTimeInterval(1)
        #expect(await cache.fetch(next, via: ok) == .ok(Data()))
    }

    @Test("brew's answers are kept too, so typing the same name again runs no brew")
    func cacheBrew() async {
        let count = Count(), cache = InstallSearch.Cache()
        let run: InstallSearch.Brew = { _ in await count.add(); return "x" }
        _ = await cache.brew(["search", "--cask", "x"], via: run)
        _ = await cache.brew(["search", "--cask", "x"], via: run)
        #expect(await count.n == 1)
    }

    // MARK: How each installs

    @Test("A key names its package, its GitHub download or its page, and only on the hosts Install opens")
    func keys() {
        let asset = URL(string: "https://github.com/rxhanson/Rectangle/releases/download/v2.0.3/Rectangle2.0.3.dmg")!
        for method in [InstallSearch.Method.package(Package(.go, "github.com/jesseduffield/lazygit")!), .download(asset),
                       .page(URL(string: "macappstore://apps.apple.com/app/id416970936")!), .page(InstallSearch.webURL(Q("8 ball pool")!))] {
            #expect(InstallSearch.Method(key: method.key) == method)
        }
        #expect(InstallSearch.Method(key: "page:https://evil.example/x") == nil)
        #expect(InstallSearch.Method(key: "page:file:///etc/passwd") == nil)
        #expect(InstallSearch.Method(key: "asset:https://github.com/o/r/archive/main.zip") == nil)
        #expect(InstallSearch.Method(key: "asset:https://example.com/o/r/releases/download/v1/x.dmg") == nil)
    }

    @Test("A release's file downloads to Downloads and opens; the URL is quoted, a file name with shell text refused")
    func download() {
        let asset = URL(string: "https://github.com/rxhanson/Rectangle/releases/download/v2.0.3/Rectangle2.0.3.dmg")!
        #expect(InstallSearch.downloadCommand(asset)
                == "curl -fL --progress-bar -o ~/Downloads/Rectangle2.0.3.dmg 'https://github.com/rxhanson/Rectangle/releases/download/v2.0.3/Rectangle2.0.3.dmg' && open ~/Downloads/Rectangle2.0.3.dmg")
        #expect(InstallSearch.downloadCommand(URL(string: "https://github.com/o/r/releases/download/v1/a%3Bb.dmg")!) == nil)
        #expect(Package(.pipx, "httpie")?.remove == "pipx uninstall httpie")
        #expect(Package(.cargo, "ripgrep")?.install == "cargo install ripgrep")
    }

    // MARK: The menu

    @Test("In the menu each source heads its own rows, in the sources' order, after the catalogue's matches and before the branches")
    func menu() async throws {
        let catalogue = MenuEntries.install([CatalogueEntry(id: "rectangle-app", name: "Rectangle Pro", category: "Utilities",
                                                            method: .package(Package(.cask, "rectangle-pro")!), check: .bundle("x"),
                                                            vendor: "https://rectangleapp.com/", checked: "2026-10-09")], installed: [])
        let query = Q("rectangle")!
        let groups = await InstallSearch.search(query, tools: [.npm], brew: { arguments in
            arguments == ["search", "--cask", "rectangle"] ? "rect\n"
                : arguments == ["info", "--json=v2", "--cask", "rect"]
                ? #"{"formulae": [], "casks": [{"full_token": "rect", "desc": "Move windows", "installed": null}]}"# : ""
        }, fetch: { url in
            url.host() == "api.github.com" ? .trouble(.limited(until: nil)) : await Self.network(url)
        })
        let rows = MenuEntries.found(groups, query: query)
        #expect(rows.allSatisfy { !$0.inSearch && $0.keywords == "rectangle" })
        let limited = try #require(rows.first { $0.title == "Search GitHub on the web" })
        #expect(limited.target == .package("page:https://github.com/search?q=rectangle&type=repositories"))

        for branch in [MenuBranch.install, .homebrew] {
            var nav = MenuNavigator(entries: catalogue, branch: branch)
            nav.provide(.package, home: .homebrew, rows)
            nav.query = "rectangle"
            let heads = MenuGroups.headings(nav.rows, searching: false, branch: branch).sorted { $0.key < $1.key }.map(\.value)
            let sources: [MenuGroups.Group] = [.section("Homebrew"), .section("GitHub"), .section("Web")]
            #expect(heads == (branch == .install ? [.section("Catalogue")] + sources : sources), "\(branch)")
            #expect(nav.rows.last?.title == "Search the web for “rectangle”")
        }
        var nav = MenuNavigator(entries: catalogue, branch: .install)
        nav.provide(.package, home: .homebrew, rows)
        nav.provide(.package, home: .homebrew, [])
        nav.query = "rectangle"
        #expect(nav.rows.map(\.title) == ["Rectangle Pro"], "clearing the search leaves the catalogue")
    }
}
