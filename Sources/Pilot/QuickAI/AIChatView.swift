import PilotCore
import SwiftUI

/// The AI chat panel's face (story 166), Ask AI's bar drop: hung from the top bar, square at the top and round at the
/// bottom; the drops' header (BarDropHeader: `✦ Ask AI  Claude Code · Sonnet`, `esc close`, `⌘N new chat`; spec Bar
/// drops T8), no rule under it (the turns fade out beneath), the turns (AIChatTranscript), and the input at the foot with
/// Send, or Stop while an answer streams. One layout in every style, in that style's Ink and corner. Opened as a sliding
/// drop, its contents fade in under the slide (BarDropMotion) while its ground and edge come whole. The AI page draws the
/// same turns and input on its own card (T13), so the two show one conversation one way.
struct AIChatView: View {
    @Environment(\.ink) private var ink
    let model: AIChatModel
    var send: () -> Void = {}
    var newChat: () -> Void = {}
    /// The header's close: Ask AI's drop closes, as Escape closes it.
    var close: () -> Void = { BarDrops.shared.close(.askAI) }
    /// The notch's corner (AIChatPanel.radius), the glass's too.
    let radius: CGFloat
    /// Over Look's Glass: no ground of its own, the glass's tint carries it.
    var glass = false
    /// Made while its drop slides in: the contents fade in under the slide.
    private let fadesIn = BarDropMotion.opening
    @State private var entered = false

    static let hint = "Ask anything. Return sends, Shift+Return adds a line, Esc closes; ⌘N starts a new chat."

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
        VStack(spacing: 0) {
            BarDropHeader(symbol: BarParts.dropSymbol(.askAI), title: "Ask AI", detail: model.route, hints: [
                .init(key: "esc", label: "close", action: close),
                .init(key: "⌘N", label: "new chat", action: newChat, disabled: model.turns.isEmpty && !model.running),
            ])
            AIChatTranscript(model: model, inset: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
                Text(Self.hint).font(ink.ui(13)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            ink.line.frame(height: 1)
            AIChatInput(model: model, send: send)
        }
        .opacity(fadesIn && !entered ? 0 : 1)
        .onAppear { if fadesIn { withAnimation(BarDropMotion.contents) { entered = true } } }
        .background(glass ? .clear : ink.surface, in: shape)
        // Over the glass its own rim is the edge, and a hairline beside it read as a double outline (Sven on build 29).
        .overlay { if !glass { BarDropEdge(radius: radius).stroke(ink.windowLine, lineWidth: ink.stroke).padding(.horizontal, ink.stroke / 2).padding(.bottom, ink.stroke / 2) } }
        .clipShape(shape)
    }
}

/// The conversation as both chats draw it: the user's turns in a bubble on the right, the answers full width as the
/// extension chat draws markdown (BlockMarkdown) with Copy under each, the answer streaming in, and how the last turn
/// failed; `empty` before the first turn. The answers are rows, not bubbles, so the `pilot` commands an agent ran (T16)
/// drop in under the message that asked, one folded row each (AIChatCallRow). Drawn, it tells the model a surface shows
/// the chat, so the Allow gate asks on a row. On the page the turns keep a reading column
/// (`column`) in the middle of a wide window; the turns fade out under whatever sits above them.
struct AIChatTranscript<Empty: View>: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let model: AIChatModel
    var inset: EdgeInsets
    /// The turns' widest, centred; nil runs them edge to edge (the notch).
    var column: CGFloat?
    /// Before the first turn, `empty` sits in the middle (the page), not at the head of the turns (the notch's hint).
    var centresEmpty = false
    @ViewBuilder var empty: Empty

    var body: some View {
        Group {
            if centresEmpty && model.turns.isEmpty && !model.running && model.state == .idle {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                turns
            }
        }
        .onAppear { model.viewers += 1 }
        .onDisappear { model.viewers -= 1 }
    }

