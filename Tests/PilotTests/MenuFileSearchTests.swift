import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422968: the menu's model asks the file index only from the Files view, never while Sven types under
/// All. A fake index counts the asks; no panel and no helper.
@MainActor
@Suite("Menu file search")
struct MenuFileSearchTests {
    @Test("Typing bitwa asks the index nothing; picking Search files asks it once with bitwa; leaving drops the files")
    func filesOnlyWhenAsked() {
        let model = MenuModel(nav: MenuNavigator(entries: [
            MenuEntry(title: "Bitwarden", target: .app("com.bitwarden.desktop"), home: .apps),
            MenuEntry(title: "Bitwarden: search vault", target: .action("apps.bitwardenSearch")),
        ]))
        var asked: [String?] = []
        model.onFileQuery = { asked.append($0?.text) }
        for letter in "bitwa" { model.nav.query += String(letter) }
        #expect(asked.isEmpty)
        #expect(model.nav.rows.first?.title == "Bitwarden")
        // Search files sits with Ask AI and Search the web after the best match (Q182).
        #expect(model.nav.rows.contains { $0.title == "Search files for \"bitwa\"" })
        while model.nav.selected?.target != .searchFiles { _ = model.nav.handle(.down) }
        #expect(model.nav.handle(.return) == .handled)
        #expect(asked == ["bitwa"])
        _ = model.nav.handle(.escape)
        #expect(asked == ["bitwa", nil])
    }

    @Test("Without Full Disk Access the Files view lists one row that says why and opens the setting (card agent-bo-95423031)")
    func filesWithoutTheGrant() throws {
        let model = MenuModel(nav: MenuNavigator(entries: []))
        for letter in "keymap" { model.nav.query += String(letter) }
        _ = model.nav.handle(.tab); _ = model.nav.handle(.tab); _ = model.nav.handle(.tab)
        #expect(model.nav.only == .file)
        model.nav.provide(.file, [MenuEntries.allowFullDiskAccess(search: "keymap")])
        #expect(model.nav.rows.map(\.title) == ["Allow Full Disk Access to search files"])
        let row = try #require(model.nav.rows.first)
        #expect(row.target == .allowFullDiskAccess && row.subtitle?.contains("macOS keeps your files") == true)
        #expect(model.nav.handle(.return) == .run(row))
    }

    @Test("Return on Search to install opens Search packages and hands its providers the text kept (Sven 2026-10-12)")
    func installSearchAsked() {
        let model = MenuModel(nav: MenuNavigator(entries: [MenuEntry(title: "Bitwarden", target: .app("com.bitwarden.desktop"), home: .apps)]))
        var asked: [String] = []
        model.nav.query = "raycast"
        model.onQuery = { asked.append($0) }
        #expect(model.noMatch && model.nav.selected?.target == .ask("raycast"))
        while model.nav.selected?.target != .searchInstall("raycast") { _ = model.nav.handle(.down) }
        #expect(model.nav.handle(.return) == .handled)
        #expect(model.nav.branch == .homebrew && asked == ["raycast"])
    }

    @Test("Each file row says where it came from, and from:whatsapp asks the index for those files alone (Homy-style Files, check 3)")
    func whereFilesCameFrom() throws {
        let home = "/Users/test"
        let line = #"{"id":3,"query":"photo","files":[{"path":"/Users/test/Downloads/photo.zip","modified":null,"from":"github.com"},"#
            + #"{"path":"/Users/test/Downloads/photo.jpg","modified":null,"from":"WhatsApp"},{"path":"/Users/test/photo.md","modified":null}]}"#
        let answer = try #require(FileSearch.answer(line))
        #expect(answer.files.map(\.from) == ["github.com", "WhatsApp", nil])
        #expect(MenuEntries.files(answer.files, home: home).map(\.subtitle) == ["~/Downloads · from github.com", "~/Downloads · from WhatsApp", "~"])

        let model = MenuModel(nav: MenuNavigator(entries: []))
        model.nav.home = home
        var asked: [FileSearch.Ask?] = []
        model.onFileQuery = { asked.append($0) }
        for letter in "photo from:WhatsApp" { model.nav.query += String(letter) }
        _ = model.nav.handle(.tab); _ = model.nav.handle(.tab); _ = model.nav.handle(.tab)
        #expect(model.nav.only == .file)
        let ask = try #require(model.nav.fileAsk)
        #expect(ask.text == "photo" && ask.from == "WhatsApp")
        #expect(asked.last == ask)
        let request = try #require(try JSONSerialization.jsonObject(with: Data(ask.request(id: 1, home: home).utf8)) as? [String: Any])
        #expect(request["query"] as? String == "photo" && request["from"] as? String == "WhatsApp")
        #expect(!FileSearch.Ask(text: "photo").request(id: 1, home: home).contains("from"), "no from: no key")
        // The rows the index sends are ranked by the words alone, so from: drops none of them.
        model.nav.provide(.file, MenuEntries.files([answer.files[1]], home: home))
        #expect(model.nav.rows.map(\.subtitle) == ["~/Downloads · from WhatsApp"])
        // from: alone is no search, as kind:pdf alone is none.
        model.nav.query = "from:whatsapp"
        #expect(model.nav.fileAsk == nil)
    }

