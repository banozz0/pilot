import SwiftUI

// The ⓘ that says what a setting does (card agent-bo-95422898, design round 4 section 7), and the fold that opens on a
// click anywhere on its line.

/// A fold's line: a chevron that turns, then its title, the whole line one button. In place of a DisclosureGroup's label:
/// on macOS that turns only on its small chevron, so a click on the words did nothing (Sven's round 3 notes on build 2300,
/// Look's "› More"). `quiet` draws it small and muted, as a list's Hidden (N) line.
struct KitFoldLine: View {
    @Environment(\.ink) private var ink
    let title: String
    @Binding var open: Bool
    var quiet = false
    /// What VoiceOver reads, when it differs from the title.
    var spoken: String? = nil

    var body: some View {
        Button { withAnimation(Kit.change) { open.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).font(ink.system(9, weight: .bold))
                Text(title)
                Spacer(minLength: 0)
            }
            .font(quiet ? ink.ui(12, .semibold) : ink.ui(13)).foregroundStyle(quiet ? ink.muted : ink.text)
            .frame(minHeight: 24).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken ?? title).accessibilityValue(open ? "shown" : "folded")
    }
}

/// A fold in place of a DisclosureGroup: its line (KitFoldLine), then while open its content, set in under the chevron.
/// It keeps its own open state unless `open` is given; a click redraws only the fold.
struct KitFold<Content: View>: View {
    let title: String
    var open: Binding<Bool>? = nil
    @ViewBuilder var content: Content
    @State private var own = false

    var body: some View {
        let isOpen = open ?? $own
        VStack(alignment: .leading, spacing: 6) {
            KitFoldLine(title: title, open: isOpen)
            if isOpen.wrappedValue {
                VStack(alignment: .leading, spacing: 6) { content }.padding(.leading, 15)
            }
        }
    }
}

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