    private var turns: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.turns.isEmpty && !model.running && !centresEmpty { empty }
                // Each row carries its turn, never an index back into the list: New chat empties it while rows still draw.
                ForEach(Array(model.turns.enumerated()), id: \.offset) { i, each in
                    turn(each)
                    AIChatCalls(model: model, calls: model.calls[i] ?? [], turn: i)
                }
                if model.running { AIChatStreaming(model: model) }
                if case .failed(let why) = model.state { failure(why) }
            }
            .frame(maxWidth: column ?? .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity)
            .padding(inset)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // No rule under the header (Sven on build 29): the turns fade out under it instead.
        .mask { VStack(spacing: 0) { LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Cut.fade); Color.black } }
    }

    @ViewBuilder private func turn(_ turn: AIChat.Turn) -> some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 64)
                VStack(alignment: .trailing, spacing: 6) {
                    if let image = turn.image { AIChatPicture(image: image, height: 120).equatable() }
                    Text(turn.text).font(ink.ui(13)).foregroundStyle(ink.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        // Toybox's raised fill is its panel's white, so its bubble takes the sun's soft fill.
                        .background(style.kind == .toybox ? ink.selection : ink.selected, in: .rect(cornerRadius: 12, style: .continuous))
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                BlockMarkdown(text: turn.text, compact: false).equatable()
                Button { SystemModule.copy(turn.text) } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(ink.ui(11.5)).foregroundStyle(ink.muted)
                }
                .buttonStyle(.plain).help("Copy this answer")
            }
        }
    }

    private func failure(_ why: QuickAI.Failure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(why.title).font(ink.ui(13, .semibold)).foregroundStyle(why == .cancelled ? ink.muted : ink.red)
            if let hint = why.hint {
                Text(hint).font(ink.ui(11.5)).foregroundStyle(ink.text2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A turn's `pilot` commands: those done fold into one quiet "Checked N things" row that a click unfolds (Sven,
/// 2026-10-23: seven raw lines before any answer), while one still running or asking Allow stays its own row, so its
/// spinner and the gate's question show. One done command alone keeps its own row.
struct AIChatCalls: View {
    @Environment(\.ink) private var ink
    let model: AIChatModel
    let calls: [AIChatModel.Call]
    let turn: Int

    var body: some View {
        let fold = "checked-\(turn)", open = model.unfolded.contains(fold)
        let (done, live) = (calls.filter { $0.result != nil && $0.asking == nil }, calls.filter { $0.result == nil || $0.asking != nil })
        let folds = done.count > 1
        if folds {
            Button { model.toggle(fold) } label: {
                HStack(spacing: 6) {
                    AIChatCallRow.chevron(open)
                    Text("Checked \(done.count) things").font(ink.ui(11.5))
                    if done.contains(where: \.failed) { AIChatCallRow.failedMark(ink) }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ink.muted).contentShape(.rect)
            }
            .buttonStyle(.plain).help(open ? "Fold" : "Show the commands")
            .accessibilityLabel("Checked \(done.count) things")
        }
        ForEach(folds && !open ? live : calls) { call in
            AIChatCallRow(model: model, call: call, open: model.unfolded.contains(call.id)).equatable()
        }
    }
}

/// One `pilot` command an agent ran, folded to one grey line as the extension chat folds a tool turn (ADR 0010): the
/// command whole on one line, a spinner while it runs and a mark when it failed; a click unfolds what came back. While
/// the Allow gate asks about it, the question sits under it: who asks, the exact thing with every hidden character written
/// out, Deny first and primary, then Allow; a plan's question (`pilot plan apply`) draws as its card (AIPlanCard). No key
/// answers it, so Return in the input never allows.
struct AIChatCallRow: View, Equatable {
    @Environment(\.ink) private var ink
    let model: AIChatModel
    let call: AIChatModel.Call
    let open: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool { a.call == b.call && a.open == b.open }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if call.result != nil { model.toggle(call.id) } } label: {
                HStack(spacing: 6) {
                    Self.chevron(open)
                    Text(call.command).font(ink.mono(11.5)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if call.result == nil, call.asking == nil {
                        ProgressView().controlSize(.mini)
                    } else if call.failed {
                        Self.failedMark(ink)
                    }
                }
                .foregroundStyle(ink.muted).contentShape(.rect)
            }
            .buttonStyle(.plain).help(call.result == nil ? "Running" : open ? "Fold" : "Show what came back")
            .accessibilityLabel("Ran \(call.command)")
            if open, let result = call.result {
                Text(result.isEmpty ? "(nothing came back)" : result).font(ink.mono(11)).foregroundStyle(call.failed ? ink.red : ink.text2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(ink.well, in: .rect(cornerRadius: 6))
            }
            if let asking = call.asking {
                if asking.ask.rows.isEmpty { ask(asking) } else { AIPlanCard(asking: asking) { model.answer($0, asked: asking.asked) } }
            }
        }
    }

    static func chevron(_ open: Bool) -> some View {
        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .semibold)).frame(width: 10)
    }

    static func failedMark(_ ink: Ink) -> some View {
        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(ink.red)
    }

    private func ask(_ asking: AIChatModel.Asking) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AllowPromptView.question(asking.program)).font(ink.ui(13, .semibold)).foregroundStyle(ink.text)
            Text(AllowPromptView.thing(asking.ask))
                .font(ink.mono(11.5)).foregroundStyle(ink.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(AllowPromptView.warning).font(ink.ui(11.5)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Deny") { model.answer(false, asked: asking.asked) }.buttonStyle(PilotButtonStyle(primary: true)).fixedSize()
                Button("Allow") { model.answer(true, asked: asking.asked) }.buttonStyle(PilotButtonStyle(primary: false)).fixedSize()
            }
            .padding(.top, 2)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(ink.well, in: .rect(cornerRadius: ink.blockRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous).strokeBorder(ink.accent.opacity(0.55), lineWidth: ink.stroke) }
    }
}

