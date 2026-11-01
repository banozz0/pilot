import Foundation
import Synchronization

/// The menu's ranking (stories 74 and 75, card agent-bo-95422766). Written for Pilot from how Vicinae's root search
/// behaves (vicinaehq/vicinae, GPL-3.0; none of its code is here) and the fzf-style scoring both descend from:
/// - Each typed word is matched on its own, its letters in order anywhere in the title, case and accents ignored.
///   A letter scores more at the title's start or a word's start (after a space or punctuation, or a capital after a
///   small letter) and right after the letter before it; a gap costs, except a jump to a word's start, so initials
///   ("vsc", "am") score like a prefix.
/// - The score is out of 100: the words' points over what each would score as the title's own start.
/// - A match that runs across words but starts a run inside one ("txe" in TextEdit) is noise and lists nothing, and
///   so is a weak one: under 65, which drops two letters inside a word ("ap" in Maps) and keeps three ("lock" in Clock).
/// - Beyond Vicinae: a word of four letters or more is tried again with two neighbouring letters swapped or one letter
///   dropped ("fidner", "telegarm"), at three quarters of its score; one of eight or more, failing that, within two
///   edits of the start of a title word ("calcualtro", "keybnidigns"), at 0.7. A typo never lists while a row spells
///   the query surely (80 or more, as a word's start does); under that, rows found through a typo rank among the
///   spelled ones by score, so "mial" lists Mail over Terminal, which only holds its letters (Sven 2026-10-19).
/// Rank is that score times `weight` times one plus frecency (SPEC.md, Frecency); ties go to `prefer`, then the shorter
/// title, then the input order. Given a `name`, its strength comes first (P53): a row named exactly what was typed, then
/// one with a word of its name starting what was typed, outranks every other match and any frecency, which still orders
/// rows of one strength. While no row has that strength, a row with a word of its name starting within a typo of what
/// was typed (one edit, two from eight letters) has it: "mial" lists Mail over Sound, whose keywords spell it as initials.
public enum FuzzyRanker {
    /// Under this a row is not listed.
    private static let gate = 65
    /// A typo's share of the score the corrected word earns; two edits earn less.
    private static let typo = 0.75, twoTypos = 0.7
    /// A spelled match this strong keeps typos out.
    private static let sure = 80
    /// The fewest letters a word needs before a typo of it counts.
    static let typoLetters = 4

    /// The edits a typo may make: one, two from eight letters.
    static func allowed(_ count: Int) -> Int { count >= 8 ? 2 : 1 }

    /// 0 to 100, or nil when the title does not match, typos included; an empty query matches everything with 0.
    public static func score(_ query: String, in title: String) -> Int? { score(Query(query), in: Title(title)) }

    /// Spelled, or with typos unless spelled surely.
    private static func score(_ query: Query, in title: Title) -> Int? {
        if let spelled = score(query, in: title, typos: false), spelled >= sure || !query.typos { return spelled }
        return score(query, in: title, typos: true)
    }

    /// The searches that filter a list in its own order (Sven 2026-10-19): an item with a field holding the query as
    /// typed, case and accents aside; only while no item has one, an item with a field a word of which starts within a
    /// typo of it (`nearly`). A list that held the query keeps exactly what it held.
    public struct Filter {
        public let typed: String
        private let letters: [Character]

        public init(_ query: String) {
            typed = query.trimmingCharacters(in: .whitespaces)
            letters = Query(typed).letters
        }

        /// A field holds the query as typed; a blank query holds everything.
        public func holds(_ fields: [String]) -> Bool {
            typed.isEmpty || fields.contains { $0.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }

        /// A word of a field starts within a typo of the query (`edits`); never under four letters.
        public func nearly(_ fields: [String]) -> Bool { edits(fields) != nil }

        /// The fewest edits from the query to the start of a word of a field, within a typo's (one, two from eight
        /// letters); nil past that or under four letters.
        public func edits(_ fields: [String]) -> Int? {
            guard letters.count >= typoLetters else { return nil }
            return fields.compactMap { field -> Int? in
                // Most fields lack too many of the letters, told from their bytes before folding them.
                if let missing = missing(letters, in: field), missing > allowed(letters.count) { return nil }
                return nearest(letters, in: Title(field), before: nil)
            }.min()
        }

        /// A search that is not one flat list, run with `holds`, else, when `nothing` says it found nothing, with
        /// `nearly`.
        public func search<R>(_ run: (([String]) -> Bool) -> R, nothing: (R) -> Bool) -> R {
            let held = run(holds)
            return nothing(held) ? run(nearly) : held
        }

        public func search<R: Collection>(_ run: (([String]) -> Bool) -> R) -> R { search(run, nothing: \.isEmpty) }

        /// The items `holds` keeps in their order, else those a typo finds, the closest first.
        public func filter<T>(_ items: [T], _ fields: (T) -> [String]) -> [T] {
            let held = items.filter { holds(fields($0)) }
            return held.isEmpty ? Self.closest(items) { edits(fields($0)) } : held
        }

        /// The items a typo finds (`edits` not nil), fewest edits first, ties in their order.
        public static func closest<T>(_ items: [T], _ edits: (T) -> Int?) -> [T] {
            items.enumerated().compactMap { i, item in edits(item).map { (item, $0, i) } }.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
        }
    }

    /// 2 when the name is what was typed, case and accents ignored; 1 when the name or a word of it starts with it, so
    /// "code" holds CodexBar and Visual Studio Code alike and recent use orders them; 0 otherwise (P53:
    /// "stats" ran across Read selected text aloud's title and keywords as initials, 93, over the Stats page, a Setting's
    /// 0.8 of 100).
    public static func strength(_ query: String, of name: String) -> Int {
        strength(typed: Query(query).typed, folded: fold(name))
    }

    /// `typed` is the query folded, its words one space apart; `name` is folded.
    private static func strength(typed: String, folded name: String) -> Int {
        guard !typed.isEmpty else { return 0 }
        if name == typed { return 2 }
        // A word starts the name or follows a space or punctuation.
        return name.indices.contains { i in
            (i == name.startIndex || !name[name.index(before: i)].isLetter && !name[name.index(before: i)].isNumber)
                && name[i...].hasPrefix(typed)
        } ? 1 : 0
    }

    /// The items matching the query, best first (see the type's comment). An empty query keeps every item, by boost
    /// alone. `boost` is frecency normalised to the best entry, 0 to 1; `name` is what `strength` reads, the bare title
    /// where `title` adds keywords (none: every row is of one strength). `memo` keeps what the rows' titles score between
    /// rankings, as a navigator ranks every row again per keystroke.
    public static func rank<T>(_ items: [T], query: String, title: (T) -> String, name: (T) -> String = { _ in "" },
                               boost: (T) -> Double = { _ in 0 }, weight: (T) -> Double = { _ in 1 },
                               prefer: (T) -> Int = { _ in 0 }, memo: Memo? = nil) -> [T] {
        let q = Query(query)
        let rows = items.enumerated().map { i, item in (item: item, title: title(item), index: i) }
        guard !q.words.isEmpty else {
            return rows.map { ($0.item, boost($0.item), $0.index) }.sorted { ($1.1, $0.2) < ($0.1, $1.2) }.map(\.0)
        }
        return hits(q, titles: rows.map(\.title), names: rows.map { name($0.item) }, memo: memo)
            .map { hit -> (item: T, strength: Int, rank: Double, prefer: Int, length: Int, index: Int) in
                let row = rows[hit.row]
                return (row.item, hit.strength, Double(hit.score) * weight(row.item) * (1 + boost(row.item)), prefer(row.item),
                        row.title.count, row.index)
            }
            .sorted { ($1.strength, $1.rank, $1.prefer, $0.length, $0.index) < ($0.strength, $0.rank, $0.prefer, $1.length, $1.index) }
            .map(\.item)
    }

    /// `hits` with `memo`'s cache, or one that keeps no scores.
    private static func hits(_ q: Query, titles: [String], names: [String], memo: Memo?) -> [(row: Int, score: Int, strength: Int)] {
        guard let memo else {
            var once = Cache(keeps: false)
            return hits(q, titles: titles, names: names, cache: &once)
        }
        return memo.cache.withLock { hits(q, titles: titles, names: names, cache: &$0) }
    }

    /// The rows matching `q`, by index, with their score and strength (see `rank`).
    private static func hits(_ q: Query, titles: [String], names: [String], cache: inout Cache) -> [(row: Int, score: Int, strength: Int)] {
        cache.query = q.typed
        func scored(typos: Bool) -> [(row: Int, score: Int, strength: Int)] {
            titles.indices.compactMap { r in cache.score(q, titles[r], typos: typos).map { (r, $0, cache.strength(q.typed, of: names[r])) } }
        }
        var hits = scored(typos: false)
        if !hits.contains(where: { $0.score >= sure }), q.typos { hits = scored(typos: true) }
        // No row is named by what was typed: one named by a typo of it is, so Mail leads "mial" over Sound, whose
        // keywords spell it as initials (microphone, alert).
        if q.letters.count >= typoLetters, !hits.contains(where: { $0.strength > 0 }) {
            for r in titles.indices where cache.isTypo(q.letters, of: names[r], in: titles[r]) {
                if let i = hits.firstIndex(where: { $0.row == r }) { hits[i].strength = 1; continue }
                hits.append((r, cache.score(q, titles[r], typos: true) ?? Int(100 * typo), 1))
            }
        }
        return hits
    }

    /// What ranking learns about the rows' titles, kept between rankings: a navigator ranks every row again on each
    /// keystroke, per kind tab and per provider's rows (Build 83's typing lag), and the titles stay while Sven types.
    public final class Memo: Sendable {
        fileprivate let cache = Mutex(Cache(keeps: true))
        public init() {}
    }

    /// Each title and name folded, kept until there are `limit` (a live picker's or the Files view's rows change as Sven
    /// types); their scores and strengths for `query`, dropped when it changes, unless it `keeps` no scores: a ranking
    /// without a memo folds each title once and scores it afresh, as nothing would read the scores again.
    fileprivate struct Cache {
        let keeps: Bool
        private static let limit = 4096
        private var titles: [String: Title] = [:], folded: [String: String] = [:]
        private var spelled: [String: Int?] = [:], typoed: [String: Int?] = [:], strengths: [String: Int] = [:], typos: [String: Bool] = [:]
        var query = "" {
            didSet {
                guard query != oldValue else { return }
                spelled.removeAll(keepingCapacity: true)
                typoed.removeAll(keepingCapacity: true)
                strengths.removeAll(keepingCapacity: true)
                typos.removeAll(keepingCapacity: true)
                if titles.count > Self.limit { titles = [:]; folded = [:] }
            }
        }

        mutating func title(_ raw: String) -> Title {
            if let t = titles[raw] { return t }
            let t = Title(raw)
            titles[raw] = t
            return t
        }

        mutating func score(_ q: Query, _ raw: String, typos: Bool) -> Int? {
            guard keeps else { return FuzzyRanker.score(q, in: title(raw), typos: typos) }
            if let known = typos ? typoed[raw] : spelled[raw] { return known }
            let s = FuzzyRanker.score(q, in: title(raw), typos: typos)
            if typos { typoed[raw] = s } else { spelled[raw] = s }
            return s
        }

        mutating func strength(_ typed: String, of name: String) -> Int {
            guard keeps else { return FuzzyRanker.strength(typed: typed, folded: fold(name)) }
            if let s = strengths[name] { return s }
            let f: String
            if let known = folded[name] { f = known } else { f = fold(name); folded[name] = f }
            let s = FuzzyRanker.strength(typed: typed, folded: f)
            strengths[name] = s
            return s
        }

        /// FuzzyRanker.isTypo for the row titled `raw`; a name that lacks too many of the letters is no typo, told before
        /// any key is made.
        mutating func isTypo(_ typed: [Character], of name: String, in raw: String) -> Bool {
            if let missing = missing(typed, in: name), missing > allowed(typed.count) { return false }
            guard keeps else { return FuzzyRanker.isTypo(typed, of: name, in: title(raw), of: raw) }
            let key = raw + "\u{0}" + name
            if let known = typos[key] { return known }
            let t = FuzzyRanker.isTypo(typed, of: name, in: title(raw), of: raw)
            typos[key] = t
            return t
        }
    }

