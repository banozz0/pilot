import Foundation
import Testing
@testable import PilotCore

/// Remove (stories 84 and 98; SPEC.md, the Remove part of the Install line; wireframe wo-nZ-ZEKkY section 12): what
/// Homebrew has, Pilot's installs first, a needed formula marked, sorted three ways, web apps after. Pure: the fixture
/// is `brew info --json=v2 --installed`'s shape, captured read-only on 2026-10-05 and cut down.
@Suite("Remove list")
struct RemoveListTests {
    static let installed = Data("""
    {"formulae": [
       {"name": "hello", "full_name": "hello", "desc": "Program providing model for GNU coding standards", "dependencies": [],
        "installed": [{"version": "2.12.2", "installed_on_request": true}]},
       {"name": "abseil", "full_name": "abseil", "desc": "C++ Common Libraries", "dependencies": [],
        "installed": [{"version": "20250814.1", "installed_on_request": false}]},
       {"name": "protobuf", "full_name": "protobuf", "desc": "Protocol buffers", "dependencies": ["abseil"],
        "installed": [{"version": "33.0", "installed_on_request": true}]},
       {"name": "mpv", "full_name": "mpv", "desc": "Media player", "dependencies": [],
        "installed": [{"version": "0.40.0", "installed_on_request": false}]}],
     "casks": [
       {"full_token": "zed", "name": ["Zed"], "desc": "Multiplayer code editor", "installed": "0.205.4",
        "artifacts": [{"app": ["Zed.app"], "target": "/Applications/Zed.app"}]},
       {"full_token": "iina", "name": ["IINA"], "desc": null, "installed": "1.4.1",
        "artifacts": [{"binary": ["iina"], "target": "/opt/homebrew/bin/iina"}, {"app": ["IINA.app"]}],
        "depends_on": {"formula": ["mpv"], "macos": {">=": ["14"]}}}]}
    """.utf8)

    static func rows() throws -> [RemoveRow] {
        var rows = try RemoveList.parse(installed)
        rows.append(RemoveRow(source: .webApp(bundleID: "dev.banozz.pilot.webapp.x"), name: "X"))
        return rows
    }

    @Test("The parser lists formulae and casks; a formula an installed formula or cask needs carries the marker")
    func parse() throws {
        let rows = try RemoveList.parse(Self.installed)
        #expect(rows.map(\.name) == ["hello", "abseil", "protobuf", "mpv", "Zed", "IINA"])
        #expect(rows.map(\.needed) == [false, true, false, true, false, false])
        #expect(rows.map(\.key) == ["formula:hello", "formula:abseil", "formula:protobuf", "formula:mpv", "cask:zed", "cask:iina"])
        #expect(rows[4].app == "/Applications/Zed.app")
        #expect(rows[5].app == "/Applications/IINA.app")
        #expect(rows[0].app == nil)
        let entries = RemoveList.entries(rows).filter { if case .remove = $0.target { true } else { false } }
        #expect(entries[1].detail == "Homebrew formula · needed by other packages")
        #expect(entries.allSatisfy { $0.home?.parent == .remove && $0.target.key == nil })
        #expect(entries[0].target == .remove(.row("formula:hello")))
    }

    @Test("Pilot's installs come first, its uv tools among them, then the rest by name, web apps last")
    func pilotFirst() throws {
        var rows = try Self.rows()
        RemoveList.mark(&rows, pilot: ["formula:hello", "uv:telegram-tools"], lastUsed: [:])
        let sorted = RemoveList.sorted(rows, .pilotFirst)
        #expect(sorted.map(\.name) == ["hello", "telegram-tools", "abseil", "IINA", "mpv", "protobuf", "Zed", "X"])
        #expect(sorted[1].key == "uv:telegram-tools")
        #expect(RemoveList.entries(sorted).first { $0.title == "hello" }?.detail == "Homebrew formula · installed by Pilot")
    }

