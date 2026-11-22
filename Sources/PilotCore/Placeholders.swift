import Foundation

/// The placeholders snippets and quicklinks fill as they paste or open (launcher-best T6; the idea from Raycast's, Alfred's
/// and LaunchBar's docs, no code): `{date}` and `{time}`, each with an offset (`+7d`, `-2w`, `+1mo`, `+1y`, `+3h`, `+30m`)
/// and a `format="d MMM"`; `{clipboard}`, and `{clipboard N}` for the copy N before it; `{selection}`; `{argument}` and
/// `{argument name}`; `{cursor}`; a quicklink's `{query}`. Any but `{cursor}` takes `| uppercase`, `| lowercase`, `| trim`
/// or `| encode`, applied left to right. An unknown brace, or a known one with words it does not take, stays as typed.
public enum Placeholders {
    public enum Kind: Hashable, Sendable { case date, time, clipboard, selection, argument, cursor, query }

    /// What the placeholders fill with. Nil clipboard or selection fills nothing; a nil query leaves `{query}` as typed.
    public struct Values: Sendable {
        public var now: Date
        public var clipboard: String?
        /// Clipboard history before the latest copy, newest first: `{clipboard 1}` is the first.
        public var earlierClips: [String]
        public var selection: String?
        /// What was asked for. Several argument names split it at commas, in the order each name first appears.
        public var argument: String
        public var query: String?
        public var locale: Locale
        public var timeZone: TimeZone

        public init(now: Date = Date(), clipboard: String? = nil, earlierClips: [String] = [], selection: String? = nil,
                    argument: String = "", query: String? = nil, locale: Locale = .current, timeZone: TimeZone = .current) {
            self.now = now; self.clipboard = clipboard; self.earlierClips = earlierClips; self.selection = selection
            self.argument = argument; self.query = query; self.locale = locale; self.timeZone = timeZone
        }
    }

    /// The text filled, and where `{cursor}` was in it, in characters from the start (the first one; later ones drop).
    public struct Filled: Equatable, Sendable {
        public var text: String
        public var caret: Int?
    }

    /// Percent-encoding for a value put in a URL: `&`, `=`, `+`, `#`, `?` and `/` stay inside it.
    static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?/"))

    /// `text` with its placeholders filled. `only`: the kinds filled, the rest left as typed. `url`: every value is
    /// percent-encoded once (already so with `| encode`), as a quicklink's `{query}` always was.
    public static func fill(_ text: String, _ values: Values, only: Set<Kind>? = nil, url: Bool = false) -> Filled {
        let names = summary(of: text).argumentNames
        var out = "", caret: Int?
        scan(text) { piece in
            switch piece {
            case .text(let s): out += s
            case .token(let raw, let token):
                guard only?.contains(token.kind) ?? true else { out += raw; return }
                if token.kind == .cursor { if caret == nil { caret = out.count }; return }
                guard var value = value(token, values, names: names) else { out += raw; return }
                for modifier in token.modifiers { value = modifier.apply(value) }
                if url, !token.modifiers.contains(.encode) { value = Modifier.encode.apply(value) }
                out += value
            }
        }
        return Filled(text: out, caret: caret)
    }

    /// What a fill of `text` needs, from one pass over it.
    public struct Summary: Sendable {
        /// The kinds it holds.
        public var kinds = Set<Kind>()
        /// The deepest `{clipboard N}`, 0 when none reaches back: how much history a fill needs.
        public var clipboardDepth = 0
        /// The argument names, each once, in the order they first appear; "" for a bare `{argument}`.
        public var argumentNames: [String] = []
    }

    public static func summary(of text: String) -> Summary {
        var summary = Summary()
        scan(text) {
            guard case .token(_, let t) = $0 else { return }
            summary.kinds.insert(t.kind)
            if t.kind == .clipboard { summary.clipboardDepth = max(summary.clipboardDepth, t.index) }
            if t.kind == .argument, !summary.argumentNames.contains(t.name) { summary.argumentNames.append(t.name) }
        }
        return summary
    }

    /// The kinds `text` holds.
    public static func kinds(in text: String) -> Set<Kind> { summary(of: text).kinds }

    // MARK: Parsing

    enum Modifier: String {
        case uppercase, lowercase, trim, encode

        func apply(_ s: String) -> String {
            switch self {
            case .uppercase: s.uppercased()
            case .lowercase: s.lowercased()
            case .trim: s.trimmingCharacters(in: .whitespacesAndNewlines)
            case .encode: s.addingPercentEncoding(withAllowedCharacters: Placeholders.queryAllowed) ?? ""
            }
        }
    }

    struct Token {
        var kind: Kind
        var offset = DateComponents()
        var format: String?
        /// `{clipboard N}`'s N.
        var index = 0
        /// `{argument name}`'s name.
        var name = ""
        var modifiers: [Modifier] = []
    }

    enum Piece { case text(Substring), token(raw: Substring, Token) }

