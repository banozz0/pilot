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
        case .bold: return Self.inline(s, selection, "**", MarkdownMarks.bold)
        case .italic: return Self.inline(s, selection, "_", MarkdownMarks.italic)
        case .code:
            if let unfenced = Self.unfence(s, selection) { return unfenced }
            return s.substring(with: Self.words(s, selection)).contains("\n") ? Self.fence(s, selection) : Self.inline(s, selection, "`", MarkdownMarks.code)
        case .link: return Self.link(s, selection)
        case .heading:
            let level = Self.headingLevel(s.substring(with: s.lineRange(for: NSRange(location: selection.location, length: 0))))
            let next = level >= 3 ? 0 : level + 1
            return Self.lines(s, selection) { line in
                // A heading is never a list item: a list or check mark before the words goes.
                let rest = String(line.drop { $0 == " " || $0 == "\t" })
                let body = Self.has(rest, Self.listMark) ? Self.strip(rest, Self.listMark) : Self.strip(line, Self.headingMark)
                return next == 0 ? body : String(repeating: "#", count: next) + " " + body
            }
        case .bullets: return Self.prefix(s, selection, "- ", has: Self.bulletMark)
        case .checklist: return Self.prefix(s, selection, "- [ ] ", has: Self.checkMark)
        }
    }

    // MARK: Inline

    /// The marks a line starts with: its indent, a quote's `>`, then a heading's `#`s or a list or check mark.
    static let lineMark = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]?)*(?:"# + headingMark.pattern.dropFirst() + "|" + listMark.pattern.dropFirst() + ")?")

    /// The words a selection picks: past the marks its line starts with, no space, line end or table pipe at either end
    /// (a triple-click picks the line end too). No selection keeps the caret, moved past those marks.
    static func words(_ s: NSString, _ sel: NSRange) -> NSRange {
        func blank(_ i: Int) -> Bool { s.character(at: i) == 124 || (UnicodeScalar(s.character(at: i)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false) }
        var start = sel.location, end = NSMaxRange(sel)
        while end > start, blank(end - 1) { end -= 1 }
        while start < end, blank(start) { start += 1 }
        if let m = lineMark.firstMatch(in: s as String, range: s.lineRange(for: NSRange(location: start, length: 0))), start < NSMaxRange(m.range) {
            start = NSMaxRange(m.range)
            end = max(end, start)
        }
        return NSRange(location: start, length: end - start)
    }

    /// Whether `range` holds the selection, or the caret strictly inside it.
    private static func holds(_ range: NSRange, _ sel: NSRange) -> Bool {
        sel.length > 0 ? NSIntersectionRange(range, sel) == sel : range.location < sel.location && sel.location < NSMaxRange(range)
    }

    /// The links on `sel`'s line, each with its `!` when it shows a picture.
    private static func links(_ s: NSString, _ sel: NSRange) -> [(match: NSTextCheckingResult, whole: NSRange, picture: Bool)] {
        MarkdownMarks.link.matches(in: s as String, range: s.lineRange(for: sel)).map { m in
            let picture = m.range.location > 0 && s.character(at: m.range.location - 1) == 33
            return (m, picture ? NSRange(location: m.range.location - 1, length: m.range.length + 1) : m.range, picture)
        }
    }

    /// Lines no mark is typed into: fenced code (its fence lines too), a line that only shows a picture and a table's
    /// `|---|` line, or every table line for a format over lines (a mark round a row or across cells breaks the table).
    private static func quiet(_ s: NSString, tables whole: Bool = false) -> [NSRange] {
        let fences = MarkdownBlocks.fences(s).map(\.block)
        let pictures = MarkdownMarks.image.matches(in: s as String, range: NSRange(location: 0, length: s.length)).map(\.range)
        return fences + pictures + MarkdownBlocks.tables(s, skipping: fences).map { whole ? $0.block : $0.rows[1] }
    }

    private static func isQuiet(_ quiet: [NSRange], _ line: NSRange) -> Bool {
        quiet.contains { NSIntersectionRange($0, line).length > 0 || NSLocationInRange(line.location, $0) }
    }

    /// The selection widened over what a mark never lands inside: a link's or a picture's address (to the whole link), a
    /// bare address, and code's words, taken as typed (unless the mark is code's own).
    private static func snap(_ s: NSString, _ sel: NSRange, code: Bool) -> NSRange {
        let line = s.lineRange(for: sel)
        var atoms = links(s, sel).map { l in (part: NSRange(location: NSMaxRange(l.match.range(at: 1)), length: NSMaxRange(l.match.range) - NSMaxRange(l.match.range(at: 1))), whole: l.whole) }
        atoms += MarkdownMarks.bareURL.matches(in: s as String, range: line).map { ($0.range, $0.range) }
        if code { atoms += MarkdownMarks.code.matches(in: s as String, range: line).map { ($0.range, $0.range) } }
        return atoms.reduce(sel) { sel, atom in NSIntersectionRange(atom.part, sel).length > 0 || holds(atom.part, sel) ? NSUnionRange(sel, atom.whole) : sel }
    }

    /// Edits on separate lines, in order, as one edit picking all it wrote.
    private static func splice(_ s: NSString, _ edits: [(range: NSRange, replacement: String)]) -> Edit {
        let range = NSRange(location: edits[0].range.location, length: NSMaxRange(edits[edits.count - 1].range) - edits[0].range.location)
        var replacement = "", at = range.location
        for edit in edits {
            replacement += s.substring(with: NSRange(location: at, length: edit.range.location - at)) + edit.replacement
            at = NSMaxRange(edit.range)
        }
        return Edit(range: range, replacement: replacement, selection: NSRange(location: range.location, length: (replacement as NSString).length))
    }

    /// `mark` round the words picked, or taken off when they already have it. Over lines, each line's words on their own
    /// (a mark never spans a line end), the marks coming off only when every line has them. Quiet lines are left alone.
    private static func inline(_ s: NSString, _ sel: NSRange, _ mark: String, _ span: NSRegularExpression) -> Edit {
        let words = words(s, sel), one = !s.substring(with: words).contains("\n"), quiet = quiet(s, tables: !one)
        let each = pieces(s, words).compactMap { line -> (edit: Edit, off: Bool)? in
            let start = max(line.range.location, words.location), end = min(NSMaxRange(line.range), NSMaxRange(words))
            guard end >= start, !isQuiet(quiet, line.range) else { return nil }
            let picked = Self.words(s, NSRange(location: start, length: end - start))
            return one || picked.length > 0 ? wrap(s, picked, mark, span) : nil
        }
        if one, let only = each.first { return only.edit }
        let off = !each.isEmpty && each.allSatisfy(\.off)
        let edits = each.filter { $0.off == off }.map { ($0.edit.range, $0.edit.replacement) }
        return edits.isEmpty ? unchanged(sel) : splice(s, edits)
    }

    /// No edit: the selection as it was.
    private static func unchanged(_ sel: NSRange) -> Edit { Edit(range: NSRange(location: sel.location, length: 0), replacement: "", selection: sel) }

    /// `mark` round one line's words, or taken off (`off`) when they sit in a span the editor draws with it (`span`), the
    /// marks picked or not, other marks between; same-style spans inside the words merge into the one wrap. No selection
    /// types the pair with the caret between, and a second press takes the empty pair off. Never inside an address, nor
    /// bold or italic inside code (`snap`); italic takes whole words, as the editor draws no `_` inside or beside one.
    private static func wrap(_ s: NSString, _ sel: NSRange, _ mark: String, _ span: NSRegularExpression) -> (edit: Edit, off: Bool) {
        func word(_ i: Int) -> Bool {
            guard i >= 0, i < s.length, let c = UnicodeScalar(s.character(at: i)) else { return false }
            return c == "_" || CharacterSet.alphanumerics.contains(c)
        }
        var sel = snap(s, sel, code: mark != "`")
        let m = (mark as NSString).length
        let spans = span.matches(in: s as String, range: s.lineRange(for: sel)).map(\.range)
        // The empty pair, which no span matches: never part of a longer run of the mark (a fence's ```, `user__name`) unless
        // that is a span's own mark beside it (`**a**` then the pair), nor the end of one span and the start of the next
        // (`**a**|**b**`).
        func same(_ i: Int) -> Bool { i >= 0 && i < s.length && s.character(at: i) == (mark as NSString).character(at: 0) }
        if sel.length == 0, sel.location >= m, sel.location + m <= s.length,
           s.substring(with: NSRange(location: sel.location - m, length: 2 * m)) == mark + mark,
           !same(sel.location - m - 1) || spans.contains(where: { NSMaxRange($0) == sel.location - m }),
           !same(sel.location + m) || spans.contains(where: { $0.location == sel.location + m }),
           !(mark == "_" && word(sel.location - m - 1) && word(sel.location + m)),
           !spans.contains(where: { NSMaxRange($0) == sel.location || $0.location == sel.location }) {
            return (Edit(range: NSRange(location: sel.location - m, length: 2 * m), replacement: "", selection: NSRange(location: sel.location - m, length: 0)), true)
        }
        // `_` never opens or closes italic beside a word's letters: a caret touching a word takes the word.
        if mark == "_", sel.length > 0 || word(sel.location - 1) || word(sel.location) {
            var start = sel.location, end = NSMaxRange(sel)
            while word(start - 1) { start -= 1 }
            while word(end) { end += 1 }
            // A word at an address's edge takes the whole address.
            sel = snap(s, NSRange(location: start, length: end - start), code: true)
        }
        let picked = s.substring(with: sel)
        let around = spans.first { r in
            sel.length > 0 ? holds(r, sel) : r.location + m <= sel.location && sel.location <= NSMaxRange(r) - m
        }
        if let around {
            let inner = NSRange(location: around.location + m, length: around.length - 2 * m)
            func moved(_ i: Int) -> Int { min(max(i, inner.location), NSMaxRange(inner)) - m }
            let start = moved(sel.location)
            return (Edit(range: around, replacement: s.substring(with: inner), selection: NSRange(location: start, length: moved(NSMaxRange(sel)) - start)), true)
        }
        let inside = sel.length > 0 ? spans.filter { NSIntersectionRange($0, sel).length > 0 } : []
        if !inside.isEmpty {
            let whole = inside.reduce(sel, NSUnionRange)
            var text = "", at = whole.location
            for r in inside {
                text += s.substring(with: NSRange(location: at, length: r.location - at)) + s.substring(with: NSRange(location: r.location + m, length: r.length - 2 * m))
                at = NSMaxRange(r)
            }
            text += s.substring(with: NSRange(location: at, length: NSMaxRange(whole) - at))
            return (Edit(range: whole, replacement: mark + text + mark, selection: NSRange(location: whole.location + m, length: (text as NSString).length)), false)
        }
        return (Edit(range: sel, replacement: mark + picked + mark, selection: NSRange(location: sel.location + m, length: sel.length)), false)
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

    /// The fenced block the selection sits in (its fence lines included), its fence lines taken off and every line between
    /// kept; an unclosed one loses its opening line alone. Nil outside one.
    private static func unfence(_ s: NSString, _ sel: NSRange) -> Edit? {
        for fence in MarkdownBlocks.fences(s) {
            guard sel.location >= fence.block.location, NSMaxRange(sel) <= fence.close.map(NSMaxRange) ?? NSMaxRange(fence.block) else { continue }
            let inside = NSMaxRange(s.lineRange(for: fence.open))
            guard let close = fence.close else {
                let body = s.substring(with: NSRange(location: inside, length: NSMaxRange(fence.block) - inside))
                return Edit(range: fence.block, replacement: body, selection: NSRange(location: fence.block.location, length: (body as NSString).length))
            }
            var body = s.substring(with: NSRange(location: inside, length: close.location - inside))
            if body.hasSuffix("\n") { body.removeLast() }
            let trailing = s.substring(with: NSRange(location: NSMaxRange(close), length: NSMaxRange(fence.block) - NSMaxRange(close)))
            return Edit(range: fence.block, replacement: body + trailing, selection: NSRange(location: fence.block.location, length: (body as NSString).length))
        }
        return nil
    }

    /// `[words](https://)` with the address picked to type over; a picked address becomes the link with the caret in
    /// its words. Inside a link (its words or its address) the link comes off and its words stay; a picture's stays. One
    /// line's words only; none on a quiet line.
    private static func link(_ s: NSString, _ sel: NSRange) -> Edit {
        let first = words(s, sel), line = pieces(s, first)[0].range
        guard !isQuiet(quiet(s), line) else { return unchanged(sel) }
        let sel = snap(s, words(s, NSRange(location: first.location, length: max(min(NSMaxRange(first), NSMaxRange(line)) - first.location, 0))), code: true)
        if let found = links(s, sel).first(where: { holds($0.whole, sel) }) {
            guard !found.picture else { return unchanged(sel) }
            let link = found.match, words = s.substring(with: link.range(at: 1))
            return Edit(range: link.range, replacement: words, selection: NSRange(location: link.range.location, length: link.range(at: 1).length))
        }
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
            // A list item is never a heading: a heading's `#`s before the words go.
            let body = strip(strip(rest, headingMark), listMark)
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

    /// Each picked line through `change`. One line keeps the caret or the selection on the same words, never on the marks
    /// before them; more pick them all.
    private static func lines(_ s: NSString, _ sel: NSRange, _ change: (String) -> String) -> Edit {
        let picked = pieces(s, sel)
        let whole = splice(s, picked.map { ($0.range, change($0.body)) })
        let range = whole.range, replacement = whole.replacement
        guard picked.count == 1 else { return whole }
        // A place in the words moves with them; one in the old marks lands where the new marks end.
        let old = s.substring(with: range) as NSString, new = replacement as NSString
        func marks(_ t: NSString) -> Int { lineMark.firstMatch(in: t as String, range: NSRange(location: 0, length: t.length)).map { NSMaxRange($0.range) } ?? 0 }
        let from = marks(old), to = marks(new)
        func moved(_ i: Int) -> Int {
            let at = i - range.location
            return at > old.length ? i + new.length - old.length : range.location + min(max(at - from, 0) + to, new.length)
        }
        let start = moved(sel.location)
        return Edit(range: range, replacement: replacement, selection: NSRange(location: start, length: max(moved(NSMaxRange(sel)) - start, 0)))
    }
}
