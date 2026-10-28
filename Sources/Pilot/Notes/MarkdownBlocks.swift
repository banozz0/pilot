import AppKit

/// The notes editor's blocks that span lines (Q114, Sven 2026-10-15): fenced code and tables, found in the text as typed.
/// Pure, so the live preview's passes and the tests read the same blocks.
enum MarkdownBlocks {
    /// A fenced code block: its fence lines (their words, no line end) and every line from the opening fence to the end
    /// of the closing one, its line end included. An unclosed fence runs to the end of the note.
    struct Fence: Equatable {
        var block: NSRange
        var open: NSRange
        var close: NSRange?
    }

    /// A table: its lines' words (no line ends), the second the `|---|` line under the header; `block` spans them all.
    struct Table: Equatable {
        var block: NSRange
        var rows: [NSRange]
    }

    private static let fenceLine = try! NSRegularExpression(pattern: #"^[ ]{0,3}(```|~~~)"#)
    private static let separator = try! NSRegularExpression(pattern: #"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)

    /// Each line's words and the line with its end, in order.
    static func lines(_ s: NSString) -> [(words: NSRange, line: NSRange)] {
        var out: [(NSRange, NSRange)] = []
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.byLines, .substringNotRequired]) { _, words, line, _ in
            out.append((words, line))
        }
        return out
    }

    static func fences(_ s: NSString) -> [Fence] {
        var found: [Fence] = []
        var open: (words: NSRange, line: NSRange, mark: String)?
        for (words, line) in lines(s) {
            let text = s.substring(with: words)
            guard let m = fenceLine.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { continue }
            let mark = (text as NSString).substring(with: m.range(at: 1))
            if let start = open {
                guard mark == start.mark else { continue }
                found.append(Fence(block: NSRange(location: start.line.location, length: NSMaxRange(line) - start.line.location), open: start.words, close: words))
                open = nil
            } else {
                open = (words, line, mark)
            }
        }
        if let start = open {
            found.append(Fence(block: NSRange(location: start.line.location, length: s.length - start.line.location), open: start.words, close: nil))
        }
        return found
    }

    /// Tables outside `skipping` (code blocks): a line starting with `|`, then a `|---|` line, then any further `|` lines.
    static func tables(_ s: NSString, skipping: [NSRange] = []) -> [Table] {
        let all = lines(s)
        func piped(_ i: Int) -> Bool {
            let words = all[i].words
            guard !skipping.contains(where: { NSIntersectionRange($0, all[i].line).length > 0 }) else { return false }
            return s.substring(with: words).trimmingCharacters(in: .whitespaces).hasPrefix("|")
        }
        func isSeparator(_ i: Int) -> Bool {
            let text = s.substring(with: all[i].words)
            return text.contains("-") && separator.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
        var found: [Table] = []
        var i = 0
        while i < all.count {
            guard i + 1 < all.count, piped(i), piped(i + 1), isSeparator(i + 1) else { i += 1; continue }
            var end = i + 2
            while end < all.count, piped(end), !isSeparator(end) { end += 1 }
            let rows = all[i..<end].map(\.words)
            let block = NSRange(location: all[i].line.location, length: NSMaxRange(all[end - 1].line) - all[i].line.location)
            found.append(Table(block: block, rows: rows))
            i = end
        }
        return found
    }

    /// A row's cells: each cell's words, trimmed of the spaces round them (empty at the cell's place when it has none).
    /// The pipes at either end bound the row; `\|` is a pipe in the words.
    static func cells(_ s: NSString, row: NSRange) -> [NSRange] {
        var pipes: [Int] = []
        var i = row.location
        while i < NSMaxRange(row) {
            let c = s.character(at: i)
            if c == 92 /* \ */ { i += 2; continue }
            if c == 124 /* | */ { pipes.append(i) }
            i += 1
        }
        let text = s.substring(with: row).trimmingCharacters(in: .whitespaces)
        var bounds = pipes
        if !text.hasPrefix("|") { bounds.insert(row.location - 1, at: 0) }
        if !text.hasSuffix("|") || bounds.count < 2 { bounds.append(NSMaxRange(row)) }
        var cells: [NSRange] = []
        for (a, b) in zip(bounds, bounds.dropFirst()) {
            var start = a + 1, end = b
            while start < end, [32, 9].contains(s.character(at: start)) { start += 1 }
            while end > start, [32, 9].contains(s.character(at: end - 1)) { end -= 1 }
            cells.append(NSRange(location: start, length: end - start))
        }
        return cells
    }
}

/// On a table's lines while it draws as a grid: where its column lines fall (from the text's left edge, the last its
/// right edge) and each row's characters, the `|---|` line second.
final class MarkdownTableGrid: NSObject {
    let columns: [CGFloat]
    let rows: [NSRange]

    init(columns: [CGFloat], rows: [NSRange]) {
        self.columns = columns
        self.rows = rows
    }
}

extension NSAttributedString.Key {
    /// Characters drawn as nothing and taking no room: a mark off the caret's line (live preview).
    static let notesHidden = NSAttributedString.Key("PilotNotesHidden")
    /// On a list's `-`, drawn clear: a dot is drawn in its place.
    static let notesBullet = NSAttributedString.Key("PilotNotesBullet")
    /// On a quote's lines, their ends included, so a quote's lines read as one callout.
    static let notesQuote = NSAttributedString.Key("PilotNotesQuote")
    /// On a fenced code block's lines: its start, so two blocks one under the other stay two panels.
    static let notesCodeBlock = NSAttributedString.Key("PilotNotesCodeBlock")
    /// On a table drawn as a grid: its MarkdownTableGrid.
    static let notesTable = NSAttributedString.Key("PilotNotesTable")
}
