import AppKit
import PilotCore
import SwiftUI

// Surfaces v2, P3 (SPEC story 165): the blocks and row parts an extension's popover or page takes input with: a chat, a
// reply box, a row's badges and inline buttons, and a run's ask, drawn in the row itself, never a modal.

/// A chat block: the user's turns on the right in the accent, the assistant's on the left as markdown, tool turns one grey
/// line; "Working…" under them while the agent works.
struct ExtensionChatView: View {
    @Environment(\.ink) private var ink
    let chat: Extension.Block.Chat
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            let shown = chat.shown
            if shown.isEmpty { Text("No messages yet.").font(ink.ui(compact ? 12 : 13)).foregroundStyle(ink.muted) }
            ForEach(shown.indices, id: \.self) { message(shown[$0]) }
            if chat.working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Working…")
                }
                .font(ink.ui(compact ? 11 : 12)).foregroundStyle(ink.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func message(_ message: Extension.Block.Chat.Message) -> some View {
        switch message.role {
        case .tool:
            Text(message.text).font(ink.ui(compact ? 11 : 12)).foregroundStyle(ink.muted).lineLimit(1).padding(.horizontal, 9)
        case .user:
            HStack {
                Spacer(minLength: compact ? 28 : 60)
                bubble(message) { Text(message.text).foregroundStyle(ink.onAccent).textSelection(.enabled) }
                    .background(ink.accent, in: UnevenRoundedRectangle(cornerRadii: corners(user: true), style: .continuous))
            }
        case .assistant:
            HStack {
                bubble(message) { BlockMarkdown(text: message.text, compact: true).equatable() }
                    .background(ink.well, in: UnevenRoundedRectangle(cornerRadii: corners(user: false), style: .continuous))
                Spacer(minLength: compact ? 28 : 60)
            }
        }
    }

    private func bubble(_ message: Extension.Block.Chat.Message, @ViewBuilder text: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            text().fixedSize(horizontal: false, vertical: true)
            if let at = message.at {
                Text(at.formatted(date: .omitted, time: .shortened)).font(ink.ui(10)).opacity(0.65)
                    .foregroundStyle(message.role == .user ? ink.onAccent : ink.muted)
            }
        }
        .font(ink.ui(compact ? 12 : 13))
        .padding(.horizontal, 9).padding(.vertical, 6)
    }

    /// A speech bubble's corners: round but the one at its speaker's foot.
    private func corners(user: Bool) -> RectangleCornerRadii {
        RectangleCornerRadii(topLeading: 11, bottomLeading: user ? 11 : 4, bottomTrailing: user ? 4 : 11, topTrailing: 11)
    }
}

/// An input block: a field and a send button; Return runs its action, Option+Return its alt, the text handed on as
/// `"input"`, then the field empties. A live one on a page (`typed`, 2026-10-17) runs its action as the text changes,
/// once typing pauses, Return at once, and keeps its text.
struct ExtensionInputView: View {
    @Environment(\.ink) private var ink
    let input: Extension.Block.Input
    var compact = false
    var typed: ((Extension.Item.Action, Duration?) -> Void)?
    let act: (Extension.Item.Action) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ReturnField(text: $text, placeholder: input.placeholder ?? "Reply…", size: compact ? 12.5 : 13, ink: ink,
                            submit: { send(alt: $0) })
                Button { send(alt: false) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(ink.onAccent)
                        .frame(width: 22, height: 22).background(ink.accent, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(input.action.label)
                .accessibilityLabel(input.action.title ?? "Send")
            }
            .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 5)
            .background(ink.well, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ink.accent.opacity(0.55)))
            Text(hint).font(ink.ui(compact ? 10.5 : 11)).foregroundStyle(ink.muted).lineLimit(1)
        }
        .onChange(of: text) { typed?(input.typed(text), input.live) }
    }

    /// "↩ Send · ⌥↩ Interrupt", by the actions' titles; a live box's "Search as you type".
    private var hint: String {
        [typed == nil ? "↩ \(input.action.title ?? "send")" : "\(input.action.title ?? "Runs") as you type",
         input.alt.map { "⌥↩ \($0.title ?? "alt")" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func send(alt: Bool) {
        if let typed, !alt { return typed(input.typed(text), nil) }
        guard let action = input.submit(text, alt: alt) else { return }
        text = ""
        act(action)
    }
}

/// A row's badges: up to three short words, each in its tone (none: muted).
struct ExtensionBadges: View {
    @Environment(\.ink) private var ink
    let badges: [Extension.Item.Badge]
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(badges.indices, id: \.self) { i in
                let colour = ink.tone(badges[i].tone, else: ink.muted)
                Text(badges[i].text).font(ink.ui(compact ? 10 : 10.5, .medium)).foregroundStyle(colour).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(colour.opacity(0.14), in: .rect(cornerRadius: 4))
            }
        }
        .fixedSize()
    }
}

