import PilotCore
import SwiftUI

/// An extension's detail in Instrument (card agent-bo-95423181, batch 7; ADR 0008's `extensionDetail`): the words in the
/// style's reading type (the notes panel's Instrument headings, body at a reading line, inline code on the raised fill,
/// fenced code in a sunk well, a rule a hairline, an image drawn, T31), and its metadata past a hairline as Raycast lays a
/// Detail's out (T31, RaycastMetadataColumn: at Raycast's share of the width, each title over its value, tags, links,
/// separators); an extension that sends flat facts gets them as labels. Each side scrolls on its own and every word can
/// be selected.
struct InstrumentExtensionDetail: View {
    let blocks: [DetailBlock]
    /// Its metadata's parts (T31, Extension.Detail.laidOut).
    let parts: [Extension.Detail.Part]
    /// A detail's own blocks (pilot-1-1 T9), drawn in place of its words, and where their actions go.
    var drawn: [Extension.Block] = []
    var act: (Extension.Item.Action) -> Void = { _ in }

    var body: some View {
        let hasBody = !blocks.isEmpty || !drawn.isEmpty, laid = parts
        GeometryReader { size in
            HStack(spacing: 0) {
                if !drawn.isEmpty { ExtensionDetailBlocks(blocks: drawn, act: act) } else if !blocks.isEmpty { ExtensionDetailWords(blocks: blocks) }
                if !laid.isEmpty {
                    if hasBody { InstrumentRule(vertical: true) }
                    RaycastMetadataColumn(parts: laid).frame(width: hasBody ? (size.size.width * RaycastLayout.metadataShare).rounded() : nil)
                }
            }
        }
    }
}

/// A detail's markdown in the style's reading type, scrolling on its own: the full detail's words and a list's side detail's.
struct ExtensionDetailWords: View {
    @Environment(\.style) private var style
    let blocks: [DetailBlock]

    var body: some View { words(MarkdownStyle(style: style)) }

    private func words(_ type: MarkdownStyle) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks.indices, id: \.self) { i in
                    block(blocks[i], type).padding(.top, i == 0 ? 0 : DetailBlock.gap(blocks[i - 1], blocks[i]))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 20, trailing: 22))
        }
    }

    @ViewBuilder private func block(_ block: DetailBlock, _ type: MarkdownStyle) -> some View {
        switch block {
        case .heading(let level, let text):
            let face = level == 1 ? type.h1 : level == 2 ? type.h2 : nil
            Text(inline(text)).font(Font(face?.font ?? type.bold)).tracking(face?.tracking ?? 0).foregroundStyle(style.color(\.text))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            prose(text)
        case .item(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(marker).styleText(\.body).foregroundStyle(style.color(\.text3)).frame(minWidth: 12, alignment: .leading)
                prose(text)
            }
        case .rule:
            InstrumentRule().accessibilityHidden(true)
        case .code(let text):
            Text(text).styleText(\.mono).lineSpacing(5).foregroundStyle(style.color(\.text)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .instrumentWell()
        case .image(let alt, let source):
            MarkdownImage(alt: alt, source: source)
        }
    }

    private func prose(_ text: String) -> some View {
        Text(inline(text)).styleText(\.body).lineSpacing(5).foregroundStyle(style.color(\.text))
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    /// Words with markdown's inline marks, inline code in the mono face on the raised fill, as a key chip sits.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let (font, fill) = (style.font(\.mono), style.color(\.raised))
        for range in styled.runs.filter({ $0.inlinePresentationIntent?.contains(.code) == true }).map(\.range) {
            styled[range].swiftUI.font = font
            styled[range].swiftUI.backgroundColor = fill
        }
        return styled
    }
}
