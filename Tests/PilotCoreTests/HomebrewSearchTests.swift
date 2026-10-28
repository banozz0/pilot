import Foundation
import Testing
@testable import PilotCore

/// Install → Search Homebrew (story 82; wireframe wo-nZ-ZEKkY section 10), Install's search's Homebrew source since N9:
/// `brew search --formula` and `--cask` give names, one `brew info --json=v2` per kind gives each its description. Pure:
/// fixtures captured read-only on 2026-10-05, cask names kept short so the commit guard's token rule does not read
/// `full_token` as a credential.
@Suite("Homebrew search")
struct HomebrewSearchTests {
    static let info = Data("""
    {"formulae": [{"name": "cowsay", "full_name": "cowsay", "desc": "Apjanke's fork of the classic cowsay project", "installed": []},
                  {"name": "git-lfs", "full_name": "git-lfs", "desc": "Git extension for versioning large files",
                   "installed": [{"version": "3.7.1"}]}],
     "casks": [{"full_token": "ghostex", "name": ["Ghostex"],
                "desc": "Workspace for running and reviewing multiple CLI coding agents", "installed": "5.5.0", "auto_updates": true,
                "homepage": "https://ghostex.dev/"},
               {"full_token": "zed", "name": ["Zed"], "desc": null, "installed": null}]}
    """.utf8)

    @Test("The parser lists each formula and cask with its description, how it installs, whether it is installed and a cask's site icon")
    func parse() throws {
        let rows = try InstallSearch.brewResults(Self.info)
        #expect(rows.map(\.title) == ["cowsay", "git-lfs", "ghostex", "zed"])
        #expect(rows.map(\.detail) == ["Apjanke's fork of the classic cowsay project", "Git extension for versioning large files",
                                       "Workspace for running and reviewing multiple CLI coding agents", "Zed"])
        #expect(rows.map(\.via) == ["Homebrew tool", "Homebrew tool", "Homebrew app", "Homebrew app"])
        #expect(rows.map(\.installed) == [false, true, true, false])
        #expect(rows.map(\.key) == ["formula:cowsay", "formula:git-lfs", "cask:ghostex", "cask:zed"])
        #expect(rows.map(\.image) == [nil, nil, "https://ghostex.dev/apple-touch-icon.png", nil])
        #expect(rows.allSatisfy { $0.source == .homebrew })
    }

    @Test("brew search's lines become names, unsafe ones dropped, the first ten kept")
    func names() {
        #expect(InstallSearch.names("cowsay\n\nponysay\n-rf\nbad name\n") == ["cowsay", "ponysay"])
        #expect(InstallSearch.names((1...30).map { "pkg\($0)" }.joined(separator: "\n")).count == InstallSearch.brewNames)
        #expect(InstallSearch.brewNames == 10)
    }

    @Test("Homebrew is asked from the second character, only for a name no shell or brew flag can read into; spaces become hyphens")
    func query() {
        #expect(InstallSearch.Query("co")?.brewName == "co")
        #expect(InstallSearch.Query("git-lfs")?.brewName == "git-lfs")
        #expect(InstallSearch.Query("c") == nil)
        #expect(InstallSearch.Query("--help") == nil)
        #expect(InstallSearch.Query("  Visual   Studio Code ")?.brewName == "visual-studio-code")
        #expect(InstallSearch.Query("x;rm")?.brewName == nil)
    }

    @Test("Search Homebrew is Install's first row; its results are found only inside it, ranked by what is typed")
    func branch() throws {
        let catalogue = MenuEntries.install([CatalogueEntry(id: "coteditor", name: "CotEditor", category: "Editors",
                                                            method: .package(Package(.cask, "coteditor")!),
                                                            check: .bundle("com.coteditor.CotEditor"), vendor: "https://coteditor.com/",
                                                            checked: "2026-10-05")], installed: [])
        let entries = MenuEntries.build(apps: [], actions: [], store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                        openID: { "apps.open:\($0)" }, running: []) + catalogue
        var nav = MenuNavigator(entries: entries, branch: .install)
        #expect(nav.rows.first?.target == .branch(.homebrew))
        #expect(nav.rows.first?.title == "Search packages")
        // Card agent-bo-95422994, G13: Make a web app follows, before the catalogue's categories.
        let webApp = MenuEntries.build(apps: [], actions: [BindsPage.ActionInfo(id: "apps.webApp", label: "Make a web app", module: "apps")],
                                       store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                       openID: { "apps.open:\($0)" }, running: []) + catalogue
        #expect(MenuNavigator(entries: webApp, branch: .install).rows.prefix(2).map(\.target) == [.branch(.homebrew), .action("apps.webApp")])
        #expect(nav.handle(.return) == .handled)
        #expect(nav.path == [.install, .homebrew])
        let cow = InstallSearch.Query("cow")!
        nav.provide(.package, home: .homebrew, MenuEntries.found([.init(source: .homebrew, results: try InstallSearch.brewResults(Self.info))], query: cow)
            .filter { $0.title == "cowsay" })
        nav.query = "cow"
        #expect(nav.rows.map(\.title) == ["cowsay"])
        #expect(nav.handle(.return) == .run(nav.rows[0]))
        _ = nav.handle(.escape)
        _ = nav.handle(.escape)
        nav.query = "cotedit"
        #expect(nav.matched.map(\.target) == [.package("cask:coteditor")])  // the catalogue's, not a Homebrew row
        #expect(nav.rows[0].home == .category("Editors"))
    }
}

