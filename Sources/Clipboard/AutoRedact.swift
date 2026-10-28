import CoreGraphics
import Foundation

/// What the capture editor's auto-redact covers (story 195): emails, card numbers, IP addresses, keys and phone numbers,
/// found in the capture's OCR lines. The text never leaves this: callers get kinds, ranges and boxes, and log counts.
public enum Sensitive: Int, CaseIterable, Sendable {
    // An overlap goes to the earlier kind: an email is never also cut into a key.
    case email, card, key, address, phone

    /// How the editor's hint names `count` of them: "2 emails", "1 card number".
    public func named(_ count: Int) -> String {
        let (one, many) = switch self {
        case .email: ("email", "emails")
        case .card: ("card number", "card numbers")
        case .key: ("key", "keys")
        case .address: ("IP address", "IP addresses")
        case .phone: ("phone number", "phone numbers")
        }
        return "\(count) \(count == 1 ? one : many)"
    }

    /// Every sensitive run in `text`, left to right, none overlapping another.
    public static func find(in text: String) -> [(kind: Sensitive, range: Range<String.Index>)] {
        var found: [(kind: Sensitive, range: Range<String.Index>)] = []
        for kind in allCases {
            for range in kind.matches(in: text) where !found.contains(where: { $0.range.overlaps(range) }) {
                found.append((kind, range))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func matches(in text: String) -> [Range<String.Index>] {
        switch self {
        case .email: Self.runs(Self.emailShape, in: text)
        case .card: Self.runs(Self.cardShape, in: text).filter { Self.luhn(text[$0]) }
        case .key:
            // A value after its label ("Password: …", "Bearer …"), a JWT's three parts, or one long run of letters and digits that
            // reads as random rather than as a word.
            Self.runs(Self.labelled, in: text, group: 1) + Self.runs(Self.bearer, in: text, group: 1) + Self.runs(Self.jwtShape, in: text)
                + Self.runs(Self.longRun, in: text).filter { Self.random(text[$0]) }
        case .address: Self.runs(Self.ip4Shape, in: text) + Self.runs(Self.ip6Shape, in: text).filter { Self.ip6(text[$0]) }
        case .phone:
            (Self.runs(Self.worldPhone, in: text) + Self.runs(Self.localPhone, in: text)).filter {
                (8...15).contains(text[$0].filter(\.isNumber).count)
            }
        }
    }

    private static func shape(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    private static let emailShape = shape(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#)
    private static let cardShape = shape(#"(?<![\d])(?:\d[ -]?){12,18}\d(?![\d])"#)
    private static let labelled = shape(#"(?i)\b(?:api[ _-]?key|secret|passw(?:or)?d|pwd|token)\s*[:=]\s*([^\s"',;]{6,})"#)
    private static let bearer = shape(#"(?i)\bbearer\s+([^\s"',;]{6,})"#)
    private static let jwtShape = shape(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#)
    private static let longRun = shape(#"(?<![A-Za-z0-9_+=-])[A-Za-z0-9_+=-]{20,}(?![A-Za-z0-9_+=-])"#)
    private static let ip4Shape = shape(#"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\.?\d)"#)
    private static let ip6Shape = shape(#"(?<![0-9A-Za-z:])[0-9A-Fa-f:]{6,39}(?![0-9A-Za-z:])"#)
    private static let worldPhone = shape(#"\+\d{1,3}(?:[ .-]?\(?\d{1,4}\)?){2,5}(?!\d)"#)
    private static let localPhone = shape(#"(?<![\d+])\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}(?!\d)"#)

    /// The ranges `pattern` matches, or its `group`'s.
    private static func runs(_ pattern: NSRegularExpression, in text: String, group: Int = 0) -> [Range<String.Index>] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: group), in: text) }
    }

    /// The card check: 13 to 19 digits whose Luhn sum ends in 0.
    static func luhn(_ s: Substring) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { sum, d in
            let n = d.offset % 2 == 1 ? d.element * 2 : d.element
            return sum + (n > 9 ? n - 9 : n)
        }
        return sum % 10 == 0
    }

    /// Letters and digits mixed, at least two of each, and as varied as a random string (over 3.3 bits a character):
    /// `nw_live_7f3a…` is, `CaptureEditorRenders` and `INV-0142` are not.
    static func random(_ s: Substring) -> Bool {
        guard s.filter(\.isNumber).count >= 2, s.filter(\.isLetter).count >= 2 else { return false }
        let counts = Dictionary(s.map { ($0, 1) }, uniquingKeysWith: +).values
        let n = Double(s.count)
        return counts.reduce(0) { $0 - Double($1) / n * log2(Double($1) / n) } > 3.3
    }

    /// Eight groups, or fewer round one `::`, each one to four hex digits: `fe80::1`, never a time like `12:30:45`.
    static func ip6(_ s: Substring) -> Bool {
        let halves = s.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        let groups = halves.flatMap { $0.split(separator: ":", omittingEmptySubsequences: false) }.filter { !$0.isEmpty }
        guard groups.allSatisfy({ $0.count <= 4 }), !s.hasSuffix(":") || s.hasSuffix("::") else { return false }
        return halves.count == 2 ? groups.count <= 7 : groups.count == 8
    }
}

extension ReadLine {
    /// The whitespace-separated words' ranges in `text`, in order: what `words` lines up with.
    public static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for i in text.indices {
            if text[i].isWhitespace {
                if let s = start { ranges.append(s..<i); start = nil }
            } else if start == nil {
                start = i
            }
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }

    /// Where `range` of the text sits, 0 to 1 of the image: the words it touches, a word it only partly covers cut by its
    /// share of characters with half a character spare each side; the line's box cut so when the words have no boxes.
    public func box(of range: Range<String.Index>) -> CGRect {
        let ranges = Self.wordRanges(text)
        if let words, words.count == ranges.count {
            let touched = zip(ranges, words).filter { $0.0.overlaps(range) }
            let union = touched.reduce(CGRect.null) { $0.union(slice($1.1, word: $1.0, part: $1.0.clamped(to: range))) }
            if !union.isNull { return union }
        }
        return slice(box, word: text.startIndex..<text.endIndex, part: range)
    }

    /// The share of `box`, which holds `word`, that `part` of it takes.
    private func slice(_ box: CGRect, word: Range<String.Index>, part: Range<String.Index>) -> CGRect {
        let n = CGFloat(text.distance(from: word.lowerBound, to: word.upperBound))
        guard n > 0 else { return box }
        let a = CGFloat(text.distance(from: word.lowerBound, to: part.lowerBound)), b = CGFloat(text.distance(from: word.lowerBound, to: part.upperBound))
        let unit = box.width / n
        let x0 = max(box.minX, box.minX + (a - 0.5) * unit), x1 = min(box.maxX, box.minX + (b + 0.5) * unit)
        return CGRect(x: x0, y: box.minY, width: max(0, x1 - x0), height: box.height)
    }
}

/// Turns read lines into the editor's marks' places, in the capture's points.
public enum AutoRedact {
    /// Every sensitive run in `lines` (read from an image `size` points big) with its kind, padded two points; a code
    /// whose payload is sensitive is covered whole.
    public static func cover(_ lines: [ReadLine], size: CGSize) -> [(kind: Sensitive, rect: CGRect)] {
        lines.flatMap { line in
            Sensitive.find(in: line.text).map { found in
                (found.kind, points(line.code ? line.box : line.box(of: found.range), size).insetBy(dx: -2, dy: -2))
            }
        }
    }

    /// The text inside `area` (points), one box a line: the words at least half inside it, or the line's part inside it
    /// when its words have no boxes; codes are left alone.
    public static func text(_ lines: [ReadLine], in area: CGRect, size: CGSize) -> [CGRect] {
        func inside(_ r: CGRect) -> Bool {
            let cut = r.intersection(area)
            return !cut.isNull && cut.width * cut.height >= r.width * r.height / 2
        }
        return lines.filter { !$0.code }.compactMap { line in
            let words = (line.words?.count == ReadLine.wordRanges(line.text).count ? line.words : nil)?.map { points($0, size) }
            let kept = words.map { $0.filter(inside).reduce(CGRect.null) { $0.union($1) } } ?? points(line.box, size).intersection(area)
            return kept.isNull || kept.isEmpty ? nil : kept.insetBy(dx: -2, dy: -2)
        }
    }

    private static func points(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }
}