/// The answer as it streams in, the caret after it.
private struct AIChatStreaming: View {
    @Environment(\.ink) private var ink
    let model: AIChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.streaming.isEmpty { BlockMarkdown(text: model.streaming, compact: false) }
            Text(model.streaming.isEmpty ? "Thinking ▍" : "▍").font(ink.ui(13)).foregroundStyle(model.streaming.isEmpty ? ink.muted : ink.accent)
        }
    }
}

/// The input and its Send or Stop. The notch's runs flat along its foot under a rule; the page's (`boxed`) is a field of
/// its own, the send inside it, so it reads as the one place to type.
struct AIChatInput: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    @Bindable var model: AIChatModel
    let send: () -> Void
    var boxed = false
    var placeholder = "Ask anything"
    /// The page's hold on the field, so a picked skill puts the caret after its starter.
    var focus: FocusState<Bool>.Binding?
    /// The page's Skills (P29): the bubble and its list; none in the notch.
    var skills: [AISkill] = []
    /// How tall the Skills list may rise over the chat above the input.
    var room: CGFloat = 430
    /// Told whether the Skills list is open, so the page's empty chat steps back behind it.
    var listOpen: Binding<Bool>?
    @State private var selection: TextSelection?
    /// The bubble opened the list, its own search field first; else a / typed at the start of the field opens the list.
    /// A flag beside a plain String, never `Binding($optional)`: that binding force-unwraps on every read, and the list
    /// still read it after a pick set the search back to nil, which quit Pilot (Build 74).
    @State private var open = false
    @State private var search = ""
    /// Escape closed the typed /'s list until the field changes.
    @State private var closed = false
    @State private var picked = 0
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let picture = model.attachment {
                AIChatAttachment(model: model, picture: picture, send: send)
                    .padding(boxed ? EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0) : EdgeInsets(top: 10, leading: 18, bottom: 0, trailing: 18))
            }
            if let shown {
                // No height of its own: the list rises over the chat from the input's top edge.
                SkillsList(skills: shown, picked: picked, room: room - 20, search: open ? $search : nil, searching: $searching,
                           hover: { picked = $0 }, pick: pick, submit: { submit(shown) }, key: key)
                    .padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 0, alignment: .bottomLeading)
            }
            field
        }
        .onChange(of: model.draft) { if closed { closed = false } }
        .onChange(of: query) { picked = 0 }
        .onChange(of: shown != nil, initial: true) { _, open in listOpen?.wrappedValue = open }
    }

    // MARK: Skills

    /// What follows a / typed at the start of the field, before any space: the list's search.
    private var typed: String? {
        guard !skills.isEmpty, !closed, model.draft.hasPrefix("/"), !model.draft.contains(where: \.isWhitespace) else { return nil }
        return String(model.draft.dropFirst())
    }

    private var query: String? { open ? search : typed }

    /// The rows the open list shows; nil while it is closed, as it is when a typed / matches nothing.
    private var shown: [AISkill]? {
        guard let query else { return nil }
        let found = AskPilotSkills.matching(skills, query)
        return open || !found.isEmpty ? found : nil
    }

    private func toggle() {
        open.toggle()
        if open { search = ""; Task { @MainActor in searching = true } } else { refocus() }
    }

    /// Return on the list: the row it points at.
    private func submit(_ shown: [AISkill]) {
        if shown.indices.contains(picked) { pick(shown[picked]) }
    }

    /// Puts the skill's command and its starter in the chat box, caret after them; never sends (Q270 B).
    private func pick(_ skill: AISkill) {
        model.draft = AskPilotSkills.draft(picking: skill, over: model.draft)
        open = false
        refocus()
    }

    /// Off, then on a turn later, so a field that already had focus still moves its caret after the words.
    private func refocus() {
        focus?.wrappedValue = false
        Task { @MainActor in focus?.wrappedValue = true }
    }

    /// ↑ and ↓ move the pick, Escape closes; every other key goes to the field.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard let shown else { return .ignored }
        switch press.key {
        case .upArrow: picked = max(picked - 1, 0)
        case .downArrow: picked = min(picked + 1, shown.count - 1)
        case .escape:
            if open { toggle() } else { closed = true }
        default: return .ignored
        }
        return .handled
    }

    @ViewBuilder private var field: some View {
        let prompt = model.attachment == nil ? placeholder : "Ask about this capture"
        let row = HStack(alignment: .bottom, spacing: 10) {
            if !skills.isEmpty { SkillsBubble(open: open, toggle: toggle) }
            TextField("Message", text: $model.draft, selection: $selection, prompt: Text(prompt).foregroundStyle(ink.muted), axis: .vertical)
                .textFieldStyle(.plain).font(ink.ui(13)).foregroundStyle(ink.text).lineLimit(1...5)
                .padding(.vertical, 3)
                .onSubmit {
                    // Return picks while a typed / shows the list, else sends.
                    if !open, let shown, !shown.isEmpty { return submit(shown) }
                    if boxed { send() }
                }
                .onKeyPress(keys: [.upArrow, .downArrow, .escape], action: key)
                .modifier(InputFocus(focus: focus))
                // Focusing selects the whole field; a picked skill's words stay and the caret goes after them.
                .onChange(of: focus?.wrappedValue ?? false) { _, now in
                    if now { selection = TextSelection(insertionPoint: model.draft.endIndex) }
                }
            if model.running {
                Button(action: model.stop) { Image(systemName: "stop.circle.fill").font(.system(size: 20)).foregroundStyle(ink.text2) }
                    .buttonStyle(.plain).help("Stop (⌘.)").accessibilityLabel("Stop")
            } else {
                let empty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(empty ? ink.muted : ink.accent) }
                    .buttonStyle(.plain).disabled(empty).help("Send (Return)").accessibilityLabel("Send")
            }
        }
        if boxed && style.kind == .toybox {
            // Toybox's typed field: the white well in the ink outline, as its other fields.
            row.padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8).toyWell(\.panel, radius: 14)
        } else if boxed {
            row.padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
                .background(ink.background, in: .rect(cornerRadius: ink.blockRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous).strokeBorder(ink.line2, lineWidth: ink.stroke) }
        } else {
            row.padding(.horizontal, 18).padding(.vertical, 10)
        }
    }
}