    @Test("Least used lists apps by last use, oldest first, then what has no usage (formulae) by name")
    func leastUsed() throws {
        var rows = try Self.rows()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        RemoveList.mark(&rows, pilot: [], lastUsed: ["/Applications/Zed.app": now, "/Applications/IINA.app": now.addingTimeInterval(-86_400 * 90)])
        #expect(RemoveList.sorted(rows, .leastUsed).map(\.name) == ["IINA", "Zed", "abseil", "hello", "mpv", "protobuf", "X"])
        #expect(RemoveList.sorted(rows, .name).map(\.name) == ["abseil", "hello", "IINA", "mpv", "protobuf", "Zed", "X"])
        #expect(RemoveList.Order.allCases.map(\.title) == ["Pilot's installs first", "Least used", "Name"])
        #expect([RemoveList.Order.pilotFirst.next, .leastUsed.next, .name.next] == [.leastUsed, .name, .pilotFirst])
    }

    @Test("Each package has its remove command; a remove row is not a frecency pick")
    func commands() {
        #expect(Package(.cask, "coteditor")?.remove == "brew uninstall --cask coteditor")
        #expect(Package(.formula, "hello")?.remove == "brew uninstall hello")
        #expect(Package(.uv, "telegram-tools")?.remove == "uv tool uninstall telegram-tools")
        #expect(MenuEntry.Target.remove(.row("formula:hello")).key == nil)
    }

    @Test("Remove lists its categories; typing searches every category's rows (card agent-bo-95423022)")
    func branch() throws {
        var nav = MenuNavigator(entries: RemoveList.entries(try Self.rows()), branch: .remove)
        #expect(nav.rows.map(\.title) == ["Apps", "Command-line tools", "Web apps"])
        nav.query = "proto"
        #expect(nav.rows.map(\.title) == ["protobuf"])
        #expect(nav.handle(.return) == .run(nav.rows[0]))
        nav.query = ""
        _ = nav.handle(.down)
        #expect(nav.handle(.return) == .handled)
        #expect(nav.branch == .category("Command-line tools", in: .remove))
        #expect(nav.path == [.remove, .category("Command-line tools", in: .remove)])
        #expect(nav.rows.map(\.title) == ["hello", "abseil", "protobuf", "mpv"])
        #expect(nav.handle(.escape) == .handled)
        #expect(nav.selected?.title == "Command-line tools")
    }