    /// A query folded once: its words, what `strength` compares, and each word's typos from four letters (two
    /// neighbouring letters swapped or one dropped), made once rather than per row.
    fileprivate struct Query {
        /// `letters` is `typed`'s, for a typo of the words as one.
        let words: [[Character]], typed: String, letters: [Character], fixes: [[[Character]]]

        init(_ raw: String) {
            words = fold(raw).split(whereSeparator: \.isWhitespace).map(Array.init)
            typed = words.map { String($0) }.joined(separator: " ")
            letters = Array(typed)
            fixes = words.map { w in
                w.count < typoLetters ? [] : Array(Set(w.indices.dropLast().map { i in var f = w; f.swapAt(i, i + 1); return f }
                    + w.indices.map { i in var f = w; f.remove(at: i); return f }))
            }
        }

        /// Whether a word is long enough for typos.
        var typos: Bool { words.contains { $0.count >= typoLetters } }
    }

    /// Whether a word of `name` starts within a typo of what was typed, the words as one. A name that starts the row's
    /// title (`raw`, folded as `title`) is read from it, unfolded again.
    private static func isTypo(_ typed: [Character], of name: String, in title: Title, of raw: String) -> Bool {
        guard !name.isEmpty else { return false }
        // Each typed letter the name lacks is an edit: most names lack too many, told from their bytes (as Filter.edits).
        if let missing = missing(typed, in: name), missing > allowed(typed.count) { return false }
        let titled = raw.hasPrefix(name)
        return startsNear(typed, in: titled ? title : Title(name), before: titled ? name.count : nil)
    }

    /// Whether a word of the title, before letter `end` (nil: all of it), starts within `allowed` edits of `typed`.
    private static func startsNear(_ typed: [Character], in t: Title, before end: Int?) -> Bool { nearest(typed, in: t, before: end) != nil }

    /// The fewest edits from `typed` to the start of a word of the title before letter `end`, within `allowed`.
    private static func nearest(_ typed: [Character], in t: Title, before end: Int?) -> Int? {
        let end = end ?? t.letters.count
        return (0..<end).compactMap { t.starts[$0] ? edits(typed, toStartOf: t.letters[$0..<end], within: allowed(typed.count)) : nil }.min()
    }

    /// How many of the letters `field` lacks, read from its bytes without folding it; nil when either holds a letter
    /// outside ASCII.
    private static func missing(_ letters: [Character], in field: String) -> Int? {
        var has: (UInt64, UInt64) = (0, 0)
        for b in field.utf8 {
            guard b < 128 else { return nil }
            let c = b >= 65 && b <= 90 ? b + 32 : b
            if c < 64 { has.0 |= 1 << c } else { has.1 |= 1 << (c - 64) }
        }
        var missing = 0
        for ch in letters where ch != " " {
            guard let c = ch.asciiValue else { return nil }
            if (c < 64 ? has.0 >> c : has.1 >> (c - 64)) & 1 == 0 { missing += 1 }
        }
        return missing
    }

    /// A title folded once: its letters and where its words start.
    fileprivate struct Title {
        let letters: [Character], starts: [Bool]

        init(_ raw: String) {
            let chars = Array(raw)
            // ASCII folds to its lowercase without a String per letter, which every keystroke paid on every row.
            letters = chars.map { c in
                guard let a = c.asciiValue else { return fold(String(c)).first ?? c }
                return (65...90).contains(a) ? Character(Unicode.Scalar(a + 32)) : c
            }
            starts = chars.indices.map { j in
                j == 0 || !(chars[j - 1].isLetter || chars[j - 1].isNumber) || (chars[j].isUppercase && chars[j - 1].isLowercase)
            }
        }
    }

    /// `words` is never empty when typed; the total only gates typo scores, since a spelled word already passed it.
    private static func score(_ query: Query, in title: Title, typos: Bool) -> Int? {
        guard !query.words.isEmpty else { return 0 }
        var points = 0, best = 0
        for w in query.words.indices {
            guard let p = wordPoints(query.words[w], fixes: query.fixes[w], in: title, typos: typos) else { return nil }
            points += p
            best += perfect(query.words[w].count)
        }
        let total = points * 100 / best
        return total >= gate ? min(total, 100) : nil
    }

    /// A word's points in the title, from its own letters or, with `typos` and failing those, from a typo of it.
    private static func wordPoints(_ word: [Character], fixes: [[Character]], in title: Title, typos: Bool) -> Int? {
        let full = perfect(word.count)
        if let p = align(word, in: title), p * 100 >= gate * full { return p }
        guard typos, word.count >= typoLetters else { return nil }
        if let best = fixes.compactMap({ fix in align(fix, in: title).map { $0 * full / perfect(fix.count) } }).max() {
            return Int(Double(best) * typo)
        }
        guard word.count >= 8, startsNear(word, in: title, before: nil) else { return nil }
        return Int(Double(full) * twoTypos)
    }

    /// The fewest edits (a letter added, dropped, changed, or two neighbours swapped) turning `word` into the start of
    /// `title`, when `within` or fewer; nil otherwise. One table row per letter of the word, over the title's first
    /// letters only, and it stops once no row can come back under the limit (a swap reads the row two back).
    static func edits(_ word: [Character], toStartOf title: ArraySlice<Character>, within limit: Int) -> Int? {
        guard !word.isEmpty else { return 0 }
        let t = title.prefix(word.count + limit), m = t.count, at = t.startIndex
        // The row two back, the last row and the one being filled, reused.
        var back = [Int](repeating: 0, count: m + 1), last = Array(0...m), row = back, lastLow = 0
        for i in 1...word.count {
            row[0] = i
            var low = i
            for j in stride(from: 1, through: m, by: 1) {
                var d = min(last[j] + 1, row[j - 1] + 1, last[j - 1] + (word[i - 1] == t[at + j - 1] ? 0 : 1))
                if i > 1, j > 1, word[i - 1] == t[at + j - 2], word[i - 2] == t[at + j - 1] { d = min(d, back[j - 2] + 1) }
                row[j] = d
                low = min(low, d)
            }
            guard min(low, lastLow + 1) <= limit else { return nil }
            (back, last, row, lastLow) = (last, row, back, low)
        }
        return lastLow <= limit ? lastLow : nil
    }

    /// What a word scores as the title's own start, every letter in a row.
    private static func perfect(_ n: Int) -> Int { 36 + 22 * (n - 1) }

    /// One placement of a word's first letters, ending at a title letter: its points, whether the run it ends began
    /// at a word's start, where its first letter sits and whether any run began inside a word.
    private struct Placement { var points: Int, boundaryRun: Bool, first: Int, runInWord: Bool }

