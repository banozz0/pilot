import Foundation

/// An alias on a menu row (card agent-bo-95423037, audit gap 10, after Raycast's): typed exactly at the Hyper+Space root,
/// it lists that row first, `wp` for the web-app picker. The row is its frecency key (MenuEntry.Target.key); its title is
/// kept so Launcher › Aliases can name it.
public struct Alias: Codable, Equatable, Identifiable, Sendable {
    public var key: String, alias: String, title: String

    public init(key: String, alias: String, title: String) {
        self.key = key; self.alias = alias; self.title = title
    }

    public var id: String { key }

    /// The starter aliases (Sven 2026-10-10), on rows every Pilot has, none a starter quicklink's keyword: saved once for
    /// anyone with no aliases file yet; each is removed as any alias is.
    public static let starters = [
        Alias(key: "action:apps.clipboard", alias: "cb", title: "Clipboard history"),
        Alias(key: "action:apps.emoji", alias: "em", title: "Emoji picker"),
        Alias(key: "action:ai.ask", alias: "ai", title: "Ask AI"),
        Alias(key: "action:captures.pickColour", alias: "cp", title: "Pick a colour"),
        Alias(key: "action:apps.webApp", alias: "wa", title: "Make a web app"),
        Alias(key: "branch:system", alias: "sys", title: "System"),
    ]

    /// The row's kind in the words the root search tags it with, read from its key's prefix (MenuEntry.Target.key).
    public var kindWord: String? { MenuEntry.Kind(rawValue: String(key.prefix { $0 != ":" }))?.word }
}

/// Every alias, one per row and none shared.
public struct Aliases: Equatable, Sendable {
    public private(set) var all: [Alias] { didSet { index() } }
    /// `all` by row and by alias, since the menu asks on every keystroke and for every row it draws.
    private var byKey: [String: String] = [:], byAlias: [String: String] = [:]

    public init(_ all: [Alias] = []) {
        self.all = all
        index()
    }

    private mutating func index() {
        byKey = Dictionary(all.map { ($0.key, $0.alias) }) { first, _ in first }
        byAlias = Dictionary(all.map { ($0.alias, $0.key) }) { first, _ in first }
    }

    public var isEmpty: Bool { all.isEmpty }

    public func alias(for key: String) -> String? { byKey[key] }

    /// The row a query names when it is an alias exactly, case ignored; a query only starting with one names none.
    public func key(for query: String) -> String? { byAlias.isEmpty ? nil : byAlias[query.lowercased()] }

    /// Sets the row's alias, trimmed, and returns nil; an empty one removes it. Else the line saying why not, and nothing
    /// changes: an alias is lowercase letters and digits, and no other row's.
    public mutating func set(_ alias: String, for key: String, title: String) -> String? {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else {
            all.removeAll { $0.key == key }
            return nil
        }
        if !alias.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) {
            return "An alias is lowercase letters and digits, with no spaces."
        }
        if let other = byAlias[alias], other != key, let title = all.first(where: { $0.key == other })?.title {
            return "\(alias) is \(title)'s alias; pick another."
        }
        let new = Alias(key: key, alias: alias, title: title)
        if let i = all.firstIndex(where: { $0.key == key }) { all[i] = new } else { all.append(new) }
        return nil
    }
}

/// The aliases on disk: a JSON list, kept on the Mac.
public struct AliasesStore: Sendable {
    /// ~/Library/Application Support/Pilot/aliases.json
    public static let standard = AliasesStore(url: PilotFolder.support.appending(path: "aliases.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// `starters` when there is no file yet, saved at once so they are added only this once (none by default: the app's
    /// book passes Alias.starters). A file that does not decode throws, so no save wipes it. A retired action's alias
    /// names the action that replaced it.
    public func load(starters: [Alias] = []) throws -> Aliases {
        let file = JSONFile<[Alias]>(url: url)
        let saved = try starters.isEmpty ? file.load(or: []) : file.load(seeding: starters)
        return Aliases(saved.map { var a = $0; a.key = RetiredActions.current(key: a.key); return a })
    }

    public func save(_ aliases: Aliases) throws { try JSONFile(url: url).save(aliases.all) }
}
