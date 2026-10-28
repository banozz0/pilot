import Foundation
import SQLite3
import Synchronization

/// One image the text index finds by its words: the Files view lists it under the name hits (story 77).
struct ImageTextHit: Equatable, Sendable {
    let path: String
    let modified: Date
    /// The matched words in context, about 60 characters.
    let words: String
}

/// The words read from the images in Text in images' folders (Homy-style Files, Sven 2026-10-12): Pilot's own SQLite
/// file with an FTS5 table (in Apple's SQLite, checked 2026-10-12), so text search works while the file helper is
/// stopped. A row per image read: its path, size and modified time, which say whether it changed since, and its text,
/// empty for an image skipped or holding none. One connection, one call at a time: the reader writes from the
/// background while the menu searches.
final class ImageTextIndex: Sendable {
    private let db: Mutex<OpaquePointer?>

    /// Dates are kept as seconds since 2001, Date's own, so one read back equals the file's to the last bit.
    struct Entry: Equatable, Sendable {
        let size: Int64
        let modified: Date
    }

    enum Failure: Error { case sqlite(String) }

    /// Opens the file, making it on first use with `created` as the date its first pass started.
    init(file: URL, created: Date = Date()) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw Failure.sqlite(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(file.path)")
        }
        db = Mutex(handle)
        try exec("""
            PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA cache_size = -256;
            CREATE TABLE IF NOT EXISTS images (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, size INTEGER NOT NULL,
                modified REAL NOT NULL, text TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5(text, content = 'images', content_rowid = 'id',
                tokenize = 'unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS images_in AFTER INSERT ON images BEGIN
                INSERT INTO words (rowid, text) VALUES (new.id, new.text); END;
            CREATE TRIGGER IF NOT EXISTS images_out AFTER DELETE ON images BEGIN
                INSERT INTO words (words, rowid, text) VALUES ('delete', old.id, old.text); END;
            CREATE TRIGGER IF NOT EXISTS images_change AFTER UPDATE ON images BEGIN
                INSERT INTO words (words, rowid, text) VALUES ('delete', old.id, old.text);
                INSERT INTO words (rowid, text) VALUES (new.id, new.text); END;
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value REAL NOT NULL);
            """)
        try run("INSERT OR IGNORE INTO meta VALUES ('created', ?)", [.real(created.timeIntervalSinceReferenceDate)])
    }

    deinit { db.withLock { _ = sqlite3_close($0) } }

    /// When the first pass started: on battery it reads only images newer than this until it is done.
    var created: Date {
        Date(timeIntervalSinceReferenceDate: (try? query("SELECT value FROM meta WHERE key = 'created'", []) { $0.double(0) })?.first ?? 0)
    }

    /// Whether a pass has read every image in the folders once.
    var firstPassDone: Bool {
        get { ((try? query("SELECT value FROM meta WHERE key = 'firstPassDone'", []) { $0.double(0) })?.first ?? 0) != 0 }
        set { try? run("INSERT OR REPLACE INTO meta VALUES ('firstPassDone', ?)", [.real(newValue ? 1 : 0)]) }
    }

    /// Every image read, by path.
    func entries() throws -> [String: Entry] {
        Dictionary(uniqueKeysWithValues: try query("SELECT path, size, modified FROM images", []) {
            ($0.text(0) ?? "", Entry(size: $0.int64(1), modified: Date(timeIntervalSinceReferenceDate: $0.double(2))))
        })
    }

    /// Stores what each image holds, replacing what was read from it before, in one transaction.
    func set(_ images: [(path: String, entry: Entry, text: String)]) throws {
        try transaction(images) {
            try run("""
                INSERT INTO images (path, size, modified, text) VALUES (?, ?, ?, ?)
                ON CONFLICT (path) DO UPDATE SET size = excluded.size, modified = excluded.modified, text = excluded.text
                """, [.text($0.path), .int($0.entry.size), .real($0.entry.modified.timeIntervalSinceReferenceDate), .text($0.text)])
        }
    }

    func remove(_ paths: [String]) throws {
        try transaction(paths) { try run("DELETE FROM images WHERE path = ?", [.text($0)]) }
    }

    /// The images whose text holds every typed word, each as a word start: best match first, newest first on ties.
    func search(_ typed: String, limit: Int = 10) throws -> [ImageTextHit] {
        let words = typed.split { !$0.isLetter && !$0.isNumber }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        return try query("""
            SELECT path, modified, snippet(words, 0, '', '', '…', 10) FROM words JOIN images ON images.id = words.rowid
            WHERE words MATCH ? ORDER BY rank, modified DESC LIMIT ?
            """, [.text(match), .int(Int64(limit))]) {
            ImageTextHit(path: $0.text(0) ?? "", modified: Date(timeIntervalSinceReferenceDate: $0.double(1)),
                         words: ($0.text(2) ?? "").split(whereSeparator: \.isNewline).joined(separator: " "))
        }
    }

    // MARK: SQLite

    private enum Value { case int(Int64), real(Double), text(String) }

    private struct Row {
        let statement: OpaquePointer
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
    }

    /// `body` for each item, all or none kept.
    private func transaction<T>(_ items: [T], _ body: (T) throws -> Void) throws {
        guard !items.isEmpty else { return }
        try exec("BEGIN")
        do {
            for item in items { try body(item) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        try db.withLock { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.failure(db) }
        }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Value], _ read: (Row) -> T) throws -> [T] {
        try db.withLock { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Self.failure(db) }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in values.enumerated() {
                let slot = Int32(index + 1)
                switch value {
                case .int(let v): sqlite3_bind_int64(statement, slot, v)
                case .real(let v): sqlite3_bind_double(statement, slot, v)
                case .text(let v): sqlite3_bind_text(statement, slot, v, -1, transient)
                }
            }
            var rows: [T] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: rows.append(read(Row(statement: statement)))
                case SQLITE_DONE: return rows
                default: throw Self.failure(db)
                }
            }
        }
    }

    private static func failure(_ db: OpaquePointer?) -> Failure {
        .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }
}