    /// The best placement of the word's letters in order, by points; nil when the letters are not there, or when the
    /// best placement crosses words and starts a run inside one.
    private static func align(_ q: [Character], in title: Title) -> Int? {
        let t = title.letters, starts = title.starts, n = q.count, m = t.count
        // Most rows fail this one pass, which skips the table.
        var next = 0
        for c in t where next < n && c == q[next] { next += 1 }
        guard n > 0, next == n else { return nil }
        func bonus(_ j: Int) -> Int { j == 0 ? 10 : starts[j] ? 8 : 0 }
        // row[j]: the best placement with the current letter at title letter j; only the row before is ever read.
        var row: [Placement?] = t.indices.map { j in
            t[j] == q[0] ? Placement(points: 16 + 2 * bonus(j), boundaryRun: bonus(j) > 0, first: j, runInWord: !starts[j]) : nil
        }
        for i in 1..<n {
            // The best earlier placement two or more letters back, for a gap (a gap of g letters costs 3 + (g - 1),
            // kept as points + index) and for a jump to a word's start, which costs a flat 3.
            var gap: (key: Int, at: Placement)?, jump: Placement?
            var next = [Placement?](repeating: nil, count: m)
            for j in 0..<m {
                if j >= 2, let p = row[j - 2] {
                    if gap.map({ p.points + j - 2 > $0.key }) ?? true { gap = (p.points + j - 2, p) }
                    if jump.map({ p.points > $0.points }) ?? true { jump = p }
                }
                guard t[j] == q[i], j >= 1 else { continue }
                var pick: Placement?
                if let p = row[j - 1] {
                    pick = Placement(points: p.points + 16 + max(bonus(j), p.boundaryRun ? 6 : 4), boundaryRun: p.boundaryRun,
                                     first: p.first, runInWord: p.runInWord)
                }
                let jumped = starts[j] ? jump.map { Placement(points: $0.points + 16 + bonus(j) - 3, boundaryRun: true,
                                                               first: $0.first, runInWord: $0.runInWord) }
                                       : gap.map { Placement(points: $0.key - j + 15, boundaryRun: false, first: $0.at.first,
                                                             runInWord: true) }
                if let jumped, jumped.points > pick?.points ?? Int.min { pick = jumped }
                next[j] = pick
            }
            row = next
        }
        guard let end = row.indices.filter({ row[$0] != nil }).max(by: { row[$0]!.points < row[$1]!.points }),
              let best = row[end] else { return nil }
        let crossesWords = (best.first + 1..<end + 1).contains { starts[$0] }
        return crossesWords && best.runInWord ? nil : best.points
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}

/// One level of the menu (GLOSSARY.md, Branch): the ten under the root, Learn → Keybindings and Trigger → Capture inside
/// them, and the categories Install, Remove and Update are browsed by.
public indirect enum MenuBranch: Hashable, Sendable {
    case apps, learn, trigger, install, remove, update, clean, system, config, keybindings, capture, homebrew, translate, reminders,
         snippets, notes
    /// Extensions (story 158): a sub-branch per installed extension holding its commands, then Browse catalogue; above
    /// System.
    case extensions
    /// Trigger → Stickers and GIFs (card agent-bo-95423130).
    case stickers
    /// Trigger → Emoji, the grid (P39).
    case emoji
    /// What runs on this Mac and its readings, as screens of their own in the menu (Sven 2026-10-21, Q399 and Q400): extra
    /// rows only, off until switched on, found by name at a root search. Activity lists the apps and the background, live;
    /// Stats draws its cards in place of rows (MenuStatsScreen).
    case activity, stats
    /// About (Sven 2026-10-24, Q443): this Mac and Pilot, Omarchy's About as a screen of its own in the menu
    /// (MenuAboutScreen), above System as Omarchy keeps it.
    case about
    /// Trigger → QR: Make and Read a QR code, which Trigger also lists, for More rows' QR (Sven, Q398).
    case qr
    /// Trigger → Define (Q596): a word's meanings, synonyms and Spanish, its picked row in full beside them (Define).
    case define
    /// A category by name inside Install (a catalogue category), Remove or Update (card agent-bo-95423022).
    case category(String, in: MenuBranch = .install)

    /// Every fixed branch, by hand since `category` takes a value; a new case goes here too, or the root misses it.
    /// The root's default order is theirs (Sven's own is MenuRoot): System last, where Omarchy keeps it, About right above
    /// it as Omarchy has it (Q446), Extensions above that (story 158). A saved order puts About after Extensions.
    public static let allCases: [MenuBranch] = [.apps, .learn, .trigger, .install, .remove, .update, .clean, .config, .extensions, .about, .system,
                                                .keybindings, .capture,
                                                .homebrew, .translate, .reminders, .snippets, .notes, .stickers, .emoji,
                                                .activity, .stats, .qr, .define]

    /// The branches under the root, which a root search finds by name: `top` and Config.
    public static let searched = allCases.filter { $0.parent == nil }

    /// The branches the root lists. Config, Activity and Stats are extra rows, off until switched on (Sven 2026-10-21).
    public static let top = searched.filter { ![.config, .activity, .stats].contains($0) }

    /// The branch a category browses (Install, Remove or Update); any other branch itself.
    public var browsed: MenuBranch { if case .category(_, let b) = self { b } else { self } }

    /// Whether `other` is one of this branch's categories, or of the branch it also browses (MenuLayout.alsoBrowses).
    func browses(_ other: MenuBranch) -> Bool {
        other != self && (other.browsed == self || other.browsed == MenuLayout.alsoBrowses[self])
    }

    /// The branch's id in logs and frecency: its case name, `category:<name>` in Install, `remove:<name>` and `update:<name>`.
    public var rawValue: String {
        if case .category(let c, let browse) = self { return "\(browse == .install ? "category" : browse.rawValue):\(c)" }
        return String(describing: self)
    }

    public var title: String {
        switch self {
        case .category(let c, _): c
        case .homebrew: "Search packages"
        case .stickers: "Stickers and GIFs"
        case .qr: "QR"
        default: rawValue.capitalized
        }
    }

    /// The branch that lists this one (MenuLayout, or the branch a category browses); nil under the root.
    public var parent: MenuBranch? {
        if case .category(_, let browse) = self { return browse }
        return MenuLayout.rows.first { $0.value.contains { if case .branch(self, _) = $0 { true } else { false } } }?.key
    }
}

/// One row of the menu: an app, a window, a file, a registry action or a branch. `home` is the branch that lists it;
/// nil is found only by typing at the root, as windows, files and unbound actions are.
public struct MenuEntry: Identifiable, Equatable, Sendable {
    public enum Target: Hashable, Sendable {
        /// A window by the tiler's id; a file by its path; a package to install by its key (Package.key, or
        /// `download:<catalogue id>`).
        case app(String), window(Int), file(String), package(String), action(String), branch(MenuBranch)
        /// A row Remove lists, by RemoveRow.key; not a pick, so Remove keeps its own order.
        case remove(RemoveList.Pick)
        /// A row Update lists; not a pick either.
        case update(UpdateList.Pick)
        /// A row Clean lists (story 117); not a pick.
        case clean(CleanMenu.Pick)
        /// Text Return copies, such as a translation; not a pick.
        case copy(String)
        /// An emoji Return types into the app Sven was in (EmojiSearch); a pick, so the ones he uses come first.
        case emoji(String)
        /// A sticker Return pastes as a picture into the app Sven was in (Stickers); a pick.
        case sticker(Sticker)
        /// A reminder Return sets, or one Return cancels (Reminders); neither is a pick.
        case reminder(Reminders.Pick)
        /// A snippet Return pastes into the app Sven was in (card agent-bo-95423044); a pick, whatever its argument.
        case snippet(SnippetPick)
        /// A quick note Return opens in the notes panel, or a line Return adds to Scratch (Notes); not a pick.
        case note(Notes.Pick)
        /// A question Return sends in the AI chat (QuickAI, story 166); not a pick.
        case ask(String)
        /// An event typed after `event ` Return adds to the default calendar (QuickEvent); not a pick.
        case calendarEvent(QuickEvent)
        /// The root search's Search files row for what was typed (card agent-bo-95422968): Return opens the Files
        /// view, the one place the file index is asked; not a pick.
        case searchFiles
        /// A root search that found nothing else offers Install's search for the text (Sven 2026-10-12): Return opens
        /// Search packages searching it; not a pick.
        case searchInstall(String)
        /// Search the web for what was typed, in the default browser with its default search engine (Sven 2026-10-16):
        /// every root search offers it, as it offers Ask AI (MenuNavigator.fallbacks); not a pick.
        case searchWeb(String)
        /// The Files view's one row while Pilot lacks Full Disk Access (card agent-bo-95423031): Return opens that
        /// setting; not a pick.
        case allowFullDiskAccess
        /// A place in Pilot's app window Return opens, a page and its tab, such as Launcher › Abilities for the GIPHY key
        /// (story 164; a tab since the page map, Sven 2026-10-17); not a pick.
        case openPage(AppPlace)
        /// A row Activity lists, by Activity.Row.id: Return asks it to quit, Cmd+Return forces it (MenuActivity); not a pick.
        case process(String)

        /// A row that offers to search elsewhere for what was typed (Search files, Search to install), not a result.
        public var isSearchOffer: Bool {
            switch self { case .searchFiles, .searchInstall, .searchWeb: true; default: false }
        }

        /// The entry's id in the frecency store; nil for a window, which is not a pick: the tiler's id ends with it.
        /// The target a saved `key` names, for the kinds a Launcher tile keeps (Widget.isMenuKey): an app, an action, a
        /// branch; nil for any other.
        public init?(key: String) {
            guard let colon = key.firstIndex(of: ":") else { return nil }
            let id = String(key[key.index(after: colon)...])
            switch key[..<colon] {
            case "app": self = .app(id)
            case "action": self = .action(id)
            case "branch": guard let branch = MenuBranch(id: id) else { return nil }; self = .branch(branch)
            default: return nil
            }
        }

        public var key: String? {
            switch self {
            case .app(let b): "app:\(b)"
            case .window, .remove, .update, .clean, .copy, .reminder, .note, .ask, .calendarEvent, .searchFiles, .searchInstall, .searchWeb, .allowFullDiskAccess, .openPage, .process: nil
            case .file(let path): "file:\(path)"
            case .package(let key): "package:\(key)"
            case .action(let id): "action:\(id)"
            case .branch(let b): "branch:\(b.rawValue)"
            case .emoji(let e): "emoji:\(e)"
            case .snippet(let pick): "snippet:\(pick.id.uuidString)"
            case .sticker(let s): "sticker:\(s.value)"
            }
        }

        /// A file's path, or a picture sticker's: the rows that wear the file's icon.
        public var filePath: String? {
            switch self {
            case .file(let path), .sticker(.image(let path)): path
            default: nil
            }
        }
    }
    /// The tag a search result carries (wireframe section 5); Tab narrows the root search to one.
    public enum Kind: String, CaseIterable, Sendable {
        /// A setting is a page or part of Pilot's window or a System Settings pane, found by typing (SettingsSearch).
        case app, window, file, action, package, emoji, snippet, sticker, answer, branch, menuItem, setting
        /// An app's own command from the drive catalogue (P38): an action Tab and the counts take as one.
        case command
        /// An action on what is selected in the app in front, Finder's folders (P43): its provider never replaces the actions.
        case selection

        /// Tab's cycle at the root search, as the wireframe orders it: every kind (nil), then each with a chip; branches,
        /// emoji and answers have none (cards agent-bo-95422931 and agent-bo-95422933).
        public static let tabOrder: [Kind?] = [nil, .app, .window, .file, .action, .package]

        /// The kind as a word, Vicinae's "Command"; nil for a file and an answer.
        public var word: String? {
            switch self {
            case .app: "App"
            case .window: "Window"
            case .action, .selection: "Action"
            case .command: "Command"
            case .package: "Package"
            case .emoji: "Emoji"
            case .snippet: "Snippet"
            case .sticker: "Sticker"
            case .branch: "Menu"
            case .menuItem: "Menu item"
            case .setting: "Setting"
            case .file, .answer: nil
            }
        }

        /// A row's share of its match score at a search. Files count 0.8 (they rank only among themselves since the Files
        /// view, card agent-bo-95422968, so this weighs nothing today): there are thousands of names, so one starting
        /// with the typed letters must not push out the app, action or window that matches about as well (am: files
        /// starting with am over Activity Monitor, card agent-bo-95422777); a file still wins on a clearly better match.
        /// Emoji count 0.6, so an app or action that matches as well stays above an emoji never picked; menu items 0.8,
        /// so the app or action that matches as well stays above one of the front app's hundreds of items; settings 0.8, so
        /// Pilot's own Wi-Fi switch stays above the Wi-Fi pane (Q131). It weighs only among rows of one strength: a
        /// title typed whole leads at any weight (FuzzyRanker.strength, P53).
        public var searchWeight: Double {
            switch self { case .file, .menuItem, .setting: 0.8; case .emoji: 0.6; default: 1 }
        }

        /// The tab that lists the kind: a command or an app's menu item is an action there, so it needs no tab of its own
        /// (P38; Sven, 1.0.1: an app's actions counted only its catalogue commands).
        public var tab: Kind { self == .command || self == .menuItem ? .action : self }
    }

