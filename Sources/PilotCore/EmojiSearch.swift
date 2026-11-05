import Foundation

/// One emoji of the bundled list: github/gemoji's db/emoji.json (MIT, its notice in Packaging/gemoji-LICENSE.txt),
/// trimmed to the emoji, its name, its aliases and tags as keywords and its category (Scripts/emoji-json.py).
public struct Emoji: Decodable, Sendable, Equatable {
    /// The category is gemoji's ("Smileys & Emotion"); empty in a list made without one.
    public let emoji: String, name: String, keywords: [String], category: String
    /// The name's words and the name's with the keywords', lower case, split once as the list loads.
    let nameWords: [String], allWords: [String]

    enum CodingKeys: String, CodingKey { case emoji = "e", name = "n", keywords = "k", category = "c" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try c.decode(String.self, forKey: .emoji)
        name = try c.decode(String.self, forKey: .name)
        keywords = try c.decode([String].self, forKey: .keywords)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        nameWords = EmojiSearch.words(name)
        allWords = nameWords + keywords.flatMap(EmojiSearch.words)
    }
}

/// Emoji at the menu's root (card agent-bo-95422931; Vicinae's emoji search, rebuilt): every typed word starts a word of
/// the name or of a keyword, from the second character, at most `limit` rows, the menu's frecency ranking them after.
public enum EmojiSearch {
    public static let limit = 30
    /// The emoji picker's row: its alias and words ("em funny") list only the emoji they find, best first (T37).
    public static let pickerKey = "action:apps.emoji"

    public static func parse(_ data: Data) throws -> [Emoji] { try JSONDecoder().decode([Emoji].self, from: data) }

    public static func entries(for query: String, in list: [Emoji]) -> [MenuEntry] {
        matches(for: query, in: list).prefix(limit).map { entry($0) }
    }

    /// The emoji the words find: none under two characters; the name itself, then names holding the words, then keyword
    /// hits, each in gemoji's order; when none, the emoji a typo finds (`nearly`). At the root the cap takes the first 30
    /// and the menu's own ranking orders them after; the emoji grid lists them all as they come (EmojiGrid).
    public static func matches(for query: String, in list: [Emoji]) -> [Emoji] {
        let typed = words(query)
        guard query.trimmingCharacters(in: .whitespaces).count >= MenuNavigator.minimumQuery, !typed.isEmpty else { return [] }
        func tiered(_ tier: (Emoji) -> Int?) -> [Emoji] { FuzzyRanker.Filter.closest(list, tier) }
        let spelled = tiered { e in e.nameWords == typed ? 0 : covers(typed, e.nameWords) ? 1 : covers(typed, e.allWords) ? 2 : nil }
        // A mood word gemoji never tags ("funny", T37) finds the emoji its words do, in their order.
        if spelled.isEmpty, typed.count == 1, let felt = moods[typed[0]] {
            return tiered { e in felt.firstIndex { e.allWords.contains($0) } }
        }
        guard spelled.isEmpty, typed.contains(where: { $0.count >= FuzzyRanker.typoLetters }) else { return spelled }
        let letters = typed.map { (word: $0, letters: Array($0)) }
        func near(_ own: [String]) -> Bool { letters.allSatisfy { t in own.contains { nearly(t.word, t.letters, $0) } } }
        // Tiered as the spelled ones are: a name of as many words as typed, then a name, then a keyword.
        return tiered { e in near(e.nameWords) ? (e.nameWords.count == typed.count ? 0 : 1) : near(e.allWords) ? 2 : nil }
    }

    /// Words people type for a feeling that no gemoji name or tag holds, each with the gemoji words that find its emoji,
    /// best first (T37: Sven typed "em funny").
    static let moods: [String: [String]] = {
        let funny = ["laughing", "rofl", "joy", "haha", "silly", "goofy", "zany"], cute = ["pleading", "blush", "hearts"]
        let gross = ["nauseated", "vomiting"], crazy = ["zany", "goofy", "woozy"], congrats = ["tada", "partying", "confetti", "clap"]
        return ["funny": funny, "hilarious": funny, "lmao": funny, "cute": cute, "adorable": cute, "gross": gross, "disgusting": gross,
                "scary": ["fearful", "scream", "ghost"], "yummy": ["yum", "drooling"], "awkward": ["grimacing", "sweat"],
                "excited": ["partying", "struck", "tada"], "omg": ["scream", "exploding", "flushed"],
                "embarrassed": ["flushed", "blush", "grimacing"], "crazy": crazy, "weird": ["confused", "woozy", "zany"],
                "bored": ["unamused", "yawning", "sleepy"], "congrats": congrats, "congratulations": congrats]
    }()

    /// Whether `own` starts with the typed word, or, from four letters, starts within a typo of it: one edit, two from
    /// eight letters (FuzzyRanker.edits). The first letter, or a swap of the first two, is taken as typed.
    static func nearly(_ typed: String, _ letters: [Character], _ own: String) -> Bool {
        if own.hasPrefix(typed) { return true }
        let allowed = FuzzyRanker.allowed(letters.count)
        guard letters.count >= FuzzyRanker.typoLetters, let first = own.first, first == letters[0] || first == letters[1] else { return false }
        return FuzzyRanker.edits(letters, toStartOf: Array(own.prefix(letters.count + allowed))[...], within: allowed) != nil
    }

    /// The emoji's row: "🔥  fire", typed where Sven was on Return, found by its keywords too.
    static func entry(_ e: Emoji, home: MenuBranch? = nil) -> MenuEntry {
        MenuEntry(title: "\(e.emoji)  \(e.name)", target: .emoji(e.emoji), home: home, inSearch: home == nil, keywords: e.keywords.joined(separator: " "))
    }

    /// Whether each typed word starts one of `own`.
    static func covers(_ typed: [String], _ own: [String]) -> Bool { typed.allSatisfy { t in own.contains { $0.hasPrefix(t) } } }

    /// Lower-case words; gemoji's aliases join theirs with underscores ("heart_eyes").
    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
