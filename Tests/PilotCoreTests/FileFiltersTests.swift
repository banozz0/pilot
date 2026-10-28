import Foundation
import Testing
@testable import PilotCore

/// N5 (Sven 2026-10-09): the Files view's filters, stepped with ⌘1, ⌘2, ⌘3 or typed, Show hidden with ⌘⇧., the
/// request the file index reads (pilot-files filter.rs) and the never-index list it takes as gitignore lines.
@Suite("File filters")
struct FileFiltersTests {
    static let home = "/Users/ada"

    @Test("Typed kind:, in: and when: words become filters and leave the search; an unknown value stays typed")
    func typed() {
        let (text, filters) = FileFilters.typed("budget kind:pdf in:downloads when:week", home: Self.home)
        #expect(text == "budget")
        #expect(filters == FileFilters(kind: .ext("pdf"), place: .downloads, when: .week))
        #expect(FileFilters.typed("kind:img in:~/code/pilot x", home: Self.home).filters
            == FileFilters(kind: .images, place: .folder("/Users/ada/code/pilot")))
        #expect(FileFilters.typed("KIND:Folders when:today", home: Self.home).filters == FileFilters(kind: .folders, when: .today))
        let odd = FileFilters.typed("kind:p|df in:nowhere when:year", home: Self.home)
        #expect(odd.text == "kind:p|df in:nowhere when:year" && odd.filters == FileFilters())
        #expect(FileFilters.removing(.kind, from: "budget kind:pdf when:week", home: Self.home) == "budget when:week")
    }

    @Test("A step walks the kinds, places and times through Any and round; a typed extension steps on to the first")
    func step() {
        var f = FileFilters()
        f.step(.kind, by: 1)
        #expect(f.kind == .folders)
        f.step(.kind, by: -2)
        #expect(f.kind == .apps)
        f.step(.kind, by: 1)
        #expect(f.kind == nil)
        f.kind = .ext("pdf")
        f.step(.kind, by: 1)
        #expect(f.kind == .folders)
        f.step(.place, by: -1)
        #expect(f.place == .iCloud)
        for _ in 0..<4 { f.step(.when, by: 1) }
        #expect(f.when == nil)
        #expect(FileFilters(kind: .code, hidden: true).merged(with: FileFilters(kind: .audio, when: .today))
            == FileFilters(kind: .audio, when: .today, hidden: true))
    }

    @Test("The request the index reads: the words, the kind or extension, the place's folder, the time, hidden, its id")
    func request() throws {
        let ask = FileSearch.Ask(text: "budget", filters: FileFilters(kind: .documents, place: .iCloud, when: .month))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(ask.request(id: 7, home: Self.home).utf8)) as? [String: Any])
        #expect(json["id"] as? Int == 7 && json["query"] as? String == "budget" && json["kind"] as? String == "documents")
        #expect(json["folder"] as? String == "/Users/ada/Library/Mobile Documents" && json["when"] as? String == "month")
        #expect(json["hidden"] as? Bool == false && json["ext"] == nil)
        let ext = FileSearch.Ask(text: "x", filters: FileFilters(kind: .ext("pdf"), hidden: true)).request(id: 1, home: Self.home)
        #expect(ext == #"{"ext":"pdf","hidden":true,"id":1,"query":"x"}"#)
        // The answer says which request it answers.
        #expect(FileSearch.answer(#"{"id":7,"query":"budget","files":[]}"#)?.id == 7)
        #expect(FileSearch.answer(#"{"query":"budget","files":[]}"#)?.id == nil)
    }

    @Test("The never-index list: the helper's default lines (DEFAULT_IGNORE), ~/Library keeping iCloud Drive, typed entries checked")
    func exclusions() {
        #expect(FileExclusions.lines(FileExclusions.defaults) == [
            "/Library/*", "!/Library/Mobile Documents/", "/.Trash/", "/.cache/", "/.bun/", "/.npm/", "/.cargo/", "/.rustup/",
            "node_modules/", ".git/", ".build/", "DerivedData/", "target/", "__pycache__/", "venv/", ".venv/",
        ])
        #expect(FileExclusions.entry(" Pods/ ", home: Self.home) == "Pods")
        #expect(FileExclusions.entry("/Users/ada/Movies/", home: Self.home) == "~/Movies")
        #expect(FileExclusions.entry("~/code/old", home: Self.home) == "~/code/old")
        for refused in ["", "  ", "~", "/Users/ada", "/Volumes/x", "!keep", "#c", "*.log", "~bob"] {
            #expect(FileExclusions.entry(refused, home: Self.home) == nil, "\(refused)")
        }
    }

    @Test("Files view: ⌘1 to ⌘3 step the filters and ⌘⇧. Show hidden, each a new ask; elsewhere the keys are the field's")
    func navigatorKeys() {
        var nav = MenuNavigator(entries: [])
        nav.home = Self.home
        nav.query = "budget"
        #expect(nav.handle(.filter(.kind, back: false)) == .ignored)
        #expect(nav.handle(.toggleHidden) == .ignored)
        nav.show(.file)
        #expect(nav.fileAsk == FileSearch.Ask(text: "budget"))
        #expect(nav.handle(.filter(.kind, back: false)) == .handled)
        #expect(nav.handle(.filter(.place, back: true)) == .handled)
        #expect(nav.handle(.filter(.when, back: false)) == .handled)
        #expect(nav.handle(.toggleHidden) == .handled)
        #expect(nav.fileAsk == FileSearch.Ask(text: "budget", filters: FileFilters(kind: .folders, place: .iCloud, when: .today, hidden: true)))
    }

    @Test("Typed filters show as chips and win over stepped ones; a chip's × or a step takes the typed word out of the search")
    func typedInTheNavigator() {
        var nav = MenuNavigator(entries: [])
        nav.home = Self.home
        nav.query = "kind:pdf"
        nav.show(.file)
        #expect(nav.fileAsk == nil, "a filter alone is no search")
        nav.query = "kind:pdf budget"
        nav.fileFilters.kind = .images
        #expect(nav.fileQuery == "budget")
        #expect(nav.fileAsk?.filters.kind == .ext("pdf"))
        // The row the index found by its filter is listed though its name does not spell `kind:pdf`.
        nav.provide(.file, MenuEntries.files([("/Users/ada/budget.pdf", nil)], home: Self.home))
        #expect(nav.rows.map(\.title) == ["budget.pdf"])
        nav.clearFilter(.kind)
        #expect(nav.query == "budget" && nav.shownFileFilters.kind == nil)
        nav.query = "budget when:today"
        nav.stepFilter(.when)
        #expect(nav.query == "budget" && nav.shownFileFilters.when == .week)
    }

    @Test("Search inside on a folder: Where becomes it and the Files view waits for a search; a file or an app has no such action")
    func searchInside() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FileFiltersTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Thing.app"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "notes.md"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let rows = MenuEntries.files([(folder.path, nil), (folder.appending(path: "notes.md").path, nil),
                                      (folder.appending(path: "Thing.app").path, nil)], home: Self.home)
        #expect(RowAction.list(for: rows[0], favourite: false).contains(.searchInside))
        #expect(!RowAction.list(for: rows[1], favourite: false).contains(.searchInside))
        #expect(!RowAction.list(for: rows[2], favourite: false).contains(.searchInside))

        var nav = MenuNavigator(entries: [])
        nav.query = "FileFiltersTests"
        nav.show(.file)
        nav.provide(.file, [rows[0]])
        _ = nav.handle(.commandK)
        while nav.actions?.selected != .row(.searchInside) { _ = nav.handle(.down) }
        #expect(nav.handle(.return) == .handled)
        #expect(nav.query.isEmpty && nav.inFiles && nav.rows.isEmpty)
        #expect(nav.fileFilters.place == .folder(folder.path))
        nav.query = "notes"
        #expect(nav.fileAsk?.filters.place == .folder(folder.path))
    }
}
