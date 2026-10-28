import Clipboard
import SwiftUI

/// The clipboard preview's highlight (Sven, 2026-10-10; Maccy's search highlight, MIT, is the reference): every searched
/// word lit where the preview shows it, by the search's own matching (ClipQuery.highlights), the first one scrolled into
/// view, and on an image that matched through the text read from it, a box over each place the word is written.
enum ClipHighlight {
    /// The id a preview's scroll view scrolls to: the part of the text that starts near its first match.
    static let first = "clip-first-match"

    /// `text` with each searched word on a wash of `lit`.
    static func lit(_ text: some StringProtocol, _ query: ClipQuery, _ lit: Color) -> AttributedString {
        let text = String(text)
        var attributed = AttributedString(text)
        for range in query.highlights(in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = lit.opacity(0.35)
        }
        return attributed
    }

    /// `text` cut where the line two above its first match starts, so scrolling that line to the top shows the match
    /// with its context; nil when the first match is on one of the first three lines, or there is none.
    static func cut(_ text: String, _ query: ClipQuery) -> (head: String, tail: String)? {
        guard let first = query.highlights(in: text).map(\.lowerBound).min() else { return nil }
        let breaks = text[..<first].indices.filter { text[$0] == "\n" }
        guard breaks.count > 2 else { return nil }
        let cut = breaks[breaks.count - 3]
        return (String(text[..<cut]), String(text[text.index(after: cut)...]))
    }
}

/// A preview's text lit by the search, in the layout's face (`face`), cut in two near the first match so its scroll
/// view (`scrollsToFirstMatch`) can bring it into view; `spacing` is the face's line spacing, kept at the cut.
struct LitText<Face: View>: View {
    let text: String
    let query: ClipQuery
    let lit: Color
    let spacing: CGFloat
    @ViewBuilder let face: (Text) -> Face

    var body: some View {
        if let cut = ClipHighlight.cut(text, query) {
            VStack(alignment: .leading, spacing: spacing) {
                face(Text(ClipHighlight.lit(cut.head, query, lit)))
                face(Text(ClipHighlight.lit(cut.tail, query, lit))).id(ClipHighlight.first)
            }
        } else {
            face(Text(ClipHighlight.lit(text, query, lit)))
        }
    }
}

extension View {
    /// A scroll view holding a LitText starts at the top for each text and search, then scrolls a cut text's first
    /// match into view.
    func scrollsToFirstMatch(_ text: String, _ query: ClipQuery) -> some View {
        ScrollViewReader { proxy in
            id(query.words.joined(separator: "\n") + "\u{0}" + text)
                .onAppear { if ClipHighlight.cut(text, query) != nil { proxy.scrollTo(ClipHighlight.first, anchor: .top) } }
        }
    }

    /// An image preview with a box in `lit` over each place a searched word is written (`boxes`: 0 to 1, origin top left).
    func litBoxes(_ boxes: [CGRect], _ lit: Color) -> some View {
        overlay {
            GeometryReader { geometry in
                let size = geometry.size
                ForEach(boxes.indices, id: \.self) { index in
                    let box = boxes[index]
                    let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    shape.fill(lit.opacity(0.3)).overlay { shape.strokeBorder(lit, lineWidth: 1.5) }
                        .frame(width: box.width * size.width + 4, height: box.height * size.height + 4)
                        .position(x: box.midX * size.width, y: box.midY * size.height)
                }
            }
            .accessibilityHidden(true)
        }
    }
}