    public var title: String, target: Target, home: MenuBranch?
    /// What the row shows on the right: a bind, or a branch's count.
    public var detail: String?
    /// The detail is a bind's trigger, drawn as a key cap; otherwise it is a count, a place, a path or a command.
    public var detailIsKey: Bool
    /// An app that runs, with a window or without: its row shows a dot.
    public var running: Bool
    /// False for a row only its branch lists, such as Learn's copy of a bind search already finds as an app row.
    public var inSearch: Bool
    /// More words the search matches besides the title, such as an emoji's keywords ("burn" for 🔥).
    public var keywords: String?
    /// A row that answers what was typed instead of matching it, such as a translation (card agent-bo-95422932): never
    /// ranked or filtered out, listed first.
    public var isAnswer: Bool
    /// A kind of its own over the one its target gives, so its provider never replaces that kind's rows: a menu item
    /// of the front app runs a drive route action, yet is listed as a menu item (MenuItemSearch).
    public var ownKind: Kind?
    /// The bundle id of the app the row belongs to, whose icon it wears: a window's app, an action titled "App: verb".
    public var app: String?
    /// Muted words after the title: the app an action belongs to, a file's folder.
    public var subtitle: String?
    /// A switch's state, shown on its row (System's dark mode, Wi-Fi); nil for a row that switches nothing.
    public var isOn: Bool?
    /// What the row's icon shows when its target alone does not say (MenuIcon): a package's app or kind, an Install
    /// category's glyph, a line of Clean's preview.
    public var icon: MenuIcon?
    /// A live picker row's own actions by title, first Return's (an extension row's, card agent-bo-95423244).
    public var ownActions: [String]?
    /// Each of those actions' key, nil for one with none; nil when none has a key (To-do B): pressed, it runs that action.
    public var ownKeys: [Extension.Item.Action.Key?]?
    /// The heading a picker draws over this row and the rows after it that share it (an extension item's `section`, Open
    /// With…'s Suggested and Other apps).
    public var section: String?
    /// An extension's detail, which the panel draws in place of the list this row stands alone in (card agent-bo-95423245).
    public var extensionDetail: Extension.Detail?
    /// The extension whose page Cmd+Return opens from its detail (pilot-1-1 T9, Q639); nil when it has none to open.
    public var extensionPage: String?
    /// The installed extension an Extensions row stands for (story 158): Cmd+K offers Uninstall… on it.
    public var extensionID: String?
    /// What Return types into the search instead of running the row: a quicklink's keyword and a space, so the words
    /// it searches for go after it (card agent-bo-95423030).
    public var fills: String?
    /// The detail in a few words, where a style shows a summary in its place and the detail whole in a tooltip
    /// (Instrument's Update all: "2 casks · 1 formula" for its command).
    public var short: String?
    /// The words in a file's picture the text index matched (Homy-style Files): a row found by them alone lists after
    /// the name hits, in the index's order, and its icon wears text.viewfinder.
    public var matchedWords: String?

    public init(title: String, target: Target, home: MenuBranch? = nil, detail: String? = nil, detailIsKey: Bool = false,
                running: Bool = false, inSearch: Bool = true, keywords: String? = nil, isAnswer: Bool = false, ownKind: Kind? = nil,
                app: String? = nil, subtitle: String? = nil, isOn: Bool? = nil, icon: MenuIcon? = nil, fills: String? = nil,
                short: String? = nil) {
        self.title = title; self.target = target; self.home = home; self.detail = detail; self.detailIsKey = detailIsKey
        self.running = running
        self.inSearch = inSearch
        self.keywords = keywords
        self.isAnswer = isAnswer
        self.ownKind = ownKind
        self.app = app; self.subtitle = subtitle; self.isOn = isOn; self.icon = icon; self.fills = fills; self.short = short
    }

    public var id: Target { target }
    /// The row's id in the frecency store: its target's, except an answer's, which answers one search and is never a pick
    /// (a translation's Download row opens an action, yet picking it says nothing about that action).
    public var frecencyKey: String? { isAnswer ? nil : target.key }
    /// What a search matches: the title and any keywords.
    public var searchText: String { keywords.map { "\(title) \($0)" } ?? title }
    /// An answer is its own kind (card agent-bo-95422933), so providing answers never replaces the rows of the kind its
    /// target would give (the root's unbound actions).
    public var kind: Kind {
        if isAnswer { return .answer }
        if let ownKind { return ownKind }
        return switch target {
        case .app: .app; case .window: .window; case .file, .allowFullDiskAccess: .file; case .package, .remove, .update: .package; case .action, .copy, .clean, .reminder, .note, .ask, .calendarEvent, .openPage, .process: .action
        case .emoji: .emoji
        case .snippet: .snippet
        case .sticker: .sticker
        case .branch, .searchFiles, .searchInstall, .searchWeb: .branch
        }
    }

    /// The title as the row shows it: a switch the thing it switches ("Dark mode"); an app's action drops the "App: " its
    /// app's icon and subtitle already say, with its verb capitalised ("Search vault"); search still matches the whole title.
    public var shownTitle: String {
        if isOn != nil {
            var noun = Substring(title)
            for verb in ["Toggle ", "Turn "] where noun.hasPrefix(verb) { noun = noun.dropFirst(verb.count) }
            if noun.hasSuffix(" on or off") { noun = noun.dropLast(" on or off".count) }
            return noun.prefix(1).uppercased() + noun.dropFirst()
        }
        guard app != nil, kind.tab == .action, let subtitle, title.hasPrefix(subtitle + ": ") else { return title }
        let verb = title.dropFirst(subtitle.count + 2)
        return verb.prefix(1).uppercased() + verb.dropFirst()
    }

    /// The row's kind as a word on its right, Vicinae's "Command"; nil for a file, whose day sits there, and an answer.
    /// A row that offers to look elsewhere for what was typed, not a result: Search files, Search to install, Search the
    /// web, and the Ask AI row every root search ends its hits with (an `ask …` typed is an answer, a result).
    public var isOffer: Bool {
        if target.isSearchOffer { return true }
        if case .ask = target { return !isAnswer }
        return false
    }

    public var kindWord: String? { if case .sticker(let s) = target { s.word } else { kind.word } }

    /// What Return does to the row, as the foot names it.
    public var returnLabel: String {
        switch target {
        case .app: "Open app"
        case .window: "Focus window"
        case .file: "Open file"
        // Install's Searching row searches the web while the sources answer.
        case .package: MenuEntries.isSearching(self) ? "Search the web" : "Install"
        case .branch, .searchFiles, .searchInstall, .note(.open), .openPage: "Open"
        case .searchWeb: "Search"
        case .note(.append), .calendarEvent: "Add"
        case .ask: "Ask"
        case .allowFullDiskAccess: "Open Settings"
        case .copy: "Copy"
        case .emoji: "Type"
        case .snippet, .sticker: "Paste"
        case .action, .remove, .update, .clean, .reminder: "Run"
        case .process: "Quit"
        }
    }
}

/// The menu's state and keys, with no window: which branch is open, the search, the selected row and the kind Tab
/// narrowed the root search to. The panel feeds it keys and acts on the outcome.
public struct MenuNavigator: Sendable {
    public enum Key: Equatable, Sendable {
        case up, down, `return`, commandReturn, commandK, escape, left, right, tab, space
        /// Shift+Tab: the kind tab before.
        case backTab
        /// ⌘1, ⌘2, ⌘3 (with ⇧ the one before): the Files view's filters (N5).
        case filter(FileFilters.Facet, back: Bool)
        /// ⌘⇧.: Show hidden in the Files view, as Finder's.
        case toggleHidden
        /// ⌘1 to ⌘9 in Line (menu-morph T3): run the list's nth row, as a click on it would. PilotMenu sends it only
        /// outside the Files view, where ⌘1 to ⌘3 stay its filters.
        case number(Int)
    }
    /// Providers that search as Sven types (files, Homebrew) start at this many characters.
    public static let minimumQuery = 2
    /// ignored: the key is not the menu's, so the search field gets it (← and → move the caret). act: a Cmd+K action
    /// the panel carries out on the row. preview: Quick Look on a file.
    /// back: Escape in a picker opened from a menu row, which reopens the menu where that row was (card agent-bo-95423020).
    /// toggle: Space on a switch, whose action the panel runs with the menu left open (S1); the row is already flipped.
    public enum Outcome: Equatable, Sendable {
        case handled, ignored, close, run(MenuEntry), reveal(MenuEntry), act(RowAction, MenuEntry), preview(MenuEntry), back(Spot)
        case toggle(MenuEntry)
        /// One of a live picker row's own actions, by its index (card agent-bo-95423244); Return is its first.
        case own(Int, MenuEntry)
    }

    /// Where the menu stands: the open branch, what was typed and the selected row. A picker opened while a menu row runs
    /// carries it (card agent-bo-95423020), so Escape there goes back one level instead of closing the menu.
    public struct Spot: Equatable, Sendable {
        public var branch: MenuBranch?, query: String, row: MenuEntry.Target?
        /// MenuNavigator.rooted, so back in a branch an extra row opened, up still goes to the root.
        public var rooted: MenuBranch?

        public init(branch: MenuBranch?, query: String = "", row: MenuEntry.Target? = nil, rooted: MenuBranch? = nil) {
            self.branch = branch; self.query = query; self.row = row; self.rooted = rooted
        }
    }

    private var entries: [MenuEntry]
    /// The root search Search to install left, which Escape in Search packages goes back to; gone once Sven goes up.
    private var installFrom: Spot?
    /// The picks the ranking reads; Reset ranking changes them here and the panel saves them.
    public private(set) var frecency: Frecency
    private let now: Date
    /// The rows Sven made favourites, by frecency key: a favourite's boost is two more than its frecency's, and frecency
    /// tops out at one, so it beats any equal match that is not a favourite (Moody, o8q5FSbLr3o).
    public private(set) var favourites: Set<String>
    /// The rows' aliases (card agent-bo-95423037): the one the root search names exactly lists first.
    public let aliases: Aliases
    /// The selected row's Cmd+K actions while they show; the keys go to them first.
    public private(set) var actions: RowActionsMenu?
    /// What the actions' filter holds.
    public var actionQuery: String {
        get { actions?.query ?? "" }
        set { actions?.query = newValue }
    }
    /// Each entry's frecency over the best entry's, 0 to 1; empty when nothing was picked.
    private var boost: [String: Double]
    /// What the rows' titles scored, so the ranks a keystroke runs (the search, each kind's count, each provider's rows)
    /// score each title once.
    private let memo = FuzzyRanker.Memo()
    public private(set) var branch: MenuBranch?
    /// A deeper branch an extra row opened from the root before typing (Notes from More rows, Sven 2026-10-21): up from it
    /// goes back to the root, not to the branch it lives in; nil when the open branch was reached through its parent.
    private var rooted: MenuBranch?
    /// Ranks again only when it changes: the search field hands back its text as it takes focus, which must not move the
    /// selection to the first row.
    public var query = "" { didSet { if query != oldValue { refresh() } } }
    /// The web search's engine and browser as the Search the web row names them ("Google in Chrome"); nil until read.
    public var webVia: String? { didSet { if webVia != oldValue, !query.isEmpty { refresh() } } }
    /// The root without a search lists the branches; a root search ranks every entry and the branch names, gathered by group after the best match (MenuGroups); inside a
    /// branch, its own entries by frecency, ranked once something is typed. Ranked once per change, not per read.
    public private(set) var rows: [MenuEntry] = []
    public private(set) var selection = 0
    /// Tab's pick at the root search; nil is every kind.
    public private(set) var only: MenuEntry.Kind?
    /// Each tab kind's count at the root, set with the rows; read through `count(of:)`.
    private var kindCounts: [MenuEntry.Kind: Int] = [:]
    /// Every root branch, which a root search finds, hidden ones and Config too; `rootRows` the ones the root lists before typing,
    /// in Sven's order (MenuRoot, story 152).
    private let branchRows: [MenuEntry], rootRows: [MenuEntry]
    /// A picker: the root lists the entries themselves, not the branches.
    public let isList: Bool
    /// A picker's heading, "Audio output"; nil is the menu's own.
    public let title: String?
    /// Where a picker opened from a menu row came from; nil for the menu itself and a picker a bind opened.
    public let back: Spot?
    /// A live picker, whose rows its source replaces as Sven types (an extension's list, card agent-bo-95423243).
    public let isLive: Bool

