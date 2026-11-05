import Foundation

/// An app's menu bar as Pilot last read it (T41, Sven Q827): macOS has no public way to list a closed app's actions, so
/// each app's menu bar is read as it comes forward, at most once per version a day, and kept here so typing its name
/// lists its menu items while it is closed. Only what the app always shows is kept: never a document, window, account or
/// content title (MenuItemSearch's walk skips them, `keeps`), never a check mark or greyed-out state.
public struct SavedMenu: Codable, Equatable, Sendable {
    public var bundle: String, version: String
    public var read: Date
    public var items: [MenuItemNode]

    public init(bundle: String, version: String, read: Date, items: [MenuItemNode]) {
        self.bundle = bundle; self.version = version; self.read = read; self.items = items
    }

    /// The menu bar Pilot keeps of a fresh read: titled items only, each listed as pickable (an item greyed out with no
    /// window open is often the one wanted; the press checks it again) and with no check mark.
    public static func kept(_ bar: [MenuItemNode]) -> [MenuItemNode] {
        bar.compactMap { node in
            guard !node.isSeparator else { return nil }
            return MenuItemNode(title: node.title, enabled: true, children: kept(node.children), char: node.char, modifiers: node.modifiers,
                                virtualKey: node.virtualKey)
        }
    }

    /// How many items it holds, submenus' items counted.
    public static func count(_ items: [MenuItemNode]) -> Int { items.reduce(0) { $0 + ($1.children.isEmpty ? 1 : count($1.children)) } }

    /// Whether an app at `version` is read again as it comes forward: never read, another version, or a day since.
    public static func due(saved: (version: String, read: Date)?, version: String, now: Date = .now) -> Bool {
        guard let saved else { return true }
        return saved.version != version || now.timeIntervalSince(saved.read) >= 24 * 3600
    }

    /// The walk's skips for a menu bar Pilot keeps (Sven's brief for T41; review round 1): menus whose items name what the
    /// app holds (Window's windows, History, Bookmarks, recent files, profiles and accounts, Mail's mailboxes), Help; inside
    /// a submenu, every item with no shortcut, since a submenu's list is where an app names its accounts, playlists and
    /// devices (Mail's Erase Deleted Items, Music's Add to Playlist); anything that quits, hides or destroys without asking,
    /// since a saved item fires on an app Sven cannot see; and any item whose title carries the app's content: a quote, an
    /// address, a path or a file name, an Undo or Redo naming the last edit, or, on an item with no shortcut, one of its
    /// window titles (Chrome's New Tab, ⌘T, stays while a new tab is in front). The rules read English titles; MenuCache
    /// keeps only an English menu bar (`english`). Titles the walk skips are never read further, so a big History costs
    /// nothing.
    public static func skip(windowTitles: [String], app: String) -> MenuItemSearch.Skip {
        let windows = contentTitles(windowTitles, app: app), appName = app.lowercased()
        return { title, isMenu, level, hasKey in
            if MenuItemSearch.services(title, isMenu, level, hasKey) { return true }
            if level >= 3, !hasKey { return true }
            let t = title.trimmingCharacters(in: .whitespaces), lower = t.lowercased()
            if level == 1, menusSkipped.contains(lower) { return true }
            if isMenu, submenusSkipped.contains(where: { lower.hasPrefix($0) }) { return true }
            if unseen(lower, app: appName) { return true }
            return !keeps(t, windows: hasKey ? [] : windows)
        }
    }