    /// Walks `text`: plain runs and placeholders in order. A brace that is no placeholder is plain text through its close.
    static func scan(_ text: String, _ each: (Piece) -> Void) {
        var rest = text[...]
        while let open = rest.firstIndex(of: "{") {
            if open > rest.startIndex { each(.text(rest[..<open])) }
            guard let close = rest[open...].firstIndex(of: "}") else { rest = rest[open...]; break }
            let raw = rest[open...close]
            if let token = token(rest[rest.index(after: open)..<close]) { each(.token(raw: raw, token)) } else { each(.text(raw)) }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { each(.text(rest)) }
    }

    private static let names: [String: Kind] = ["date": .date, "time": .time, "clipboard": .clipboard, "selection": .selection,
                                                 "argument": .argument, "cursor": .cursor, "query": .query]

    /// One placeholder's inside: a name, its words, then `| modifier`s; nil when it is not one.
    static func token(_ body: Substring) -> Token? {
        guard !body.contains(where: \.isNewline) else { return nil }
        let segments = split(body, at: "|")
        let words = split(segments[0][...], at: " ").filter { !$0.isEmpty }
        guard let head = words.first else { return nil }
        guard let kind = names[head] else { return nil }
        var token = Token(kind: kind)
        for word in words.dropFirst() {
            let (key, value) = pair(word)
            switch (kind, key) {
            case (.date, nil), (.time, nil), (.date, "offset"), (.time, "offset"):
                guard let offset = offset(value) else { return nil }
                token.offset = offset
            case (.date, "format"), (.time, "format"):
                guard !value.isEmpty else { return nil }
                token.format = value
            case (.clipboard, nil), (.clipboard, "offset"):
                guard let n = Int(value), n >= 0 else { return nil }
                token.index = n
            case (.argument, nil), (.argument, "name"):
                guard token.name.isEmpty, !value.isEmpty else { return nil }
                token.name = value
            default: return nil
            }
        }
        for segment in segments.dropFirst() {
            guard let modifier = Modifier(rawValue: segment.trimmingCharacters(in: .whitespaces)) else { return nil }
            token.modifiers.append(modifier)
        }
        if kind == .cursor, !token.modifiers.isEmpty { return nil }
        return token
    }

    /// `s` cut at `separator` outside double quotes.
    private static func split(_ s: Substring, at separator: Character) -> [String] {
        var parts = [""], quoted = false
        for c in s {
            if c == "\"" { quoted.toggle() }
            if c == separator, !quoted { parts.append("") } else { parts[parts.count - 1].append(c) }
        }
        return parts
    }

    /// `key=value` or a bare value, its quotes taken off.
    private static func pair(_ word: String) -> (key: String?, value: String) {
        func unquoted(_ s: Substring) -> String {
            s.count >= 2 && s.first == "\"" && s.last == "\"" ? String(s.dropFirst().dropLast()) : String(s)
        }
        guard let eq = word.firstIndex(of: "="), !word[..<eq].contains("\"") else { return (nil, unquoted(word[...])) }
        return (String(word[..<eq]), unquoted(word[word.index(after: eq)...]))
    }

    /// `+7d`, `-2w`, `+1mo`, `+1y`, `+3h`, `+30m` (minutes).
    private static func offset(_ s: String) -> DateComponents? {
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let body = s.dropFirst(), digits = body.prefix(while: \.isNumber), unit = body.dropFirst(digits.count)
        guard let n = Int(digits) else { return nil }
        let v = sign == "-" ? -n : n
        var c = DateComponents()
        switch unit {
        case "y": c.year = v
        case "mo": c.month = v
        case "w": c.day = 7 * v
        case "d": c.day = v
        case "h": c.hour = v
        case "m": c.minute = v
        default: return nil
        }
        return c
    }

    private static func value(_ token: Token, _ values: Values, names: [String]) -> String? {
        switch token.kind {
        case .date, .time:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = values.timeZone
            let date = calendar.date(byAdding: token.offset, to: values.now) ?? values.now
            let formatter = DateFormatter()
            formatter.locale = values.locale
            formatter.timeZone = values.timeZone
            if let format = token.format { formatter.dateFormat = format } else {
                formatter.dateStyle = token.kind == .date ? .medium : .none
                formatter.timeStyle = token.kind == .date ? .none : .short
            }
            return formatter.string(from: date)
        case .clipboard:
            guard token.index > 0 else { return values.clipboard ?? "" }
            return values.earlierClips.indices.contains(token.index - 1) ? values.earlierClips[token.index - 1] : ""
        case .selection: return values.selection ?? ""
        case .argument:
            guard names.count > 1, let at = names.firstIndex(of: token.name) else { return values.argument }
            let parts = values.argument.split(separator: ",", maxSplits: names.count - 1, omittingEmptySubsequences: false)
            return parts.indices.contains(at) ? parts[at].trimmingCharacters(in: .whitespaces) : ""
        case .query: return values.query
        case .cursor: return nil
        }
    }
}
