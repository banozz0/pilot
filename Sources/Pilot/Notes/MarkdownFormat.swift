import Foundation
import PilotCore

/// The notes toolbar's edits (Q116, Sven 2026-10-15): each one types Markdown at the selection, never styles it, so
/// the file stays plain Markdown. Pure: the text and selection in, one replacement and the selection after it out; the
/// editor applies it as an edit Undo takes back. The paragraph styles are Apple Notes' (Sven, 2026-11-20), each a plain
/// Markdown line form: Title `# `, Heading `## `, Subheading `### `, Body none, Monostyled a fenced block, Bulleted List
/// `- `, Dashed List `+ ` (CommonMark's third bullet, which Pilot draws as a dash), Numbered List `1. `, Block Quote `> `.
/// Underline is `<u>…</u>` (inline HTML, which CommonMark keeps), strikethrough GitHub's `~~…~~`.
enum MarkdownFormat: String, CaseIterable, Identifiable {
    case title, heading, subheading, body, mono, bullets, dashes, numbers, quote
    case bold, italic, underline, strike, code, checklist, link

    var id: String { rawValue }

    /// The paragraph styles, in the Aa menu's order (Apple Notes').
    static let styles: [MarkdownFormat] = [.title, .heading, .subheading, .body, .mono, .bullets, .dashes, .numbers, .quote]