    @Test("A removal forgets Pilot's record of the install")
    func forget() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "installed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InstalledStore(url: dir.appending(path: "Pilot/installed.json"))
        try store.record(Package(.formula, "hello")!, at: .now)
        try store.forget(Package(.formula, "hello")!)
        #expect(try store.load().isEmpty)
    }

    /// Card agent-bo-95422979, Sven: "have it 1st show apps installed then other stuff so we dont see casks and
    /// bullshit". One of each kind: formulae, cask apps, a cask with no app, a uv tool, a web app, an app Homebrew did
    /// not install (Notion) and one a cask installed through a pkg (Karabiner-Elements, which names no app).
    static func everyKind() throws -> [RemoveRow] {
        var rows = try RemoveList.parse(installed)
        rows += [RemoveRow(source: .package(Package(.cask, "karabiner-elements")!), name: "Karabiner-Elements"),
                 RemoveRow(source: .package(Package(.cask, "font-inter")!), name: "Inter")]
        RemoveList.addApps(&rows, paths: ["/Applications/Zed.app", "/Applications/Notion.app", "/Applications/Karabiner-Elements.app",
                                          "/Users/s/Applications/X.app", "/Applications/Things3.app"], skipping: ["/Users/s/Applications/X.app"],
                           appStore: ["/Applications/Things3.app"])
        RemoveList.mark(&rows, pilot: ["uv:telegram-tools"], lastUsed: [:])
        rows.append(RemoveRow(source: .webApp(bundleID: "dev.banozz.pilot.webapp.x"), name: "X"))
        return rows
    }

    @Test("Apps on disk join the list: one Homebrew did not install is an app row; a pkg cask's app makes that cask an app")
    func addApps() throws {
        let rows = try Self.everyKind()
        let notion = try #require(rows.first { $0.name == "Notion" })
        #expect(notion.key == "app:/Applications/Notion.app")
        #expect(notion.app == "/Applications/Notion.app")
        #expect(rows.filter { $0.name == "Zed" }.count == 1, "a cask's own app is not listed twice")
        #expect(rows.filter { $0.name == "X" }.count == 1, "a web app is listed once, as a web app")
        #expect(rows.first { $0.name == "Karabiner-Elements" }?.app == "/Applications/Karabiner-Elements.app")
        #expect(rows.filter { $0.name == "Karabiner-Elements" }.count == 1)
        #expect(RemoveList.entries([notion]).last?.detail == "app")
        #expect(rows.first { $0.name == "Things3" }?.origin(home: "/Users/s") == "App Store")
    }

    @Test("Each kind lands in its category: apps (App Store and pkg casks too), command-line tools, casks without an app, web apps")
    func categories() throws {
        let entries = RemoveList.entries(RemoveList.sorted(try Self.everyKind(), .name))
        func listed(_ c: RemoveList.Category) -> [String] { entries.filter { $0.home == c.branch }.map(\.title) }
        #expect(entries.prefix(4).map(\.title) == ["Apps", "Command-line tools", "Casks without an app", "Web apps"])
        #expect(entries.prefix(4).map(\.target) == [RemoveList.Category.apps, .tools, .casks, .webApps].map { .branch($0.branch) })
        #expect(entries[0].detail == "5", "a category with nothing measured yet says only how many")
        #expect(listed(.apps) == ["IINA", "Karabiner-Elements", "Notion", "Things3", "Zed"])
        #expect(listed(.tools) == ["abseil", "hello", "mpv", "protobuf", "telegram-tools"])
        #expect(listed(.casks) == ["Inter"])
        #expect(listed(.webApps) == ["X"])
        #expect(RemoveList.entries([]).isEmpty, "no rows, no categories")
    }

    @Test("Each row says where it came from and its size; a category sums its sizes")
    func originAndSize() throws {
        var rows = try Self.everyKind()
        for i in rows.indices { rows[i].size = 412_000_000 }
        rows[rows.firstIndex { $0.name == "hello" }!].size = nil
        let entries = RemoveList.entries(RemoveList.sorted(rows, .name), home: "/Users/s")
        func detail(_ name: String) -> String? { entries.first { $0.title == name && $0.target != .branch(.category(name, in: .remove)) }?.detail }
        #expect(detail("Zed") == "Homebrew cask · 412 MB")
        #expect(detail("Notion") == "app · 412 MB")
        #expect(detail("Things3") == "App Store · 412 MB")
        #expect(detail("protobuf") == "Homebrew formula · 412 MB")
        #expect(detail("hello") == "Homebrew formula", "an unmeasured row leaves its size out")
        #expect(detail("telegram-tools") == "uv tool · 412 MB · installed by Pilot")
        #expect(detail("X") == "web app · 412 MB")
        #expect(entries.first { $0.title == "Command-line tools" }?.detail == "5 · 1.65 GB")
        #expect(entries.first { $0.title == "Zed" }?.icon?.appPath == "/Applications/Zed.app", "an app wears its own icon")
        #expect(entries.first { $0.title == "hello" }?.icon == .formula)
    }

    @Test("A row is measured where it lives: its app, a formula's keg, a cask's Caskroom, a uv tool's environment, an npm folder")
    func sizePaths() throws {
        let rows = try Self.everyKind() + RemoveNPMTests.rows()
        func path(_ name: String) -> String? { rows.first { $0.name == name }?.sizePath(brewPrefix: "/opt/homebrew", home: "/Users/s") }
        #expect(path("Zed") == "/Applications/Zed.app")
        #expect(path("Notion") == "/Applications/Notion.app")
        #expect(path("hello") == "/opt/homebrew/Cellar/hello")
        #expect(path("Inter") == "/opt/homebrew/Caskroom/font-inter")
        #expect(path("telegram-tools") == "/Users/s/.local/share/uv/tools/telegram-tools")
        #expect(path("agent-browser") == "/opt/homebrew/lib/node_modules/agent-browser")
        #expect(path("X") == nil, "a web app is measured by its app once the module knows where it is")
    }

    @Test("Uninstall on an app Homebrew did not install finds it in Remove")
    func uninstallFindsApp() throws {
        var nav = MenuNavigator(entries: [MenuEntry(title: "Notion", target: .app("notion.id"), home: .apps)])
        nav.query = "noti"
        _ = nav.handle(.commandK)
        nav.actionQuery = "uninst"
        _ = nav.handle(.return)
        nav.provide(.package, home: .remove, RemoveList.entries(try Self.everyKind()))
        #expect(nav.branch == .remove)
        #expect(nav.rows.map(\.title) == ["Notion"])
        #expect(nav.rows.first?.target == .remove(.row("app:/Applications/Notion.app")))
    }
}