    @Test("invoice lists Screenshot 14.png by its words, under the name hits, filters applied (Homy-style Files, check 1)")
    func imagesByTheirWords() throws {
        let home = "/Users/test", now = Date(timeIntervalSince1970: 1_791_800_000)
        let shot = "/Users/test/Desktop/Screenshot 14.png"
        let model = MenuModel(nav: MenuNavigator(entries: []))
        model.nav.home = home
        for letter in "invoice" { model.nav.query += String(letter) }
        _ = model.nav.handle(.tab); _ = model.nav.handle(.tab); _ = model.nav.handle(.tab)
        let ask = try #require(model.nav.fileAsk)
        let names = [FileSearch.Hit(path: "/Users/test/Documents/invoice.pdf"), FileSearch.Hit(path: "/Users/test/Downloads/invoices.png")]
        let text = [(path: shot, modified: now, words: "invoice 4471"),
                    (path: "/Users/test/Downloads/invoices.png", modified: now, words: "Invoices due"),
                    (path: "/Users/test/Pictures/receipt.jpg", modified: now.addingTimeInterval(-40 * 86_400), words: "invoice paid")]
        model.nav.provide(.file, MenuEntries.files(names, text: text, ask: ask, home: home, now: now))
        #expect(model.nav.rows.map(\.title) == ["invoice.pdf", "invoices.png", "Screenshot 14.png", "receipt.jpg"])
        #expect(model.nav.rows.map(\.subtitle) == ["~/Documents", "“Invoices due” · ~/Downloads", "“invoice 4471” · ~/Desktop", "“invoice paid” · ~/Pictures"])
        #expect(model.nav.rows.map { $0.matchedWords != nil } == [false, true, true, true])

        func listed(_ ask: FileSearch.Ask) -> [String] {
            MenuEntries.files([], text: text, ask: ask, home: home, now: now).map(\.title)
        }
        #expect(listed(FileSearch.Ask(text: "invoice", filters: FileFilters(kind: .images))).count == 3)
        #expect(listed(FileSearch.Ask(text: "invoice", filters: FileFilters(kind: .ext("JPG")))) == ["receipt.jpg"])
        #expect(listed(FileSearch.Ask(text: "invoice", filters: FileFilters(kind: .documents))).isEmpty)
        #expect(listed(FileSearch.Ask(text: "invoice", filters: FileFilters(place: .desktop))) == ["Screenshot 14.png"])
        #expect(listed(FileSearch.Ask(text: "invoice", filters: FileFilters(when: .month))) == ["Screenshot 14.png", "invoices.png"])
        #expect(listed(FileSearch.Ask(text: "invoice", from: "whatsapp")).isEmpty, "the text index knows no source")

        let many = (1...14).map { (path: "/Users/test/Desktop/shot \($0).png", modified: now, words: "invoice") }
        let rows = MenuEntries.files([], text: many, ask: ask, home: home, now: now)
        #expect(rows.count == FileSearch.textHits && rows.first?.title == "shot 1.png" && rows.last?.title == "shot 10.png")
        let long = MenuEntries.files([], text: [(path: shot, modified: now, words: String(repeating: "invoice ", count: 12))], ask: ask, home: home)
        #expect(long.first?.matchedWords?.count == 60 && long.first?.matchedWords?.hasSuffix("…") == true)
    }
}