    /// Its name: the format bar's tooltip, what VoiceOver reads, its row in the Aa menu and Cmd+K's Format group.
    var title: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .mono: "Monostyled"
        case .bullets: "Bulleted List"
        case .dashes: "Dashed List"
        case .numbers: "Numbered List"
        case .quote: "Block Quote"
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strike: "Strikethrough"
        case .code: "Code"
        case .checklist: "Checklist"
        case .link: "Link"
        }
    }

    /// Its key in the editor (direction B, 2026-10-18; Apple Notes' style keys, 2026-11-20): Command with this
    /// character, Shift too for the line formats. ⌘⇧H sets Heading (it cycled #, ##, ### before the Aa menu).
    var shortcut: (character: String, shift: Bool)? {
        switch self {
        case .title: ("t", true)
        case .heading: ("h", true)
        case .subheading: ("j", true)
        case .body: ("b", true)
        case .bullets: ("7", true)
        case .dashes: ("8", true)
        case .numbers: ("9", true)
        case .bold: ("b", false)
        case .italic: ("i", false)
        case .underline: ("u", false)
        case .code: ("e", false)
        case .checklist: ("l", true)
        case .mono, .quote, .strike, .link: nil
        }
    }

    /// The key as its row shows it: ⌘B, ⌘⇧H.
    var key: String? { shortcut.map { "⌘" + ($0.shift ? "⇧" : "") + $0.character.uppercased() } }

    /// The formats with a key, the styles first: Cmd+K's Format group.
    static let keyed = allCases.filter { $0.shortcut != nil }

    /// The format a key asks for: Command with `character` (the key's own character, no modifier applied, so ⌘⇧7 reads
    /// "7"), and Shift or not.
    static func keyed(_ character: String?, command: Bool, shift: Bool) -> MarkdownFormat? {
        guard command, let character = character?.lowercased() else { return nil }
        return keyed.first { $0.shortcut?.character == character && $0.shortcut?.shift == shift }
    }

    var symbol: String {
        switch self {
        case .title: "textformat.size.larger"
        case .heading: "textformat.size"
        case .subheading: "textformat.size.smaller"
        case .body: "textformat"
        case .mono: "curlybraces"
        case .bullets: "list.bullet"
        case .dashes: "list.dash"
        case .numbers: "list.number"
        case .quote: "text.quote"
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strike: "strikethrough"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .checklist: "checklist"
        case .link: "link"
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
        case .bold: return Self.inline(s, selection, "**", "**", MarkdownMarks.bold)
        case .italic: return Self.inline(s, selection, "_", "_", MarkdownMarks.italic)
        case .underline: return Self.inline(s, selection, "<u>", "</u>", MarkdownMarks.underline)
        case .strike: return Self.inline(s, selection, "~~", "~~", MarkdownMarks.strike)
        case .code:
            if let unfenced = Self.unfence(s, selection) { return unfenced }
            return s.substring(with: Self.words(s, selection)).contains("\n") ? Self.fence(s, selection) : Self.inline(s, selection, "`", "`", MarkdownMarks.code)
        case .link: return Self.link(s, selection)
        // The paragraph styles and the checklist: a line's kind.
        default: return style(s, selection)
        }
    }

    // MARK: Paragraph styles

    /// This paragraph style (or the checklist) over the picked lines, as Apple Notes' Aa menu sets it: each line's marks
    /// (a quote's `>`, a heading's `#`s, a list or check mark) swapped for this style's; when every picked line already
    /// has it, they go back to Body. Monostyled fences the lines (their marks taken off first), or takes the fence off when they sit in
    /// one; any other style inside a fence takes the fence off first.
    private func style(_ s: NSString, _ sel: NSRange) -> Edit {
        if let unfenced = Self.unfence(s, sel) {
            guard self != .mono else { return unfenced }
            // The picked lines where they land once the opening fence line is gone, inside the block's lines.
            let fenceLine = s.lineRange(for: NSRange(location: unfenced.range.location, length: 0)).length
            let body = unfenced.selection, start = min(max(sel.location - fenceLine, body.location), NSMaxRange(body))
            let end = min(max(NSMaxRange(sel) - fenceLine, start), NSMaxRange(body))
            return Self.then(s, unfenced) { text, _ in edit(text, selection: NSRange(location: start, length: end - start)) }
        }
        if self == .mono {
            return Self.then(s, Self.restyle(s, sel, .body)) { text, sel in Self.fence(text as NSString, sel) }
        }
        return Self.restyle(s, sel, self)
    }

    /// The picked lines in `style` (not Monostyled), or back to Body when they all have it; a numbered list counts 1, 2,
    /// 3 down the lines with words. Lists and checklists keep their indent; headings and quotes start at the line's
    /// start. Blank lines stay blank unless the caret is on one alone.
    private static func restyle(_ s: NSString, _ sel: NSRange, _ style: MarkdownFormat) -> Edit {
        let picked = pieces(s, sel)
        let filled = picked.count == 1 ? picked : picked.filter { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
        let off = style != .body && !filled.isEmpty && filled.allSatisfy { lineStyle($0.body) == style }
        var number = 0
        return lines(s, sel) { line in
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let rest = String(line.dropFirst(indent.count))
            if picked.count > 1, rest.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            let words = bare(rest)
            if off { return indent + words }
            number += 1
            switch style {
            case .title: return "# " + words
            case .heading: return "## " + words
            case .subheading: return "### " + words
            case .bullets: return indent + "- " + words
            case .dashes: return indent + "+ " + words
            case .numbers: return indent + "\(number). " + words
            case .quote: return "> " + words
            case .checklist: return indent + "- [ ] " + words
            default: return indent + words
            }
        }
    }

    /// A line's words with the marks it starts with taken off: a quote's `>`s, then a heading's `#`s or a list or check mark.
    private static func bare(_ line: String) -> String {
        var rest = line
        while has(rest, quoteMark) { rest = strip(rest, quoteMark) }
        return strip(strip(rest, headingMark), listMark)
    }

    /// The paragraph style a line is in, its indent aside, or the checklist (which the Aa menu does not list).
    static func lineStyle(_ line: String) -> MarkdownFormat {
        let rest = String(line.drop { $0 == " " || $0 == "\t" })
        if has(rest, quoteMark) { return .quote }
        switch headingLevel(rest) {
        case 1: return .title
        case 2: return .heading
        case 3...: return .subheading
        default: break
        }
        if has(rest, checkMark) { return .checklist }
        if has(rest, dashMark) { return .dashes }
        if has(rest, bulletMark) { return .bullets }
        if has(rest, numberMark) { return .numbers }
        return .body
    }

    /// The paragraph style the selection's first line is in: Monostyled inside a fenced block (where Monostyled would
    /// take the fence off); the Aa menu ticks it.
    static func style(of text: String, selection sel: NSRange) -> MarkdownFormat? {
        let s = text as NSString
        guard sel.location <= s.length else { return nil }
        if unfence(s, sel) != nil { return .mono }
        return lineStyle(s.substring(with: s.lineRange(for: NSRange(location: sel.location, length: 0))))
    }

    /// `first`, then `next` on the text and selection it leaves, as one edit of `s`: the span the two changed.
    private static func then(_ s: NSString, _ first: Edit, _ next: (String, NSRange) -> Edit) -> Edit {
        let middle = s.replacingCharacters(in: first.range, with: first.replacement) as NSString
        let second = next(middle as String, first.selection)
        let end = middle.replacingCharacters(in: second.range, with: second.replacement) as NSString
        var head = 0
        while head < s.length, head < end.length, s.character(at: head) == end.character(at: head) { head += 1 }
        var tail = 0
        while tail < s.length - head, tail < end.length - head, s.character(at: s.length - 1 - tail) == end.character(at: end.length - 1 - tail) { tail += 1 }
        return Edit(range: NSRange(location: head, length: s.length - head - tail),
                    replacement: end.substring(with: NSRange(location: head, length: end.length - head - tail)), selection: second.selection)
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

    /// `open` and `close` round the words picked, or taken off when they already have them. Over lines, each line's words
    /// on their own (a mark never spans a line end), the marks coming off only when every line has them. Quiet lines are
    /// left alone.
    private static func inline(_ s: NSString, _ sel: NSRange, _ open: String, _ close: String, _ span: NSRegularExpression) -> Edit {
        let words = words(s, sel), one = !s.substring(with: words).contains("\n"), quiet = quiet(s, tables: !one)
        let each = pieces(s, words).compactMap { line -> (edit: Edit, off: Bool)? in
            let start = max(line.range.location, words.location), end = min(NSMaxRange(line.range), NSMaxRange(words))
            guard end >= start, !isQuiet(quiet, line.range) else { return nil }
            let picked = Self.words(s, NSRange(location: start, length: end - start))
            return one || picked.length > 0 ? wrap(s, picked, open, close, span) : nil
        }
        if one, let only = each.first { return only.edit }
        let off = !each.isEmpty && each.allSatisfy(\.off)
        let edits = each.filter { $0.off == off }.map { ($0.edit.range, $0.edit.replacement) }
        return edits.isEmpty ? unchanged(sel) : splice(s, edits)
    }

    /// No edit: the selection as it was.
    private static func unchanged(_ sel: NSRange) -> Edit { Edit(range: NSRange(location: sel.location, length: 0), replacement: "", selection: sel) }

    /// `open` and `close` round one line's words, or taken off (`off`) when they sit in a span the editor draws with them (`span`), the
    /// marks picked or not, other marks between; same-style spans inside the words merge into the one wrap. No selection
    /// types the pair with the caret between, and a second press takes the empty pair off. Never inside an address, nor
    /// bold or italic inside code (`snap`); italic takes whole words, as the editor draws no `_` inside or beside one.
    private static func wrap(_ s: NSString, _ sel: NSRange, _ open: String, _ close: String, _ span: NSRegularExpression) -> (edit: Edit, off: Bool) {
        func word(_ i: Int) -> Bool {
            guard i >= 0, i < s.length, let c = UnicodeScalar(s.character(at: i)) else { return false }
            return c == "_" || CharacterSet.alphanumerics.contains(c)
        }
        var sel = snap(s, sel, code: open != "`")
        let o = (open as NSString).length, c = (close as NSString).length
        let spans = span.matches(in: s as String, range: s.lineRange(for: sel)).map(\.range)
        // The empty pair, which no span matches: never part of a longer run of the mark (a fence's ```, `user__name`) unless
        // that is a span's own mark beside it (`**a**` then the pair), nor the end of one span and the start of the next
        // (`**a**|**b**`).
        func same(_ i: Int, _ mark: String) -> Bool { i >= 0 && i < s.length && s.character(at: i) == (mark as NSString).character(at: 0) }
        if sel.length == 0, sel.location >= o, sel.location + c <= s.length,
           s.substring(with: NSRange(location: sel.location - o, length: o + c)) == open + close,
           !same(sel.location - o - 1, open) || spans.contains(where: { NSMaxRange($0) == sel.location - o }),
           !same(sel.location + c, close) || spans.contains(where: { $0.location == sel.location + c }),
           !(open == "_" && word(sel.location - o - 1) && word(sel.location + c)),
           !spans.contains(where: { NSMaxRange($0) == sel.location || $0.location == sel.location }) {
            return (Edit(range: NSRange(location: sel.location - o, length: o + c), replacement: "", selection: NSRange(location: sel.location - o, length: 0)), true)
        }
        // `_` never opens or closes italic beside a word's letters: a caret touching a word takes the word.
        if open == "_", sel.length > 0 || word(sel.location - 1) || word(sel.location) {
            var start = sel.location, end = NSMaxRange(sel)
            while word(start - 1) { start -= 1 }
            while word(end) { end += 1 }
            // A word at an address's edge takes the whole address.
            sel = snap(s, NSRange(location: start, length: end - start), code: true)
        }
        let picked = s.substring(with: sel)
        let around = spans.first { r in
            sel.length > 0 ? holds(r, sel) : r.location + o <= sel.location && sel.location <= NSMaxRange(r) - c
        }
        if let around {
            let inner = NSRange(location: around.location + o, length: around.length - o - c)
            func moved(_ i: Int) -> Int { min(max(i, inner.location), NSMaxRange(inner)) - o }
            let start = moved(sel.location)
            return (Edit(range: around, replacement: s.substring(with: inner), selection: NSRange(location: start, length: moved(NSMaxRange(sel)) - start)), true)
        }
        let inside = sel.length > 0 ? spans.filter { NSIntersectionRange($0, sel).length > 0 } : []
        if !inside.isEmpty {
            let whole = inside.reduce(sel, NSUnionRange)
            var text = "", at = whole.location
            for r in inside {
                text += s.substring(with: NSRange(location: at, length: r.location - at)) + s.substring(with: NSRange(location: r.location + o, length: r.length - o - c))
                at = NSMaxRange(r)
            }
            text += s.substring(with: NSRange(location: at, length: NSMaxRange(whole) - at))
            return (Edit(range: whole, replacement: open + text + close, selection: NSRange(location: whole.location + o, length: (text as NSString).length)), false)
        }
        return (Edit(range: sel, replacement: open + picked + close, selection: NSRange(location: sel.location + o, length: sel.length)), false)
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
    /// A bulleted line's `- ` or `* `; `+ ` is the dashed list's.
    static let bulletMark = try! NSRegularExpression(pattern: #"^[-*][ \t]+(?!\[[ xX]\][ \t])"#)
    static let dashMark = try! NSRegularExpression(pattern: #"^\+[ \t]+(?!\[[ xX]\][ \t])"#)
    static let numberMark = try! NSRegularExpression(pattern: #"^\d+[.)][ \t]+"#)
    static let quoteMark = try! NSRegularExpression(pattern: #"^>[ \t]?"#)
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
