import PilotCore
import SwiftUI

/// An extension's detail in the menu's panel, in place of the list (card agent-bo-95423245, ADR 0008's `extensionDetail`
/// surface), after Raycast's detail: its markdown, its facts in a quiet column beside it, each label over its value. Each
/// side scrolls on its own and every word can be selected; Return and Cmd+K are its row's, which the panel runs. A live
/// picker is always the wide panel, so the facts always fit beside the words. Instrument and Toybox draw their own
/// (InstrumentExtensionDetail, ToyExtensionDetail).
struct ExtensionDetailView: View, Equatable {
    let detail: Extension.Detail

    /// The same detail draws the same, so a menu redraw (a pointer move, a Cmd+K filter) never splits its markdown again.
    nonisolated static func == (a: Self, b: Self) -> Bool { a.detail == b.detail }

    /// The facts' column; the words take the rest of the panel.
    static let factsWidth: CGFloat = 208

    var body: some View {
        DetailBody(detail: detail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .styled(.extensionDetail)
    }
}

/// The detail in the style styled(.extensionDetail) gives it: Instrument's or Toybox's own.
private struct DetailBody: View {
    @Environment(\.style) private var style
    let detail: Extension.Detail

    var body: some View {
        let blocks = DetailBlock.split(detail.markdown), facts = detail.metadata
        if blocks.isEmpty, facts.isEmpty {
            nothing
        } else if style.kind == .instrument {
            InstrumentExtensionDetail(blocks: blocks, facts: facts)
        } else {
            ToyExtensionDetail(blocks: blocks, facts: facts)
        }
    }

    /// An empty detail, said as the menu says an empty list.
    private var nothing: some View {
        PanelEmptyText(text: "Nothing to show. The command sent an empty detail.").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A detail's markdown cut into what ExtensionDetailView draws: Quick AI's fenced code apart from its prose
/// (AnswerBlock), and in the prose each heading (`#` to `######`), list item (`-`, `*`, `+` or `1.`), rule (`---`) and
/// paragraph apart. A paragraph's lines join as CommonMark joins them, with a space, unless a line ends in two spaces or
/// a backslash; an indented line under an item carries on that item.
enum DetailBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case item(marker: String, text: String)
    case rule
    case code(String)

    /// The room over `block` after `above`: a heading more over it than under it, a list's items closer than paragraphs.
    static func gap(_ above: DetailBlock, _ block: DetailBlock) -> CGFloat {
        if case .heading = block { return 22 }
        if case .heading = above { return 8 }
        if case .item = above, case .item = block { return 5 }
        return 14
    }

    static func split(_ markdown: String) -> [DetailBlock] {
        AnswerBlock.split(markdown).flatMap { block -> [DetailBlock] in
            switch block {
            case .code(let text): [.code(text)]
            case .prose(let text): lines(text)
            }
        }
    }

    private static func lines(_ prose: String) -> [DetailBlock] {
        var blocks: [DetailBlock] = [], paragraph = "", breaks = false
        func close() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)) }
            paragraph = ""
            breaks = false
        }
        for line in prose.split(separator: "\n", omittingEmptySubsequences: false) {
            let bare = line.trimmingCharacters(in: .whitespaces)
            if bare.isEmpty { close(); continue }
            // A rule before an item, so `* * *` is a rule.
            if let block = heading(bare) ?? rule(bare) ?? item(bare) { close(); blocks.append(block); continue }
            if paragraph.isEmpty, line.first?.isWhitespace == true, case .item(let marker, let text) = blocks.last {
                blocks[blocks.count - 1] = .item(marker: marker, text: text + " " + bare)
                continue
            }
            let words = bare.hasSuffix("\\") ? String(bare.dropLast()) : bare
            paragraph += paragraph.isEmpty ? words : (breaks ? "\n" : " ") + words
            breaks = line.hasSuffix("  ") || bare.hasSuffix("\\")
        }
        close()
        return blocks
    }

    /// `# Title` to `###### Title` as the notes panel matches it (MarkdownMarks), its closing hashes dropped.
    private static func heading(_ line: String) -> DetailBlock? {
        guard let match = MarkdownMarks.heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let hashes = Range(match.range(at: 1), in: line) else { return nil }
        let text = line[hashes.upperBound...].trimmingCharacters(in: .whitespaces).replacing(/\s+#+$/, with: "")
        return text.isEmpty ? nil : .heading(level: line.distance(from: hashes.lowerBound, to: hashes.upperBound), text: text)
    }

    /// Three or more of one of `-`, `*` or `_`, spaces between allowed.
    private static func rule(_ line: String) -> DetailBlock? {
        let marks = line.filter { !$0.isWhitespace }
        guard let mark = marks.first, "-*_".contains(mark), marks.count >= 3, marks.allSatisfy({ $0 == mark }) else { return nil }
        return .rule
    }

    /// A list line as the notes panel matches it (MarkdownMarks): `-`, `*` or `+` as a bullet, `1.` or `1)` as its number.
    private static func item(_ line: String) -> DetailBlock? {
        guard let match = MarkdownMarks.list.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let marker = Range(match.range(at: 2), in: line), let whole = Range(match.range, in: line) else { return nil }
        let mark = line[marker]
        return .item(marker: "-*+".contains(mark) ? "•" : mark.dropLast() + ".", text: line[whole.upperBound...].trimmingCharacters(in: .whitespaces))
    }
}

/// An answer cut at its code fences: prose between them, code inside. A fence still open while Claude writes holds the
/// rest, so code streams into its block.
enum AnswerBlock: Equatable {
    case prose(String)
    case code(String)

    static func split(_ answer: String) -> [AnswerBlock] {
        var blocks: [AnswerBlock] = [], lines: [Substring] = [], inCode = false
        func close() {
            let text = lines.joined(separator: "\n")
            if inCode { blocks.append(.code(text)) } else {
                let prose = text.trimmingCharacters(in: .newlines)
                if !prose.isEmpty { blocks.append(.prose(prose)) }
            }
            lines = []
        }
        for line in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.drop(while: { $0 == " " }).hasPrefix("```") { close(); inCode.toggle() } else { lines.append(line) }
        }
        close()
        return blocks
    }
}
