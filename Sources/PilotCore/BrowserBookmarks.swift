import Foundation
import SQLite3

/// Browser bookmarks in Hyper+Space's search, and pages from a browser's history behind `hist <words>` (spec launcher-best
/// T9; history off until switched on, Q328). Pure: what each browser family keeps where, how its files read, and the rows
/// they make. The reading itself (Full Disk Access, copies of the SQLite files, the cache) is BrowserReader's. Titles and
/// URLs are another app's private record: nothing here logs them.
public enum BrowserBookmarks {
    /// A page a bookmark or a history visit names, and the browser that keeps it.
    public struct Page: Equatable, Sendable {
        public let title: String, url: String
        /// The last visit, for a history page; nil for a bookmark.
        public var visited: Date?
        public init(title: String, url: String, visited: Date? = nil) { self.title = title; self.url = url; self.visited = visited }
    }

    /// How a browser keeps its pages, under the home folder.
    public enum Family: Equatable, Sendable {
        /// Each profile's `Bookmarks` (JSON) and `History` (SQLite) under Application Support/`folder`.
        case chromium(folder: String)
        /// `Library/Safari`'s `Bookmarks.plist` and `History.db`.
        case safari
        /// Each profile's `places.sqlite` under Application Support/`folder`/Profiles, bookmarks and history in one.
        case firefox(folder: String)
    }

    /// A browser the menu reads, by the name its rows show.
    public struct Browser: Equatable, Sendable {
        public let name: String, bundle: String, family: Family
    }

    /// The browsers read, Safari first, then every Chromium browser WebSearch knows (its one table of their folders), then
    /// the Firefox family; a browser with no files on this Mac adds nothing.
    public static let browsers: [Browser] = [Browser(name: "Safari", bundle: "com.apple.Safari", family: .safari)]
        + WebSearch.chromium.sorted { $0.key < $1.key }.map { bundle, browser in
            Browser(name: names[bundle] ?? browser.folder.split(separator: "/").first.map(String.init) ?? bundle, bundle: bundle,
                    family: .chromium(folder: browser.folder))
        }
        + [("Firefox", "org.mozilla.firefox", "Firefox"), ("Zen", "app.zen-browser.zen", "zen"), ("LibreWolf", "org.mozilla.librewolf", "librewolf"),
           ("Floorp", "one.ablaze.floorp", "Floorp"), ("Waterfox", "net.waterfox.waterfox", "Waterfox")]
        .map { Browser(name: $0.0, bundle: $0.1, family: .firefox(folder: $0.2)) }

    /// The names rows show where a browser's folder does not say it.
    private static let names = [
        "com.google.Chrome": "Chrome", "com.google.Chrome.beta": "Chrome Beta", "com.google.Chrome.canary": "Chrome Canary",
        "com.brave.Browser": "Brave", "com.microsoft.edgemac": "Edge", "company.thebrowser.Browser": "Arc",
    ]

    /// The most bookmarks the menu keeps, and the most history pages one `hist` search lists.
    public static let bookmarkCap = 5000, historyCap = 50

    // MARK: Files

    /// A profile's files: its bookmarks file and its history database, one file in Firefox's.
    public struct Profile: Equatable, Sendable {
        public let bookmarks: URL, history: URL
    }

    /// `browser`'s profiles under `home` that hold a bookmarks file or a history database. Chromium's are `Default` and
    /// `Profile N`, Firefox's every folder under Profiles; reading the folder names asks nothing of the browser.
    public static func profiles(_ browser: Browser, home: URL) -> [Profile] {
        let support = home.appending(path: "Library/Application Support")
        let manager = FileManager.default
        func folders(_ root: URL) -> [URL] {
            ((try? manager.contentsOfDirectory(atPath: root.path)) ?? []).sorted().map { root.appending(path: $0) }
        }
        switch browser.family {
        case .safari:
            let root = home.appending(path: "Library/Safari")
            return [Profile(bookmarks: root.appending(path: "Bookmarks.plist"), history: root.appending(path: "History.db"))]
        case .chromium(let folder):
            return folders(support.appending(path: folder))
                .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
                .map { Profile(bookmarks: $0.appending(path: "Bookmarks"), history: $0.appending(path: "History")) }
        case .firefox(let folder):
            return folders(support.appending(path: folder).appending(path: "Profiles"))
                .map { $0.appending(path: "places.sqlite") }.map { Profile(bookmarks: $0, history: $0) }
        }
    }

    /// A SQLite file and its sidecars, which must be copied with it: a WAL database's newest pages are in `-wal`.
    public static func sidecars(of database: URL) -> [URL] {
        ["-wal", "-journal"].map { URL(fileURLWithPath: database.path + $0) }
    }

    // MARK: Reading