    /// `branch` opens the menu inside it, as Omarchy's apps menu opens in Apps; `frecency` ranks the entries as of `now`;
    /// `root` orders and hides the root's branches and places the extras switched on among them.
    public init(entries: [MenuEntry], branch: MenuBranch? = nil, frecency: Frecency = Frecency(), favourites: Set<String> = [],
                aliases: Aliases = Aliases(), root: MenuRoot = MenuRoot(), now: Date = .now) {
        self.entries = entries
        isList = false
        isLive = false
        title = nil
        back = nil
        self.frecency = frecency
        self.favourites = favourites
        self.aliases = aliases
        self.now = now
        boost = frecency.boosts(for: entries.compactMap(\.target.key), now: now)
        let apps = entries.count { $0.home == .apps }
        func row(_ b: MenuBranch) -> MenuEntry { MenuEntry(title: b.title, target: .branch(b), detail: b == .apps ? "\(apps) installed" : nil) }
        branchRows = (root.arranged() + MenuBranch.searched.filter { !MenuBranch.top.contains($0) }).map(row)
        // An extra's action row is the action's own (its icon, its key) under the extra's name; one not registered is left
        // out. Only the root before typing lists extras: a search finds them where they live.
        rootRows = root.shownRows().compactMap { r -> MenuEntry? in
            switch r {
            case .branch(let b): return row(b)
            case .extra(let e):
                guard case .action(let id) = e.target else { return MenuEntry(title: e.title, target: e.target) }
                guard var entry = entries.first(where: { $0.target == .action(id) }) else { return nil }
                entry.title = e.title
                return entry
            }
        }
        self.branch = branch
        refresh()
    }

    /// A picker over `list`, e.g. the lazygit repos: ranked by what is typed, Return picks, Escape goes `back` to the menu
    /// row that opened it, or closes.
    public init(list: [MenuEntry], title: String? = nil, back: Spot? = nil, live: Bool = false) {
        entries = list
        isList = true
        isLive = live
        self.title = title
        self.back = back
        frecency = Frecency()
        favourites = []
        aliases = Aliases()
        now = .now
        boost = [:]
        branchRows = []
        rootRows = []
        refresh()
    }

    public var selected: MenuEntry? { rows.indices.contains(selection) ? rows[selection] : nil }

    /// Where the menu stands now, for a picker the selected row opens.
    public var spot: Spot { Spot(branch: branch, query: query, row: selected?.id, rooted: rooted) }

    /// Back at `spot` (Escape in a picker it opened): its branch and search, its row selected while it is listed.
    public mutating func go(to spot: Spot) {
        let moved = branch != spot.branch || only != nil
        branch = spot.branch
        rooted = spot.rooted
        only = nil
        if query != spot.query { query = spot.query } else if moved { refresh() }
        select(spot.row)
    }

    /// `id`'s row, or the first when it is not listed.
    private mutating func select(_ id: MenuEntry.Target?) { selection = rows.firstIndex { $0.id == id } ?? 0 }

    /// The extension detail the panel draws in place of the list: a live picker's one row's (card agent-bo-95423245).
    public var shownDetail: Extension.Detail? { isLive && rows.count == 1 ? rows[0].extensionDetail : nil }

    /// What Cmd+K offers on the selected row: in a live picker the row's own actions, in another picker nothing (its
    /// rows can be Bitwarden's logins), elsewhere Pilot's row actions.
    public var selectedActions: [RowActionsMenu.Choice] {
        guard let row = selected else { return [] }
        if isList { return isLive ? (row.ownActions ?? []).enumerated().map { .own($0, $1) } : [] }
        return RowAction.list(for: row, favourite: row.frecencyKey.map(favourites.contains) ?? false)
            .filter { $0 != .changeLanguages || branch == nil }.map(RowActionsMenu.Choice.row)
    }

    /// The line the file index is asked: only in the Files view (Search files picked, or Tab to Files), never while
    /// typing under All (card agent-bo-95422968); without the typed filters (`kind:pdf`, `from:whatsapp`), from the
    /// second other character.
    public var fileQuery: String? { inFiles ? FileSearch.query(for: fileWords.text) : nil }

    /// The Files view's words without the typed filters, and the `from:` among them.
    private var fileWords: (text: String, from: String?) { FileSearch.typedFrom(FileFilters.typed(query, home: home).text) }

    /// The Files view: a root search showing files only.
    public var inFiles: Bool { branch == nil && !isList && only == .file }

    /// The Files view's stepped filters and Show hidden (N5), kept while the menu is open; the panel sets `hidden` from
    /// Files › File search as the menu opens.
    public var fileFilters = FileFilters()
    /// Home, which `~` and the places stand for; a test passes its own.
    public var home = NSHomeDirectory()

    /// The filters in force: the stepped ones with the typed ones over them, as the chips show them.
    public var shownFileFilters: FileFilters { fileFilters.merged(with: FileFilters.typed(query, home: home).filters) }

    /// What the index is asked in the Files view: the words and the filters in force.
    public var fileAsk: FileSearch.Ask? {
        guard inFiles else { return nil }
        let words = fileWords
        return FileSearch.query(for: words.text).map { FileSearch.Ask(text: $0, filters: shownFileFilters, from: words.from) }
    }

    /// ⌘1, ⌘2, ⌘3 or a chip's click: the next value of a filter. A typed one gives way, so the step shows.
    public mutating func stepFilter(_ facet: FileFilters.Facet, by step: Int = 1) {
        if FileFilters.typed(query, home: home).filters.isSet(facet) {
            fileFilters = shownFileFilters
            query = FileFilters.removing(facet, from: query, home: home)
        }
        fileFilters.step(facet, by: step)
    }

    /// A chip's ×: the filter is gone, typed or stepped.
    public mutating func clearFilter(_ facet: FileFilters.Facet) {
        fileFilters.clear(facet)
        if FileFilters.typed(query, home: home).filters.isSet(facet) { query = FileFilters.removing(facet, from: query, home: home) }
    }

    /// The open branch and the branches above it, outermost first: the breadcrumbs.
    public var path: [MenuBranch] { Array(sequence(first: branch) { $0.map(parent) }.compactMap(\.self).reversed()) }

    /// The branch up goes to from `b`: the root from the one an extra row opened, else the branch `b` lives in.
    private func parent(_ b: MenuBranch) -> MenuBranch? { b == rooted ? nil : b.parent }

    /// A provider's rows that arrive after the menu opens (windows, files, Homebrew's results) replace the rows of that
    /// kind and home, and in a browsed branch the rows of its categories too (Remove's and Update's, card
    /// agent-bo-95423022), and the rows of those categories themselves, which its rows bring again (Sven 2026-10-09:
    /// Update's second read listed Apps twice); the selected row stays selected when it is still listed. An arriving
    /// answer (a translation) is selected unless Sven had moved off the first row, so Return takes what he asked for.
    public mutating func provide(_ kind: MenuEntry.Kind, home: MenuBranch? = nil, _ rows: [MenuEntry]) {
        func category(_ e: MenuEntry) -> Bool {
            if case .branch(let b) = e.target, e.home == home { home?.browses(b) == true } else { false }
        }
        func theirs(_ e: MenuEntry) -> Bool {
            category(e) || e.kind == kind && (e.home == home || (e.home.map { home?.browses($0) ?? false } ?? false))
        }
        // Nothing new (no rows before or after, or the same ones again): no rank, which runs on every keystroke.
        guard entries.filter(theirs) != rows else { return }
        let untouched = selection == 0, answer = rows.contains(where: \.isAnswer)
        // An offer (Ask AI, Search the web, Search files) or Install's Searching row, selected only because nothing else
        // was listed yet, gives way to the first row that arrives: the Searching row shares the web row's target, so
        // keeping it carried the selection to that last row (Sven 2026-10-12).
        let placeholder = selected.map { $0.isOffer || MenuEntries.isSearching($0) } ?? false
        let keep = untouched && (answer || placeholder) ? nil : selected?.id
        entries = entries.filter { !theirs($0) } + rows
        rerank(keeping: keep)
    }

    /// A live picker's rows, all its source's (an extension's list, card agent-bo-95423243): each answer replaces every
    /// row before it, answers and ranked rows alike (Moody l8cEdH7tJF8), and the first row is selected. Only a live
    /// picker's: the menu's and another picker's rows are never replaced wholesale.
    public mutating func replaceList(_ rows: [MenuEntry]) {
        guard isLive else { return }
        entries = rows
        rerank(keeping: nil)
    }

    /// Ranks again after the entries, picks or favourites changed, keeping `id` selected while it is listed.
    private mutating func rerank(keeping id: MenuEntry.Target?) {
        boost = frecency.boosts(for: entries.compactMap(\.target.key), now: now)
        refresh()
        select(id)
    }

    private mutating func refresh() {
        selection = 0
        kindCounts = [:]
        guard let branch else {
            if isList { rows = MenuGroups.bySection(rank(entries)); return }
            // Nothing typed: the root's branches, or the kind Tab shows (rootKind); the Files view (also when Search inside
            // emptied it) lists nothing until Sven types.
            guard !query.isEmpty else {
                rows = only.map(rootKind) ?? rootRows
                kindCounts = Dictionary(uniqueKeysWithValues: [.app, .window, .action].map { k in (k, entries.count { Self.listedUntyped($0) && $0.kind.tab == k }) })
                return
            }
            // Under All, files wait for the Search files row (card agent-bo-95422968).
            let searched = (branchRows + entries).filter { $0.inSearch && (only == nil ? $0.kind != .file : $0.kind.tab == only) }
            let listed = rank(searched)
            // Each kind ranked on its own, as Tab to it lists them, so its count is that list's length; files only in the
            // Files view; the offers below are added after.
            kindCounts = [:]
            for k in MenuEntry.Kind.tabOrder.compactMap(\.self) where k != .file || only == .file {
                kindCounts[k] = k == only ? listed.count : rank(entries.filter { $0.inSearch && $0.kind.tab == k }).count
            }
            let searchFiles = only == nil ? FileSearch.query(for: query).map { MenuEntry(title: "Search files for \"\($0)\"", target: .searchFiles) } : nil
            rows = aliasFirst(MenuGroups.grouped(only == nil ? MenuGroups.appFirst(listed, query: query) : listed), of: searched)
            let files = searchFiles.map { [$0] } ?? []
            // Under All, Ask AI and Search the web for what was typed always, Search files with them: after the best match's
            // group, or first when nothing matched (Sven 2026-10-16, Q174; Search files joined them, Q182).
            let fallbacks = only == nil ? Self.fallbacks(query, after: rows, via: webVia) : []
            let install = InstallSearch.Query(query).map { [MenuEntry(title: "Search to install \"\($0.text)\"", target: .searchInstall($0.text))] } ?? []
            // Nothing else matched: Install's search is offered too, first when the text reads as an app's name.
            if only == nil, rows.isEmpty, !install.isEmpty {
                let offers = install + files
                rows = fallbacks + (Self.looksLikeApp(query) ? offers : offers.reversed())
            } else if only == .package {
                // Packages lists the catalogue's matches; Install's search follows them (Sven, 1.0.1: "videorc").
                rows += install
            } else {
                // Something matched, but not an app on this Mac (an emoji for "videorc", Sven 1.0.1): an app's name is still
                // offered to install.
                let installs = only == nil && rows.first?.kind != .app && Self.looksLikeApp(query)
                let end = Self.bestMatchEnd(rows), offers = fallbacks + files + (installs ? install : [])
                rows = Array(rows.prefix(end)) + offers + rows.dropFirst(end)
            }
            return
        }
        // The emoji grid lists its provider's rows as they came: EmojiGrid already matched and ordered them (P39).
        if branch == .emoji { rows = entries.filter { $0.home == .emoji }; return }
        // A search in Install, Remove or Update also finds the rows of its categories (card agent-bo-95423022).
        let listed = entries.filter { $0.home == branch || (!query.isEmpty && $0.home.map(branch.browses) == true) }
        // Activity's rows keep their Apps and Background together under a filter too, each busiest first as provided.
        rows = branch == .activity ? MenuGroups.bySection(rank(listed)) : MenuGroups.sectioned(rank(listed), in: branch, searching: !query.isEmpty)
    }

