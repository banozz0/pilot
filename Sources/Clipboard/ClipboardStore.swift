import Foundation
import SQLite3

/// One history row as the panel lists it; its pasteboard data comes from `contents(of:)` when it is pasted.
public struct StoredClip: Equatable, Sendable {
    public let id: Int64
    public var kind: ClipKind
    public var text: String
    public var sourceApp: String?
    public var copiedAt: Date
    public var pinned: Bool
    /// Its tags, by name.
    public var tags: [ClipTag] = []
    /// When it was first copied, how often, and its bytes: what the panel sorts by besides the last copy.
    public var firstCopiedAt = Date(timeIntervalSince1970: 0)
    public var copyCount = 1
    public var size = 0

    /// The name it was given (Cmd+K, Rename), if any.
    public var customTitle: String?

    /// The text read from an image (card agent-bo-95423070): nil until it is read, empty when it holds none.
    public var recognised: String?

    /// When a copied card number or key leaves the history (P65); nil for every other copy and for a pinned one.
    public var expiresAt: Date?

    /// What the panel shows for it: its name, else the text, or "Image" for a copy with none.
    public var title: String { customTitle ?? (text.isEmpty ? "Image" : text) }

    /// What a plain paste writes: the text, or for an image the text read from it.
    public var plainText: String { text.isEmpty ? recognised ?? "" : text }
    /// An image whose text ClipboardOCR has not read yet (ClipboardStore.unreadImages): the search cannot find it by its words until then.
    public var isReadingText: Bool { kind == .image && recognised == nil }
}

/// A tag on clipboard items: a name, one per name in any case, and one of eight colours the panel draws.
public struct ClipTag: Hashable, Sendable {
    public let id: Int64
    public var name: String
    public var colour: Int

    public static let colours = 8

    /// A tag's name as stored: no leading #, spaces as dashes, so `#name` in the search is one word that finds it.
    public static func name(_ typed: String) -> String {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("#") { name.removeFirst() }
        return name.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }
}

public enum ClipboardStoreError: Error {
    case sqlite(String)
}

/// Clipboard history in SQLite: newest first, the same contents kept once, unpinned items capped
/// (500 by default) and dropped past `maxAge` (none by default) or, a copied card number or key, past its timer (P65),
/// pinned ones exempt, so a full history is `cap` rows plus the pins (SPEC.md, the Clipboard history line; Settings ›
/// Clipboard sets the limits and the timer).
public final class ClipboardStore {
    /// Unpinned rows kept; a change takes effect on the next copy or `prune`.
    public var cap: Int
    /// Seconds an unpinned row is kept; nil keeps it until the cap pushes it out.
    public var maxAge: TimeInterval?
    /// Seconds a copied card number or key is kept (P65); nil, they are kept as any other copy. `setSecretLifetime` sets it.
    public private(set) var secretLifetime: TimeInterval?
    /// The soonest a copied secret goes, kept in memory so the watcher's poll reads SQLite only once it passes: every
    /// write that times a row lowers it, so an edit, a format, a split or a merge needs no call to rearm; prune reads it again.
    /// Early is harmless (that prune finds nothing due), late would keep a secret past its time.
    public private(set) var soonestExpiry: Date?
    private var db: OpaquePointer?

