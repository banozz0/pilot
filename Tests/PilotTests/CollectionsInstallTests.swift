import Foundation
@testable import PilotCore
import Testing
import WebApps
@testable import Pilot

/// CLI W16: Install's catalogue, its search, Get and Remove as `pilot list catalogue|removable`, `pilot install` and
/// `pilot remove removable`. Nothing installs, nothing is searched on the network and no browser opens: the catalogue
/// is a fixture, the search and Remove's rows are the test's, the terminal and the page opener are recorders and the
/// Trash is a temp folder. The gate's decider is the test's; no prompt shows.
@MainActor
@Suite("Collections: install catalogue, search and remove")
final class CollectionsInstallTests {
    let home = URL(filePath: NSTemporaryDirectory()).appending(path: "pilot-install-\(UUID().uuidString)", directoryHint: .isDirectory)
    let install = ControlInstall()
    let verbs = ControlVerbs()
    var asked: [ControlGate.Ask] = []
    var allow = false
    var ran: [(command: String, title: String, onSuccess: String)] = []
    var opened: [URL] = []
    var recommend = true
    var installedIDs: Set<String> = ["obsidian"]
    var reads = 0, measures = 0
    var rows: [RemoveRow]? = []
    var searched: [String] = []
    var groups: [InstallSearch.Group] = []
    var helpers: Set<String> = ["homebrew", "mole"]

    static let entries = [
        CatalogueEntry(id: "obsidian", name: "Obsidian", category: "Notes", method: .package(Package(.cask, "obsidian")!), check: .bundle("md.obsidian"),
                       vendor: "https://obsidian.md", checked: "2026-10-01"),
        CatalogueEntry(id: "hello", name: "Hello", category: "Tools", method: .package(Package(.formula, "hello")!), check: .command("hello"),
                       vendor: "https://gnu.org/software/hello", checked: "2026-10-01"),
        CatalogueEntry(id: "zen", name: "Zen", category: "Browsers", method: .download("https://zen-browser.app/download"),
                       check: .bundle("app.zen-browser.zen"), vendor: "https://zen-browser.app", checked: "2026-10-01"),
        CatalogueEntry(id: "hermes-context", name: "Hermes context", category: "Tools",
                       method: .script("https://github.com/o/r/releases/download/v1/install.sh"), check: .command("hermes-context"),
                       vendor: "https://github.com/o/r", checked: "2026-10-01"),
    ]

    init() throws {
        try FileManager.default.createDirectory(at: home.appending(path: "Trash"), withIntermediateDirectories: true)
        install.gate = ControlGate(wait: .seconds(5)) { [unowned self] ask, _ in asked.append(ask); return allow }
        install.entries = { Self.entries }
        install.isInstalled = { [unowned self] in installedIDs.contains($0.id) }
        install.helpers = { [unowned self] in helpers }
        install.recommend = { [unowned self] in recommend }
        install.search = { [unowned self] text in
            await MainActor.run { searched.append(text) }
            return await (InstallSearch.Query(text)!, MainActor.run { groups })
        }
        install.removeRows = { [unowned self] in await MainActor.run { reads += 1; return rows } }
        install.measure = { [unowned self] rows in
            await MainActor.run { measures += 1 }
            return rows.map { var r = $0; r.size = 1_000; return r }
        }
        install.run = { [unowned self] in ran.append(($0, $1, $2)) }
        install.open = { [unowned self] in opened.append($0) }
        install.trash = { [home] url in
            let to = home.appending(path: "Trash/\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: to)
            return to
        }
        install.webApps = home.appending(path: "Applications")
        verbs.registerInstall(install)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func answer(_ verb: String, _ args: [String]) async -> ControlAnswer {
        await verbs.answer(ControlRequest(id: .number(1), verb: verb, args: args), peer: nil)
    }

    func list(_ collection: String) async -> [[String: JSONValue]] {
        guard case .array(let rows) = await answer("list", [collection]).result else { Issue.record("list \(collection) gave no rows"); return [] }
        return rows.compactMap { if case .object(let row) = $0 { row } else { nil } }
    }

    @Test("list catalogue reads each entry with how it installs and whether it is installed; none while Recommend apps is off")
    func catalogue() async {
        let listed = await list("catalogue")
        #expect(listed.map { $0["key"] } == ["cask:obsidian", "formula:hello", "download:zen", "download:hermes-context"].map { .string($0) })
        #expect(listed[0] == ["key": .string("cask:obsidian"), "id": .string("obsidian"), "name": .string("Obsidian"), "category": .string("Notes"),
                              "via": .string("Homebrew app"), "installed": .bool(true), "vendor": .string("https://obsidian.md"),
                              "checked": .string("2026-10-01"), "command": .string("brew install --cask obsidian")])
        #expect(listed[2]["page"] == .string("https://zen-browser.app/download") && listed[2]["command"] == nil)
        #expect(listed[3]["command"] == .string("curl -fsSL 'https://github.com/o/r/releases/download/v1/install.sh' | sh"))
        recommend = false
        #expect(await list("catalogue").isEmpty)
        #expect(await answer("add", ["catalogue", "--key", "x"]).error == ControlError(.badValue, "catalogue is read-only"))
    }

