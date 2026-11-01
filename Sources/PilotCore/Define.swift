import Foundation

/// One word's entry in the Mac's dictionary (Define, Q596): its headword, syllables, pronunciation, senses, origin and
/// the dictionary's name, read from the entry's record (its XHTML, `init(records:dictionary:)`) or, without one, cut from
/// the one run-on string `DCSCopyTextDefinition` answers ("ephemeral | ɪˈfɛm(ə)r(ə)l | adjective lasting for a very short
/// time: fashions are ephemeral … • (chiefly of plants) having … noun an ephemeral plant … ORIGIN late 16th century …").
public struct DictionaryEntry: Equatable, Sendable {
    public struct Sense: Equatable, Sendable {
        /// "adjective", "noun"; empty when the entry names none.
        public let partOfSpeech: String
        /// What it means, without its example: "lasting for a very short time".
        public let meaning: String
        /// The examples after the meaning's colon: "fashions are ephemeral", "works of more than ephemeral interest".
        public let examples: [String]
        /// A label before the meaning: "chiefly of plants", "mass noun".
        public let note: String?

        public init(partOfSpeech: String, meaning: String, examples: [String], note: String?) {
            self.partOfSpeech = partOfSpeech
            self.meaning = meaning
            self.examples = examples
            self.note = note
        }
    }

    public let word: String
    /// Where the headword breaks, from the record: "ser·en·dip·ity"; nil when it has one part or no record.
    public let syllables: String?
    public let pronunciation: String?
    public let senses: [Sense]
    public let origin: String?
    /// The dictionary the entry is from, by its name on this Mac: "Oxford Dictionary of English"; nil from the text.
    public let dictionary: String?

    /// The most senses kept: "run" has some eighty.
    static let senseCap = 8
    static let partsOfSpeech = ["plural noun", "noun", "verb", "adjective", "adverb", "pronoun", "preposition", "conjunction",
                                "exclamation", "determiner", "abbreviation", "prefix", "suffix", "combining form", "symbol"]
    /// Where the senses end, each starting a part of the entry the panel does not list but ORIGIN.
    static let stops = ["PHRASES", "PHRASAL VERBS", "DERIVATIVES", "USAGE", "ORIGIN"]