    /// A Chromium profile's `Bookmarks` file: every bookmark in its bar, Other and Mobile folders, depth first.
    public static func chromium(_ data: Data) -> [Page] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let roots = json["roots"] as? [String: Any] else { return [] }
        var pages: [Page] = []
        func walk(_ node: [String: Any]) {
            guard pages.count < bookmarkCap else { return }
            if node["type"] as? String == "url", let url = node["url"] as? String {
                pages.append(Page(title: node["name"] as? String ?? "", url: url))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for key in ["bookmark_bar", "other", "synced"] { if let root = roots[key] as? [String: Any] { walk(root) } }
        return pages
    }

    /// Safari's `Bookmarks.plist`: every leaf, the Reading List's included, depth first.
    public static func safari(_ data: Data) -> [Page] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var pages: [Page] = []
        func walk(_ node: [String: Any]) {
            guard pages.count < bookmarkCap else { return }
            if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf", let url = node["URLString"] as? String {
                pages.append(Page(title: (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? "", url: url))
            }
            for child in node["Children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(plist)
        return pages
    }

    /// Firefox's bookmarks, from a copy of `places.sqlite`.
    public static func firefoxBookmarks(copy: URL) -> [Page] {
        query(copy, "SELECT p.url, b.title FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk WHERE b.type = 1 LIMIT \(bookmarkCap)", words: [])
    }

    /// The pages `words` find in a copy of `family`'s history database, the last visited first: each word in the title or
    /// the address. Nothing typed lists the last visited.
    public static func history(_ family: Family, copy: URL, words: [String]) -> [Page] {
        let (table, title, url, last, group): (String, String, String, String, String) = switch family {
        case .chromium: ("urls WHERE hidden = 0", "title", "url", "last_visit_time", "url")
        case .safari: ("history_items i JOIN history_visits v ON v.history_item = i.id WHERE 1", "v.title", "i.url", "v.visit_time", "i.id")
        case .firefox: ("moz_places WHERE last_visit_date IS NOT NULL", "title", "url", "last_visit_date", "url")
        }
        let match = words.indices.map { " AND (\(title) LIKE ?\($0 + 1) ESCAPE '\\' OR \(url) LIKE ?\($0 + 1) ESCAPE '\\')" }.joined()
        let sql = "SELECT \(url), \(title), MAX(\(last)) AS seen FROM \(table)\(match) GROUP BY \(group) ORDER BY seen DESC LIMIT \(historyCap * 2)"
        return query(copy, sql, words: words.map { "%" + like($0) + "%" }, visit: { visit(family, $0) })
    }

    /// A visit's time as `family` stores it, as a date: Chromium's microseconds since 1601, Safari's seconds since 2001,
    /// Firefox's microseconds since 1970.
    static func visit(_ family: Family, _ raw: Double) -> Date {
        switch family {
        case .chromium: Date(timeIntervalSince1970: raw / 1_000_000 - 11_644_473_600)
        case .safari: Date(timeIntervalSinceReferenceDate: raw)
        case .firefox: Date(timeIntervalSince1970: raw / 1_000_000)
        }
    }

    /// `word` with LIKE's wildcards escaped, so `100%` matches itself.
    static func like(_ word: String) -> String {
        word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// `sql`'s rows (address, title, and a third column's number as the stored visit) from the database at `copy`; none
    /// when it does not open or read. Only ever a copy BrowserReader made, never the browser's own file, so its lock is never
    /// touched; opened for writing, as SQLite folds a copied `-wal` into its copy only so (a read-only open with no `-shm`
    /// refuses a WAL database).
    static func query(_ copy: URL, _ sql: String, words: [String], visit: ((Double) -> Date)? = nil) -> [Page] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return [] }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, word) in words.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), word, -1, transient) }
        var pages: [Page] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            let seen = visit.flatMap { visit in sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : visit(sqlite3_column_double(statement, 2)) }
            pages.append(Page(title: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "", url: url, visited: seen))
        }
        return pages
    }

    // MARK: Rows

    /// The words after `hist ` at the root, nil for any other search: `hist invoice` searches history for invoice.
    public static func historyWords(_ query: String) -> [String]? {
        guard query.lowercased().hasPrefix("hist ") else { return nil }
        return query.dropFirst(5).split(separator: " ").map(String.init)
    }

    /// Web pages only, once each by address, in the order given: a `javascript:` bookmarklet or a `file:` link never
    /// becomes a row Return opens.
    public static func web(_ pages: [Page]) -> [Page] {
        var seen = Set<String>()
        return pages.filter { page in
            guard let scheme = URL(string: page.url)?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
            return seen.insert(page.url).inserted
        }
    }

    /// The menu's rows for `pages` kept by `browser`: the title (else the address's host), the browser as its subtitle and
    /// icon, Return opening the page in that browser. A bookmark is found by its title and host as any row is and ranks
    /// with picks; a history page is listed only behind `hist` and is never a pick (MenuEntry.frecencyKey), so no visited
    /// address lands in Pilot's ranking.
    public static func rows(_ pages: [Page], browser: Browser, kind: MenuEntry.Kind) -> [MenuEntry] {
        web(pages).map { page in
            let host = URL(string: page.url)?.host() ?? page.url
            let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return MenuEntry(title: title.isEmpty ? host : title, target: .action(AppLink.url(bundle: browser.bundle, url: page.url).id),
                             inSearch: kind == .bookmark, keywords: host, ownKind: kind, app: browser.bundle, subtitle: browser.name)
        }
    }

    /// `hist` while history is off (Q328): the one row, Return opening Launcher › More rows where it is switched on.
    public static let historyOff = MenuEntry(title: "Browser history is off", target: .openPage(AppPlace(.menuExtras)),
                                             detail: "Return opens Launcher › More rows to switch it on", inSearch: false, ownKind: .history)
}
