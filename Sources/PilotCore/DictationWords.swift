import Foundation

/// What Sven taught dictation (Q598): the words Whisper should spell as written, and the replacements Pilot makes in every
/// model's text, heard → written ("cloud" → "Claude"). One file in the Speech folder, beside the models, so pilot-dictate
/// reads the words from it for Whisper's prompt (never from its arguments); Pilot reads and writes it.
public struct DictationWords: Codable, Equatable, Sendable {
    public struct Replacement: Codable, Equatable, Hashable, Sendable {
        public var heard: String
        public var written: String
        public init(heard: String, written: String) { self.heard = heard; self.written = written }
    }

    public var words: [String]
    public var replacements: [Replacement]

    public init(words: [String] = [], replacements: [Replacement] = []) {
        self.words = words
        self.replacements = replacements
    }

    /// The file's name in the Speech folder.
    public static let fileName = "vocabulary.json"

    /// The file in `speech`, the folder that holds each model's folder.
    public static func file(in speech: URL) -> URL { speech.appending(path: fileName) }

    /// What `file` holds; nothing taught when it is missing or unreadable.
    public static func read(_ file: URL) -> DictationWords {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(DictationWords.self, from: $0) } ?? DictationWords()
    }

    public func write(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    /// A word added once, whatever its case; blank ones are not.
    public mutating func learn(_ word: String) {
        let word = Self.tidy(word)
        guard !word.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        words.append(word)
    }

    /// The pair added, or the written form changed for a heard form already kept; nothing for a blank side or a pair that
    /// changes nothing.
    public mutating func replace(_ heard: String, with written: String) {
        let heard = Self.tidy(heard), written = Self.tidy(written)
        guard !heard.isEmpty, !written.isEmpty, heard != written else { return }
        if let i = replacements.firstIndex(where: { Self.key($0.heard) == Self.key(heard) }) {
            replacements[i].written = written
        } else {
            replacements.append(Replacement(heard: heard, written: written))
        }
    }

    /// `text` with each heard form, as whole words and whatever its case, written as taught, the written form's own case
    /// kept: "Ask cloud code to" → "Ask Claude Code to". One pass, the longest heard form first, so a written form that
    /// holds its heard form ("Claude" for "Claud") is never replaced again.
    public func replaced(_ text: String) -> String {
        let pairs = replacements.filter { !Self.key($0.heard).isEmpty }
        guard !pairs.isEmpty, !text.isEmpty else { return text }
        let written = Dictionary(pairs.map { (Self.key($0.heard), $0.written) }, uniquingKeysWith: { first, _ in first })
        let alternatives = written.keys.sorted { ($0.count, $0) > ($1.count, $1) }.map { key in
            key.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        }
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}'’])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}])"#,
                                                   options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        var out = "", last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let heard = source.substring(with: match.range)
            out += written[Self.key(heard)] ?? heard
            last = match.range.location + match.range.length
        }
        return out + source.substring(from: last)
    }

    /// Lowercased, its words one space apart: how a heard form is matched.
    static func key(_ text: String) -> String { tidy(text).lowercased() }

    /// Trimmed, its words one space apart.
    static func tidy(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

/// One take Pilot wrote down (Q599): its text as the model heard it, before any replacement, so a misheard word can be
/// fixed from it; when, how long, by which model and into which app. No audio is kept here.
public struct DictationTake: Codable, Equatable, Identifiable, Sendable {
    public var text: String
    public var at: Date
    public var seconds: Double?
    public var model: String?
    public var app: String?
    public let id: UUID

    public init(text: String, at: Date, seconds: Double? = nil, model: String? = nil, app: String? = nil, id: UUID = UUID()) {
        self.text = text; self.at = at; self.seconds = seconds; self.model = model; self.app = app; self.id = id
    }

    /// How many are kept, newest first.
    public static let kept = 20

    /// `takes` with `take` first, the oldest past `kept` dropped.
    public static func adding(_ take: DictationTake, to takes: [DictationTake]) -> [DictationTake] {
        Array(([take] + takes).prefix(kept))
    }
}
