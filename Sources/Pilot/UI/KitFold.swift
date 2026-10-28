import SwiftUI

// The ⓘ that says what a setting does (card agent-bo-95422898, design round 4 section 7).

/// What a setting does, as an ⓘ beside it (section 7 drops the paragraphs; Look's rows, Sven 2026-10-09): one or two
/// plain lines in a popover once the pointer rests on it, or on a click. Any settings row can put one after its label;
/// the glyph and the words are the style's, the popover a floating surface.
struct InfoMark: View {
    @Environment(\.ink) private var ink
    let text: String
    @State private var open = false
    /// The pointer over the glyph: a pass over it opens nothing, and leaving closes after a beat.
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle").font(ink.ui(12)).foregroundStyle(ink.muted).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard hovering != open else { return }
            try? await Task.sleep(for: .milliseconds(hovering ? 350 : 150))
            if !Task.isCancelled { open = hovering }
        }
        .accessibilityLabel(text)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Text(text).font(ink.ui(12)).foregroundStyle(ink.text2)
                .fixedSize(horizontal: false, vertical: true).frame(width: 260, alignment: .leading).padding(12)
                .floating()
        }
    }
}
