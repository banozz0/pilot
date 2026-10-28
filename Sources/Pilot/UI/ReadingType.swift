import PilotCore
import SwiftUI

/// Pilot's reading type for markdown's inline marks in a panel: inline code in the mono face on a faint fill. An
/// extension's markdown blocks (BlockMarkdown) set their words with it.
@MainActor
struct ReadingType {
    private var codeFace: Font { Theme.mono(12.5) }
    /// Code's fill.
    private var codeFill: Color { Theme.text.opacity(0.08) }

    /// Words with markdown's inline marks (bold, italic, links), inline code in the mono face on the faint fill.
    func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let (font, fill) = (codeFace, codeFill)
        for range in styled.runs.filter({ $0.inlinePresentationIntent?.contains(.code) == true }).map(\.range) {
            styled[range].swiftUI.font = font
            styled[range].swiftUI.backgroundColor = fill
        }
        return styled
    }
}