/// A row's inline button: its icon from Pilot's list (Kit's IconButton) or its emoji, its title when it has neither; the
/// title its tooltip.
struct ExtensionInlineButton: View {
    @Environment(\.ink) private var ink
    let action: Extension.Item.Action
    var compact = false
    let tap: () -> Void

    var body: some View {
        if let icon = action.icon, let symbol = Extension.Item.Action.icons[icon] {
            IconButton(symbol: symbol, label: action.label, size: compact ? 22 : 26, glyph: compact ? 11 : 13,
                       tint: action.destructive ? ink.destructive : nil, action: tap)
        } else {
            Button(action: tap) {
                Text(action.icon ?? action.label).font(action.icon == nil ? ink.ui(compact ? 11 : 12) : .system(size: compact ? 12 : 13))
                    .foregroundStyle(action.destructive ? ink.destructive : ink.text)
                    .padding(.horizontal, action.icon == nil ? 6 : 0)
                    .frame(minWidth: compact ? 22 : 26, minHeight: compact ? 22 : 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.kitPress)
            .help(action.label)
            .accessibilityLabel(action.label)
        }
    }
}

/// A run's ask, in place of its row or button row: a field (Return or Save runs, Esc cancels), its choices, or its
/// question with the action's own word (red when it ends something) and Cancel.
struct ExtensionAskView: View {
    @Environment(\.ink) private var ink
    @State var asking: Extension.Asking
    var compact = false
    /// The answered action to run, or nil: cancelled.
    let done: (Extension.Item.Action?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch asking.ask {
            case .text:
                ReturnField(text: $asking.text, placeholder: asking.action.label, size: compact ? 12 : 13, ink: ink, focus: true,
                            submit: { _ in save() }, cancel: { done(nil) })
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(ink.well, in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.accent))
                button("Save", primary: true) { save() }
            case .choices(let choices):
                Text(asking.action.label).foregroundStyle(ink.muted).lineLimit(1)
                Spacer(minLength: 4)
                ForEach(choices.indices, id: \.self) { i in button(choices[i].title, primary: false) { done(asking.pick(choices[i])) } }
            case .confirm(let question):
                Text(question).foregroundStyle(ink.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                button(asking.yes, primary: true, destructive: asking.action.destructive) { done(asking.save()) }
            }
            button("Cancel", primary: false) { done(nil) }.keyboardShortcut(.cancelAction)
        }
        .font(ink.ui(compact ? 12 : 13))
    }

    private func save() {
        guard let answered = asking.save() else { return }
        done(answered)
    }

    /// The style's own buttons; a destructive confirm is the style's primary filled red, so it keeps Cancel's size.
    private func button(_ title: String, primary: Bool, destructive: Bool = false, run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(PilotButtonStyle(primary: primary, destructive: destructive)).fixedSize()
    }
}

/// A one-line text field that tells Return from Option+Return (an NSTextField's field editor sends them as two commands)
/// and hands Esc to `cancel`; `focus` takes the keyboard as it shows. In a popover it types because BarPanel is a key panel.
struct ReturnField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String, size: CGFloat, ink: Ink
    var focus = false
    /// Return (false) or Option+Return (true).
    let submit: (Bool) -> Void
    var cancel: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusField {
        let field = FocusField()
        field.focusOnShow = focus
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FocusField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        // The look is set again only when it changes, not on each keystroke.
        let look = Coordinator.Look(size: size * ink.style.scale, text: NSColor(ink.text), muted: NSColor(ink.muted), placeholder: placeholder)
        guard look != context.coordinator.look else { return }
        context.coordinator.look = look
        let font = NSFont.systemFont(ofSize: look.size)
        field.font = font
        field.textColor = look.text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: look.muted, .font: font])
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        struct Look: Equatable { let size: CGFloat, text: NSColor, muted: NSColor, placeholder: String }
        var parent: ReturnField
        var look: Look?
        init(_ parent: ReturnField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            if field.stringValue.count > Extension.Item.Action.longest { field.stringValue = String(field.stringValue.prefix(Extension.Item.Action.longest)) }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.submit(false)
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): parent.submit(true)
            case #selector(NSResponder.cancelOperation(_:)):
                guard let cancel = parent.cancel else { return false }
                cancel()
            default: return false
            }
            return true
        }
    }

    final class FocusField: NSTextField {
        var focusOnShow = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if focusOnShow, let window { window.makeFirstResponder(self) }
        }
    }
}
