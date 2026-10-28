import Foundation
import SQLite3
import Testing
@testable import Clipboard

/// Sorting the history (card agent-bo-95422783, ClipBook's sort options: last copy, first copy, number of copies,
/// size, each either way round; no ClipBook code), and the migration that adds what they sort by.
@Suite("Clipboard sort")
struct SortTests {
    let database = TemporaryDatabase()

    func item(_ text: String, bytes: Int? = nil) -> ClipItem {
        ClipItem(kind: .text, text: text, contents: [["public.utf8-plain-text": Data(repeating: 65, count: bytes ?? text.utf8.count)]],
                 sourceApp: nil)
    }

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    /// A history file as card agent-bo-95422782 left it: version 1's rows plus the tag tables, user_version 2.
    static func writeVersion2(at path: URL) throws {
        try TagTests.writeVersion1(at: path)
        var db: OpaquePointer?
        try #require(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, """
            CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE, colour INTEGER NOT NULL);
            CREATE TABLE clip_tags (
                clip_id INTEGER NOT NULL REFERENCES clips (id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags (id) ON DELETE CASCADE, PRIMARY KEY (clip_id, tag_id));
            CREATE INDEX clip_tags_tag ON clip_tags (tag_id);
            INSERT INTO tags VALUES (1, 'work', 3);
            INSERT INTO clip_tags VALUES (1, 1);
            PRAGMA user_version = 2;
            """, nil, nil, nil) == SQLITE_OK)
    }

    @Test("Version 1 and version 2 files open with every row; old rows read first copy = last copy, 1 copy, their bytes")
    func migrates() throws {
        for (version, write) in [(1, TagTests.writeVersion1), (2, Self.writeVersion2)] {
            let file = TemporaryDatabase()
            try write(file.path)
            let store = try ClipboardStore(path: file.path)
            let clips = try store.recent()
            #expect(clips.map(\.text) == ["", "old copy"], "version \(version)")
            let old = try #require(clips.last)
            #expect(old.firstCopiedAt == old.copiedAt)
            #expect(old.copyCount == 1)
            #expect(old.size == 8 + 7)  // "old copy" plus its RTF
            #expect(clips.first?.size == 4)
            #expect(try store.contents(of: 1).first?.count == 2)
            if version == 2 { #expect(old.tags.map(\.name) == ["work"]) }
            #expect(try TagTests.userVersion(at: file.path) == Int32(ClipboardStore.migrations.count))
        }
    }

    @Test("A build from before the sort columns resets user_version to 1; the next open still works")
    func reopenAfterOlderBuild() throws {
        _ = try ClipboardStore(path: database.path)
        var db: OpaquePointer?
        try #require(sqlite3_open(database.path.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, "PRAGMA user_version = 1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = try ClipboardStore(path: database.path)
        try store.add(item("after"), at: at(1))
        #expect(try store.recent().first?.copyCount == 1)
    }

    @Test("The same text copied three times counts 3 and keeps its first copy time")
    func copyCount() throws {
        let store = try ClipboardStore(path: database.path)
        for second in [1.0, 5, 9] { try store.add(item("again"), at: at(second)) }
        let clip = try #require(try store.recent().first)
        #expect(clip.copyCount == 3)
        #expect(clip.firstCopiedAt == at(1))
        #expect(clip.copiedAt == at(9))
    }

    @Test("Each sort and its reverse orders a known set; the panel still puts pins first")
    func sorts() throws {
        let store = try ClipboardStore(path: database.path)
        // a: first at 1, last at 7, 2 copies, 30 bytes. b: 2, 2.3, 4, 10. c: 3, 8, 3, 20. Every sort orders them
        // differently from the others (c a b, c b a, b c a, a c b), so a sort reading the wrong column fails.
        try store.add(item("a", bytes: 30), at: at(1))
        for second in [2, 2.1, 2.2, 2.3] { try store.add(item("b", bytes: 10), at: at(second)) }
        try store.add(item("c", bytes: 20), at: at(3))
        try store.add(item("a", bytes: 30), at: at(7))
        try store.add(item("c", bytes: 20), at: at(6))
        try store.add(item("c", bytes: 20), at: at(8))
        func texts(_ sort: ClipSort, reversed: Bool = false) throws -> [String] {
            try store.search(ClipQuery("", order: ClipOrder(sort: sort, reversed: reversed)), appName: { _ in nil }).map(\.text)
        }
        #expect(try texts(.lastCopy) == ["c", "a", "b"])
        #expect(try texts(.lastCopy, reversed: true) == ["b", "a", "c"])
        #expect(try texts(.firstCopy) == ["c", "b", "a"])
        #expect(try texts(.firstCopy, reversed: true) == ["a", "b", "c"])
        #expect(try texts(.copies) == ["b", "c", "a"])
        #expect(try texts(.copies, reversed: true) == ["a", "c", "b"])
        #expect(try texts(.size) == ["a", "c", "b"])
        #expect(try texts(.size, reversed: true) == ["b", "c", "a"])
        // b is smallest, so pinning it shows the pin moving to the top.
        try store.setPinned(try #require(store.recent().first { $0.text == "b" }).id, true)
        let pinnedLast = try store.search(ClipQuery("", order: ClipOrder(sort: .size, reversed: false)), appName: { _ in nil })
        #expect(PanelRows.ordered(pinnedLast).map(\.text) == ["b", "a", "c"])
    }

    @Test("Cmd+S steps the sort, Cmd+Shift+S reverses it; the steps wrap")
    func keys() {
        #expect(PanelCommand(key: .character("s"), command: true, searchEmpty: false) == .cycleSort)
        #expect(PanelCommand(key: .character("s"), command: true, shift: true, searchEmpty: true) == .reverseSort)
        #expect(PanelCommand(key: .character("s"), searchEmpty: true) == nil)
        #expect(ClipSort.lastCopy.next == .firstCopy)
        #expect(ClipSort.size.next == .lastCopy)
    }

    @Test("The chosen sort survives a relaunch; a fresh Mac sorts by last copy, newest first")
    func setting() throws {
        let suite = testSuite()
        let defaults = try #require(UserDefaults(suiteName: suite))
        #expect(ClipboardSettings(defaults: defaults).order == ClipOrder(sort: .lastCopy, reversed: false))
        var settings = ClipboardSettings(defaults: defaults)
        settings.order = ClipOrder(sort: .copies, reversed: true)
        settings.save(to: defaults)
        #expect(ClipboardSettings(defaults: try #require(UserDefaults(suiteName: suite))).order == ClipOrder(sort: .copies, reversed: true))
    }
}
