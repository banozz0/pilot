import Foundation
import JavaScriptCore
import SQLite3

// Node's `node:sqlite` under the prelude (sqlite.js, T7), on macOS's own SQLite, read-only: every database opens with
// SQLITE_OPEN_READONLY, so no statement can write; macOS's SQLite is built without extension loading (the SDK's
// sqlite3.h defines SQLITE_OMIT_LOAD_EXTENSION), so none can load. Enough for @raycast/utils' useSQL,
// which Chrome's history and VS Code's recent projects read through (`DatabaseSync`, `prepare().all()`). A failure comes
// back as `{"error": "ERR_SQLITE_ERROR", "message": …}`, as Native.swift's do.
@MainActor enum SQLiteBridge {
    private static var databases: [Int: OpaquePointer] = [:]
    private static var last = 0
    /// The most rows one statement answers; past it the answer is cut, as a LIMIT would.
    static let mostRows = 100_000

    static func install(into native: JSValue) {
        func add(_ name: String, _ block: Any) { native.setObject(block, forKeyedSubscript: name as NSString) }
        add("sqliteOpen", { (path: String) -> Any in open(path) } as @convention(block) (String) -> Any)
        add("sqliteAll", { (id: Int, sql: String, params: [Any]) -> Any in all(id, sql, params) } as @convention(block) (Int, String, [Any]) -> Any)
        add("sqliteClose", { (id: Int) in if let db = databases.removeValue(forKey: id) { sqlite3_close_v2(db) } } as @convention(block) (Int) -> Void)
    }

    static func failure(_ message: String) -> [String: Any] { ["error": "ERR_SQLITE_ERROR", "message": message] }

    static func open(_ path: String) -> Any {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(db)
            return failure("unable to open database file \(path): \(why)")
        }
        last += 1
        databases[last] = db
        return last
    }

    /// Every row `sql` answers, each an object by column name; parameters bound in order (numbers, text, null).
    static func all(_ id: Int, _ sql: String, _ params: [Any]) -> Any {
        guard let db = databases[id] else { return failure("database is not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return failure(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in params.enumerated() {
            let at = Int32(index + 1)
            switch value {
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 9e15 { sqlite3_bind_int64(statement, at, number.int64Value) }
                else { sqlite3_bind_double(statement, at, number.doubleValue) }
            case let number as NSNumber: sqlite3_bind_int64(statement, at, number.boolValue ? 1 : 0)
            case let text as String: sqlite3_bind_text(statement, at, text, -1, transient)
            default: sqlite3_bind_null(statement, at)
            }
        }
        var rows: [[String: Any]] = []
        while rows.count < mostRows {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return failure(String(cString: sqlite3_errmsg(db))) }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    // A blob goes as `{"$blob": base64}`, which sqlite.js turns into a Buffer, as Node answers a blob.
                    row[name] = ["$blob": sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count).base64EncodedString() } ?? ""]
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }
}
