import Foundation

/// Saved text Sven pastes by typing its keyword in any app or picking it in Hyper+Space's Snippets branch (card
/// agent-bo-95423044, audit gap 2). Its text may hold placeholders, filled
/// as it is pasted (Placeholders): {date +7d format="d MMM"}, {time}, {clipboard} and {clipboard N}, {selection}, {argument}
/// or {argument name} (asked for first), {cursor} (where the caret ends up), each with | uppercase, lowercase, trim or encode.
public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Typed in any app, it is replaced by the snippet, e.g. ;cm. Empty: the menu alone pastes it.
    public var keyword: String
    public var text: String

    public init(id: UUID = UUID(), name: String, keyword: String, text: String) {
        self.id = id; self.name = name; self.keyword = keyword; self.text = text
    }

    /// Its text holds an {argument}, named or not, so pasting it asks for one first.
    public var needsArgument: Bool { !Placeholders.summary(of: text).argumentNames.isEmpty }

    /// The first line of `text` with any words, as the editor's list and the menu show it.
    public static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// The text to paste, its placeholders filled (Placeholders); an unknown brace stays as typed. `earlierClips`: the
    /// clipboard history before the latest copy, newest first, for {clipboard N}.
    public func expanded(now: Date, clipboard: String?, argument: String = "", locale: Locale = .current,
                         timeZone: TimeZone = .current, earlierClips: [String] = [], selection: String? = nil) -> SnippetText {
        expanded(.init(now: now, clipboard: clipboard, earlierClips: earlierClips, selection: selection, argument: argument,
                       locale: locale, timeZone: timeZone))
    }

    /// The text to paste, filled with `values`.
    public func expanded(_ values: Placeholders.Values) -> SnippetText {
        let filled = Placeholders.fill(text, values)
        return SnippetText(text: filled.text, caretBack: filled.caret.map { filled.text.count - $0 } ?? 0)
    }
}

/// A snippet ready to paste: its text, and how many characters from the end the caret goes back for {cursor}.
public struct SnippetText: Equatable, Sendable {
    public var text: String
    public var caretBack: Int

    public init(text: String, caretBack: Int) { self.text = text; self.caretBack = caretBack }
}

/// What was typed lately, held to spot a keyword (the tap feeds it every character the focused app gets). A keyword
/// expands the moment its last character is typed, the longest when two end there; one that starts with a letter or
/// digit only at the start of a word, so sig never fires inside design.
public struct SnippetTyping: Sendable {
    private let keywords: [String]
    private var typed = ""
    /// The longest keyword's length, and one character before it for the word-start check: older ones are dropped.
    private let kept: Int

    public init(keywords: [String]) {
        self.keywords = keywords.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        kept = (self.keywords.first?.count ?? 0) + 1
    }

    /// The keyword `characters` completed, if any; the buffer then starts over.
    public mutating func type(_ characters: String) -> String? {
        typed += characters
        if typed.count > kept { typed.removeFirst(typed.count - kept) }
        guard let hit = keywords.first(where: { keyword in
            guard typed.hasSuffix(keyword) else { return false }
            guard keyword.first?.isLetter == true || keyword.first?.isNumber == true else { return true }
            let before = typed.dropLast(keyword.count).last
            return before.map { !$0.isLetter && !$0.isNumber } ?? true
        }) else { return nil }
        typed = ""
        return hit
    }

    public mutating func backspace() { _ = typed.popLast() }

    /// A click, another app, an arrow or a shortcut: the caret may be anywhere, so what came before no longer counts.
    public mutating func reset() { typed = "" }
}

/// A snippet row's pick: which snippet, and the argument typed after its name or keyword, when it takes one.
public struct SnippetPick: Hashable, Sendable {
    public var id: UUID
    public var argument: String?

    public init(id: UUID, argument: String? = nil) { self.id = id; self.argument = argument }
}

extension MenuEntries {
    /// Trigger › Snippets' rows, found at the root search too: each snippet by name, its keyword and first line beside
    /// it. One that takes an argument takes what is typed after its name or keyword and a space ("greeting Ana"), its
    /// line showing it filled in; the row then matches that whole search.
    public static func snippets(_ snippets: [Snippet], query: String) -> [MenuEntry] {
        snippets.map { s in
            // Nothing after the name yet is no argument: Return asks again rather than paste an empty one.
            let argument = s.needsArgument ? [s.name, s.keyword].lazy.filter { !$0.isEmpty }.compactMap { head in
                query.lowercased().hasPrefix(head.lowercased() + " ") ? String(query.dropFirst(head.count + 1).drop(while: \.isWhitespace)) : nil
            }.first.flatMap { $0.isEmpty ? nil : $0 } : nil
            let shown = argument.map { Placeholders.fill(s.text, .init(argument: $0), only: [.argument]).text } ?? s.text
            let line = Snippet.firstLine(shown) ?? ""
            return MenuEntry(title: s.name, target: .snippet(SnippetPick(id: s.id, argument: argument)), home: .snippets,
                             detail: [s.keyword, line].filter { !$0.isEmpty }.joined(separator: " · "),
                             keywords: ([s.keyword, s.text] + (argument == nil ? [] : [query])).joined(separator: " "))
        }
    }
}

/// The snippets on disk: ~/Library/Application Support/Pilot/snippets.json, in the order the editor lists them.
public struct SnippetStore: Sendable {
    public static let standard = SnippetStore(url: PilotFolder.support.appending(path: "snippets.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// None before the first save. A file that does not decode throws, so no save wipes it.
    public func load() throws -> [Snippet] { try JSONFile(url: url).load(or: []) }

    public func save(_ snippets: [Snippet]) throws { try JSONFile(url: url).save(snippets) }
}