/// The Homebrew source's steps against a fake brew (story 82): the order, the per-kind lookups and what an empty search
/// skips.
@Suite("Homebrew search steps")
struct HomebrewSearchStepsTests {
    actor Calls { var all: [[String]] = []; func add(_ c: [String]) { all.append(c) } }

    @Test("Each kind searches, then asks brew info for its names; a kind with no hits asks nothing more")
    func steps() async {
        let calls = Calls()
        let rows = await InstallSearch.homebrewResults(InstallSearch.Query("cowsay")!) { arguments in
            await calls.add(arguments)
            switch arguments {
            case ["search", "--formula", "cowsay"]: return "cowsay\n"
            case ["search", "--cask", "cowsay"]: return ""
            case ["info", "--json=v2", "--formula", "cowsay"]:
                return #"{"formulae": [{"full_name": "cowsay", "desc": "Talking cow", "installed": []}], "casks": []}"#
            default: return ""
            }
        }
        #expect(rows.map(\.title) == ["cowsay"])
        #expect(rows.first?.detail == "Talking cow")
        let all = await calls.all
        #expect(Set(all) == [["search", "--formula", "cowsay"], ["search", "--cask", "cowsay"], ["info", "--json=v2", "--formula", "cowsay"],
                             ["info", "--json=v2", "cowsay"]])
        #expect(all.firstIndex(of: ["search", "--formula", "cowsay"])! < all.firstIndex(of: ["info", "--json=v2", "--formula", "cowsay"])!)
    }

    /// Card agent-bo-95423304: Sven typed easy-cd, a cask in his own tap, and got nothing; brew info knows it by name. The
    /// tap and cask are short stand-ins (u/t/ecd), so the commit guard does not read `full_token` as a credential.
    @Test("A package brew search misses is still found by its exact name, a tap's included, once")
    func exactName() async {
        let rows = await InstallSearch.homebrewResults(InstallSearch.Query("ecd")!) { arguments in
            switch arguments {
            case ["search", "--formula", "ecd"]: return "ecdh\n"
            case ["info", "--json=v2", "--formula", "ecdh"]:
                return #"{"formulae": [{"full_name": "ecdh", "desc": "Key tool", "installed": []}], "casks": []}"#
            case ["info", "--json=v2", "ecd"]:
                return #"{"formulae": [], "casks": [{"full_token": "u/t/ecd", "desc": "Folder picker", "installed": null}]}"#
            default: return ""
            }
        }
        #expect(rows.map(\.title) == ["ecdh", "u/t/ecd"])
        #expect(rows.last?.key == "cask:u/t/ecd")
        var nav = MenuNavigator(entries: [], branch: .homebrew)
        nav.provide(.package, home: .homebrew, MenuEntries.found([.init(source: .homebrew, results: rows)], query: InstallSearch.Query("ecd")!))
        nav.query = "ecd"
        #expect(nav.rows.map(\.title).contains("u/t/ecd"))

        let twice = await InstallSearch.homebrewResults(InstallSearch.Query("cowsay")!) { arguments in
            switch arguments {
            case ["search", "--formula", "cowsay"]: return "cowsay\n"
            case ["info", "--json=v2", "--formula", "cowsay"], ["info", "--json=v2", "cowsay"]:
                return #"{"formulae": [{"full_name": "cowsay", "desc": "Talking cow", "installed": []}], "casks": []}"#
            default: return ""
            }
        }
        #expect(twice.map(\.title) == ["cowsay"], "a name both found and asked for shows once")
    }

    @Test("Typed searches start at the second character, files and Homebrew alike")
    func minimum() {
        #expect(MenuNavigator.minimumQuery == 2)
        #expect(FileSearch.query(for: "a") == nil)
        #expect(InstallSearch.Query("a") == nil)
    }
}

/// A child process stops when its task is cancelled, so a superseded search frees its brew at once.
@Suite("Child process")
struct ChildProcessCancelTests {
    @Test("Cancelling the task terminates the child and throws CancellationError, not its exit")
    func cancel() async {
        let start = ContinuousClock.now
        let task = Task { try await ChildProcess.run("/bin/sleep", ["30"]) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(8), "well under the child's 30 s; loose so a loaded machine passes")
        #expect(throws: CancellationError.self) { try result.get() }
    }

    /// Card agent-bo-95423085: a cancel just before launch found no child to stop, so it ran to its timeout.
    @Test("Cancelling just before the child launches never leaves it running")
    func cancelBeforeLaunch() async {
        let reached = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        let start = ContinuousClock.now
        let task = Task {
            try await ChildProcess.run("/bin/sleep", ["30"], environment: nil, input: nil, timeout: .seconds(10), success: [0], lines: nil,
                                       launching: { reached.signal(); go.wait() })
        }
        await withCheckedContinuation { done in DispatchQueue.global().async { reached.wait(); done.resume() } }
        task.cancel()
        go.signal()
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(8), "well under the child's 30 s; loose so a loaded machine passes")
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
