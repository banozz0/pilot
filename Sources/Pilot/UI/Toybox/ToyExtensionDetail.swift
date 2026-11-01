import PilotCore
import SwiftUI

/// An extension's detail in Toybox (card agent-bo-95423182, batch 7; ADR 0008's `extensionDetail`), the notes panel's
/// language: the words in Nunito with Fredoka headings (MarkdownStyle(style:)), inline code in mono on the sun's soft
/// fill, fenced code on a sunk well in the ink outline, a rule the ink's; the facts on the sunk fill past an ink rule, each
/// label an eyebrow over its value. Each side scrolls on its own and every word can be selected.
struct ToyExtensionDetail: View {
    @Environment(\.style) private var style
    let blocks: [DetailBlock]
    let facts: [Extension.Detail.Fact]
    /// A detail's own blocks (pilot-1-1 T9), drawn in place of its words, and where their actions go.
    var drawn: [Extension.Block] = []
    var act: (Extension.Item.Action) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            let hasBody = !blocks.isEmpty || !drawn.isEmpty
            if !drawn.isEmpty { ExtensionDetailBlocks(blocks: drawn, act: act) } else if !blocks.isEmpty { words(MarkdownStyle(style: style)) }
            if !facts.isEmpty {
                if hasBody { ToyRule(vertical: true) }
                factsColumn.frame(width: hasBody ? ExtensionDetailView.factsWidth : nil).background(style.color(\.sunken))
            }
        }
    }

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
                Text(marker).font(style.toyNunito(800, 14)).foregroundStyle(style.color(\.text3)).frame(minWidth: 12, alignment: .leading)
                prose(text)
            }
        case .rule:
            ToyRule().accessibilityHidden(true)
        case .code(let text):
            Text(text).font(style.toyMono(12.5)).lineSpacing(5).foregroundStyle(style.color(\.text)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .toyWell(radius: 14)
        }
    }

    private func prose(_ text: String) -> some View {
        Text(inline(text)).font(style.toyNunito(700, 14)).lineSpacing(5).foregroundStyle(style.color(\.text))
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    /// Words with markdown's inline marks, inline code in mono on the sun's soft fill.
    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let (font, fill) = (style.toyMono(12.5), style.color(\.accentSoft))
        for range in styled.runs.filter({ $0.inlinePresentationIntent?.contains(.code) == true }).map(\.range) {
            styled[range].swiftUI.font = font
            styled[range].swiftUI.backgroundColor = fill
        }
        return styled
    }

    private var factsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(facts.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        ToyEyebrow(text: facts[i].label)
                        Text(facts[i].text).font(style.toyNunito(700, 13.5)).foregroundStyle(style.color(\.text))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(EdgeInsets(top: 18, leading: 18, bottom: 16, trailing: 18))
        }
    }
}
