import AppKit

/// The panel's kind filter, stepped with Tab and Shift+Tab (card agent-bo-95422781; ClipBook filters its history by
/// text, image, link, file, colour and email, and by favourites). Snippets lists the saved snippets, not copies (Sven,
/// 2026-10-08).
public enum ClipFilter: String, CaseIterable, Sendable {
    case all, text, image, file, link, colour, email, pinned, snippet

    public var label: String { self == .snippet ? "Snippets" : rawValue.capitalized }

    /// The kinds a row must be to pass; nil passes every kind.
    var kinds: Set<ClipKind>? {
        switch self {
        case .all, .pinned: nil
        case .snippet: []
        case .text: [.text, .richText]
        case .image: [.image]
        case .file: [.file]
        case .link: [.link]
        case .colour: [.colour]
        case .email: [.email]
        }
    }
}

/// One of the panel's tabs (card agent-bo-95422970): a kind, or one tag. Left, Right, Tab and Shift+Tab step through
/// the kinds, then every tag.
public enum PanelTab: Hashable, Sendable {
    case kind(ClipFilter), tag(ClipTag)

    public var label: String {
        switch self {
        case .kind(let kind): kind.label
        case .tag(let tag): "#" + tag.name
        }
    }

    public static func all(tags: [ClipTag]) -> [PanelTab] { ClipFilter.allCases.map(kind) + tags.map(tag) }

    /// The tab `step` places on, wrapping both ways; a tab that is gone (its tag deleted) counts as All.
    public func step(_ step: Int, in tabs: [PanelTab]) -> PanelTab {
        guard !tabs.isEmpty else { return self }
        return tabs[wrapping: (tabs.firstIndex(of: self) ?? 0) + step]
    }
}

/// What the panel sorts by (card agent-bo-95422783; ClipBook's sort options), stepped with Cmd+S.
public enum ClipSort: String, CaseIterable, Sendable {
    case lastCopy, firstCopy, copies, size

    public var title: String {
        switch self {
        case .lastCopy: "Last copy"
        case .firstCopy: "First copy"
        case .copies: "Times copied"
        case .size: "Size"
        }
    }

    public var next: ClipSort { stepped(1) }

    var column: String {
        switch self {
        case .lastCopy: "copied_at"
        case .firstCopy: "first_copied_at"
        case .copies: "copy_count"
        case .size: "size"
        }
    }
}

/// A sort and its direction: newest, most or largest first unless reversed (Cmd+Shift+S).
public struct ClipOrder: Equatable, Sendable {
    public var sort: ClipSort
    public var reversed: Bool

    public init(sort: ClipSort = .lastCopy, reversed: Bool = false) {
        self.sort = sort; self.reversed = reversed
    }

    var sql: String {
        let direction = reversed ? "ASC" : "DESC"
        return "\(sort.column) \(direction), id \(direction)"
    }
}

/// What the panel's search means. Words match the text (a file copy's text is its paths, an image's the text read from it) in any order, ignoring
/// case; `type:<kind>` (all, text, image, file, link, colour or color, email, pinned), `app:<part of the app's name or bundle id>`,
/// `#<tag>` and `is:pinned` filter, `type:snippet` lists the snippets instead. An unknown token is searched as a word.
/// Plain words that describe a copy are hints (P64): "link from monday", "hex from figma". A copy passes a hint when it
/// fits it or holds its words as text, as before, and copies that fit more hints list first.
public struct ClipQuery: Equatable, Sendable {
    /// The words searched as text, which the preview lights: a hint's words too, which a copy that does not fit it
    /// must hold.
    public private(set) var words: [String] = []
    /// The words every copy must hold as text: `words` without the hints'.
    private var textWords: [String] = []
    private(set) var hints: [Hint] = []
    /// The Snippets tab, or type:snippet typed: the panel lists the saved snippets, which `matches` searches.
    public private(set) var snippets = false
    var kinds: Set<ClipKind>?
    /// Words typed where images are listed: an image whose text is not read yet cannot match them.
    public var searchesImageText: Bool { !snippets && !words.isEmpty && kinds?.contains(.image) != false }
    var app: String?
    var pinnedOnly = false
    /// `#name`: rows with that tag, any case, or with the text #name when no tag has it (card agent-bo-95422782).
    var tagNames: [String] = []

    var order: ClipOrder