/// A capture waiting on the input (story 191): its picture, the starters while nothing is typed (a click sends one with
/// it), and × to take it off.
private struct AIChatAttachment: View {
    @Environment(\.ink) private var ink
    @Bindable var model: AIChatModel
    let picture: AIChat.Image
    let send: () -> Void
    private static let starters = AIChat.Starter.capture(language: AIChat.Starter.language())

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AIChatPicture(image: picture, height: 40, width: 72).equatable()
            if model.draft.isEmpty {
                ForEach(Self.starters, id: \.title) { starter in
                    Button(starter.title) { model.draft = starter.prompt; send() }
                        .buttonStyle(PilotButtonStyle(primary: false)).fixedSize().help(starter.prompt)
                }
            } else {
                Text("The capture goes with your message").font(ink.ui(11.5)).foregroundStyle(ink.muted)
            }
            Spacer(minLength: 0)
            Button { model.attachment = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(ink.muted)
            }
            .buttonStyle(.plain).help("Leave the capture out").accessibilityLabel("Remove the capture")
        }
    }
}

/// A picture sent with a message, fitted in `width` by `height` and rounded, ringed by a hairline; decoded once, off the
/// main thread, at the size it shows (PanelModel.downsample).
struct AIChatPicture: View, Equatable {
    @Environment(\.ink) private var ink
    @Environment(\.displayScale) private var scale
    let image: AIChat.Image
    var height: CGFloat
    var width: CGFloat = 240
    @State private var picture: CGImage?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.image == b.image && a.height == b.height && a.width == b.width }

    var body: some View {
        ZStack {
            // Something to hang the decode on until the picture is in.
            if let picture { drawn(picture) } else { Color.clear.frame(width: 1, height: 1) }
        }
        .task(id: image.id) {
            let (data, pixels) = (image.data, Int(max(width, height) * scale))
            picture = await Task.detached(priority: .userInitiated) { PanelModel.downsample(data, maxPixels: pixels) }.value
        }
    }

    private func drawn(_ picture: CGImage) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Image(decorative: picture, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(maxWidth: width, maxHeight: height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(ink.line2, lineWidth: ink.stroke) }
            .accessibilityLabel("The capture")
    }
}

/// `.focused` on the page's binding, nothing in the notch, which has none.
private struct InputFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let focus { content.focused(focus) } else { content }
    }
}