    /// A kind Tab shows at the empty root (Sven 2026-10-12): every app by frecency then name, every window by workspace
    /// as its provider listed them (MenuEntries.byWorkspace), every action by frecency then name; files and packages wait
    /// for a search and say so (emptyLine).
    private func rootKind(_ kind: MenuEntry.Kind) -> [MenuEntry] {
        guard [.app, .window, .action].contains(kind) else { return [] }
        let listed = entries.filter { Self.listedUntyped($0) && $0.kind.tab == kind }
        return kind == .window ? listed : rank(listed.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    /// A row a kind tab lists before anything is typed: an app's menu items are found only by typing (MenuItemSearch).
    private static func listedUntyped(_ row: MenuEntry) -> Bool { row.inSearch && row.kind != .menuItem }

    /// How many rows `kind` holds at the root (the Rail's counts): with a search, what Tab to it lists, offers never
    /// counted; nothing typed, every app, window and action. Nil leaves it blank: files under All, which wait for Search
    /// files (a file-index query per key), files and packages before a search, and every kind in a branch or a picker.
    public func count(of kind: MenuEntry.Kind) -> Int? { kindCounts[kind] }

    /// What an empty list says before anything is typed in the Files view or Packages; nil elsewhere, where the panel
    /// says it.
    public var emptyLine: String? {
        guard branch == nil, !isList, query.isEmpty else { return nil }
        switch only {
        case .file: return "Type to search \(shownFileFilters.place.map { "in \($0.title)" } ?? "your files")."
        case .package: return "Type to search Homebrew and the catalogue."
        default: return nil
        }
    }

    /// The row of `searched` whose alias the query is, before `rows` (card agent-bo-95423037), found even when its name
    /// does not match; `rows` as they are when the query is no alias.
    private func aliasFirst(_ rows: [MenuEntry], of searched: [MenuEntry]) -> [MenuEntry] {
        guard let key = aliases.key(for: query), let row = searched.first(where: { $0.frecencyKey == key }) else { return rows }
        return [row] + rows.filter { $0.id != row.id }
    }

    /// The alias the row's chip shows; nil when it has none.
    public func alias(of row: MenuEntry) -> String? { aliases.isEmpty ? nil : row.frecencyKey.flatMap(aliases.alias(for:)) }

    /// Answers first as they came, then the rest by match; in the Files view by the words alone, since the index
    /// already applied the typed filters (`kind:pdf`, `from:whatsapp`) the rows do not spell.
    /// An image found by its words alone matches no name: it follows the name hits, as the text index ranked it.
    private func rank(_ rows: [MenuEntry]) -> [MenuEntry] {
        let ranked = FuzzyRanker.rank(rows.filter { !$0.isAnswer }, query: inFiles ? fileWords.text : query, title: \.searchText,
                                      name: \.title, boost: { $0.target.key.map { (boost[$0] ?? 0) + (favourites.contains($0) ? 2 : 0) } ?? 0 },
                                      weight: { $0.kind.searchWeight },
                                      prefer: { $0.kind == .app ? 1 : 0 }, memo: memo)
        guard inFiles else { return rows.filter(\.isAnswer) + ranked }
        let listed = Set(ranked.map(\.id))
        return rows.filter(\.isAnswer) + ranked + rows.filter { $0.matchedWords != nil && !listed.contains($0.id) }
    }

    /// While text is typed Left and Right are the search field's, moving its caret (Sven 2026-10-12, over card
    /// agent-bo-95423021); Tab and Shift+Tab step a root search's kind tabs.
    public mutating func handle(_ key: Key) -> Outcome {
        if let menu = actions { return handleActions(key, menu) }
        switch key {
        case .up, .down:
            selection = min(max(selection + (key == .up ? -1 : 1), 0), max(rows.count - 1, 0))
            return .handled
        case .return:
            guard let row = selected else { return .handled }
            return pick(row)
        case .right:
            guard query.isEmpty, case .branch(let b)? = selected?.target else { return .ignored }
            open(b)
            return .handled
        case .commandReturn:
            guard let row = selected, [.app, .file].contains(row.kind) else { return .ignored }
            return .reveal(row)
        case .commandK:
            let list = selectedActions
            if let row = selected, !list.isEmpty { actions = RowActionsMenu(row: row, list) }
            return .handled
        case .escape:
            guard branch != nil else {
                if isList { return back.map { .back($0) } ?? .close }
                // At the root a typed search clears first, so Escape never throws away what Sven typed and closes at once.
                guard !query.isEmpty else { return .close }
                only = nil
                query = ""
                return .handled
            }
            if branch == .homebrew, let from = installFrom {
                installFrom = nil
                go(to: from)
                return .handled
            }
            up()
            return .handled
        case .left:
            guard branch != nil, query.isEmpty else { return .ignored }
            up()
            return .handled
        case .tab, .backTab:
            // At the empty root too, where each kind lists all it holds (Sven 2026-10-12); never in an empty picker.
            guard branch == nil, !query.isEmpty || !isList else { return .ignored }
            stepKind(key == .tab ? 1 : -1)
            return .handled
        case .filter(let facet, let back):
            guard inFiles else { return .ignored }
            stepFilter(facet, by: back ? -1 : 1)
            return .handled
        case .toggleHidden:
            guard inFiles else { return .ignored }
            fileFilters.hidden.toggle()
            return .handled
        case .number(let n):
            guard actions == nil, rows.indices.contains(n - 1) else { return .handled }
            return click(at: n - 1)
        case .space:
            // Quick Look in the Files view (Sven, 2026-10-07); a switch flips (S1); anywhere else the space is typed.
            if fileQuery != nil, let row = selected, row.kind == .file { return .preview(row) }
            guard spaceToggles, let row = selected, case .action(let id) = row.target else { return .ignored }
            switches([id: row.isOn != true])
            return .toggle(row)
        }
    }

    /// Space flips the selected row (S1, Sven 2026-10-09): only a switch, and only while nothing is typed, so a space
    /// Sven types is never taken from the search; a picker's rows are picked, never flipped.
    public var spaceToggles: Bool { query.isEmpty && !isList && selected?.isOn != nil }

    /// Switch states by action id, shown at once on their rows, which keep their places: Space's flip, then the states
    /// read again (Keep awake also moves Lock when idle).
    public mutating func switches(_ states: [String: Bool]) {
        func set(_ row: inout MenuEntry) {
            if row.isOn != nil, case .action(let id) = row.target, let on = states[id] { row.isOn = on }
        }
        for i in entries.indices { set(&entries[i]) }
        for i in rows.indices { set(&rows[i]) }
    }

    /// A click on a kind tab (card agent-bo-95422994): that kind, as Tab reaching it shows it.
    public mutating func show(_ kind: MenuEntry.Kind?) {
        guard kind != only else { return }
        only = kind
        refresh()
    }

    /// The pointer over a row selects it; ignored while Cmd+K's actions show, which sit over the list.
    public mutating func point(at index: Int) {
        guard actions == nil, rows.indices.contains(index) else { return }
        selection = index
    }

    /// A click on a row is Return on it.
    public mutating func click(at index: Int) -> Outcome {
        guard actions == nil, rows.indices.contains(index) else { return .handled }
        selection = index
        return handle(.return)
    }

    /// The pointer over one of Cmd+K's actions selects it; a click runs it, as Return does.
    public mutating func pointAction(at index: Int) { actions?.select(index) }

    public mutating func clickAction(at index: Int) -> Outcome {
        guard actions?.visible.indices.contains(index) == true else { return .handled }
        pointAction(at: index)
        return handle(.return)
    }

    /// Where a root search's Ask AI and Search the web go (Sven Q174): after the rows under the Best match heading (the
    /// best match, and any answers heading with it), at the next heading, so no heading repeats after them.
    public static func bestMatchEnd(_ rows: [MenuEntry]) -> Int {
        let headings = MenuGroups.headings(rows, searching: true)
        return rows.indices.dropFirst().first { headings[$0] != nil } ?? rows.count
    }

    /// The two rows a root search always offers for what was typed (Sven 2026-10-16): Ask AI, whose Return opens the AI
    /// chat with it (none when `rows` already ask, as `ask …` does), and Search the web, in the default browser with its
    /// engine, named by `via` once read. Both are offers (MenuEntry.isOffer): no kind counts them.
    public static func fallbacks(_ query: String, after rows: [MenuEntry], via: String?) -> [MenuEntry] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        let asks = rows.contains { if case .ask = $0.target { true } else { false } }
        let ask = MenuEntry(title: "Ask AI", target: .ask(typed), detail: "Return asks your AI", subtitle: "“\(typed)”")
        let web = MenuEntry(title: "Search the web", target: .searchWeb(typed), detail: via.map { "Return searches \($0)" } ?? "Return searches the web",
                            subtitle: "“\(typed)”")
        return (asks ? [] : [ask]) + [web]
    }

    /// Whether a search that found nothing reads as an app's name ("raycast", "visual studio code") rather than a file's
    /// ("report.pdf", "~/notes"), so Search to install leads Search files.
    public static func looksLikeApp(_ query: String) -> Bool {
        InstallSearch.Query(query)?.brewName != nil && !query.contains { ".~/".contains($0) }
    }

    /// The next (1) or previous (-1) kind tab of a root search, wrapping.
    private mutating func stepKind(_ step: Int) {
        let kinds = MenuEntry.Kind.tabOrder
        show(kinds[((kinds.firstIndex(of: only) ?? 0) + step + kinds.count) % kinds.count])
    }

    /// Return on a row: a branch opens, Search files opens the Files view, a row that fills the search types its words
    /// there, the rest run.
    private mutating func pick(_ row: MenuEntry) -> Outcome {
        if let fills = row.fills {
            query = fills
            return .handled
        }
        switch row.target {
        case .branch(let b): open(b)
        case .searchFiles: only = .file; refresh()
        case .searchInstall(let text):
            let from = Spot(branch: nil, query: query, row: row.target)
            open(.homebrew)
            query = text
            installFrom = from
        default: return .run(row)
        }
        return .handled
    }

    /// Keys while the Cmd+K actions show: arrows move, Return runs one, Escape or Cmd+K closes them, ← and → move the
    /// filter's caret.
    private mutating func handleActions(_ key: Key, _ menu: RowActionsMenu) -> Outcome {
        var menu = menu
        switch key {
        case .up, .down:
            menu.move(key == .up ? -1 : 1)
            actions = menu
            return .handled
        case .escape, .commandK:
            actions = nil
            return .handled
        case .left, .right:
            return .ignored
        case .tab, .backTab, .commandReturn, .filter, .toggleHidden, .number:
            return .handled
        case .space:
            return .ignored
        case .return:
            actions = nil
            switch menu.selected {
            case .row(let action)?: return act(action, on: menu.row)
            case .own(let index, _)?: return .own(index, menu.row)
            case nil: return .handled
            }
        }
    }

    /// A Cmd+K action: opening is Return on the row, Uninstall searches Remove for the app (its confirm asks first), a
    /// favourite or a ranking reset reranks here; the panel carries out the rest and stores what changed.
    private mutating func act(_ action: RowAction, on row: MenuEntry) -> Outcome {
        switch action {
        case .open, .run, .focus, .install:
            return pick(row)
        case .uninstall:
            // An extension's row: the panel asks first, as the catalogue does; an app's is found in Remove.
            guard row.extensionID == nil else { return .act(action, row) }
            open(.remove)
            query = row.title
            return .handled
        case .changeLanguages:
            let text = Translate.text(after: query) ?? ""
            open(.translate)
            query = text
            return .handled
        case .searchInside:
            guard case .file(let path) = row.target else { return .handled }
            fileFilters.place = .folder(path)
            only = .file
            query = ""
            return .handled
        case .favourite, .unfavourite, .resetRanking:
            guard let key = row.frecencyKey else { return .handled }
            switch action {
            case .resetRanking: frecency.forget(key)
            case .favourite: favourites.insert(key)
            default: favourites.remove(key)
            }
            rerank(keeping: selected?.id)
        default: break
        }
        return .act(action, row)
    }

    private mutating func open(_ b: MenuBranch) {
        if branch == nil { rooted = query.isEmpty && b.parent != nil ? b : nil }
        branch = b
        only = nil
        clearQuery()
    }

    /// An empty search, listed again for a new place even when it was already empty.
    private mutating func clearQuery() {
        if query.isEmpty { refresh() } else { query = "" }
    }

    /// Up one level, with the branch just left selected.
    private mutating func up() {
        installFrom = nil
        let left = branch
        branch = left.flatMap(parent)
        if branch == nil { rooted = nil }
        clearQuery()
        select(left.map(MenuEntry.Target.branch))
    }
}

/// What the menu lists (wireframe sections 2 to 4): every installed app with its bind, its own or the role it fills
/// (Hyper+Return on the terminal); the rows MenuLayout places in Learn, Trigger and System; then every action the Binds
/// screen lists but `menu`, the one that opens it, and the app opens the app rows already are.
public enum MenuEntries {
    /// `roleApps`: a role's action id → the bundle id it resolves to. `openID`: an app's own action id. `running`: the
    /// bundle ids of the apps running as the menu opens. `extras`: rows read as the menu opens, after a branch's layout
    /// rows (the sound outputs in System). `switches`: each switch's state by action id, as the menu opens. `branches`:
    /// sub-branch rows read as the menu opens, before a branch's extras (an extension's in Extensions, story 158).
    public static func build(apps: [(name: String, bundle: String)], actions: [BindsPage.ActionInfo], store: BindStore,
                             roleApps: [String: String], menu: String, openID: (String) -> String,
                             running: Set<String>, extras: [MenuBranch: [BindsPage.ActionInfo]] = [:], branches: [MenuBranch: [MenuEntry]] = [:],
                             switches: [String: Bool] = [:], fills: [String: String] = [:]) -> [MenuEntry] {
        let roleKeys = roleKeys(store: store, roleApps: roleApps)
        // An action titled "App: verb" belongs to that app (card agent-bo-95422981).
        let bundles = Dictionary(apps.map { ($0.name, $0.bundle) }, uniquingKeysWith: { first, _ in first })
        let keywords = Dictionary(actions.compactMap { a in a.keywords.map { (a.id, $0) } }, uniquingKeysWith: { first, _ in first })
        func action(_ title: String, _ id: String, home: MenuBranch?, detail: String? = nil, inSearch: Bool = true,
                    icon: MenuIcon? = nil) -> MenuEntry {
            let owner = title.firstRange(of: ": ").map { String(title[..<$0.lowerBound]) }.flatMap { bundles[$0] == nil ? nil : $0 }
            return MenuEntry(title: title, target: .action(id), home: home, detail: detail, detailIsKey: true, inSearch: inSearch,
                             keywords: keywords[id], app: owner.flatMap { bundles[$0] }, subtitle: owner, isOn: switches[id], icon: icon,
                             fills: fills[id])
        }
        let appRows = apps.map { app in
            MenuEntry(title: app.name, target: .app(app.bundle), home: .apps,
                      detail: appKey(app.bundle, store: store, roleKeys: roleKeys, openID: openID)?.label, detailIsKey: true,
                      running: running.contains(app.bundle))
        }
        let labels = Dictionary(actions.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        // A branch filled only by extras (Config) has no layout rows.
        let laidOut = Set(MenuLayout.rows.keys).union(extras.keys).union(branches.keys).flatMap { home in
            (MenuLayout.rows[home] ?? []).compactMap { row -> MenuEntry? in
                switch row {
                case .branch(let b, let opener):
                    return MenuEntry(title: b.title, target: .branch(b), home: home, detail: opener.flatMap { store.trigger(for: $0) }?.label,
                                     detailIsKey: true)
                case .action(let id):
                    guard let title = labels[id] else { return nil }
                    // A row its branch's parent lists too (QR's, in Trigger) is found by search as the parent's.
                    let twice = home.parent.flatMap { MenuLayout.rows[$0] }?.contains(.action(id)) == true
                    return action(title, id, home: home, detail: store.trigger(for: id)?.label, inSearch: !twice)
                }
            } + (branches[home] ?? []) + (extras[home] ?? []).map { action($0.label, $0.id, home: home, detail: store.trigger(for: $0.id)?.label, icon: $0.icon) }
        }
        // A sub-branch nothing landed in (System's, C6) would be a dead row too.
        let filled = Set(laidOut.compactMap(\.home))
        let layoutRows = laidOut.filter { if case .branch(let b) = $0.target, case .category = b { filled.contains(b) } else { true } }
        // An action a branch row shows, and the one that opens a branch, are found by search as that row.
        let openers = MenuLayout.rows.values.joined().compactMap { if case .branch(_, let opener?) = $0 { opener } else { nil } }
        let placed = Set(layoutRows.compactMap { if case .action(let id) = $0.target { id } else { nil } } + openers
                         + MenuLayout.topOpeners)
        let opens = Set(apps.map { openID($0.bundle) })
        // Keybindings lists every bind, the cheat sheet (story 27); an unbound action is found by search. A bind search
        // already finds elsewhere (the menu's own, an app's open, a branch's row) keeps its Keybindings copy out of search.
        // The essentials come first (KeybindingsOrder).
        let actionRows = KeybindingsOrder.sorted(actions).compactMap { info -> MenuEntry? in
            let key = store.trigger(for: info.id), elsewhere = info.id == menu || opens.contains(info.id) || placed.contains(info.id)
            if elsewhere && key == nil { return nil }
            return action(info.label, info.id, home: key == nil ? nil : .keybindings, detail: key?.label, inSearch: !elsewhere, icon: info.icon)
        }
        return appRows + layoutRows + actionRows
    }
}

extension MenuEntries {
    /// Each role's key by the bundle id it resolves to (Hyper+Return on the terminal app).
    public static func roleKeys(store: BindStore, roleApps: [String: String]) -> [String: Key] {
        var keys: [String: Key] = [:]
        for (action, bundle) in roleApps { if let key = store.trigger(for: action) { keys[bundle] = key } }
        return keys
    }

