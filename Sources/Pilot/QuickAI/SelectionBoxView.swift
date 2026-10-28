import PilotCore
import SwiftUI

/// The chat bubble's face (Sven Q217, after SuperCmd's Quick Prompt): Ask AI's sparkle, the provider and a close X; the
/// selection quoted under it; the rewrite chips until the first message, "…" swapping in the rest; then the turns as
/// Ask AI draws them; a rewrite's answer gets Replace (⌘Return), Copy and Re-prompt; Ask AI's input at the foot. In the
/// style's Ink, ground and corner.
struct SelectionBoxView: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    @Bindable var model: SelectionBoxModel
    var send: (SelectionPrompt.Preset) -> Void = { _ in }
    var sendDraft: () -> Void = {}
    var replace: () -> Void = {}
    var copy: () -> Void = {}
    var reprompt: () -> Void = {}
    var close: () -> Void = {}

    static let placeholder = "Ask about the selection, or pick a rewrite"

    /// A chip's and a button's ground: Toybox's raised fill is its panel's white, so it takes the sun's soft fill.
    private var fill: Color { style.kind == .toybox ? ink.selection : ink.selected }

    var body: some View {
        let radius = CGFloat(style.radii.pop)
        VStack(alignment: .leading, spacing: 0) {
            header
            quote
            ink.line.frame(height: 1)
            if model.started {
                AIChatTranscript(model: model.chat, inset: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)) { EmptyView() }
                    .frame(maxHeight: .infinity)
                if model.replaces {
                    ink.line.frame(height: 1)
                    rewriteBar
                }
            } else {
                chips
            }
            ink.line.frame(height: 1)
            AIChatInput(model: model.chat, send: sendDraft, placeholder: model.started ? "Ask a follow-up" : Self.placeholder)
        }
        .background(ink.surface, in: .rect(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ink.windowLine, lineWidth: ink.stroke))
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: BarParts.dropSymbol(.askAI)).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink.accentInk)
                .accessibilityHidden(true)
            Text("Ask AI").font(ink.ui(13, .semibold)).foregroundStyle(ink.text)
            Text(model.chat.route).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
            Spacer(minLength: 0)
            Text("esc close").font(ink.ui(11.5)).foregroundStyle(ink.muted)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(ink.muted)
                    .frame(width: 22, height: 22).background(fill, in: .circle)
            }
            .buttonStyle(.plain).help("Close (esc)").accessibilityLabel("Close")
        }
        .padding(.horizontal, 14).frame(height: 40)
    }

    /// The selection, two lines before the first message and one after: what every answer is about.
    private var quote: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(ink.accent).frame(width: 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.quote).font(ink.ui(12.5)).foregroundStyle(ink.text.opacity(0.8))
                    .lineLimit(model.started ? 1 : 2).truncationMode(.tail)
                Text("Selected in \(model.app) · \(model.characters) characters").font(ink.ui(11)).foregroundStyle(ink.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14).padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(model.more ? SelectionPrompt.more : SelectionPrompt.chips) { preset in
                chip(preset.label) { send(preset) }
            }
            chip(model.more ? "‹" : "…") { model.more.toggle() }
                .help(model.more ? "Back to the first rewrites" : "More: Expand, Friendlier")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(height: 50)
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(ink.ui(12.5, .medium)).foregroundStyle(ink.text).lineLimit(1).fixedSize()
                .padding(.horizontal, 10).frame(height: 28)
                .background(fill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private var rewriteBar: some View {
        HStack(spacing: 8) {
            action("Replace", key: "⌘↩", primary: true, run: replace)
            action("Copy", run: copy)
            action("Re-prompt", run: reprompt).help("Puts the instruction back in the input to edit and run again")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(height: 48)
    }

    private func action(_ title: String, key: String? = nil, primary: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 6) {
                Text(title).font(ink.ui(13, .semibold))
                if let key { Text(key).font(ink.ui(11.5)).opacity(0.7) }
            }
            .foregroundStyle(primary ? ink.onAccent : ink.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(primary ? ink.accent : fill, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