/// Card agent-bo-95422989: Remove lists each npm tree's global tools behind their own tick, read from
/// `npm ls -g --depth=0 --json --long` per npm (trimmed captures of Sven's two trees, 2026-10-07).
@Suite("Remove npm tools")
struct RemoveNPMTests {
    static let local = Data("""
    {"name": "lib", "path": "/Users/ada/.local/lib", "dependencies": {
      "@anthropic-ai/claude-code": {"version": "2.1.292", "path": "/Users/ada/.local/lib/node_modules/@anthropic-ai/claude-code"},
      "sideshow": {"version": "0.14.0", "path": "/Users/ada/.local/lib/node_modules/sideshow"},
      "corepack": {"version": "0.34.0", "path": "/Users/ada/.local/lib/node_modules/corepack"}}}
    """.utf8)
    static let homebrew = Data("""
    {"name": "lib", "path": "/opt/homebrew/lib", "dependencies": {
      "agent-browser": {"version": "0.28.0", "path": "/opt/homebrew/lib/node_modules/agent-browser"},
      "sideshow": {"version": "0.13.0", "path": "/opt/homebrew/lib/node_modules/sideshow"},
      "npm": {"version": "11.19.1", "path": "/opt/homebrew/lib/node_modules/npm"}}}
    """.utf8)

    static func rows() -> [RemoveRow] { RemoveList.parseNPM(local) + RemoveList.parseNPM(homebrew) }

    @Test("Each tree's global packages are rows keyed npm:prefix:name, once per tree, never npm or corepack")
    func parse() {
        #expect(Self.rows().map(\.key) == ["npm:/Users/ada/.local:@anthropic-ai/claude-code", "npm:/Users/ada/.local:sideshow",
                                           "npm:/opt/homebrew:agent-browser", "npm:/opt/homebrew:sideshow"])
        #expect(Self.rows().allSatisfy { $0.category == .tools })
        #expect(RemoveList.parseNPM(Data("not json".utf8)).isEmpty)
    }

    @Test("npm's tools list under Command-line tools, each naming its tree")
    func listed() throws {
        let rows = RemoveList.sorted(try RemoveListTests.everyKind() + Self.rows(), .name)
        let npm = RemoveList.entries(rows, home: "/Users/ada").filter { $0.detail?.hasPrefix("npm in") == true }
        #expect(npm.map(\.target) == Self.rows().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { .remove(.row($0.key)) })
        #expect(npm.map(\.detail) == ["npm in ~/.local", "npm in /opt/homebrew", "npm in ~/.local", "npm in /opt/homebrew"])
        #expect(npm.allSatisfy { $0.home == RemoveList.Category.tools.branch })
    }

    @Test("A tool Pilot installed with npm is marked in every tree that has it")
    func pilot() {
        var rows = Self.rows()
        RemoveList.mark(&rows, pilot: ["npm:sideshow"], lastUsed: [:])
        #expect(rows.filter(\.pilot).map(\.key) == ["npm:/Users/ada/.local:sideshow", "npm:/opt/homebrew:sideshow"])
    }
}