    /// Whether a menu bar reads as English, so the skips, which match English titles, apply to it: it has a Window menu
    /// (every Mac app's, which a German Mac calls Fenster and a Dutch one Venster; Help alone proves nothing, as Dutch keeps
    /// it).
    public static func english(menus titles: [String]) -> Bool {
        titles.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "window" }
    }

    /// The top-level menus whose items are the app's content or say nothing worth a row.
    static let menusSkipped: Set<String> = ["window", "help", "history", "bookmarks", "favourites", "favorites", "people", "tab groups"]
    /// Submenus anywhere, the menu bar's own included, whose items are recent files, places, profiles, accounts or mailboxes
    /// (Music's and TV's Account menu by "account").
    static let submenusSkipped = ["open recent", "recently closed", "recent items", "recent folders", "recent files", "recent projects",
                                  "recently opened", "move to", "copy to", "go to favourite", "go to favorite", "switch to profile",
                                  "profiles", "account"]
    /// Items that end the app or hide it, whatever follows.
    static let leaving = ["quit", "hide others", "show all"]
    /// Items that destroy or undo work; one ending in "…" asks first, so it stays.
    static let destroying = ["delete", "move to trash", "move to bin", "erase", "empty", "clear", "remove", "discard", "revert"]

    /// Whether an item would act unseen on a closed app: Quit, Hide (the app), Hide Others, Show All, or a destroying item
    /// that does not ask first.
    static func unseen(_ lower: String, app: String) -> Bool {
        if leaving.contains(where: lower.hasPrefix) || lower == "hide \(app)" || lower == "hide" { return true }
        return destroying.contains(where: lower.hasPrefix) && !lower.hasSuffix("…") && !lower.hasSuffix("...")
    }

    /// A file or site name anywhere in a title, in any script and with an ending of any length: "report.pdf",
    /// "Résumé.pdf", "acme.network" ("Zoom 1.5×" and "Version 2.0" have no letter after the dot; "Save As…" loses its
    /// ellipsis first).
    nonisolated(unsafe) static let fileName = /[\p{L}\p{N}_\-]\.\p{L}[\p{L}\p{N}]*/

    /// The parts of window titles that name what a window shows: "report.pdf — Edited" gives "report.pdf" and "edited",
    /// lower-cased; the app's own name and parts under 3 letters are no content ("Ghostty", "– 1").
    static func contentTitles(_ windowTitles: [String], app: String) -> [String] {
        let app = app.lowercased()
        let parts = windowTitles.flatMap { $0.lowercased().split(separator: /\s+[—–\-|·:]\s+/).map(String.init) }
        return Array(Set(parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 && $0 != app }))
    }

    /// Whether a title is the app's own words, not something it holds: a title holding a window's content is not.
    static func keeps(_ title: String, windows: [String]) -> Bool {
        if title.isEmpty { return true }
        let lower = title.lowercased()
        if lower.hasPrefix("undo ") || lower.hasPrefix("redo ") { return false }
        if title.contains(where: { "“”\"‘’«»@/\\".contains($0) }) || lower.contains("://") || lower.contains("www.") { return false }
        var bare = Substring(title)
        for tail in ["…", "..."] where bare.hasSuffix(tail) { bare = bare.dropLast(tail.count) }
        if bare.contains(fileName) { return false }
        return !windows.contains { lower.contains($0) }
    }
}

/// The saved menu bars on disk (T41): one JSON file per app in `menus/` beside Pilot's other stores, the folder and each
/// file readable by Sven's account alone. General › Uninstall's "Your data" takes the folder with the rest.
public struct SavedMenuStore: Sendable {
    public static let standard = SavedMenuStore(folder: PilotFolder.support.appending(path: "menus", directoryHint: .isDirectory))

    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    /// The file of a bundle id; nil for one that is not a plain reverse-DNS id, so no id names a path outside the folder.
    func file(_ bundle: String) -> URL? {
        guard !bundle.isEmpty, bundle.count <= 255, !bundle.hasPrefix("."),
              bundle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else { return nil }
        return folder.appending(path: bundle + ".json")
    }

    public func load(_ bundle: String) -> SavedMenu? {
        guard let url = file(bundle), let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SavedMenu.self, from: data)
    }

    /// Written whole through AtomicFile, which makes the file 0600 before its first byte.
    public func save(_ menu: SavedMenu) throws {
        guard let url = file(menu.bundle) else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try AtomicFile.write(Self.encoder.encode(menu), to: url, mode: 0o600)
    }

    public func remove(_ bundle: String) {
        guard let url = file(bundle) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The bundle ids that have a saved menu bar.
    public func bundles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
    }

    /// Drops the menu bars of apps no longer on this Mac (`installed` false: gone, or in the Trash): the ones kept and the
    /// ones dropped.
    @discardableResult
    public func prune(installed: (String) -> Bool) -> (kept: [String], gone: [String]) {
        let all = bundles(), gone = all.filter { !installed($0) }
        gone.forEach(remove)
        return (all.filter { !gone.contains($0) }, gone)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