    /// An app's key as the menu shows it: its own open bind, else the bind of the role it fills.
    /// `roleKeys` is read only when the app has no bind of its own: resolving the roles asks Launch Services.
    public static func appKey(_ bundle: String, store: BindStore, roleKeys: @autoclosure () -> [String: Key],
                              openID: (String) -> String) -> Key? {
        store.trigger(for: openID(bundle)) ?? roleKeys()[bundle]
    }
}

/// Which actions Learn, Trigger and System's sub-branches list, in order (stories 22, 25, 78 to 80; wireframe wo-nZ-ZEKkY
/// sections 3 and 4). A row whose action is not registered is left out.
public enum MenuLayout {
    /// A branch row names the action that opens it, whose bind the row shows.
    public enum Row: Equatable, Sendable { case branch(MenuBranch, opener: String? = nil), action(String) }

    /// The actions that open a branch under the root (Omarchy's apps menu, the System menu).
    public static let topOpeners = ["apps.appsMenu", "system.menu"]

    public static let rows: [MenuBranch: [Row]] = [
        // Make a web app opens Install › Web apps, the one place a web app is made (card agent-bo-95422994).
        .install: [.branch(.homebrew), .action("apps.webApp")],
        .learn: [.branch(.keybindings, opener: "engine.sheet")],
        .trigger: [.branch(.capture, opener: "captures.menu"), .branch(.emoji, opener: "apps.emoji"), .action("captures.pickColour"), .action("captures.makeQR"),
                   .action("captures.readQR"), .action("system.ejectAll"), .action("apps.clipboard"),
                   .branch(.stickers), .branch(.translate), .branch(.define), .branch(.reminders), .branch(.snippets), .branch(.notes),
                   .branch(.qr), .action("ai.ask"), .action("ai.chat"), .action("ai.fix"), .action("ai.selection"),
                   .action("speech.readAloud")],
        .capture: ["captures.area", "captures.activeWindow", "captures.fullscreen", "captures.scrolling", "captures.screenRecording",
                   "captures.ocr", "captures.readQRScreen", "captures.smartElement", "captures.subject", "captures.markup",
                   "captures.scrollingUp", "captures.repeatArea", "captures.delayed", "captures.editLast", "captures.editVideo", "captures.pinLast", "captures.restoreThumbnail", "captures.toggleDesktopIcons"].map { .action($0) },
        .qr: [.action("captures.makeQR"), .action("captures.readQR")],
        .system: systemSections.map { .branch(system($0.title)) },
    ].merging(systemSections.map { (system($0.title), $0.ids.map(Row.action)) }) { layout, _ in layout }

    /// System's sub-branches, in order (C6, Sven 2026-10-09: the flat list of round 11's sections had grown long), each
    /// opened with → or Return like any branch; a search in System still finds the rows of all of them, under their
    /// names. The rows read as the menu opens join Sound (each output) as its extras (Focus's, story 145, are
    /// parked on parked/pilot-focus); `symbol` is the sub-branch row's glyph.
    public struct Section: Sendable {
        public let title: String, symbol: String, ids: [String]
    }