    public init(path: URL, cap: Int = ClipboardSettings.default.keepCount) throws {
        self.cap = cap
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw error() }
        try exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        try migrate()
        try readSoonestExpiry()
    }

    static let migrations: [@Sendable (ClipboardStore) throws -> Void] = [
        // 1: the first history (card agent-bo-95422770 and before).
        { try $0.exec("""
            CREATE TABLE IF NOT EXISTS clips (
                id INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, source_app TEXT,
                pinned INTEGER NOT NULL DEFAULT 0, copied_at REAL NOT NULL, hash TEXT NOT NULL UNIQUE);
            CREATE INDEX IF NOT EXISTS clips_copied_at ON clips (copied_at);
            CREATE TABLE IF NOT EXISTS contents (
                clip_id INTEGER NOT NULL REFERENCES clips (id) ON DELETE CASCADE, item INTEGER NOT NULL,
                type TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY (clip_id, item, type));
            """) },
        // 2: tags (card agent-bo-95422782); a name is one tag whatever its case.
        { try $0.exec("""
            CREATE TABLE IF NOT EXISTS tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE, colour INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS clip_tags (
                clip_id INTEGER NOT NULL REFERENCES clips (id) ON DELETE CASCADE,
                tag_id INTEGER NOT NULL REFERENCES tags (id) ON DELETE CASCADE, PRIMARY KEY (clip_id, tag_id));
            CREATE INDEX IF NOT EXISTS clip_tags_tag ON clip_tags (tag_id);
            """) },
        // 3: what the panel sorts by (card agent-bo-95422783). Old rows: first copy = last copy, one copy, the bytes
        // of their contents; rows an older build added since are filled the same way.
        { store in
            try store.addColumn("first_copied_at", "REAL")
            try store.addColumn("copy_count", "INTEGER NOT NULL DEFAULT 1")
            try store.addColumn("size", "INTEGER NOT NULL DEFAULT 0")
            try store.exec("UPDATE clips SET first_copied_at = copied_at WHERE first_copied_at IS NULL")
            try store.exec("UPDATE clips SET \(sizeFromContents) WHERE size = 0")
        },
        // 4: a name given to a copy, shown and searched instead of its text (card agent-bo-95422784).
        { try $0.addColumn("title", "TEXT") },
        // 5: a tag lives while it tags something (card agent-bo-95422986): it goes with its last item, by untag, the
        // item's delete or the history's cap alike; old empty tags go now.
        { try $0.exec("""
            CREATE TRIGGER IF NOT EXISTS tags_gone_when_empty AFTER DELETE ON clip_tags
            WHEN NOT EXISTS (SELECT 1 FROM clip_tags WHERE tag_id = OLD.tag_id)
            BEGIN DELETE FROM tags WHERE id = OLD.tag_id; END;
            DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM clip_tags);
            """) },
        // 6: the text read from an image (card agent-bo-95423070); NULL until ClipboardOCR reads it, every old image too.
        { try $0.addColumn("recognised", "TEXT") },
        // 7: when a copied card number or key goes (P65); NULL for every row from before, so none of them expires.
        { try $0.addColumn("expires_at", "REAL") },
    ]

    /// Each step brings the file from the version before it, so Sven's history from any earlier build opens with
    /// every row (TagTests' and SortTests' fixtures). Steps are safe to run again: a build from before card
    /// agent-bo-95422782 sets user_version back to 1 whenever it opens the file.
    private func migrate() throws {
        let version = try query("PRAGMA user_version", []) { Int($0.int64(0)) }.first ?? 0
        guard version < Self.migrations.count else { return }
        try transaction {
            for step in Self.migrations[version...] { try step(self) }
            try exec("PRAGMA user_version = \(Self.migrations.count)")
        }
    }

    /// Adds a column to clips unless a run of this step before already did.
    private func addColumn(_ name: String, _ type: String) throws {
        let columns = try query("PRAGMA table_info(clips)", []) { $0.text(1) ?? "" }
        if !columns.contains(name) { try exec("ALTER TABLE clips ADD COLUMN \(name) \(type)") }
    }

    /// A copy's size: the bytes of every representation kept, set on a new copy and by migration 3.
    private static let sizeFromContents = "size = (SELECT coalesce(sum(length(data)), 0) FROM contents WHERE clip_id = clips.id)"

    deinit { sqlite3_close(db) }

    /// Stores a copy and returns its id; a copy already in the history moves to the top instead.
    @discardableResult
    public func add(_ item: ClipItem, at date: Date = Date()) throws -> Int64 {
        try transaction {
            let id = try upsert(item, at: date)
            try prune(now: date)
            return id
        }
    }

    /// A copy already in the history moves to `date` and counts once more; a new one goes in with its contents.
    private func upsert(_ item: ClipItem, at date: Date) throws -> Int64 {
        let ends = expiry(item, at: date)
        lowerSoonestExpiry(ends)
        let expires = ends.map { Value.real($0.timeIntervalSince1970) } ?? .text(nil)
        if let id = try query("SELECT id FROM clips WHERE hash = ?", [.text(item.contentHash)], { $0.int64(0) }).first {
            // Copied again, its timer starts again; a pinned one has none.
            try run("UPDATE clips SET copied_at = ?, source_app = ?, copy_count = copy_count + 1, expires_at = CASE WHEN pinned = 0 THEN ? END WHERE id = ?",
                    [.real(date.timeIntervalSince1970), .text(item.sourceApp), expires, .int(id)])
            return id
        }
        try run("INSERT INTO clips (kind, text, source_app, copied_at, first_copied_at, hash, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.text(item.kind.rawValue), .text(item.text), .text(item.sourceApp), .real(date.timeIntervalSince1970),
                 .real(date.timeIntervalSince1970), .text(item.contentHash), expires])
        let id = sqlite3_last_insert_rowid(db)
        try writeContents(id, item)
        return id
    }

    /// The row's pasteboard items, replacing any it had, and its size.
    private func writeContents(_ id: Int64, _ item: ClipItem) throws {
        try run("DELETE FROM contents WHERE clip_id = ?", [.int(id)])
        for (index, representations) in item.contents.enumerated() {
            for (type, data) in representations {
                try run("INSERT INTO contents (clip_id, item, type, data) VALUES (?, ?, ?, ?)",
                        [.int(id), .int(Int64(index)), .text(type), .blob(data)])
            }
        }
        try run("UPDATE clips SET \(Self.sizeFromContents) WHERE id = ?", [.int(id)])
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Drops the unpinned rows past the cap, older than `maxAge` or past their expiry; walks only the rows past the cap.
    public func prune(now: Date = Date()) throws {
        try run("""
            DELETE FROM clips WHERE pinned = 0 AND (copied_at < ? OR expires_at <= ? OR id IN
                (SELECT id FROM clips WHERE pinned = 0 ORDER BY copied_at DESC, id DESC LIMIT -1 OFFSET ?))
            """, [.real(maxAge.map { now.timeIntervalSince1970 - $0 } ?? 0), .real(now.timeIntervalSince1970), .int(Int64(cap))])
        if soonestExpiry != nil { try readSoonestExpiry() }
    }

    // MARK: Secrets expire (P65)

    /// Longer copies are not read for secrets: the watcher stores on the main thread, which the tap shares, and a long
    /// log through Sensitive's patterns would stall typing.
    static let secretScanLimit = 10_000

    /// A text copy holding a card number or key Sensitive finds (AutoRedact.swift); email, IP addresses and phone numbers
    /// don't count. Each key is judged on its own: a hex id is no key wherever it sits (a commit link, a path, a `git log`
    /// line, JSON's id, `invoice-<uuid>.pdf`, `request_id=<uuid>`), since Sensitive's random-run rule reads it as one and
    /// expiring it would delete a plain copy. A hex value after a label (`token: …`, `"secret": "…"`) or `Bearer` still
    /// counts, and so do a JWT (`eyJ…` is not hex) and a key word's tail (`sk_…`, `api-…`, `key-…`).
    public static func holdsSecret(_ item: ClipItem) -> Bool {
        guard item.kind == .text || item.kind == .richText, item.text.utf16.count <= secretScanLimit else { return false }
        let text = item.text
        return Sensitive.find(in: text).contains { found in
            switch found.kind {
            case .card: true
            case .key: !isHexID(text, found.range)
            case .email, .address, .phone: false
            }
        }
    }

    /// A key match that is a hex id, with no label or `Bearer` right before it. Split on `-`, `_`, `=` and `+`, empty parts
    /// skipped: every part is all hex or letters only and not a key word, and at least one is hex (`<uuid>`,
    /// `invoice-<uuid>`, `report-<uuid>-final`, `author_id=<uuid>`, `--fixup=<sha>`). A key word part (`key-…`, `sk_…`,
    /// `api-…`, `client_secret` before `=`, `nw_live_…`) or a mixed one (`md5=…`, `v2_…`) keeps it a key.
    private static func isHexID(_ text: String, _ range: Range<String.Index>) -> Bool {
        let parts = text[range].split { "-_=+".contains($0) }
        guard parts.contains(where: { $0.allSatisfy(\.isHexDigit) }),
              parts.allSatisfy({ $0.allSatisfy(\.isHexDigit) || ($0.allSatisfy(\.isLetter) && !isKeyWord($0.lowercased())) })
        else { return false }
        let start = text.index(range.lowerBound, offsetBy: -48, limitedBy: text.startIndex) ?? text.startIndex
        let before = String(text[start..<range.lowerBound])
        return labelBefore.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) == nil
    }

    /// A part that heads a key: a key word, or a label glued to its name (`clientsecret`, `apitoken`, `refreshtoken`).
    /// No ends-in-`key` or ends-in-`pass` test: `monkey`, `hockey`, `compass` are plain words.
    private static func isKeyWord(_ word: String) -> Bool {
        keyWords.contains(word) || ["token", "secret", "password", "passwd", "pwd", "apikey"].contains { word.hasSuffix($0) }
    }

    /// Words that head a key rather than a file or field name, matched as a whole part, never inside one (`author`,
    /// `passport`, `keyboard` are plain words): labels and their fused forms, key prefixes, and Shopify's `shpat_`,
    /// `shpca_`, `shppa_`, `shpss_` and Postman's `PMAK-` (gitleaks' default rules).
    private static let keyWords: Set<String> = [
        "key", "token", "secret", "api", "auth", "pass", "pwd", "apikey", "accesskey", "secretkey", "authtoken",
        "accesstoken", "password", "passwd", "sk", "pk", "rk", "live", "shpat", "shpca", "shppa", "shpss", "pmak",
        "privatekey", "signingkey", "masterkey", "appkey", "clientkey", "sessionkey", "encryptionkey", "consumerkey",
        "deploykey", "webhookkey",
    ]

    /// Sensitive's `labelled` and `bearer` shapes, read backwards from a value: also inside a longer name
    /// (`client_secret` then `=`) or JSON quotes (`"token": "`), so a labelled hex value is never let off.
    private static let labelBefore = try! NSRegularExpression(
        pattern: #"(?i)(?:(?:api[ _-]?key|secret|passw(?:or)?d|pwd|token)["']?\s*[:=]|bearer)\s*["']?$"#)

    /// When a copy made at `date` goes: only a secret's, and only while the setting is on.
    private func expiry(_ item: ClipItem, at date: Date) -> Date? {
        guard let secretLifetime, Self.holdsSecret(item) else { return nil }
        return date.addingTimeInterval(secretLifetime)
    }

    /// A new lifetime moves every deadline still waiting by the difference, so each timer keeps its start (a copy, or an
    /// edit); nil (the setting off) keeps them all for good, and turning it on again times only the copies made after.
    /// The first call, as the store opens, keeps the deadlines it finds: they were set with this lifetime. One already
    /// past its time goes first: a longer timer, or the switch off, never brings back a secret the history had stopped showing.
    public func setSecretLifetime(_ lifetime: TimeInterval?, now: Date = Date()) throws {
        try run("DELETE FROM clips WHERE pinned = 0 AND expires_at <= ?", [.real(now.timeIntervalSince1970)])
        let old = secretLifetime
        secretLifetime = lifetime
        if lifetime == nil {
            try run("UPDATE clips SET expires_at = NULL WHERE expires_at IS NOT NULL", [])
        } else if let lifetime, let old, lifetime != old {
            try run("UPDATE clips SET expires_at = expires_at + ? WHERE expires_at IS NOT NULL", [.real(lifetime - old)])
        }
        try readSoonestExpiry()
    }

    private func readSoonestExpiry() throws {
        soonestExpiry = try query("SELECT min(expires_at) FROM clips WHERE expires_at IS NOT NULL", []) {
            $0.optionalDouble(0).map(Date.init(timeIntervalSince1970:))
        }.first ?? nil
    }

    private func lowerSoonestExpiry(_ date: Date?) {
        guard let date else { return }
        soonestExpiry = min(soonestExpiry ?? date, date)
    }

    /// Clear history: every unpinned row goes, the pins stay.
    public func clear() throws {
        try run("DELETE FROM clips WHERE pinned = 0", [])
    }

    public func recent() throws -> [StoredClip] {
        try search(ClipQuery(""))
    }

    /// The panel's search, newest first (ClipQuery says what it matches).
    /// `appName` gives an app's name for `app:`; each bundle id is looked up once per search.
    public func search(_ query: ClipQuery, appName: (String) -> String? = ClipQuery.installedAppName) throws -> [StoredClip] {
        let condition = query.condition
        var names: [String: String?] = [:]
        func name(_ id: String) -> String? {
            if let known = names[id] { return known }
            let found = appName(id)
            names[id] = found
            return found
        }
        return query.ranked(try clips(where: condition.sql, condition.values.map { .text($0) }, order: query.order), appName: name)
    }

    /// The rows with these ids, in the order given, each once; an id not in the history is left out (the pilot
    /// command, CLI W11).
    public func clips(_ ids: [Int64]) throws -> [StoredClip] {
        let byID = Dictionary(try clips(where: "id IN (SELECT value FROM json_each(?))", [.text(Self.json(ids))]).map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }.compactMap { byID[$0] }
    }

    /// How many items the history holds, and how many of them are pinned, counted without reading them.
    public func counts() throws -> (all: Int, pinned: Int) {
        try query("SELECT COUNT(*), coalesce(sum(pinned), 0) FROM clips WHERE \(Self.unexpired)", [.real(Date().timeIntervalSince1970)]) { (Int($0.int64(0)), Int($0.int64(1))) }.first ?? (0, 0)
    }

    /// The copy's pasteboard items, one dictionary of type → data each, in their original order.
    public func contents(of id: Int64) throws -> [[String: Data]] {
        var items: [Int64: [String: Data]] = [:]
        for (index, type, data) in try query("SELECT item, type, data FROM contents WHERE clip_id = ?", [.int(id)], {
            ($0.int64(0), $0.text(1) ?? "", $0.blob(2))
        }) { items[index, default: [:]][type] = data }
        return items.keys.sorted().compactMap { items[$0] }
    }

    public func setPinned(_ id: Int64, _ pinned: Bool) throws {
        try setPinned([id], pinned)
    }

    /// Several rows in one statement: Cmd+A then Cmd+P is one write, not 500 commits. A pinned secret is kept for good:
    /// its timer goes, and unpinning it later does not bring the timer back.
    public func setPinned(_ ids: [Int64], _ pinned: Bool) throws {
        try run("UPDATE clips SET pinned = ?, expires_at = CASE WHEN ? THEN NULL ELSE expires_at END WHERE id IN (SELECT value FROM json_each(?))",
                [.int(pinned ? 1 : 0), .int(pinned ? 1 : 0), .text(Self.json(ids))])
    }

    public func delete(_ id: Int64) throws {
        try delete([id])
    }

    public func delete(_ ids: [Int64]) throws {
        try run("DELETE FROM clips WHERE id IN (SELECT value FROM json_each(?))", [.text(Self.json(ids))])
    }

    private static func json(_ ids: [Int64]) -> String { "[" + ids.map(String.init).joined(separator: ",") + "]" }

    // MARK: Item actions (card agent-bo-95422784)

    /// One text item per non-empty line, on top of the list in line order; the original stays. Returns their ids in
    /// line order.
    @discardableResult
    public func split(_ id: Int64) throws -> [Int64] {
        guard let clip = try clips(where: "id = ?", [.int(id)]).first else { return [] }
        return try addOnTop(clip.text.nonEmptyLines.map(String.init), sourceApp: clip.sourceApp)
    }

    /// The picked texts in pick order, joined by new lines, as one new item on top.
    @discardableResult
    public func merge(_ ids: [Int64]) throws -> Int64 {
        let picked = try clips(ids)
        return try addOnTop([picked.map(\.text).joined(separator: "\n")], sourceApp: picked.first?.sourceApp)[0]
    }

    /// Replaces the item's text, as plain text, keeping its place, pins, tags and name (a format or an edit). When
    /// another row already holds that text, it folds into this one, the row Sven is looking at: its pin, tags and name
    /// carry over, then it goes.
    public func setText(_ id: Int64, to text: String) throws {
        let item = ClipItem.plainText(text, sourceApp: nil)
        try transaction {
            if let other = try query("SELECT id FROM clips WHERE hash = ? AND id != ?", [.text(item.contentHash), .int(id)], { $0.int64(0) }).first {
                try run("""
                    UPDATE clips SET pinned = max(pinned, (SELECT pinned FROM clips WHERE id = ?)),
                        title = coalesce(title, (SELECT title FROM clips WHERE id = ?)) WHERE id = ?
                    """, [.int(other), .int(other), .int(id)])
                try run("INSERT OR IGNORE INTO clip_tags (clip_id, tag_id) SELECT ?, tag_id FROM clip_tags WHERE clip_id = ?", [.int(id), .int(other)])
                try run("DELETE FROM clips WHERE id = ?", [.int(other)])
            }
            // The new text decides its timer: a running one keeps its deadline, and one that had none starts at this edit,
            // so an old copy edited or formatted into a key shows its badge first rather than going at once.
            let ends = expiry(item, at: Date())
            lowerSoonestExpiry(ends)
            try run("UPDATE clips SET kind = 'text', text = ?, hash = ?, expires_at = CASE WHEN ? AND pinned = 0 THEN coalesce(expires_at, ?) END WHERE id = ?",
                    [.text(text), .text(item.contentHash), .int(ends == nil ? 0 : 1), .real(ends?.timeIntervalSince1970 ?? 0), .int(id)])
            try writeContents(id, item)
        }
    }

    /// A name the row shows instead of its text; an empty one clears it.
    public func rename(_ id: Int64, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try run("UPDATE clips SET title = ? WHERE id = ?", [.text(trimmed.isEmpty ? nil : trimmed), .int(id)])
    }

    /// New text items above everything in the list, the first text on top, in one transaction with one prune.
    private func addOnTop(_ texts: [String], sourceApp: String?) throws -> [Int64] {
        let newest = try query("SELECT max(copied_at) FROM clips", []) { $0.double(0) }.first ?? 0
        let top = max(Date().timeIntervalSince1970, newest)
        return try transaction {
            var ids: [Int64] = []
            for (index, text) in texts.enumerated().reversed() {
                let date = Date(timeIntervalSince1970: top + 0.001 * Double(texts.count - index))
                ids.insert(try upsert(.plainText(text, sourceApp: sourceApp), at: date), at: 0)
            }
            try prune()
            return ids
        }
    }

    // MARK: Image text (card agent-bo-95423070)

    /// The images not read yet, newest first: the ones the cap keeps longest.
    public func unreadImages() throws -> [Int64] {
        try query("SELECT id FROM clips WHERE kind = 'image' AND recognised IS NULL ORDER BY copied_at DESC, id DESC", []) { $0.int64(0) }
    }

    /// How many images are not read yet (StoredClip.isReadingText), counted without listing them.
    public func unreadImageCount() throws -> Int {
        try query("SELECT COUNT(*) FROM clips WHERE kind = 'image' AND recognised IS NULL", []) { Int($0.int64(0)) }.first ?? 0
    }

    /// The copy's picture, its PNG else its TIFF, and none of its other representations.
    public func image(of id: Int64) throws -> Data? {
        try query("""
            SELECT data FROM contents WHERE clip_id = ? AND item = 0 AND type IN ('public.png', 'public.tiff')
            ORDER BY type = 'public.png' DESC LIMIT 1
            """, [.int(id)]) { $0.blob(0) }.first
    }

    /// The text read from an image; empty marks it read with none, so it is not read again.
    public func setRecognised(_ id: Int64, _ text: String) throws {
        try run("UPDATE clips SET recognised = ? WHERE id = ?", [.text(text), .int(id)])
    }

    /// The text read from the copy with these contents, if it is in the history and was read (card agent-bo-95423072).
    public func recognised(hash: String) throws -> String? {
        try query("SELECT recognised FROM clips WHERE hash = ?", [.text(hash)]) { $0.text(0) }.first ?? nil
    }

    // MARK: Tags (card agent-bo-95422782)

    /// Every tag, by name.
    public func tags() throws -> [ClipTag] {
        try query("SELECT id, name, colour FROM tags ORDER BY name COLLATE NOCASE", [], Self.tag(at: 0))
    }

    /// The tag with this name in any case, as the search's #name finds it; nil when none has it.
    public func tag(named typed: String) throws -> ClipTag? {
        try query("SELECT id, name, colour FROM tags WHERE name = ?", [.text(ClipTag.name(typed))], Self.tag(at: 0)).first
    }

    /// Tags the rows with `name`, made first when no tag has that name in any case (the column's NOCASE unique
    /// index decides); a new tag takes the colour after the newest tag's, of eight.
    @discardableResult
    public func tag(_ ids: [Int64], with typed: String) throws -> ClipTag {
        let name = ClipTag.name(typed)
        guard !name.isEmpty else { throw ClipboardStoreError.sqlite("a tag needs a name") }
        try run("INSERT OR IGNORE INTO tags (name, colour) VALUES (?, coalesce((SELECT colour FROM tags ORDER BY id DESC LIMIT 1) + 1, 0) % ?)",
                [.text(name), .int(Int64(ClipTag.colours))])
        guard let tag = try query("SELECT id, name, colour FROM tags WHERE name = ?", [.text(name)], Self.tag(at: 0)).first else {
            throw ClipboardStoreError.sqlite("tag \(name) was not made")
        }
        try run("INSERT OR IGNORE INTO clip_tags (clip_id, tag_id) SELECT value, ? FROM json_each(?)",
                [.int(tag.id), .text(Self.json(ids))])
        return tag
    }

    public func untag(_ ids: [Int64], from tag: Int64) throws {
        try run("DELETE FROM clip_tags WHERE tag_id = ? AND clip_id IN (SELECT value FROM json_each(?))", [.int(tag), .text(Self.json(ids))])
    }

    /// Settings › Clipboard › Tags: a new name or colour for the tag.
    /// A name that is empty once stored (only # or spaces) is refused; the tag keeps its old one.
    public func updateTag(_ tag: ClipTag) throws {
        guard !ClipTag.name(tag.name).isEmpty else { throw ClipboardStoreError.sqlite("a tag needs a name") }
        try run("UPDATE tags SET name = ?, colour = ? WHERE id = ?", [.text(ClipTag.name(tag.name)), .int(Int64(tag.colour)), .int(tag.id)])
    }

    private static func tag(at column: Int32) -> (Row) -> ClipTag {
        { ClipTag(id: $0.int64(column), name: $0.text(column + 1) ?? "", colour: Int($0.int64(column + 2))) }
    }

    /// The tag goes and every row loses it; the rows stay.
    public func deleteTag(_ id: Int64) throws {
        try run("DELETE FROM tags WHERE id = ?", [.int(id)])
    }

    // MARK: SQLite

    /// A secret past its expiry is never read, even before the next prune deletes it; binds the time now.
    private static let unexpired = "(expires_at IS NULL OR expires_at > ?)"

    private func clips(where condition: String, _ values: [Value], order: ClipOrder = ClipOrder()) throws -> [StoredClip] {
        let condition = "\(Self.unexpired) AND (\(condition))"
        let values = [Value.real(Date().timeIntervalSince1970)] + values
        var tagsByClip: [Int64: [ClipTag]] = [:]
        // Only the listed rows' tags: the same condition picks them.
        for (clip, tag) in try query("""
            SELECT clip_id, id, name, colour FROM clip_tags JOIN tags ON tags.id = tag_id
            WHERE clip_id IN (SELECT id FROM clips WHERE \(condition)) ORDER BY name COLLATE NOCASE
            """, values, { ($0.int64(0), Self.tag(at: 1)($0)) }) {
            tagsByClip[clip, default: []].append(tag)
        }
        return try query("""
            SELECT id, kind, text, source_app, pinned, copied_at, first_copied_at, copy_count, size, title, recognised, expires_at FROM clips WHERE \(condition)
            ORDER BY \(order.sql)
            """, values) { row in
            let text = row.text(2) ?? ""
            return StoredClip(id: row.int64(0), kind: ClipboardCapture.kind(reading: ClipKind(rawValue: row.text(1) ?? "") ?? .text, text),
                              text: text, sourceApp: row.text(3), copiedAt: Date(timeIntervalSince1970: row.double(5)), pinned: row.int64(4) != 0,
                              tags: tagsByClip[row.int64(0)] ?? [], firstCopiedAt: Date(timeIntervalSince1970: row.double(6)),
                              copyCount: Int(row.int64(7)), size: Int(row.int64(8)), customTitle: row.text(9), recognised: row.text(10),
                              expiresAt: row.optionalDouble(11).map(Date.init(timeIntervalSince1970:)))
        }
    }

    enum Value {
        case int(Int64), real(Double), text(String?), blob(Data)
    }

    struct Row {
        let statement: OpaquePointer
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func optionalDouble(_ column: Int32) -> Double? { sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : double(column) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func blob(_ column: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Value], _ read: (Row) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, slot, v)
            case .real(let v): sqlite3_bind_double(statement, slot, v)
            case .text(let v?): sqlite3_bind_text(statement, slot, v, -1, transient)
            case .text(nil): sqlite3_bind_null(statement, slot)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, slot, $0.baseAddress, Int32($0.count), transient) }
            }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(read(Row(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw error()
            }
        }
    }

    private func error() -> ClipboardStoreError {
        .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open the database")
    }
}
