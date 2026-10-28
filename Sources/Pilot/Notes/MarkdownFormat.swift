import Foundation
import PilotCore

/// The notes toolbar's edits (Q116, Sven 2026-10-15): each one types Markdown at the selection, never styles it, so
/// the file stays plain Markdown. Pure: the text and selection in, one replacement and the selection after it out; the
/// editor applies it as an edit Undo takes back.
enum MarkdownFormat: String, CaseIterable, Identifiable {
    case heading, bold, italic, link, code, bullets, checklist

    var id: String { rawValue }

    /// Its name: the format bar's tooltip, what VoiceOver reads, its row in Cmd+K's Format group.
    var title: String {
        switch self {
        case .heading: "Heading"
        case .bold: "Bold"
        case .italic: "Italic"
        case .link: "Link"
        case .code: "Code"
        case .bullets: "Bulleted list"
        case .checklist: "Checklist"
        }
    }

    /// Its key in the editor (direction B, 2026-10-18): Command with this character, Shift too for the two line formats;
    /// Link and the bulleted list have none.
    var shortcut: (character: String, shift: Bool)? {
        switch self {
        case .bold: ("b", false)
        case .italic: ("i", false)
        case .code: ("e", false)
        case .heading: ("h", true)
        case .checklist: ("l", true)
        case .link, .bullets: nil
        }
    }

    /// The key as its row shows it: ⌘B, ⌘⇧H.
    var key: String? { shortcut.map { "⌘" + ($0.shift ? "⇧" : "") + $0.character.uppercased() } }

    /// The formats with a key, in the format bar's order: Cmd+K's Format group.
    static let keyed = allCases.filter { $0.shortcut != nil }

    /// The format a key asks for: Command with `character` (its characters, modifiers aside), and Shift or not.
    static func keyed(_ character: String?, command: Bool, shift: Bool) -> MarkdownFormat? {
        guard command, let character = character?.lowercased() else { return nil }
        return keyed.first { $0.shortcut?.character == character && $0.shortcut?.shift == shift }
    }

    var symbol: String {
        switch self {
        case .heading: "textformat.size"
        case .bold: "bold"
        case .italic: "italic"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .bullets: "list.bullet"
        case .checklist: "checklist"
        }
    }

    struct Edit: Equatable {
        /// The characters replaced, in the text before the edit.
        var range: NSRange
        var replacement: String
        /// The selection after the edit.
        var selection: NSRange
    }

    /// This format applied to `selection` in `text`.
    func edit(_ text: String, selection: NSRange) -> Edit {
        let s = text as NSString
        switch self {
        case .bold: return Self.wrap(s, selection, "**")
        case .italic: return Self.wrap(s, selection, "_")
        case .code:
            let picked = s.substring(with: selection)
            return picked.contains("\n") ? Self.fence(s, selection) : Self.wrap(s, selection, "`")
        case .link: return Self.link(s, selection)
        case .heading:
            let level = Self.headingLevel(s.substring(with: s.lineRange(for: NSRange(location: selection.location, length: 0))))
            let next = level >= 3 ? 0 : level + 1
            return Self.lines(s, selection) { line in
                let body = Self.strip(line, Self.headingMark)
                return next == 0 ? body : String(repeating: "#", count: next) + " " + body
            }
        case .bullets: return Self.prefix(s, selection, "- ", has: Self.bulletMark)
        case .checklist: return Self.prefix(s, selection, "- [ ] ", has: Self.checkMark)
        }
    }

    // MARK: Inline

    /// `mark` round the selection, or taken off when it is already there (inside the selection or just outside it); no
    /// selection types the pair with the caret between.
    private static func wrap(_ s: NSString, _ sel: NSRange, _ mark: String) -> Edit {
        let m = (mark as NSString).length, picked = s.substring(with: sel)
        if sel.length >= 2 * m, picked.hasPrefix(mark), picked.hasSuffix(mark) {
            let inner = String(picked.dropFirst(mark.count).dropLast(mark.count))
            return Edit(range: sel, replacement: inner, selection: NSRange(location: sel.location, length: (inner as NSString).length))
        }
        if sel.location >= m, NSMaxRange(sel) + m <= s.length,
           s.substring(with: NSRange(location: sel.location - m, length: m)) == mark,
           s.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == mark,
           sel.length > 0 {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            return Edit(range: outer, replacement: picked, selection: NSRange(location: outer.location, length: sel.length))
        }
        return Edit(range: sel, replacement: mark + picked + mark, selection: NSRange(location: sel.location + m, length: sel.length))
    }

    /// A selection over lines as a fenced code block, the fences on lines of their own.
    private static func fence(_ s: NSString, _ sel: NSRange) -> Edit {
        let lines = s.lineRange(for: sel)
        var body = s.substring(with: lines)
        if body.hasSuffix("\n") { body.removeLast() }
        let trailing = NSMaxRange(lines) < s.length || s.substring(with: lines).hasSuffix("\n") ? "\n" : ""
        let replacement = "```\n" + body + "\n```" + trailing
        return Edit(range: lines, replacement: replacement, selection: NSRange(location: lines.location + 4, length: (body as NSString).length))
    }