    public init(_ typed: String, filter: ClipFilter = .all, order: ClipOrder = ClipOrder(), now: Date = Date()) {
        self.order = order
        narrow(by: filter)
        for word in typed.split(whereSeparator: \.isWhitespace).map(String.init) {
            let lowered = word.lowercased()
            if let name = lowered.dropping(prefix: "type:"), let filter = ClipFilter(rawValue: name == "color" ? "colour" : name) {
                // A tab's name typed does what the tab does: type:pinned as Pinned, type:all nothing (card agent-bo-95422994).
                narrow(by: filter)
            } else if let part = word.dropping(prefix: "app:"), !part.isEmpty {
                app = part
            } else if let tag = word.dropping(prefix: "#"), !tag.isEmpty {
                tagNames.append(tag)
            } else if lowered == "is:pinned" {
                pinnedOnly = true
            } else {
                words.append(word)
            }
        }
        (hints, textWords) = Self.read(words, now: now)
    }

    /// A kind tab, or its name after type:, narrows to its kinds; Pinned to the pins; All not at all.
    private mutating func narrow(by filter: ClipFilter) {
        if filter == .pinned { pinnedOnly = true }
        if filter == .snippet { snippets = true }
        if let kinds = filter.kinds { self.kinds = (self.kinds ?? kinds).intersection(kinds) }
    }

    /// The search inside one tab: a kind's, or a tag's copies.
    public init(_ typed: String, tab: PanelTab, order: ClipOrder = ClipOrder()) {
        switch tab {
        case .kind(let kind): self.init(typed, filter: kind, order: order)
        case .tag(let tag): self.init(typed, order: order); tagNames.append(tag.name)
        }
    }

    /// The SQL condition and its values; kinds and the app are checked afterwards (`admits`), since link and email
    /// are read from the text and an app's name is not in the store.
    var condition: (sql: String, values: [String]) {
        // A word matches the text, the name the copy was given (card agent-bo-95422784) or an image's text (card
        // agent-bo-95423070), searched as one string split by new lines, which no typed word holds.
        var parts = textWords.map { _ in
            "instr(lower(text || char(10) || coalesce(title, '') || char(10) || coalesce(recognised, '')), lower(?)) > 0"
        }
        var values = textWords
        if pinnedOnly { parts.append("pinned = 1") }
        // #name is a tag when one has that name, else the text it is, so a copied #7aa2f7 is still found.
        for tag in tagNames {
            parts.append("""
                (id IN (SELECT clip_id FROM clip_tags JOIN tags ON tags.id = tag_id WHERE tags.name = ?)
                 OR (NOT EXISTS (SELECT 1 FROM tags WHERE name = ?) AND instr(lower(text), lower(?)) > 0))
                """)
            values += [tag, tag, "#" + tag]
        }
        return (parts.isEmpty ? "1" : parts.joined(separator: " AND "), values)
    }

    /// Kinds, then the app: part of its bundle id or of its name, as `appName` gives it for a bundle id.
    func admits(_ clip: StoredClip, appName: (String) -> String?) -> Bool {
        guard kinds?.contains(clip.kind) ?? true else { return false }
        guard let app else { return true }
        return Self.copied(clip, from: app, appName: appName)
    }

    private static func copied(_ clip: StoredClip, from app: String, appName: (String) -> String?) -> Bool {
        guard let id = clip.sourceApp else { return false }
        return id.localizedCaseInsensitiveContains(app) || appName(id)?.localizedCaseInsensitiveContains(app) == true
    }

    /// The copies the store found that `admits` passes and that pass every hint, those fitting more hints first, each
    /// group in the store's order.
    func ranked(_ clips: [StoredClip], appName: (String) -> String?) -> [StoredClip] {
        guard !hints.isEmpty else { return clips.filter { admits($0, appName: appName) } }
        // One list per number of hints missed, each in the store's order.
        var byMisses = Array(repeating: [StoredClip](), count: hints.count + 1)
        rows: for clip in clips where admits(clip, appName: appName) {
            var misses = 0, searched: String?
            for hint in hints where !hint.fits(clip, appName: appName) {
                // As `condition` searches: the text, the name and an image's text; lowered once, only on a miss.
                searched = searched ?? [clip.text, clip.customTitle ?? "", clip.recognised ?? ""].joined(separator: "\n").lowercased()
                guard hint.words.allSatisfy(searched!.contains) else { continue rows }
                misses += 1
            }
            byMisses[misses].append(clip)
        }
        return byMisses.flatMap { $0 }
    }

    /// A kind, a day or an app read from plain words, and the words it was read from.
    struct Hint: Equatable, Sendable {
        enum Fit: Equatable, Sendable { case kind(ClipKind), day(DateInterval), app(String) }
        var fit: Fit
        /// Lowered, as a copy's text is when it is checked.
        var words: [String]

