import Foundation
import SQLite3
import Testing
@testable import Clipboard

/// Tags on clipboard items (card agent-bo-95422782, ClipBook's tags behaviour, no ClipBook code), and the store's
/// first migration: Sven's history file from before tags must open with every row and its contents.
@Suite("Clipboard tags")
struct TagTests {
    let database = TemporaryDatabase()

    func item(_ text: String) -> ClipItem {
        ClipItem(kind: .text, text: text, contents: [["public.utf8-plain-text": Data(text.utf8)]], sourceApp: "com.apple.TextEdit")
    }

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    /// A history file exactly as Pilot wrote it before card agent-bo-95422782 (schema of commit bf86c1d, user_version 1).
    static func writeVersion1(at path: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            PRAGMA journal_mode = WAL;
            PRAGMA user_version = 1;
            CREATE TABLE clips (
                id INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, source_app TEXT,
                pinned INTEGER NOT NULL DEFAULT 0, copied_at REAL NOT NULL, hash TEXT NOT NULL UNIQUE);
            CREATE INDEX clips_copied_at ON clips (copied_at);
            CREATE TABLE contents (
                clip_id INTEGER NOT NULL REFERENCES clips (id) ON DELETE CASCADE, item INTEGER NOT NULL,
                type TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY (clip_id, item, type));
            INSERT INTO clips VALUES (1, 'text', 'old copy', 'com.apple.TextEdit', 0, 1800000001, 'h1');
            INSERT INTO clips VALUES (2, 'image', '', NULL, 1, 1800000002, 'h2');
            INSERT INTO contents VALUES (1, 0, 'public.utf8-plain-text', X'6F6C6420636F7079');
            INSERT INTO contents VALUES (1, 0, 'public.rtf', X'7B5C727466317D');
            INSERT INTO contents VALUES (2, 0, 'public.png', X'89504E47');
            """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    static func userVersion(at path: URL) throws -> Int32 {
        var db: OpaquePointer?
        try #require(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int(statement, 0)
    }

    @Test("A version 1 history opens with every row and its contents, becomes the current version, and its rows take tags")
    func migratesVersion1() throws {
        try Self.writeVersion1(at: database.path)
        let store = try ClipboardStore(path: database.path)
        let clips = try store.recent()
        #expect(clips.map(\.text) == ["", "old copy"])
        #expect(clips.map(\.pinned) == [true, false])
        #expect(try store.contents(of: 1) == [["public.utf8-plain-text": Data("old copy".utf8), "public.rtf": Data(#"{\rtf1}"#.utf8)]])
        #expect(try store.contents(of: 2) == [["public.png": Data([0x89, 0x50, 0x4E, 0x47])]])
        #expect(try Self.userVersion(at: database.path) == Int32(ClipboardStore.migrations.count))
        let work = try store.tag([1], with: "work")
        #expect(try store.recent().first { $0.id == 1 }?.tags.map(\.name) == ["work"])
        #expect(work.name == "work")
        // A second open runs no migration twice.
        _ = try ClipboardStore(path: database.path)
        #expect(try ClipboardStore(path: database.path).recent().count == 2)
    }

    @Test("Tagging two rows tags both; a second tag keeps the first; one tag per name, any case")
    func tagging() throws {
        let store = try ClipboardStore(path: database.path)
        let a = try store.add(item("a"), at: at(1)), b = try store.add(item("b"), at: at(2))
        let work = try store.tag([a, b], with: "work")
        try store.tag([a], with: "Home")
        #expect(try store.tag([b], with: "WORK").id == work.id)
        let tags = Dictionary(uniqueKeysWithValues: try store.recent().map { ($0.text, Set($0.tags.map(\.name))) })
        #expect(tags["a"] == ["work", "Home"])
        #expect(tags["b"] == ["work"])
        #expect(try store.tags().map(\.name) == ["Home", "work"])
        #expect(Set(try store.tags().map(\.colour)).count == 2)
    }

    @Test("Untagging removes the tag from those rows only; deleting a tag untags every row; renaming keeps them")
    func untagDeleteRename() throws {
        let store = try ClipboardStore(path: database.path)
        let a = try store.add(item("a"), at: at(1)), b = try store.add(item("b"), at: at(2))
        let work = try store.tag([a, b], with: "work")
        try store.untag([a], from: work.id)
        #expect(try store.recent().map(\.tags.count) == [1, 0])
        try store.updateTag(ClipTag(id: work.id, name: "office", colour: 5))
        #expect(try store.recent().first?.tags.map(\.name) == ["office"])
        #expect(try store.tags().first?.colour == 5)
        try store.deleteTag(work.id)
        #expect(try store.recent().allSatisfy(\.tags.isEmpty))
        #expect(try store.tags().isEmpty)
        // Deleting a copy drops its tag links with it, and a tag on nothing else goes too (card agent-bo-95422986).
        try store.tag([a], with: "home")
        try store.delete(a)
        #expect(try store.tags().isEmpty)
    }

    @Test("#work lists only rows tagged work, combines with words, and is not lit as a word")
    func searchByTag() throws {
        let store = try ClipboardStore(path: database.path)
        let alpha = try store.add(item("alpha one"), at: at(1))
        try store.add(item("alpha two"), at: at(2))
        let beta = try store.add(item("beta"), at: at(3))
        try store.tag([alpha, beta], with: "Work")
        func texts(_ q: String) throws -> [String] { try store.search(ClipQuery(q), appName: { _ in nil }).map(\.text) }
        #expect(try texts("#work") == ["beta", "alpha one"])
        #expect(try texts("#work alpha") == ["alpha one"])
        #expect(try texts("#nothing").isEmpty)
        #expect(ClipQuery("#work alpha").highlights(in: "alpha #work").count == 1)
        // No tag has the name: it is the text, so a copied colour is still found.
        try store.add(item("#7aa2f7"), at: at(4))
        #expect(try texts("#7AA2F7") == ["#7aa2f7"])
    }

    @Test("A name with spaces is stored with dashes and found by #name; a rename does the same")
    func spacedNames() throws {
        let store = try ClipboardStore(path: database.path)
        let a = try store.add(item("a"), at: at(1))
        #expect(try store.tag([a], with: "  #my  work ").name == "my-work")
        #expect(TagChoice.list(typed: "my work", tags: try store.tags()) == [.existing(try #require(store.tags().first))])
        #expect(try store.search(ClipQuery("#my-work"), appName: { _ in nil }).map(\.text) == ["a"])
        var tag = try #require(try store.tags().first)
        tag.name = "home office"
        try store.updateTag(tag)
        #expect(try store.tags().map(\.name) == ["home-office"])
        tag.name = " # "
        #expect(throws: ClipboardStoreError.self) { try store.updateTag(tag) }
        #expect(throws: ClipboardStoreError.self) { try store.tag([a], with: "#") }
        #expect(try store.tags().map(\.name) == ["home-office"])
    }

    @Test("Clear history keeps the pins with their tags; a new tag takes the colour after the newest tag's")
    func clearAndColours() throws {
        let store = try ClipboardStore(path: database.path)
        let pinned = try store.add(item("pinned"), at: at(1)), loose = try store.add(item("loose"), at: at(2))
        try store.setPinned(pinned, true)
        try store.tag([pinned, loose], with: "keep")
        try store.clear()
        #expect(try store.recent().map(\.text) == ["pinned"])
        #expect(try store.recent().first?.tags.map(\.name) == ["keep"])
        // keep 0, b 1, c 2; with keep deleted, the next tag takes 3, not a colour c already has.
        try store.tag([pinned], with: "b")
        try store.tag([pinned], with: "c")
        try store.deleteTag(try #require(store.tags().first { $0.name == "keep" }).id)
        #expect(try store.tag([pinned], with: "d").colour == 3)
        #expect(try Set(store.tags().map(\.colour)).count == 3)
    }

    @Test("Cmd+T opens the tag field; while tagging, Return applies, Escape and Cmd+T leave, arrows move, letters type")
    func tagKeys() {
        #expect(PanelCommand(key: .character("t"), command: true, searchEmpty: false) == .tag)
        #expect(PanelCommand(key: .character("t"), searchEmpty: true) == nil)
        #expect(PanelCommand(key: .return, prompting: true, searchEmpty: false) == .confirm)
        #expect(PanelCommand(key: .return, command: true, prompting: true, searchEmpty: false) == .confirm)
        #expect(PanelCommand(key: .escape, prompting: true, searchEmpty: true) == .dismiss)
        #expect(PanelCommand(key: .character("t"), command: true, prompting: true, searchEmpty: true) == .dismiss)
        #expect(PanelCommand(key: .down, prompting: true, searchEmpty: true) == .move(1))
        #expect(PanelCommand(key: .backspace, prompting: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .character("1"), prompting: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .tab, prompting: true, searchEmpty: true) == nil)
    }

    @Test("The tag list offers to create a new name first, then the tags that contain what was typed")
    func choices() {
        let tags = [ClipTag(id: 1, name: "work", colour: 0), ClipTag(id: 2, name: "homework", colour: 1), ClipTag(id: 3, name: "home", colour: 2)]
        #expect(TagChoice.list(typed: "wor", tags: tags) == [.create("wor"), .existing(tags[0]), .existing(tags[1])])
        #expect(TagChoice.list(typed: "#Work ", tags: tags) == [.existing(tags[0]), .existing(tags[1])])
        #expect(TagChoice.list(typed: "", tags: tags) == tags.map(TagChoice.existing))
    }

    @Test("A tag's tab lists only that tag's copies, and the search still narrows it")
    func tagTab() throws {
        let store = try ClipboardStore(path: database.path)
        let a = try store.add(item("alpha one"), at: at(1)), b = try store.add(item("beta"), at: at(2))
        let c = try store.add(item("alpha two"), at: at(3))
        let work = try store.tag([a, b], with: "work"), todo = try store.tag([c], with: "todo")
        func texts(_ typed: String, _ tag: ClipTag) throws -> [String] { try store.search(ClipQuery(typed, tab: .tag(tag))).map(\.text) }
        #expect(try texts("", work) == ["beta", "alpha one"])
        #expect(try texts("", todo) == ["alpha two"])
        #expect(try texts("alpha", work) == ["alpha one"])
        #expect(try store.search(ClipQuery("", tab: .kind(.all))).count == 3)
    }

    @Test("A tag goes when its last item loses it, by untag or by the item's delete; a tag still on an item stays")
    func emptyTagGoes() throws {
        let store = try ClipboardStore(path: database.path)
        let a = try store.add(item("alpha"), at: at(1)), b = try store.add(item("beta"), at: at(2))
        let work = try store.tag([a, b], with: "work")
        try store.tag([b], with: "todo")
        try store.untag([a], from: work.id)
        #expect(try store.tags().map(\.name) == ["todo", "work"])
        try store.untag([b], from: work.id)
        #expect(try store.tags().map(\.name) == ["todo"])
        try store.delete(b)
        #expect(try store.tags().isEmpty)
        #expect(try store.recent().map(\.text) == ["alpha"])
    }

    @Test("A history from before card agent-bo-95422986 opens with its empty tags gone and its used ones kept")
    func migrationDropsEmptyTags() throws {
        do {
            let store = try ClipboardStore(path: database.path)
            try store.tag([try store.add(item("alpha"), at: at(1))], with: "kept")
        }
        // As a version 4 file left it: no trigger, and a tag no item has.
        var db: OpaquePointer?
        try #require(sqlite3_open(database.path.path, &db) == SQLITE_OK)
        let sql = "DROP TRIGGER IF EXISTS tags_gone_when_empty; INSERT INTO tags (name, colour) VALUES ('empty', 1); PRAGMA user_version = 4;"
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = try ClipboardStore(path: database.path)
        #expect(try store.tags().map(\.name) == ["kept"])
        try store.untag([1], from: try #require(store.tags().first).id)
        #expect(try store.tags().isEmpty, "the trigger is back after the migration")
    }

    @Test("Deleting a tag on purpose keeps every item it was on")
    func deleteKeepsItems() throws {
        let store = try ClipboardStore(path: database.path)
        let a = try store.add(item("alpha"), at: at(1)), b = try store.add(item("beta"), at: at(2))
        let work = try store.tag([a, b], with: "work")
        try store.deleteTag(work.id)
        #expect(try store.tags().isEmpty)
        #expect(try store.recent().count == 2)
        #expect(try store.recent().allSatisfy { $0.tags.isEmpty })
    }
}