    /// `[words](https://)` with the address picked to type over; a picked address becomes the link with the caret in
    /// its words.
    private static func link(_ s: NSString, _ sel: NSRange) -> Edit {
        let picked = s.substring(with: sel)
        if picked.hasPrefix("http://") || picked.hasPrefix("https://") {
            return Edit(range: sel, replacement: "[](\(picked))", selection: NSRange(location: sel.location + 1, length: 0))
        }
        let words = picked.isEmpty ? "link" : picked, w = (words as NSString).length
        let replacement = "[\(words)](https://)"
        return picked.isEmpty
            ? Edit(range: sel, replacement: replacement, selection: NSRange(location: sel.location + 1, length: w))
            : Edit(range: sel, replacement: replacement, selection: NSRange(location: sel.location + w + 3, length: 8))
    }

    /// A note's title words: its first line with words, past a heading's `#` marks; empty at the start for a note with
    /// none. Cmd+K's Rename picks them, Duplicate adds " copy" after them.
    static func titleRange(_ text: String) -> NSRange {
        let s = text as NSString
        var found = NSRange(location: 0, length: 0)
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.byLines, .substringNotRequired]) { _, line, _, stop in
            var start = line.location, end = NSMaxRange(line)
            while start < end, [35, 32, 9].contains(s.character(at: start)) { start += 1 }
            while end > start, [32, 9].contains(s.character(at: end - 1)) { end -= 1 }
            guard end > start, !NoteAttachments.isImageLine(s.substring(with: line).trimmingCharacters(in: .whitespaces)) else { return }
            found = NSRange(location: start, length: end - start)
            stop.pointee = true
        }
        return found
    }

    // MARK: Lines

    static let headingMark = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
    /// A list or checklist mark with its indent kept out: `- `, `* `, `+ `, `1. `, `- [ ] `.
    static let listMark = try! NSRegularExpression(pattern: #"^([-*+][ \t]+\[[ xX]\]|[-*+]|\d+[.)])[ \t]+"#)
    static let bulletMark = try! NSRegularExpression(pattern: #"^[-*+][ \t]+(?!\[[ xX]\][ \t])"#)
    static let checkMark = try! NSRegularExpression(pattern: #"^[-*+][ \t]+\[[ xX]\][ \t]+"#)

    static func headingLevel(_ line: String) -> Int {
        let ns = line as NSString
        guard let m = headingMark.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return 0 }
        return ns.substring(with: m.range).filter { $0 == "#" }.count
    }

    private static func strip(_ line: String, _ mark: NSRegularExpression) -> String {
        let ns = line as NSString
        guard let m = mark.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
        return ns.substring(from: NSMaxRange(m.range))
    }

    private static func has(_ line: String, _ mark: NSRegularExpression) -> Bool {
        mark.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// `mark` before each picked line, its indent kept and any other list mark swapped out; when every picked line already
    /// has it, it comes off them all. Blank lines stay blank unless the caret is on one alone.
    private static func prefix(_ s: NSString, _ sel: NSRange, _ mark: String, has own: NSRegularExpression) -> Edit {
        let picked = pieces(s, sel)
        let filled = picked.count == 1 ? picked : picked.filter { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
        let off = !filled.isEmpty && filled.allSatisfy { has($0.body.drop { $0 == " " || $0 == "\t" }.description, own) }
        return lines(s, sel) { line in
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let rest = String(line.dropFirst(indent.count))
            if picked.count > 1, rest.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            let body = strip(rest, listMark)
            return indent + (off ? body : mark + body)
        }
    }

    /// The picked lines without their line ends.
    private static func pieces(_ s: NSString, _ sel: NSRange) -> [(range: NSRange, body: String)] {
        let all = s.lineRange(for: sel)
        var out: [(NSRange, String)] = []
        s.enumerateSubstrings(in: all, options: [.byLines, .substringNotRequired]) { _, range, _, _ in out.append((range, s.substring(with: range))) }
        if out.isEmpty { out.append((NSRange(location: all.location, length: 0), "")) }
        return out
    }

    /// Each picked line through `change`. One line keeps the caret where it was in the words; more pick them all.
    private static func lines(_ s: NSString, _ sel: NSRange, _ change: (String) -> String) -> Edit {
        let picked = pieces(s, sel)
        let range = NSRange(location: picked[0].range.location, length: NSMaxRange(picked[picked.count - 1].range) - picked[0].range.location)
        var replacement = "", at = range.location
        for (i, piece) in picked.enumerated() {
            if i > 0 {
                let gap = NSRange(location: at, length: piece.range.location - at)
                replacement += s.substring(with: gap)
            }
            replacement += change(piece.body)
            at = NSMaxRange(piece.range)
        }
        let length = (replacement as NSString).length
        guard picked.count == 1, sel.length == 0 else {
            return Edit(range: range, replacement: replacement, selection: NSRange(location: range.location, length: length))
        }
        // The caret keeps its place in the line's words as the mark before them grows or shrinks.
        let shift = length - range.length
        let location = min(max(sel.location + shift, range.location), range.location + length)
        return Edit(range: range, replacement: replacement, selection: NSRange(location: location, length: 0))
    }
}