/// Moody's REJECT 9_ijL7pNdDA on card agent-bo-95423022: Remove and Update provide their rows again (sizes arrive, Tab
/// sorts, more updates join), and each time the rows in their categories must be replaced, never added again.
@Suite("Browse provide")
struct BrowseProvideTests {
    @Test("Providing Remove's and Update's rows twice leaves each category's rows once, in the new order")
    func replaces() throws {
        let rows = try RemoveListTests.everyKind()
        var remove = MenuNavigator(entries: [], branch: .remove)
        remove.provide(.package, home: .remove, RemoveList.entries(RemoveList.sorted(rows, .pilotFirst)))
        remove.provide(.package, home: .remove, RemoveList.entries(RemoveList.sorted(rows, .name)))
        _ = remove.handle(.return)
        #expect(remove.branch == RemoveList.Category.apps.branch)
        #expect(remove.rows.map(\.title) == ["IINA", "Karabiner-Elements", "Notion", "Things3", "Zed"])
        var update = MenuNavigator(entries: [], branch: .update)
        let outdated = try UpdateListTests.rows()
        update.provide(.package, home: .update, UpdateList.entries(outdated, includeSelfUpdating: false))
        update.provide(.package, home: .update, UpdateList.entries(outdated, includeSelfUpdating: true))
        _ = update.handle(.down)
        _ = update.handle(.return)
        #expect(update.rows.map(\.title) == ["zed", "ghostex"])
    }

    /// Sven, 2026-10-09: Update › Apps, then Esc, laid Update out with a gap and Update all near the foot. Update's second
    /// read (npm and cargo, arriving while he was in Apps) kept the category rows of the first and added its own, so each
    /// category was listed twice under one id. A category row is its provider's too: a new read replaces it.
    @Test("A later read replaces the category rows themselves, in Update and Remove: each listed once, as the newest read says")
    func replacesCategoryRows() throws {
        let outdated = try UpdateListTests.rows()
        var update = MenuNavigator(entries: [], branch: .update)
        update.provide(.package, home: .update, UpdateList.entries(outdated.filter { $0.category == .apps }, includeSelfUpdating: true))
        for _ in 0..<3 where update.selected?.title != "Apps" { _ = update.handle(.down) }
        _ = update.handle(.return)
        #expect(update.branch == UpdateList.Category.apps.branch)
        let more = UpdateList.entries(outdated, includeSelfUpdating: true)
        update.provide(.package, home: .update, more)
        _ = update.handle(.escape)
        #expect(update.branch == .update)
        #expect(Set(update.rows.map(\.id)).count == update.rows.count, "a row listed twice: \(update.rows.map(\.title))")
        #expect(update.rows.map(\.id) == more.filter { $0.home == .update }.map(\.id))
        #expect(update.rows.compactMap(\.detail) == more.filter { $0.home == .update }.compactMap(\.detail), "the newest read's details")
        // A read that no longer has a category drops its row.
        update.provide(.package, home: .update, UpdateList.entries([], includeSelfUpdating: true))
        #expect(!update.rows.contains { if case .branch = $0.target { true } else { false } })

        let rows = try RemoveListTests.everyKind()
        var remove = MenuNavigator(entries: [], branch: .remove)
        remove.provide(.package, home: .remove, RemoveList.entries(RemoveList.sorted(rows, .pilotFirst)))
        remove.provide(.package, home: .remove, RemoveList.entries(RemoveList.sorted(rows, .name)))
        #expect(Set(remove.rows.map(\.id)).count == remove.rows.count, "a row listed twice: \(remove.rows.map(\.title))")
    }
}
