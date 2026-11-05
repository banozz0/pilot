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

    /// The words typed after `key`'s alias and a space ("em funny" gives "funny" for the emoji picker, T37), case of the
    /// alias ignored; nil when the query starts with no alias of `key` or nothing follows it.
    public func words(after key: String, in query: String) -> String? { byKey[key].flatMap { Self.words(after: $0, in: query) } }

    /// The row a query's first word is the alias of, and the words after it ("bw generate password" gives Bitwarden's row
    /// and "generate password", T40), case of the alias ignored; nil when the first word is no alias or nothing follows it.
    public func scope(of query: String) -> (key: String, words: String)? {
        guard let space = query.firstIndex(of: " "), let key = byAlias[query[..<space].lowercased()] else { return nil }
        let words = query[space...].trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : (key, words)
    }

    /// The words typed after `word` and a space, case of the word ignored; nil when the query starts otherwise or nothing
    /// follows it ("gif funny", T39).
    public static func words(after word: String, in query: String) -> String? {
        guard let space = query.firstIndex(of: " "), query[..<space].lowercased() == word else { return nil }
        let words = query[space...].trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? nil : words
    }

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

/// What an alias does with the words typed after it at the root (T40, T42), told by the row it names; a row with no
/// route here (Pick a colour, Make a web app, most actions) keeps today's search for the whole query.
public enum AliasRoute: Equatable, Sendable {
    /// The app's actions the words find, best first ("bw generate password", T40).
    case app(String)
    /// The branch opens searching the words ("sys wifi", T40; Kill a process's alias opens Activity: "kill chrome").
    case branch(MenuBranch)
    /// Stickers and GIFs opens on GIPHY's GIFs searching the words (its alias, as `gif`, T39).
    case gifs
    /// The root lists the emoji the words find ("em funny", T37).
    case emoji
    /// The words are the question Return sends in the AI chat (Ask AI's or AI chat's alias: "chat what's up").
    case ask
    /// The menu's Files view searches the words (Finder's or Pilot Files' alias: "files invoice").
    case files
    /// Clipboard history opens searching the words ("cb invoice").
    case clipboard

    public init?(key: String) {
        switch MenuEntry.Target(key: key) {
        case .app(let bundle)?: self = .app(bundle)
        case .branch(.stickers)?: self = .gifs
        case .branch(let b)?: self = .branch(b)
        case .action(let id)?:
            switch id {
            case "apps.emoji": self = .emoji
            case "ai.ask", "ai.chat": self = .ask
            case "system.killProcess": self = .branch(.activity)
            case "apps.files", "apps.pilotFiles": self = .files
            case "apps.clipboard": self = .clipboard
            default: return nil
            }
        default: return nil
        }
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