        func fits(_ clip: StoredClip, appName: (String) -> String?) -> Bool {
            switch fit {
            case .kind(let kind): clip.kind == kind
            case .day(let day): day.start <= clip.copiedAt && clip.copiedAt < day.end
            case .app(let app): ClipQuery.copied(clip, from: app, appName: appName)
            }
        }
    }

    private static let kindWords: [String: ClipKind] = {
        let names: [ClipKind: [String]] = [.link: ["link", "links", "url", "urls"], .colour: ["hex", "colour", "colours", "color", "colors"],
                                           .image: ["image", "images"],
                                           .file: ["file", "files"], .email: ["email", "emails"]]
        return Dictionary(uniqueKeysWithValues: names.flatMap { kind, words in words.map { ($0, kind) } })
    }()

    // Made once: the panel reads the query again on every keystroke. Dates are read on the Mac, no network.
    nonisolated(unsafe) private static let dates = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// The hints in the plain words, and the words left to match as text. A day is the first date phrase with a letter
    /// in it ("monday", "from yesterday"; a searched "10:30" stays text), the whole calendar day, a day still ahead
    /// stepped back a week at a time, as a clipboard holds only the past. Then "from <word>" is an app, and a kind word
    /// ("link", "hex") a kind.
    static func read(_ words: [String], now: Date, calendar: Calendar = .current) -> (hints: [Hint], text: [String]) {
        guard !words.isEmpty else { return ([], []) }
        var hints: [Hint] = [], used = Set<Int>()
        let phrase = words.joined(separator: " ") as NSString
        if let match = dates?.firstMatch(in: phrase as String, range: NSRange(location: 0, length: phrase.length)), let date = match.date,
           phrase.substring(with: match.range).contains(where: \.isLetter) {
            var start = 0, inside: [Int] = []
            for (index, word) in words.enumerated() {
                let range = NSRange(location: start, length: (word as NSString).length)
                if NSIntersectionRange(range, match.range).length > 0 { inside.append(index) }
                start += range.length + 1
            }
            var day = calendar.startOfDay(for: date)
            while day > now, let earlier = calendar.date(byAdding: .day, value: -7, to: day) { day = earlier }
            if let interval = calendar.dateInterval(of: .day, for: day) {
                hints.append(Hint(fit: .day(interval), words: inside.map { words[$0].lowercased() }))
                used.formUnion(inside)
            }
        }
        for (index, word) in words.enumerated() where !used.contains(index) {
            let lowered = word.lowercased()
            if lowered == "from", words.indices.contains(index + 1), !used.contains(index + 1) {
                hints.append(Hint(fit: .app(words[index + 1]), words: [lowered, words[index + 1].lowercased()]))
                used.formUnion([index, index + 1])
            } else if let kind = kindWords[lowered] {
                hints.append(Hint(fit: .kind(kind), words: [lowered]))
                used.insert(index)
            }
        }
        return (hints, words.indices.filter { !used.contains($0) }.map { words[$0] })
    }

    /// The name an installed app shows in Finder, from its bundle id; nil when it is not installed.
    public static func installedAppName(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
    }

    /// A snippet's name, keyword and text hold every word, a #word as typed, ignoring case.
    public func matches(_ fields: [String]) -> Bool {
        let all = fields.joined(separator: "\n")
        return (words + tagNames.map { "#" + $0 }).allSatisfy { all.localizedCaseInsensitiveContains($0) }
    }

    /// Where each word matches in `text`, ignoring case, for the row's and the preview's highlight.
    public func highlights(in text: String) -> [Range<String.Index>] {
        words.flatMap { word in
            var ranges: [Range<String.Index>] = []
            var start = text.startIndex
            while let range = text.range(of: word, options: .caseInsensitive, range: start..<text.endIndex) {
                ranges.append(range)
                start = range.upperBound
            }
            return ranges
        }
    }
}

extension CaseIterable where Self: Equatable {
    /// The case `step` places on, wrapping both ways: Tab and Shift+Tab, Cmd+S.
    func stepped(_ step: Int) -> Self {
        let all = Array(Self.allCases)
        return all[wrapping: all.firstIndex(of: self)! + step]
    }
}

extension Array {
    /// The element at `index` counted round the array both ways; the array must not be empty.
    subscript(wrapping index: Int) -> Element { self[(index % count + count) % count] }
}

private extension String {
    func dropping(prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}
