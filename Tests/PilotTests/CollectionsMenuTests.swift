import Foundation
import PilotCore
import Testing
@testable import Pilot

/// AI helper T7 and CLI W4: the menu's lists as `pilot list|add|remove <collection>`, each edit read back from the object
/// the page or the menu reads, in a test home of its own. Never the running Pilot's stores.
@MainActor
@Suite("Collections: menu lists")
struct CollectionsMenuTests {
    let home = URL(filePath: NSTemporaryDirectory()).appending(path: "pilot-collections-\(UUID().uuidString)", directoryHint: .isDirectory)
    let stores: MenuCollectionStores
    let verbs = ControlVerbs()
    let menu = PilotMenu()
    /// The optional abilities whose app this test says is on the Mac.
    final class Installed { var checks: Set<CatalogueEntry.Check> = [] }
    let installed = Installed()

    init() throws {
        try FileManager.default.createDirectory(at: home.appending(path: "Scripts"), withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: testSuite())!
        let files = FileSearchSettings(defaults: defaults, home: home.path(percentEncoded: false))
        files.onExcludedChange = {}
        stores = MenuCollectionStores()
        stores.aliases = AliasBook(store: AliasesStore(url: home.appending(path: "aliases.json")))
        stores.quicklinks = QuicklinkBook(store: QuicklinksStore(url: home.appending(path: "quicklinks.json")))
        stores.snippets = SnippetLibrary(store: SnippetStore(url: home.appending(path: "snippets.json")))
        stores.favourites = FavouriteBook(store: FavouritesStore(url: home.appending(path: "favourites.json")))
        stores.reminders = ReminderScheduler(store: ReminderStore(url: home.appending(path: "reminders.json")), armsTimer: false)
        stores.scriptsFolder = home.appending(path: "Scripts")
        stores.files = files
        stores.menuRoot = MenuRootSettings(defaults: defaults)
        stores.abilities = AbilitySettings(defaults: defaults)
        stores.has = { [installed] in installed.checks.contains($0) }
        let engine = Engine()
        stores.engine = { engine }
        menu.frecencyStore = FrecencyStore(url: home.appending(path: "frecency.json"))
        stores.menu = menu
        verbs.registerMenuCollections(stores)
    }

    func answer(_ verb: String, _ args: [String]) async -> ControlAnswer {
        await verbs.answer(ControlRequest(id: .number(1), verb: verb, args: args), peer: nil)
    }

    func rows(_ collection: String) async -> [[String: JSONValue]] {
        guard case .array(let rows) = await answer("list", [collection]).result else { Issue.record("list \(collection) gave no rows"); return [] }
        return rows.compactMap { if case .object(let row) = $0 { row } else { nil } }
    }