    /// Nil for text with no sense in it.
    public init?(definition text: String) {
        let parts = text.components(separatedBy: " | ")
        let head = parts[0].trimmingCharacters(in: .whitespaces)
        // The second part is the pronunciation only when short and no sense: an entry without one has its examples apart.
        let spoken = parts.count >= 3 && parts[1].count < 80 && !parts[1].contains(":") && head.count < 60
        // A homograph's number goes: "go 1" is go.
        let headword = spoken ? head : String(text.prefix { $0 != " " })
        word = headword.replacingOccurrences(of: #" \d+$"#, with: "", options: .regularExpression)
        syllables = nil
        dictionary = nil
        pronunciation = spoken ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        let body = spoken ? parts.dropFirst(2).joined(separator: " | ") : String(text.dropFirst(headword.count))
        let cut = Self.stops.compactMap { Self.find(" \($0) ", in: " " + body).map { max(0, $0 - 1) } }.min()
        origin = Self.find(" ORIGIN ", in: " " + body).map { start in
            let rest = String((" " + body).dropFirst(start + " ORIGIN ".count))
            let end = Self.stops.compactMap { Self.find(" \($0) ", in: rest) }.min() ?? rest.count
            return Self.sentence(String(rest.prefix(end)))
        }
        let senses = Self.blocks(String(body.prefix(cut ?? body.count))).flatMap { Self.senses(of: $0.text, partOfSpeech: $0.partOfSpeech) }
        guard !senses.isEmpty else { return nil }
        self.senses = Array(senses.prefix(Self.senseCap))
    }

    /// The entry for `search` from its records' XHTML (`DCSRecordCopyData`), a homograph's ("go 1", "go 2") senses after
    /// the first's; nil when none parses or holds a sense. A search finds every headword it is a form of ("ran" finds RAN
    /// and run): the one spelt as typed wins, then a lower-case one, as the text look-up picks. The senses are the `.df`
    /// meanings under `.sg` with their `.ex` examples, each under its `.se1`'s part of speech; DERIVATIVES and PHRASES
    /// (`.subEntryBlock`) are left out.
    public init?(records: [String], dictionary: String?, search: String) {
        let parsed = records.compactMap(RecordReader.read).filter { !$0.senses.isEmpty }
        guard let first = parsed.first(where: { $0.word == search }) ?? parsed.first(where: { $0.word == $0.word.lowercased() }) ?? parsed.first
        else { return nil }
        let homographs = parsed.filter { $0.word == first.word }
        word = first.word
        syllables = first.syllables
        pronunciation = first.pronunciation
        senses = Array(homographs.flatMap(\.senses).prefix(Self.senseCap))
        origin = homographs.lazy.compactMap(\.origin).first
        self.dictionary = dictionary
    }

    /// One record read by its spans' classes.
    private final class RecordReader: NSObject, XMLParserDelegate {
        var word = "", syllables: String?, pronunciation: String?, origin: String?
        var senses: [Sense] = []
        private var classes: [Set<String>] = []
        private var partOfSpeech = "", pos = "", ipa = "", etym = ""
        private var sense: (meaning: String, examples: [String], note: String?, label: String)?
        private var example = ""

        static func read(_ xhtml: String) -> RecordReader? {
            let reader = RecordReader(), parser = XMLParser(data: Data(xhtml.utf8))
            parser.delegate = reader
            guard parser.parse(), !reader.word.isEmpty else { return nil }
            reader.word = DictationWords.tidy(reader.word)
            reader.origin = reader.etym.isEmpty ? nil : DictionaryEntry.sentence(DictationWords.tidy(reader.etym))
            return reader
        }

        private func inside(_ name: String) -> Bool { classes.contains { $0.contains(name) } }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let names = Set((attributes["class"] ?? "").split(separator: " ").map(String.init))
            classes.append(names)
            guard !inside("subEntryBlock") else { return }
            if names.contains("hw"), let breaks = attributes["linebreaks"], breaks.contains(where: { "¦|".contains($0) }) {
                syllables = String(breaks.map { "¦|".contains($0) ? "·" : $0 })
            }
            if names.contains("msDict"), inside("sg") { sense = ("", [], nil, "") }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let names = classes.popLast() ?? []
            guard !inside("subEntryBlock"), !names.contains("subEntryBlock") else { return }
            if names.contains("ph"), pronunciation == nil, !ipa.isEmpty { pronunciation = DictationWords.tidy(ipa) }
            if names.contains("pos"), inside("sg") { partOfSpeech = DictationWords.tidy(pos); pos = "" }
            if names.contains("ex"), sense != nil { sense?.examples.append(DictationWords.tidy(example)); example = "" }
            if names.contains("gg") || names.contains("lg"), let label = sense?.label {
                let label = DictationWords.tidy(label)
                if sense?.note == nil, sense?.meaning.isEmpty == true, !label.isEmpty, !label.hasPrefix("with "), !label.hasPrefix("no object") {
                    sense?.note = label
                }
                sense?.label = ""
            }
            if names.contains("msDict"), let done = sense {
                let meaning = DictionaryEntry.sentence(DictationWords.tidy(done.meaning))
                if !meaning.isEmpty {
                    senses.append(Sense(partOfSpeech: partOfSpeech, meaning: meaning, examples: done.examples.map(DictionaryEntry.sentence).filter { !$0.isEmpty }, note: done.note))
                }
                sense = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters text: String) {
            guard !inside("subEntryBlock") else { return }
            let punctuation = inside("gp")
            if inside("hw"), !punctuation { word += text }
            if inside("ph"), inside("hg"), pronunciation == nil, !punctuation { ipa += text }
            if inside("pos"), inside("sg") { pos += text }
            if inside("etym"), inside("x_xo1") { etym += text }
            guard sense != nil else { return }
            if inside("df") { sense?.meaning += text }
            if inside("ex"), !inside("lbl") { example += text }
            if inside("gg") || inside("lg"), !inside("eg"), !punctuation { sense?.label += text }
        }
    }

    /// The senses' text cut at each part of speech that starts a block: at the start (after any label, "informal, mainly
    /// US English noun …") or after a sentence's end ("… in one season. noun an ephemeral plant").
    static func blocks(_ body: String) -> [(partOfSpeech: String, text: String)] {
        let text = body.trimmingCharacters(in: .whitespaces)
        var starts: [(at: Int, length: Int, name: String)] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let atStart = i == 0 || i >= 2 && chars[i - 1] == " " && ".!?".contains(chars[i - 2])
            if atStart || starts.isEmpty && i > 0 && i < 48 && chars[i - 1] == " " {
                if let name = partsOfSpeech.first(where: { matches($0, chars, at: i) }) {
                    starts.append((i, name.count, name))
                    i += name.count
                    continue
                }
            }
            i += 1
        }
        guard !starts.isEmpty else { return [("", text)] }
        return starts.indices.map { n in
            let from = starts[n].at + starts[n].length, to = n + 1 < starts.count ? starts[n + 1].at : chars.count
            return (starts[n].name, String(chars[from..<to]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// `word` at `i` as a whole word.
    private static func matches(_ word: String, _ chars: [Character], at i: Int) -> Bool {
        let w = Array(word)
        guard i + w.count <= chars.count, Array(chars[i..<(i + w.count)]) == w else { return false }
        return i + w.count == chars.count || !chars[i + w.count].isLetter
    }

    /// One part of speech's senses: its numbered ones in order ("1 …", then "2 …" after a sentence's end, never a "398
    /// miles" in an example), each with its "•" subsenses.
    static func senses(of block: String, partOfSpeech: String) -> [Sense] {
        var text = block
        _ = labels(&text)   // "(happier, happiest)", "[mass noun]", "(runs) (, running)": the word's forms, not a sense
        var numbered: [String] = []
        if text.hasPrefix("1 ") {
            var rest = Substring(text.dropFirst(2)), n = 2
            while let r = numberedBreak(n, in: rest) {
                numbered.append(String(rest[..<r.lowerBound]))
                rest = rest[r.upperBound...]
                n += 1
            }
            numbered.append(String(rest))
        } else {
            numbered = [text]
        }
        return numbered.flatMap { $0.components(separatedBy: " • ") }.compactMap { piece in
            var piece = piece.trimmingCharacters(in: .whitespaces)
            let note = labels(&piece).first { !$0.hasPrefix("with ") && !$0.hasPrefix("no object") }
            let colon = piece.range(of: ": ")
            let meaning = sentence(colon.map { String(piece[..<$0.lowerBound]) } ?? piece)
            guard !meaning.isEmpty else { return nil }
            let examples = colon.map { String(piece[$0.upperBound...]).components(separatedBy: " | ").map(sentence).filter { !$0.isEmpty } } ?? []
            return Sense(partOfSpeech: partOfSpeech, meaning: meaning, examples: examples, note: note)
        }
    }

    /// " n " where a sentence ended just before it and a word or label starts after it.
    private static func numberedBreak(_ n: Int, in text: Substring) -> Range<Substring.Index>? {
        var from = text.startIndex
        while let r = text.range(of: " \(n) ", range: from..<text.endIndex) {
            let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : " "
            let after = r.upperBound < text.endIndex ? text[r.upperBound] : " "
            if ".!?)]’\"".contains(before), after.isLetter || "[(".contains(after) { return r }
            from = r.upperBound
        }
        return nil
    }

    /// Takes the leading "[…]" and "(…)" labels off `text`, returning them without their brackets.
    static func labels(_ text: inout String) -> [String] {
        var found: [String] = []
        while let open = text.first, let close: Character = open == "[" ? "]" : open == "(" ? ")" : nil {
            var depth = 0, end: String.Index?
            for i in text.indices {
                if text[i] == open { depth += 1 } else if text[i] == close { depth -= 1; if depth == 0 { end = i; break } }
            }
            guard let end else { break }
            found.append(String(text[text.index(after: text.startIndex)..<end]).trimmingCharacters(in: .whitespaces))
            text = String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        return found
    }

    /// Trimmed, its last full stop and colon gone.
    static func sentence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces)
        while let last = s.last, ".:;".contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The offset of `needle` in `text`, nil when it is not there.
    private static func find(_ needle: String, in text: String) -> Int? {
        text.range(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
    }
}

/// Define (Q596 C, the designer's layout C of round 2): a menu branch beside Translate, reached by typing `def ` or
/// `define ` and a word at the root, or from Trigger. Its rows are the word's meanings from the Mac's dictionary, its
/// synonyms from the online dictionary (FreeDictionary) and its Spanish by Apple's on-device translation, under their
/// headings; the panel draws the picked row in full beside them (DefinePane).
public enum Define {
    /// The headings the rows sit under, in their order.
    /// The translation's heading is its language's name, "Spanish".
    public static let meanings = "Meanings", synonyms = "Synonyms", didYouMean = "Did you mean", web = "Web"
    /// How many of each the list shows.
    public static let shownMeanings = 4, shownSynonyms = 6, shownSuggestions = 6

    /// The text after "def " or "define ", trimmed and possibly empty; nil when the search starts with neither. The space is
    /// needed, so "def" alone still finds Default apps.
    public static func text(after search: String) -> String? {
        let search = search.drop(while: \.isWhitespace)
        guard let space = search.firstIndex(of: " "), ["def", "define"].contains(search[..<space].lowercased()) else { return nil }
        return search[space...].trimmingCharacters(in: .whitespaces)
    }

    /// The word to look up inside Define, two characters or more; nil anywhere else.
    public static func word(for search: String, in branch: MenuBranch?) -> String? {
        guard branch == .define else { return nil }
        let word = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return word.count >= MenuNavigator.minimumQuery ? word : nil
    }

    /// The rows for `word`: its meanings, synonyms (nil while they are asked for) and translation, or, for a word the Mac's
    /// dictionary lacks, what it may have meant; Search the web last. Each answers, so they keep this order.
    public static func rows(word: String, entry: DictionaryEntry?, synonyms: [String]?, translation: (language: String, text: String)?,
                            suggestions: [String] = []) -> [MenuEntry] {
        func row(_ title: String, _ section: String, detail: String? = nil, target: MenuEntry.Target? = nil) -> MenuEntry {
            var row = MenuEntry(title: title, target: target ?? .copy(title), home: .define, detail: detail, isAnswer: true)
            row.section = section
            return row
        }
        var rows: [MenuEntry] = []
        if let entry {
            rows += entry.senses.prefix(shownMeanings).map { row($0.meaning, meanings, detail: $0.partOfSpeech.isEmpty ? $0.note : $0.partOfSpeech) }
        } else {
            rows += suggestions.filter { $0.lowercased() != word.lowercased() }.prefix(shownSuggestions).map { row($0, didYouMean) }
        }
        rows += (synonyms ?? []).prefix(shownSynonyms).map { row($0, Self.synonyms) }
        if let translation, translation.text.lowercased() != word.lowercased() { rows.append(row(translation.text, translation.language)) }
        rows.append(row("Search the web for “\(word)”", web, target: .searchWeb(word)))
        // A row's id is its target: a synonym spelt like a meaning is listed once.
        var seen = Set<MenuEntry.Target>()
        return rows.filter { seen.insert($0.target).inserted }
    }

    /// Up to `limit` of `words` (the Mac's word list) nearest a misspelt `word` by edit distance, nearest first: at most a
    /// third of its letters off (two at least), lower-case words only (a capital is a name). Did you mean's fallback after
    /// the spell checker, which guesses one or two: "srendpity" finds serendipity, senility, serenity (27 ms, 2026-10-31).
    public static func nearest(_ word: String, in words: [Substring], limit: Int) -> [String] {
        let target = Array(word.lowercased().utf8), most = max(2, target.count / 3)
        guard !target.isEmpty else { return [] }
        var found: [(distance: Int, word: Substring)] = []
        var previous = [Int](repeating: 0, count: target.count + 1), row = previous
        for candidate in words {
            guard abs(candidate.utf8.count - target.count) <= most, let first = candidate.utf8.first, (97...122).contains(first) else { continue }
            let letters = Array(candidate.utf8)
            for j in previous.indices { previous[j] = j }
            var best = 0
            for (i, letter) in letters.enumerated() {
                row[0] = i + 1
                best = row[0]
                for j in target.indices {
                    row[j + 1] = min(previous[j + 1] + 1, row[j] + 1, previous[j] + (letter == target[j] ? 0 : 1))
                    best = min(best, row[j + 1])
                }
                swap(&row, &previous)
                if best > most { break }
            }
            let distance = previous[target.count]
            if distance <= most, distance > 0 { found.append((distance, candidate)) }
        }
        func rank(_ found: (distance: Int, word: Substring)) -> (Int, Int) { (found.distance, abs(found.word.utf8.count - target.count)) }
        return found.sorted { rank($0) < rank($1) }.prefix(limit).map { String($0.word) }
    }

    /// The word a row defines when → or Return picks it: a synonym's or a suggestion's; nil for any other row.
    public static func definable(_ row: MenuEntry) -> String? {
        guard row.home == .define, row.section == synonyms || row.section == didYouMean, case .copy(let word) = row.target else { return nil }
        return word
    }
}