    @Test("install search answers the catalogue's matches and every source's results and trouble, as the page shows them")
    func search() async {
        groups = [
            InstallSearch.Group(source: .homebrew, results: [
                InstallSearch.Result(title: "Obsidian", via: "Homebrew app", detail: "Knowledge base", source: .homebrew,
                                     method: .package(Package(.cask, "obsidian")!), installed: true),
                InstallSearch.Result(title: "Rectangle.dmg", via: "GitHub release · Rectangle.dmg", source: .github,
                                     method: .download(URL(string: "https://github.com/rxhanson/Rectangle/releases/download/v1/Rectangle.dmg")!)),
            ], trouble: nil),
            InstallSearch.Group(source: .github, results: [], trouble: .offline),
        ]
        let found = await answer("install", ["search", "obsid", "ian"])
        #expect(searched == ["obsid ian"])
        guard case .object(let o) = found.result else { Issue.record("no answer: \(String(describing: found.error))"); return }
        // The catalogue may answer "obsid ian" now: a typo finds its best match (Sven, 2026-10-19).
        #expect(o["query"] == .string("obsid ian"))
        #expect(o["groups"] == .array([
            .object(["source": .string("homebrew"), "title": .string("Homebrew"), "results": .array([
                .object(["key": .string("cask:obsidian"), "title": .string("Obsidian"), "via": .string("Homebrew app"), "detail": .string("Knowledge base"),
                         "installed": .bool(true), "command": .string("brew install --cask obsidian")]),
                .object(["key": .string("asset:https://github.com/rxhanson/Rectangle/releases/download/v1/Rectangle.dmg"), "title": .string("Rectangle.dmg"),
                         "via": .string("GitHub release · Rectangle.dmg"), "detail": .string(""), "installed": .bool(false),
                         "command": .string(InstallSearch.downloadCommand(URL(string: "https://github.com/rxhanson/Rectangle/releases/download/v1/Rectangle.dmg")!)!)]),
            ])]),
            .object(["source": .string("github"), "title": .string("GitHub"), "results": .array([]),
                     "trouble": .string("Offline, so GitHub was not searched")]),
        ]))

        guard case .object(let matched) = await answer("install", ["search", "obsidian"]).result else { return }
        guard case .array(let inCatalogue) = matched["catalogue"] else { return }
        #expect(inCatalogue.count == 1)
        recommend = false
        guard case .object(let off) = await answer("install", ["search", "obsidian"]).result else { return }
        #expect(off["catalogue"] == .array([]), "with Recommend apps off the catalogue offers nothing")

        #expect(await answer("install", ["search", "o"]).error?.code == .badValue)
        #expect(await answer("install", ["search", "-rf"]).error?.code == .badValue)
        #expect(searched.count == 3, "a refused query searches nothing")
    }

    @Test("install pick: installed says so; a vendor's https page opens unasked; a script and a package ask with the command")
    func pickCatalogue() async {
        #expect(await answer("install", ["pick", "obsidian"]).result == .object(["key": .string("cask:obsidian"), "name": .string("Obsidian"), "installed": .bool(true)]))
        #expect(await answer("install", ["pick", "download:zen"]).result == .object(["key": .string("download:zen"), "opened": .string("https://zen-browser.app/download")]))
        #expect(opened == [URL(string: "https://zen-browser.app/download")!] && asked.isEmpty)

        #expect(await answer("install", ["pick", "hermes-context"]).error?.code == .denied && ran.isEmpty)
        #expect(await answer("install", ["pick", "formula:hello"]).error?.code == .denied && ran.isEmpty)
        let script = "curl -fsSL 'https://github.com/o/r/releases/download/v1/install.sh' | sh"
        #expect(asked == [ControlGate.Ask("Install Hermes context", script), ControlGate.Ask("Install package", "brew install hello")])

        allow = true
        #expect(await answer("install", ["pick", "download:hermes-context"]).ok)
        #expect(await answer("install", ["pick", "formula:hello"]).ok)
        #expect(ran.map(\.command) == [script, "brew install hello"])
        #expect(ran.map(\.title) == ["Install Hermes context", "Install Hello"])
        #expect(ran.map(\.onSuccess) == [VisibleRun.waitForReturn, "open -g 'pilot://installed?package=formula:hello'"])
    }

    @Test("install pick on a search row: a GitHub file asks with its download; an https page opens; the App Store app asks; a foreign key is refused")
    func pickSearchRow() async {
        let asset = URL(string: "https://github.com/rxhanson/Rectangle/releases/download/v1/Rectangle.dmg")!
        let command = InstallSearch.downloadCommand(asset)!
        allow = true
        #expect(await answer("install", ["pick", "asset:\(asset.absoluteString)"]).ok)
        #expect(asked == [ControlGate.Ask("Install Rectangle.dmg", command)] && ran.map(\.command) == [command])

        #expect(await answer("install", ["pick", "page:https://apps.apple.com/app/id497799835"]).ok)
        #expect(asked.count == 1 && opened == [URL(string: "https://apps.apple.com/app/id497799835")!], "an https page asks nothing")
        #expect(await answer("install", ["pick", "page:macappstore://apps.apple.com/app/id497799835"]).ok)
        #expect(asked.last == ControlGate.Ask("Open link", "macappstore://apps.apple.com/app/id497799835") && opened.count == 2)

        #expect(await answer("install", ["pick", "cask:zed"]).ok && asked.last == ControlGate.Ask("Install package", "brew install --cask zed"))
        for foreign in ["page:https://evil.example/x", "asset:https://example.com/x.dmg", "rm -rf ~", "download:nope"] {
            #expect(await answer("install", ["pick", foreign]).error?.code == .badValue, "\(foreign)")
        }
        #expect(await answer("install", ["pick"]).error?.code == .badRequest)
        #expect(await answer("install", ["get", "x"]).error?.code == .badValue)
        #expect(await answer("install", ["pick", "cask:zed", "--yes"]).error?.code == .unknownFlag)
        #expect(asked.count == 3 && opened.count == 2)
    }

    @Test("list helpers reads each helper with what it unlocks, whether it is installed and how it installs")
    func listHelpers() async {
        let listed = await list("helpers")
        #expect(listed.map { $0["id"] } == ["homebrew", "mole", "mas", "npm", "cargo"].map { .string($0) })
        #expect(listed.map { $0["installed"] } == [true, true, false, false, false].map { .bool($0) })
        #expect(listed[3] == ["id": .string("npm"), "name": .string("npm"), "installed": .bool(false), "unlocks": .string(Helper.npm.unlocks),
                              "how": .string(Helper.npm.how), "command": .string("brew install node")])
        #expect(await answer("add", ["helpers", "--id", "x"]).error == ControlError(.badValue, "helpers is read-only"))
    }

    @Test("install helper asks Allow like other installs: a formula as a package, Homebrew's installer with its command; installed says so")
    func installHelper() async {
        #expect(await answer("install", ["helper", "mole"]).result == .object(["id": .string("mole"), "name": .string("Mole"), "installed": .bool(true)]))
        #expect(await answer("install", ["helper", "npm"]).error?.code == .denied && ran.isEmpty)
        #expect(asked == [ControlGate.Ask.install(.package, "brew install node")])
        allow = true
        #expect(await answer("install", ["helper", "npm"]).ok)
        #expect(ran.map(\.command) == ["brew install node"] && ran.map(\.title) == ["Install npm"])
        #expect(ran.map(\.onSuccess) == ["open -g 'pilot://installed?package=formula:node'"])

        helpers = []
        #expect(await answer("install", ["helper", "cargo"]).error?.code == .notReady, "a formula waits for Homebrew")
        #expect(await answer("install", ["helper", "homebrew"]).ok)
        #expect(asked.last == ControlGate.Ask("Install Homebrew", Helper.homebrew.install))
        #expect(ran.last?.command == Helper.homebrew.install && ran.last?.onSuccess == VisibleRun.waitForReturn)
        #expect(await answer("install", ["helper", "yarn"]).error?.code == .badValue)
        #expect(await answer("install", ["helper"]).error?.code == .badRequest)
        #expect(ran.count == 2)
    }

    /// Remove's four kinds of row, as InstallModule.removeRows reads them.
    func removeFixture() throws -> (app: URL, web: InstalledWebApp) {
        let app = home.appending(path: "Applications/Old.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let web = try WebAppStamper.stamp(try WebAppSpec(name: "Linear", url: "https://linear.app"), template: URL(filePath: "/usr/bin/true"),
                                          into: home.appending(path: "Applications"), icon: nil, signingIdentity: "-")
        let installed = try #require(WebAppDirectory.read(web))
        var zed = RemoveRow(source: .package(Package(.cask, "zed")!), name: "Zed", app: "/Applications/Zed.app")
        zed.pilot = true
        zed.lastUsed = Date(timeIntervalSince1970: 1_790_000_000)
        rows = [RemoveRow(source: .app(path: app.path), name: "Old"), RemoveRow(source: .webApp(bundleID: installed.bundleID), name: "Linear"),
                RemoveRow(source: .npm("typescript", prefix: "/opt/homebrew"), name: "typescript"),
                RemoveRow(source: .package(Package(.formula, "openssl@3")!), name: "openssl@3", needed: true), zed]
        return (app, installed)
    }

    @Test("list removable reads Remove's rows, measured and Pilot's installs first, web apps last")
    func listRemovable() async throws {
        _ = try removeFixture()
        let listed = await list("removable")
        #expect(listed.map { $0["name"] } == ["Zed", "Old", "openssl@3", "typescript", "Linear"].map { .string($0) })
        #expect(listed[0] == ["key": .string("cask:zed"), "name": .string("Zed"), "category": .string("Apps"), "origin": .string("Homebrew cask"),
                              "pilot": .bool(true), "needed": .bool(false), "appStore": .bool(false), "system": .bool(false), "app": .string("/Applications/Zed.app"),
                              "lastUsed": .string(Date(timeIntervalSince1970: 1_790_000_000).ISO8601Format()), "size": .number(1_000)])
        #expect(listed[2]["needed"] == .bool(true) && listed[3]["key"] == .string("npm:/opt/homebrew:typescript"))
        #expect(reads == 1 && measures == 1)
        rows = nil
        #expect(await answer("list", ["removable"]).error?.code == .notReady)
    }

    @Test("remove removable asks per kind: a package or npm tool with its command, an app or web app before the Trash")
    func removeRemovable() async throws {
        let (app, web) = try removeFixture()
        _ = await list("removable")
        for key in ["cask:zed", "npm:/opt/homebrew:typescript", "app:\(app.path)", "webapp:\(web.bundleID)"] {
            #expect(await answer("remove", ["removable", key]).error?.code == .denied, "\(key)")
        }
        #expect(asked == [ControlGate.Ask("Remove package", "brew uninstall --cask zed"),
                          ControlGate.Ask("Remove package", "\(UpdateList.npm("uninstall", prefix: "/opt/homebrew")) typescript"),
                          ControlGate.Ask("Remove app", "Old: move Old.app to the Trash"),
                          ControlGate.Ask("Remove web app", "Linear: move Linear.app to the Trash")])
        #expect(ran.isEmpty && FileManager.default.fileExists(atPath: app.path))
        #expect(reads == 1, "remove acts on the rows the list read")

        allow = true
        #expect(await answer("remove", ["removable", "app:\(app.path)"]).result
                == .object(["key": .string("app:\(app.path)"), "name": .string("Old"), "trashed": .string(home.appending(path: "Trash/Old.app").path(percentEncoded: false))]))
        #expect(await answer("remove", ["removable", "webapp:\(web.bundleID)"]).ok)
        #expect(!FileManager.default.fileExists(atPath: app.path) && WebAppDirectory.list(in: install.webApps).isEmpty)
        #expect(await answer("remove", ["removable", "app:\(app.path)"]).error?.code == .badValue, "gone from the kept rows")

        #expect(await answer("remove", ["removable", "npm:/opt/homebrew:typescript"]).ok)
        #expect(ran.map(\.command) == ["\(UpdateList.npm("uninstall", prefix: "/opt/homebrew")) typescript"])
        #expect(ran.first?.onSuccess == "open -g 'pilot://removed?package=npm:typescript'", "the record forgets it by its record key")
        #expect(await answer("remove", ["removable", "cask:zed"]).ok, "after a command the rows are read again")
        #expect(reads == 2 && ran.last?.command == "brew uninstall --cask zed")
        #expect(await answer("remove", ["removable", "cask:nope"]).error?.code == .badValue)
    }
}