    /// Add, then list shows the row; remove, then it is gone; each required field left out answers bad-value naming it.
    func roundTrip(_ collection: String, add fields: [String: String], remove word: String, row: (String, String),
                   live: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        func flags(_ fields: [String: String]) -> [String] { fields.sorted { $0.key < $1.key }.flatMap { ["--\($0.key)", $0.value] } }
        func listed() async -> Bool { await rows(collection).contains { $0[row.0] == .string(row.1) } }
        let added = await answer("add", [collection] + flags(fields))
        #expect(added.ok, "\(added.error?.message ?? "")", sourceLocation: sourceLocation)
        #expect(await listed(), sourceLocation: sourceLocation)
        #expect(live(), "add did not reach the live store", sourceLocation: sourceLocation)
        let removed = await answer("remove", [collection, word])
        #expect(removed.ok, "\(removed.error?.message ?? "")", sourceLocation: sourceLocation)
        #expect(!(await listed()), sourceLocation: sourceLocation)
        #expect(!live(), "remove did not reach the live store", sourceLocation: sourceLocation)
        for name in fields.keys {
            let error = await answer("add", [collection] + flags(fields.filter { $0.key != name })).error
            #expect(error?.code == .badValue && error?.message.contains("--\(name)") == true, "\(collection) without --\(name): \(String(describing: error))",
                    sourceLocation: sourceLocation)
        }
    }

    @Test("Aliases: add, list, remove through the alias book; a taken alias or a bad row key is refused")
    func aliases() async throws {
        await roundTrip("aliases", add: ["alias": "gt", "row": "app:com.mitchellh.ghostty"], remove: "gt", row: ("alias", "gt"),
                        live: { stores.aliases.aliases.key(for: "gt") == "app:com.mitchellh.ghostty" })
        _ = await answer("add", ["aliases", "--alias", "wp", "--row", "action:apps.webAppPicker", "--title", "Web app picker"])
        #expect(try AliasesStore(url: home.appending(path: "aliases.json")).load().key(for: "wp") == "action:apps.webAppPicker")
        #expect(await answer("add", ["aliases", "--alias", "wp", "--row", "app:com.apple.Safari"]).error
            == ControlError(.badValue, "--alias: wp is Web app picker's alias; pick another."))
        #expect(await answer("add", ["aliases", "--alias", "x", "--row", "nonsense"]).error?.message.hasPrefix("--row:") == true)
        #expect(await answer("remove", ["aliases", "nope"]).error == ControlError(.badValue, "no alias nope; there are wp"))
    }

    @Test("Quicklinks: add, list, remove through the quicklink book; the editor's refusals name their field")
    func quicklinks() async {
        await roundTrip("quicklinks", add: ["name": "Linear", "keyword": "lin", "url": "https://linear.app/search?q={query}"], remove: "lin",
                        row: ("keyword", "lin"), live: { stores.quicklinks.links.contains { $0.keyword == "lin" } })
        #expect(await answer("add", ["quicklinks", "--name", "X", "--keyword", "g", "--url", "https://x.com"]).error
            == ControlError(.badValue, "--keyword: g is taken by Google; pick another keyword."))
        #expect(await answer("add", ["quicklinks", "--name", "X", "--keyword", "xx", "--url", "nope"]).error?.message.hasPrefix("--url:") == true)
    }

    @Test("Snippets: add, list, remove through the snippet library; a clashing keyword is kept with a warning")
    func snippets() async {
        await roundTrip("snippets", add: ["name": "Sig", "text": "Best, Sven"], remove: "Sig", row: ("name", "Sig"),
                        live: { stores.snippets.snippets.contains { $0.name == "Sig" } })
        _ = await answer("add", ["snippets", "--name", "Mail", "--keyword", ";m", "--text", "a@b.c"])
        #expect(stores.snippets.snippets.last?.keyword == ";m")
        guard case .object(let row) = await answer("add", ["snippets", "--name", "Mail 2", "--keyword", ";m", "--text", "d@e.f"]).result else {
            Issue.record("no row"); return
        }
        #expect(row["warning"] == .string("Mail has keyword ;m too and expands instead"))
    }

    @Test("Favourites: add, list, remove through the favourite book the menu reads; Cmd+K's change and the command's both stay")
    func favourites() async throws {
        await roundTrip("favourites", add: ["row": "action:apps.clipboard"], remove: "action:apps.clipboard", row: ("row", "action:apps.clipboard"),
                        live: { stores.favourites.rows.contains("action:apps.clipboard") })
        #expect(await answer("add", ["favourites", "--row", "clipboard"]).error?.message.hasPrefix("--row:") == true)
        // The menu's Cmd+K sets one row on the same book, so neither change saves over the other.
        stores.favourites.set("app:com.apple.Safari", true)
        _ = await answer("add", ["favourites", "--row", "branch:system"])
        #expect(try FavouritesStore(url: home.appending(path: "favourites.json")).load() == ["app:com.apple.Safari", "branch:system"])
    }

    @Test("Favourites: a favourites.json that does not decode is never saved over, and add says why")
    func favouritesUnreadable() async throws {
        let url = home.appending(path: "broken-favourites.json")
        try Data("not json".utf8).write(to: url)
        stores.favourites = FavouriteBook(store: FavouritesStore(url: url))
        #expect(await answer("add", ["favourites", "--row", "branch:system"]).error == ControlError(.badValue, FavouriteBook.unreadable))
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    @Test("Reminders: add, list, remove through the scheduler; a wait past a day or not a wait is refused")
    func reminders() async throws {
        await roundTrip("reminders", add: ["text": "stretch", "in": "20m"], remove: "stretch", row: ("text", "stretch"),
                        live: { stores.reminders.list.upcoming.contains { $0.text == "stretch" } })
        _ = await answer("add", ["reminders", "--text", "tea", "--in", "1h30m"])
        let due = try #require(stores.reminders.list.upcoming.first { $0.text == "tea" }?.due)
        #expect(abs(due.timeIntervalSinceNow - 5400) < 60)
        #expect(await answer("add", ["reminders", "--text", "kettle", "--in", "10 min"]).ok)
        #expect(await answer("add", ["reminders", "--text", "x", "--in", "2d"]).error?.message.hasPrefix("--in:") == true)
        #expect(await answer("add", ["reminders", "--text", "x", "--in", "20m and"]).error?.message.hasPrefix("--in:") == true)
        #expect(await answer("add", ["reminders", "--text", "x", "--in", "25h"]).error?.message.hasPrefix("--in:") == true)
    }

    @Test("Scripts: list reads the Scripts folder; add and remove are read-only")
    func scripts() async throws {
        try "#!/bin/bash\n# @raycast.title Say hi\n# @raycast.mode silent\necho hi\n".write(to: home.appending(path: "Scripts/hi.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "Scripts/hi.sh").path(percentEncoded: false))
        #expect(await rows("scripts").first { $0["file"] == .string("hi.sh") }?["title"] == .string("Say hi"))
        #expect(await answer("add", ["scripts", "--file", "x"]).error == ControlError(.badValue, "scripts is read-only"))
        #expect(await answer("remove", ["scripts", "hi.sh"]).error == ControlError(.badValue, "scripts is read-only"))
    }

    @Test("Excluded folders: add, list, remove through the file search settings; a path outside home is refused")
    func excludedFolders() async {
        await roundTrip("excluded-folders", add: ["folder": "~/Movies"], remove: "~/Movies", row: ("folder", "~/Movies"),
                        live: { stores.files.excluded.contains("~/Movies") })
        #expect(await answer("add", ["excluded-folders", "--folder", "/etc"]).error?.message.hasPrefix("--folder:") == true)
    }

    @Test("Menu root: remove hides a branch and add shows it again at a place; an unknown branch lists the real ones")
    func menuRoot() async throws {
        let first = MenuBranch.top[0].rawValue, second = MenuBranch.top[1].rawValue
        #expect(await rows("menu-root").map { $0["branch"] } == MenuBranch.top.map { .string($0.rawValue) })
        let hid = await answer("remove", ["menu-root", second])
        #expect(hid.ok && !stores.menuRoot.root.isShown(MenuBranch.top[1]))
        // A hidden branch is still listed, in its place, read back as not shown.
        let hidden = await rows("menu-root")
        #expect(hidden.map { $0["branch"] } == MenuBranch.top.map { .string($0.rawValue) })
        #expect(hidden[1]["shown"] == .bool(false) && hidden[1]["at"] == nil && hidden[2]["at"] == .number(1))
        #expect(await answer("remove", ["menu-root", second]).error == ControlError(.badValue, "\(second) is already hidden"))
        _ = await answer("add", ["menu-root", "--branch", second, "--at", "0"])
        #expect(stores.menuRoot.root.shown().prefix(2).map(\.rawValue) == [second, first])
        #expect(await rows("menu-root").first?["branch"] == .string(second))
        // A place counts shown branches only: with the first hidden, place 1 lands after the next shown one.
        _ = await answer("remove", ["menu-root", first])
        _ = await answer("add", ["menu-root", "--branch", second, "--at", "1"])
        #expect(stores.menuRoot.root.shown().firstIndex(of: MenuBranch.top[1]) == 1)
        #expect(await answer("add", ["menu-root", "--at", "0"]).error == ControlError(.badValue, "menu-root needs --branch: one of \(MenuBranch.top.map(\.rawValue).joined(separator: ", "))"))
        #expect(await answer("add", ["menu-root", "--branch", "nope"]).error?.message.hasPrefix("--branch: no branch nope; there are") == true)
        // Reset to default: today's root, every branch shown, answered as list reads it.
        let reset = await answer("remove", ["menu-root", "--reset"])
        #expect(reset.ok && stores.menuRoot.root.isDefault())
        #expect(reset.result == (await answer("list", ["menu-root"])).result)
        #expect(await rows("menu-root").allSatisfy { $0["shown"] == .bool(true) })
        #expect(await answer("remove", ["menu-root", "--rest"]).error?.code == .unknownFlag)
    }

    @Test("Quicklinks: --id edits a link in place, keeping its id, its action and its place; an id no link has is refused")
    func quicklinkEdit() async throws {
        _ = await answer("add", ["quicklinks", "--name", "Linear", "--keyword", "lin", "--url", "https://linear.app"])
        let before = stores.quicklinks.links, link = try #require(before.first { $0.keyword == "lin" })
        let edited = await answer("add", ["quicklinks", "--id", link.id.uuidString.lowercased(), "--name", "Linear search", "--keyword", "lin",
                                          "--url", "https://linear.app/search?q={query}"])
        #expect(edited.ok, "\(edited.error?.message ?? "")")
        guard case .object(let row) = edited.result else { Issue.record("no row"); return }
        #expect(row["id"] == .string(link.id.uuidString) && row["action"] == .string(link.actionID) && row["name"] == .string("Linear search"))
        #expect(stores.quicklinks.links.map(\.id) == before.map(\.id))
        #expect(stores.quicklinks.link(link.id)?.url == "https://linear.app/search?q={query}")
        let unknown = await answer("add", ["quicklinks", "--id", UUID().uuidString, "--name", "X", "--keyword", "xx", "--url", "https://x.com"])
        #expect(unknown.error?.code == .badValue && unknown.error?.message.hasPrefix("no quicklink") == true)
        #expect(stores.quicklinks.links.count == before.count)
    }

    @Test("Snippets: --id edits one in place; a name two snippets share is refused on remove, naming both ids")
    func snippetEdit() async throws {
        for (name, keyword) in [("Dup", ";a"), ("Dup", ";b"), ("Other", "")] {
            _ = await answer("add", ["snippets", "--name", name, "--keyword", keyword, "--text", "x"])
        }
        let first = stores.snippets.snippets[0]
        let edited = await answer("add", ["snippets", "--id", first.id.uuidString, "--name", "Dup", "--keyword", ";c", "--text", "y"])
        #expect(edited.ok, "\(edited.error?.message ?? "")")
        #expect(stores.snippets.snippets.map(\.id).first == first.id && stores.snippets.snippets.count == 3)
        #expect(stores.snippets.snippets[0].keyword == ";c" && stores.snippets.snippets[0].text == "y")
        let both = stores.snippets.snippets.filter { $0.name == "Dup" }.map(\.id.uuidString)
        #expect(await answer("remove", ["snippets", "Dup"]).error
            == ControlError(.badValue, "2 snippets answer to Dup; remove one by its id: \(both.joined(separator: ", "))"))
        #expect(stores.snippets.snippets.count == 3)
        #expect(await answer("remove", ["snippets", both[1]]).ok)
        #expect(await answer("remove", ["snippets", "Dup"]).ok)
        #expect(stores.snippets.snippets.map(\.name) == ["Other"])
        #expect(await answer("add", ["snippets", "--id", UUID().uuidString, "--name", "Z", "--text", "z"]).error?.message.hasPrefix("no snippet") == true)
    }

    @Test("Snippets: each row reads back its preview with sample clipboard and argument, and where its keyword expands")
    func snippetNote() async {
        for (name, keyword, text) in [("Sym", ";m", "Hi {clipboard}, {argument}{cursor}!"), ("Word", "sig", "Best"), ("Menu", "", "m"), ("Late", ";m", "l")] {
            _ = await answer("add", ["snippets", "--name", name, "--keyword", keyword, "--text", text])
        }
        let listed = await rows("snippets")
        func row(_ name: String) -> [String: JSONValue] { listed.first { $0["name"] == .string(name) } ?? [:] }
        #expect(row("Sym")["preview"] == .string("Hi \(SnippetsEditor.sampleClipboard), \(SnippetsEditor.sampleArgument)!"))
        #expect(row("Sym")["expands"] == .string("anywhere") && row("Sym")["clashesWith"] == .string("Late"))
        #expect(row("Word")["expands"] == .string("word-start") && row("Menu")["expands"] == .string("menu-only"))
        #expect(row("Late")["expands"] == .string("never") && row("Late")["clashesWith"] == .string("Sym"))
    }

    @Test("Abilities: list shows what each does and its key, typed ones with what Try types; add and remove an optional one")
    func abilities() async throws {
        let id = "look.ghosttyApply", need = try #require(Abilities.optional[id])
        let typed = await rows("abilities").filter { $0["group"] == .string("Type in the menu") }
        #expect(typed.contains { $0["name"] == .string("File search") && $0["typing"] != nil && $0["action"] == nil })
        #expect(await rows("abilities").contains { $0["id"] == .string("apps.clipboard") && $0["what"] != nil && $0["listed"] == .bool(true) })
        // Its app not on this Mac: neither listed nor offered.
        #expect(!(await rows("abilities").contains { $0["id"] == .string(id) }))
        #expect(await answer("add", ["abilities", "--id", id]).error == ControlError(.badValue, "\(id) drives an app that is not on this Mac, so it is not offered"))
        installed.checks = [need]
        #expect(await rows("abilities").first { $0["id"] == .string(id) }?["listed"] == .bool(false))
        guard case .object(let added) = await answer("add", ["abilities", "--id", id]).result else { Issue.record("no row"); return }
        #expect(added["listed"] == .bool(true) && added["optional"] == .bool(true) && stores.abilities.added.contains(id))
        #expect(await answer("add", ["abilities", "--id", id]).error == ControlError(.badValue, "\(id) is listed already"))
        guard case .object(let removed) = await answer("remove", ["abilities", id]).result else { Issue.record("no row"); return }
        #expect(removed["listed"] == .bool(false) && !stores.abilities.added.contains(id))
        #expect(await answer("remove", ["abilities", id]).error == ControlError(.badValue, "\(id) is not added"))
        #expect(await answer("add", ["abilities", "--id", "apps.clipboard"]).error == ControlError(.badValue, "apps.clipboard ships with Pilot and is always listed"))
        #expect(await answer("remove", ["abilities", "nope"]).error?.code == .unknownAction)
        stores.engine = { nil }
        #expect(await answer("list", ["abilities"]).error?.code == .notReady)
    }

    @Test("Ranking: list reads the menu's picks best first; remove resets one through the menu, so its next pick saves no stale copy")
    func ranking() async throws {
        let now = Date(), store = FrecencyStore(url: home.appending(path: "frecency.json"))
        try store.save(Frecency(picks: ["app:a": [now, now], "app:b": [now]]))
        #expect(await rows("ranking").map { $0["row"] } == [.string("app:a"), .string("app:b")])
        #expect(await rows("ranking").first?["picks"] == .number(2))
        guard case .object(let reset) = await answer("remove", ["ranking", "app:a"]).result else { Issue.record("no row"); return }
        #expect(reset["picks"] == .number(0) && reset["score"] == .number(0))
        #expect(try store.load().picks.keys.sorted() == ["app:b"] && menu.frecency?.picks["app:a"] == nil)
        #expect(await answer("remove", ["ranking", "app:a"]).error == ControlError(.badValue, "no ranked row app:a; pilot list ranking lists them"))
    }

    @Test("Ranking: a frecency.json that does not decode is never saved over, and list and remove say why")
    func rankingUnreadable() async throws {
        let url = home.appending(path: "broken-frecency.json")
        try Data("not json".utf8).write(to: url)
        let broken = PilotMenu()
        broken.frecencyStore = FrecencyStore(url: url)
        stores.menu = broken
        #expect(await answer("list", ["ranking"]).error?.message.hasPrefix("frecency.json does not read") == true)
        #expect(await answer("remove", ["ranking", "app:a"]).error?.code == .badValue)
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    @Test("Every menu collection is listed and in schema with its fields and the row word remove takes")
    func listed() async throws {
        let keys = ["abilities": "id", "aliases": "alias", "excluded-folders": "folder", "favourites": "row", "menu-root": "branch",
                    "quicklinks": "keyword", "ranking": "row", "reminders": "id", "scripts": nil, "snippets": "id"]
        guard case .array(let all) = await answer("list", []).result else { Issue.record("no collections"); return }
        #expect(all.compactMap { if case .object(let c) = $0, case .string(let n) = c["name"] { n } else { nil } } == keys.keys.sorted())
        for (name, key) in keys {
            guard case .object(let entry) = try verbs.schema(collection: name) else { Issue.record("no schema for \(name)"); continue }
            #expect(entry["rowKey"] == key.map(JSONValue.string), "\(name)")
        }
    }
}
