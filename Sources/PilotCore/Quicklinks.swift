import Foundation

/// A quicklink (card agent-bo-95423030, audit gap 4, after Raycast's Quicklinks): a named URL Sven opens from
/// Hyper+Space, `{query}` in it filled with what he types after its keyword, so `gh pilot` searches GitHub for pilot.
/// It opens in the default browser and binds as `links.open:<id>`.
public struct Quicklink: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String, keyword: String, url: String

    public init(id: UUID = UUID(), name: String, keyword: String, url: String) {
        self.id = id; self.name = name; self.keyword = keyword; self.url = url
    }

    public static let placeholder = "{query}"
    public static let prefix = "links.open:"

    /// The starter links (Sven 2026-10-10), saved once for anyone with no quicklinks file yet, a new user or one who never
    /// saved a link; each is removed as any link is, and a file, even an empty one, is never seeded again.
    public static let shipped = [
        starter(2, "Google", "g", "https://www.google.com/search?q={query}"),
        starter(5, "YouTube", "yt", "https://www.youtube.com/results?search_query={query}"),
        starter(1, "GitHub", "gh", "https://github.com/search?q={query}"),
        starter(6, "Maps", "maps", "https://www.google.com/maps/search/{query}"),
        starter(7, "Translate", "tr", "https://translate.google.com/?sl=auto&tl=en&text={query}"),
        starter(8, "Wikipedia", "wiki", "https://en.wikipedia.org/w/index.php?search={query}"),
    ]

    /// A starter's fixed id, so a bind made on it holds across Macs (GitHub's and Google's kept from the first four).
    private static func starter(_ n: Int, _ name: String, _ keyword: String, _ url: String) -> Quicklink {
        Quicklink(id: UUID(uuidString: String(format: "6B1F0C1E-2D7A-4C55-9C1B-5A1E3F0A%04d", n))!, name: name, keyword: keyword, url: url)
    }

    public var takesQuery: Bool { url.contains(Self.placeholder) }

    public var actionID: String { Self.prefix + id.uuidString }

    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?/"))

    /// The URL with `query` in place of {query}, percent-encoded so `&`, `=` and `#` stay inside it; nil when the result
    /// is not a web or app link.
    public func url(query: String) -> URL? {
        let filled = url.replacingOccurrences(of: Self.placeholder, with: query.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? "")
        guard let link = URL(string: filled), link.scheme != nil else { return nil }
        return link
    }

    /// Why a save was refused, and the field that needs the fix.
    public struct Refusal: Equatable, Sendable {
        public enum Field: Hashable, Sendable { case name, keyword, url }
        public let field: Field
        public let line: String

        /// The book's answer to any save while quicklinks.json does not decode.
        public static let unreadable = Refusal(field: .name, line: "Pilot can not read quicklinks.json, so it saves nothing over it; fix or move that file.")
    }

    /// The link as a save keeps it: spaces trimmed from each end of its name, keyword and URL.
    public var trimmed: Quicklink {
        Quicklink(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                  keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines), url: url.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Why this link, trimmed as a save keeps it, can not be saved beside `links`, or nil when it can: it needs a name, a
    /// keyword of lowercase letters and digits that no other link has, and a URL Pilot can open once `{query}` is filled.
    public func refusal(among links: [Quicklink]) -> Refusal? {
        let link = trimmed, keyword = link.keyword
        if link.name.isEmpty { return Refusal(field: .name, line: "Give the link a name.") }
        if keyword.isEmpty { return Refusal(field: .keyword, line: "Give the link a keyword to type in Hyper+Space.") }
        if !keyword.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) {
            return Refusal(field: .keyword, line: "A keyword is lowercase letters and digits, with no spaces.")
        }
        if let other = links.first(where: { $0.id != id && $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame }) {
            return Refusal(field: .keyword, line: "\(keyword) is taken by \(other.name); pick another keyword.")
        }
        if link.url(query: "x") == nil { return Refusal(field: .url, line: "Pilot can not open that URL; start it with https://.") }
        return nil
    }

    /// The link and query an action id names: `links.open:<id>`, or `links.open:<id>:<query>` from an answer.
    public static func parse(_ actionID: String) -> (id: UUID, query: String?)? {
        guard actionID.hasPrefix(prefix) else { return nil }
        let rest = actionID.dropFirst(prefix.count)
        let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let id = UUID(uuidString: String(parts[0])) else { return nil }
        return (id, parts.count > 1 ? String(parts[1]) : nil)
    }

    /// The root's answer to a keyword, a space and words (`gh pilot`): that link filled, first in the menu.
    public static func answers(for query: String, in links: [Quicklink]) -> [MenuEntry] {
        guard let space = query.firstIndex(of: " ") else { return [] }
        let keyword = query[..<space], words = query[space...].trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, let link = links.first(where: { $0.takesQuery && $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame }),
              let url = link.url(query: words) else { return [] }
        return [MenuEntry(title: "Search \(link.name) for \u{201C}\(words)\u{201D}", target: .action("\(link.actionID):\(words)"),
                          detail: url.host(), isAnswer: true, icon: MenuIcon.quicklink)]
    }
}

/// The quicklinks on disk: a JSON list, kept on the Mac.
public struct QuicklinksStore: Sendable {
    /// ~/Library/Application Support/Pilot/quicklinks.json
    public static let standard = QuicklinksStore(url: PilotFolder.support.appending(path: "quicklinks.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// The starter links when there is no file yet, saved at once so they are added only this once. A file that does not
    /// decode throws, so no save wipes it.
    public func load() throws -> [Quicklink] { try JSONFile(url: url).load(seeding: Quicklink.shipped) }

    public func save(_ links: [Quicklink]) throws { try JSONFile(url: url).save(links) }
}

extension MenuEntries {
    /// Each link a root search row, found by its name or keyword; Return on one taking a query types its keyword into the
    /// search, so the words go after it.
    public static func quicklinks(_ links: [Quicklink]) -> [MenuEntry] {
        links.map {
            MenuEntry(title: $0.name, target: .action($0.actionID), keywords: $0.keyword, icon: MenuIcon.quicklink,
                      fills: $0.takesQuery ? "\($0.keyword) " : nil)
        }
    }
}