    public static let systemSections = [
        Section(title: "Power", symbol: "power", ids: ["system.lock", "system.sleep", "system.restart", "system.shutDown", "system.logOut",
                                                       "system.keepAwake", "system.idleLock"]),
        Section(title: "Sound", symbol: "speaker.wave.2", ids: ["system.soundSettings"]),
        Section(title: "Connections", symbol: "wifi", ids: ["system.wifi", "system.wifiSettings", "system.bluetoothSettings", "system.speedTest"]),
        Section(title: "Display", symbol: "display", ids: ["system.darkMode", "system.nightShift", "system.displaySettings", "system.rotateDisplay", "system.nextWallpaper",
                                                           "system.previousWallpaper", "system.nextWallpaperAll", "system.previousWallpaperAll"]),
        Section(title: "Focus", symbol: "moon.stars", ids: ["system.focusSettings"]),
        Section(title: "Fix it", symbol: "wrench.and.screwdriver", ids: ["workspaces.rescue", "system.killProcess"]),
    ]

    /// An extension's sub-branch in Extensions, by its title (story 158).
    public static func extensionBranch(_ title: String) -> MenuBranch { .category(title, in: .extensions) }

    /// The last row of Extensions: the catalogue (story 158).
    public static let browseCatalogue = "Browse catalogue"

    /// System's sub-branch called `title`: a category System browses, as Install's are.
    public static func system(_ title: String) -> MenuBranch { .category(title, in: .system) }

    /// Install's search sources (N9), in the order the search groups them: each a category of Search packages, which
    /// Install's own search lists too.
    public static let installSections = InstallSearch.Source.allCases.map { Section(title: $0.title, symbol: $0.symbol, ids: []) }

    /// The home of a search result from `source`.
    public static func installSection(_ source: InstallSearch.Source) -> MenuBranch { .category(source.title, in: .homebrew) }

    /// A branch whose search also lists another's categories, with their sections: Install lists Search packages'
    /// sources after its catalogue (N9).
    public static let alsoBrowses: [MenuBranch: MenuBranch] = [.install: .homebrew]

    /// The sections a branch's search is split into; empty for a branch with none.
    public static func sections(_ branch: MenuBranch) -> [Section] {
        switch branch {
        case .system: systemSections
        case .homebrew: installSections
        default: alsoBrowses[branch].map(sections) ?? []
        }
    }

    /// Whether the branch's search runs Install's search: Search packages, and Install, which also browses it (N9).
    public static func searchesInstall(_ branch: MenuBranch?) -> Bool { branch.map { (alsoBrowses[$0] ?? $0) == .homebrew } ?? false }

    /// Whether a search keeps the sections in their own order rather than each where its best row stood: Install's
    /// sources always list Homebrew first and the web last (N9).
    public static func keepsOrder(_ branch: MenuBranch) -> Bool { searchesInstall(branch) }

    /// The index of the section a row of `branch` sits in: in System, the sub-branch that lists it; nil for a sub-branch's
    /// own row and in a branch with no sections.
    static func section(of row: MenuEntry, in branch: MenuBranch) -> Int? { row.home.flatMap { section($0, in: branch) } }

    /// The index of `sub`, one of `branch`'s sub-branches (or of the branch it also browses), among its sections; nil
    /// for any other branch.
    public static func section(_ sub: MenuBranch, in branch: MenuBranch) -> Int? {
        let owner = alsoBrowses[branch] ?? branch
        guard case .category(let title, owner) = sub else { return nil }
        return sections(branch).firstIndex { $0.title == title }
    }
}

extension MenuEntries {
    /// The tiler's windows grouped by workspace, in the workspaces' display order (OccupiedWorkspace.ordered), each
    /// workspace's in the tiler's order (the sort is stable): Windows at the empty root lists them so.
    public static func byWorkspace(_ windows: [AeroWindow]) -> [AeroWindow] {
        windows.sorted { OccupiedWorkspace.ordered($0.workspace, $1.workspace) }
    }

    /// Every window on every workspace (story 76, wireframe section 7): "App — title", tagged with its workspace.
    /// `excluding` is Pilot's own bundle id, so the menu never lists itself.
    public static func windows(_ windows: [AeroWindow], excluding: String?) -> [MenuEntry] {
        windows.filter { $0.bundleId != excluding }.map { w in
            MenuEntry(title: w.title.isEmpty ? w.appName : "\(w.appName) — \(w.title)", target: .window(w.id),
                      detail: "workspace \(w.workspace)", app: w.bundleId)
        }
    }

    /// The Files view's answer while Pilot lacks Full Disk Access, in place of a silent "Nothing matches." (card
    /// agent-bo-95423031); its keywords are the search, so it stays listed whatever was typed.
    public static func allowFullDiskAccess(search: String) -> MenuEntry {
        MenuEntry(title: "Allow Full Disk Access to search files", target: .allowFullDiskAccess, keywords: search,
                  subtitle: "macOS keeps your files from Pilot until you allow it", icon: .glyph("lock.shield", .amber))
    }

    /// The file index's files (story 77, wireframe section 6): the name, its folder from home and where it came from
    /// beside it ("~/Downloads · from github.com"), and the day it was edited on the right.
    public static func files(_ hits: [FileSearch.Hit], home: String) -> [MenuEntry] {
        hits.map { hit in
            let url = URL(fileURLWithPath: hit.path), folder = AppConfigs.tilde(url.deletingLastPathComponent().path, home: home)
            return MenuEntry(title: url.lastPathComponent, target: .file(hit.path), detail: hit.edited?.formatted(.dateTime.day().month(.abbreviated)),
                             subtitle: hit.from.map { "\(folder) · from \($0)" } ?? folder)
        }
    }

    /// The Files view's rows (Homy-style Files): the name hits, then at most `FileSearch.textHits` images found by the
    /// words in them that the filters admit, in the index's order. A file in both is listed once, as its name hit; a row
    /// with words says them first, about 60 characters: "“invoice 4471” · ~/Downloads".
    public static func files(_ hits: [FileSearch.Hit], text: [(path: String, modified: Date, words: String)], ask: FileSearch.Ask,
                             home: String, now: Date = Date()) -> [MenuEntry] {
        let words = Dictionary(text.map { ($0.path, $0.words) }, uniquingKeysWith: { first, _ in first })
        let named = Set(hits.map(\.path))
        let byWords = text.filter { !named.contains($0.path) && ask.admits($0.path, modified: $0.modified, home: home, now: now) }
            .prefix(FileSearch.textHits).map { FileSearch.Hit(path: $0.path, edited: $0.modified) }
        return files(hits + byWords, home: home).map { row in
            guard let path = row.target.filePath, let found = words[path] else { return row }
            let shown = found.count > 60 ? found.prefix(59) + "…" : found
            var row = row
            row.matchedWords = shown
            row.subtitle = "“\(shown)” · " + (row.subtitle ?? "")
            return row
        }
    }

    /// Files whose source is unknown.
    public static func files(_ files: [(path: String, edited: Date?)], home: String) -> [MenuEntry] {
        self.files(files.map { FileSearch.Hit(path: $0.path, edited: $0.edited) }, home: home)
    }
}

/// The menu's file search (story 77; SPEC.md, Menu): Pilot's file index (pilot-files, built on Cardinal's engine,
/// card agent-bo-95422765) asked over its pipe from the second typed character, its best 20 files back. The index is Pilot's
/// own, so Spotlight's switch does not matter.
public enum FileSearch {
    /// The most images the Files view lists by the words in them, under the name hits (Homy-style Files).
    public static let textHits = 10

    /// The line sent to the index: the search trimmed and on one line, since a line is one search; nil under two
    /// characters.
    public static func query(for search: String) -> String? {
        let q = search.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return q.count >= MenuNavigator.minimumQuery ? q : nil
    }

    /// A file the index found: its path, when it was edited, and where it came from (the site a browser saved it from,
    /// else the app that saved it; pilot-files, source.rs).
    public struct Hit: Equatable, Sendable, Decodable {
        public var path: String
        public var edited: Date?
        public var from: String?

        public init(path: String, edited: Date? = nil, from: String? = nil) {
            self.path = path
            self.edited = edited
            self.from = from
        }

        enum CodingKeys: String, CodingKey { case path, edited = "modified", from }
    }

    /// One answer line from the index: the request it answers (its id, its search) and its files, best first. Nil for
    /// the ready line or anything that is not an answer; a search the index's syntax rejects answers with no files.
    public static func answer(_ line: String) -> (id: Int?, query: String, files: [Hit])? {
        struct Answer: Decodable {
            var id: Int?
            var query: String
            var files: [Hit]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let answer = try? decoder.decode(Answer.self, from: Data(line.utf8)) else { return nil }
        return (answer.id, answer.query, answer.files)
    }

    /// The search without its `from:` words, and the last one's value: `from:whatsapp` keeps only files saved from
    /// WhatsApp, or from a site holding the word. An empty `from:` stays a word.
    public static func typedFrom(_ search: String) -> (text: String, from: String?) {
        var from: String?
        let kept = search.split(separator: " ", omittingEmptySubsequences: false).filter { word in
            guard word.lowercased().hasPrefix("from:"), word.count > 5 else { return true }
            from = String(word.dropFirst(5))
            return false
        }
        return (kept.joined(separator: " "), from)
    }

    /// What the Files view asks the index (N5): the words and the filters, stepped and typed, and `from:`.
    public struct Ask: Equatable, Sendable {
        public var text: String
        public var filters: FileFilters
        /// Only files whose source holds this (`from:whatsapp`).
        public var from: String?

        public init(text: String, filters: FileFilters = FileFilters(), from: String? = nil) {
            self.text = text
            self.filters = filters
            self.from = from
        }

        /// The helper's request line (pilot-files, filter.rs): `id` comes back on its answer, so an answer to an older
        /// filter is never taken for this one.
        public func request(id: Int, home: String) -> String {
            struct Request: Encodable {
                var id: Int, query: String, kind: String?, ext: String?, folder: String?, when: String?, hidden: Bool, from: String?
            }
            var ext: String?
            if case .ext(let e)? = filters.kind { ext = e }
            let request = Request(id: id, query: text, kind: filters.kind?.wire, ext: ext, folder: filters.place?.path(home: home),
                                  when: filters.when?.rawValue, hidden: filters.hidden, from: from)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? text
        }
    }
}

extension FileSearch.Ask {
    /// Whether an image the text index found passes the filters the file index applies to its name hits: an image
    /// kind or its extension, the place, and the time as Cardinal reads it (since the start of today, of the week from
    /// Monday, of the month). The text index knows no source, so with `from:` none passes.
    public func admits(_ path: String, modified: Date, home: String, now: Date, calendar: Calendar = .current) -> Bool {
        guard from == nil else { return false }
        switch filters.kind {
        case nil, .images?: break
        case .ext(let ext)?: guard (path as NSString).pathExtension.lowercased() == ext.lowercased() else { return false }
        default: return false
        }
        if let place = filters.place, !path.hasPrefix(place.path(home: home) + "/") { return false }
        guard let when = filters.when else { return true }
        var calendar = calendar
        calendar.firstWeekday = 2
        let unit: Calendar.Component = switch when { case .today: .day; case .week: .weekOfYear; case .month: .month }
        return calendar.dateInterval(of: unit, for: now).map { modified >= $0.start } ?? true
    }
}
