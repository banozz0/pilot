import AppKit
import Observation
import PilotCore
import SwiftUI
import Synchronization

/// The AI chat's conversation (SPEC story 166): the turns so far, the answer as it streams in, and how the last turn
/// ended. Lives for Pilot's session, so the panel reopened shows it again, until New chat or the AI page's idle time
/// clears it. A provider that drives Pilot (T16) also hands on each `pilot` command it runs, kept beside the message
/// that asked for it, and the Allow gate asks on that command's row while the chat shows it.
@Observable @MainActor
final class AIChatModel {
    enum State: Equatable { case idle, running, failed(QuickAI.Failure) }

    /// One turn as the chat runs it: a chat-only provider's words, or an agent's (AIChat.Agent.turn) with its commands.
    typealias Turn = @Sendable (AIChat.Request, @escaping @Sendable (AIChat.AgentEvent) -> Void) async throws(QuickAI.Failure) -> AIChat.Reply

    /// One `pilot` command an agent turn ran: what came back once it has, and the gate's question while it waits on Sven.
    struct Call: Equatable, Identifiable {
        let id: String
        let command: String
        var result: String?
        var failed = false
        var asking: Asking?
    }

    /// The gate's question on a row: who asks (AllowPrompt.program), the exact thing, and which showing it is, so a
    /// button answers only the question it was drawn for.
    struct Asking: Equatable {
        let program: String
        let ask: ControlGate.Ask
        let asked: Int
    }

    private(set) var conversation = AIChat.Conversation()
    /// The answer to the last message as it streams in.
    private(set) var streaming = ""
    private(set) var state = State.idle
    /// The commands each message's turn ran, by the message's index in `turns`; a stopped or failed turn keeps its own.
    private(set) var calls: [Int: [Call]] = [:]
    /// The rows unfolded to their result.
    private(set) var unfolded: Set<String> = []
    /// What the input holds.
    var draft = ""
    /// Bumped when Pilot types into the input for the person (`type`): the input takes focus with its caret at the end.
    private(set) var typed = 0
    /// A capture waiting to go with the next message (story 191).
    var attachment: AIChat.Image?
    /// The provider and model the header names, read as the panel opens.
    var route = ""
    /// How many of the chat's surfaces show it now (the panel, the AI page): the gate asks inline only while one does.
    @ObservationIgnored var viewers = 0 {
        didSet { if viewers == 0 { settle(nil) } }
    }
    /// Whether a surface showing the chat is on screen: the panel shown, or the AI page in a window that is visible and
    /// not minimised (AIChatPanel.shared sets it); a question asks inline only then.
    @ObservationIgnored var onScreen: @MainActor () -> Bool = { true }
    /// When a turn last went out or came back.
    @ObservationIgnored private(set) var lastUsed = Date.distantPast
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Which turn is the latest sent.
    @ObservationIgnored private var sent = 0
    /// The question on a row, waiting: its row and how it ends; `asked` tells one showing from the next.
    @ObservationIgnored private var waiting: (asked: Int, turn: Int, call: String, answer: CheckedContinuation<Bool?, Never>)?
    @ObservationIgnored private var asked = 0
    /// A command ran since the last words, so the next words start a paragraph.
    @ObservationIgnored private var afterCall = false

    var turns: [AIChat.Turn] { conversation.turns }
    var running: Bool { state == .running }

    /// A chat-only provider's runner as a turn: its pieces are its words.
    nonisolated static func turn(_ run: @escaping AIChat.Runner) -> Turn {
        { request, event throws(QuickAI.Failure) in try await run(request) { event(.text($0)) } }
    }

    /// Sends `text`, else the input's draft, through a chat-only provider.
    func send(_ text: String? = nil, through route: Result<AIChat.Runner, QuickAI.Failure>) {
        send(text, acting: route.map(Self.turn))
    }

    /// Sends `text`, else the input's draft, on `route`; nothing while an answer still streams or with nothing typed.
    /// Events land on the main queue in order, a hop at a time, the words between two hops joined, as Quick AI's answer does.
    func send(_ text: String? = nil, acting route: Result<Turn, QuickAI.Failure>) {
        let message = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !running else { return }
        if text == nil { draft = "" }
        let request = conversation.send(message, image: attachment)
        attachment = nil
        (streaming, state, lastUsed, afterCall) = ("", .running, Date(), false)
        let run: Turn
        switch route {
        case .success(let turn): run = turn
        case .failure(let why): return fail(why)
        }
        let asking = turns.count - 1
        sent += 1
        let mine = sent
        let pending = StreamEvents()
        // A stopped turn's child can still answer late: only this turn's events and end count, never the next one's.
        task = Task { [weak self] in
            do throws(QuickAI.Failure) {
                let reply = try await run(request) { event in
                    guard pending.add(event) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { if self?.sent == mine { pending.take().forEach { self?.apply($0, to: asking) } } }
                    }
                }
                if self?.sent == mine { self?.answered(reply) }
            } catch {
                if self?.sent == mine { self?.fail(error) }
            }
        }
        ailog.notice("AI chat: turn \(self.turns.count / 2 + 1), \(message.count) characters")
    }

    /// Stops the answer: what came so far stays as the answer; with nothing yet the message stays unanswered. A question
    /// on a row is denied.
    func stop() {
        guard running else { return }
        task?.cancel()
        task = nil
        settle(false)
        end("stopped")
        if streaming.isEmpty { fail(.cancelled) } else { answered(AIChat.Reply(streaming)) }
    }

    /// Starts a new chat when this one has sat unused for `reset`: none while an answer streams or with nothing in it.
    /// True when it did.
    func expire(after reset: AIChat.Reset, now: Date = Date()) -> Bool {
        guard !running, !turns.isEmpty, reset.expired(last: lastUsed, now: now) else { return false }
        clear()
        ailog.notice("AI chat: new chat after \(reset.title, privacy: .public) unused")
        return true
    }

    /// New chat: a run still going is stopped, its CLI child with it (ChildProcess kills the tree on cancel), a question
    /// on a row denied, and every turn, command, planned change and the CLI session to resume go.
    func clear() {
        task?.cancel()
        task = nil
        settle(false)
        conversation.clear()
        ControlSocket.plan.clear()
        (streaming, state, draft, attachment, calls, unfolded) = ("", .idle, "", nil, [:], [])
    }

    /// A picture pasted or dropped on the input waits like a capture (Q693: /widget builds a widget from one), read and
    /// sized off the main thread, where the key tap runs; nothing when it does not read as a picture.
    func attach(_ source: CaptureAskAI.Source) {
        Task {
            guard let picture = await Task.detached(priority: .userInitiated, operation: { CaptureAskAI.picture(source) }).value else { return }
            attachment = picture
        }
    }

    /// The picture a pasteboard holds, as Notes' paste reads one (MarkdownEditor.holdsPictures): a copied picture file,
    /// else a picture with no text beside it, so ⌘V of words still pastes them.
    static func pastedPicture(_ board: NSPasteboard = .general) -> CaptureAskAI.Source? {
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files.first(where: NoteAttachments.isImage).map(CaptureAskAI.Source.file) }
        guard board.availableType(from: [.string]) == nil, let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return nil }
        return .data(data)
    }

    /// Puts `text` in the input, caret after it, for the person to go on typing (Create with AI's `/widget `).
    func type(_ text: String) {
        draft = text
        typed += 1
    }

    /// Folds or unfolds a command's row.
    func toggle(_ call: String) {
        if unfolded.remove(call) == nil { unfolded.insert(call) }
    }

    // MARK: The gate's question (T16)

    /// Asks `ask` on the running turn's open `pilot` row (one with no result yet) while a surface shows the chat, and
    /// answers Allow or Deny; nil when there is no such row or the chat stops showing first, so Pilot's own prompt asks
    /// instead. The gate's clock running out (cancelling this) or Stop or New chat denies.
    func decide(_ ask: ControlGate.Ask, program: String) async -> Bool? {
        let turn = turns.count - 1
        guard viewers > 0, onScreen(), running, waiting == nil, let call = calls[turn]?.last(where: { $0.result == nil }) else { return nil }
        asked += 1
        let mine = asked
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: false) }
                waiting = (mine, turn, call.id, continuation)
                edit(call.id, in: turn) { $0.asking = Asking(program: program, ask: ask, asked: mine) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in if self?.waiting?.asked == mine { self?.settle(false) } }
        }
    }

    /// Sven's answer to the question showing `asked`: Allow (true) or Deny (false). A click on a question that is gone,
    /// or drawn before the one now waiting replaced it, answers nothing.
    func answer(_ allowed: Bool, asked: Int) {
        guard waiting?.asked == asked else { return }
        settle(allowed)
    }

    /// Ends whatever question waits: Allow, Deny, or nil to hand it to Pilot's own prompt.
    private func settle(_ allowed: Bool?) {
        guard let (_, turn, call, answer) = waiting else { return }
        waiting = nil
        edit(call, in: turn) { $0.asking = nil }
        answer.resume(returning: allowed)
    }

    // MARK: Events

    private func apply(_ event: AIChat.AgentEvent, to index: Int) {
        guard running else { return }
        switch event {
        case .text(let piece):
            if afterCall, !streaming.isEmpty { streaming += "\n\n" }
            afterCall = false
            streaming += piece
        case .toolCall(let id, let command):
            afterCall = true
            calls[index, default: []].append(Call(id: id, command: command))
        case .toolResult(let id, let output, let isError):
            edit(id, in: index) { ($0.result, $0.failed) = (output, isError) }
        case .session, .done:
            break
        }
    }

    /// The running turn's rows still waiting on an answer that will never come, failed with `why`, so none spins on.
    private func end(_ why: String) {
        let turn = turns.count - 1
        calls[turn] = calls[turn]?.map { $0.result == nil ? Call(id: $0.id, command: $0.command, result: why, failed: true) : $0 }
    }

    /// Changes the row `id` of message `turn`'s turn.
    private func edit(_ id: String, in turn: Int, _ change: (inout Call) -> Void) {
        guard let i = calls[turn]?.firstIndex(where: { $0.id == id }) else { return }
        change(&calls[turn]![i])
    }

    private func answered(_ reply: AIChat.Reply) {
        guard running else { return }
        conversation.answered(reply)
        (streaming, state, lastUsed) = ("", .idle, Date())
    }

    private func fail(_ why: QuickAI.Failure) {
        guard running else { return }
        settle(false)
        end("the turn ended before it answered")
        (state, lastUsed) = (.failed(why), Date())
        ailog.notice("AI chat failed: \(why.message, privacy: .public)")
    }
}

/// A turn's events read but not yet on screen, in order, the words between two commands joined, and whether a
/// main-queue hop is already on its way for them.
final class StreamEvents: Sendable {
    /// The events before the words still arriving, which are appended in place.
    private let state = Mutex((events: [AIChat.AgentEvent](), text: "", hopping: false))

    /// True when this event needs a hop: none is on its way yet.
    func add(_ event: AIChat.AgentEvent) -> Bool {
        state.withLock { p in
            if case .text(let piece) = event {
                p.text += piece
            } else {
                if !p.text.isEmpty { p.events.append(.text(p.text)) }
                p.text = ""
                p.events.append(event)
            }
            defer { p.hopping = true }
            return !p.hopping
        }
    }

    func take() -> [AIChat.AgentEvent] {
        state.withLock { p in
            defer { p = ([], "", false) }
            return p.events + (p.text.isEmpty ? [] : [.text(p.text)])
        }
    }
}

/// The AI chat panel (story 166), Ask AI's bar drop (spec Bar drops T5): hangs under the top bar, square at the top and
/// round at the bottom, centred alone or right of the terminal (BarDrops). Hyper+Q toggles it (Q92). Hyper+Space's
/// "ask …" opens it with the question sent; Ask AI and Open AI chat open it on the input. Return sends, Shift+Return
/// starts a line, Escape or a click outside closes it; a run goes on while it is closed, and reopening shows the same
/// conversation.
@MainActor
final class AIChatPanel {
    /// The one the app shows; it signs its chat up to answer the Allow gate inline while it shows (T16).
    static let shared: AIChatPanel = {
        let panel = AIChatPanel()
        AllowPrompt.inline = { [model = panel.model] in await model.decide($0, program: $1) }
        return panel
    }()
    static let chatID = "ai.chat"
    /// A lone drop's size, what the renders draw; the drop itself takes BarDropPlacement's frame.
    static var size: CGSize { CGSize(width: BarDropPlacement.width, height: BarDropPlacement.height) }

    let model = AIChatModel()
    private let drops: BarDrops

    /// The AI page's provider, read on every turn, for the message sent: /extension's maker, its agent when it can drive
    /// Pilot, else its chat.
    var route: (String) -> Result<AIChatModel.Turn, QuickAI.Failure> = { AISettings.shared.chatTurn(for: $0) }
    /// A message with a picture: a chat turn, never the agent's (story 191), or its maker's (/widget, Q693).
    var pictureRoute: (String) -> Result<AIChatModel.Turn, QuickAI.Failure> = { AISettings.shared.pictureTurn(for: $0) }
    var routeName: () -> String = { AISettings.shared.routeName }
    var reset: () -> AIChat.Reset = { AISettings.shared.chatReset }
    var clock: () -> Date = { Date() }

    /// `page` says whether the AI page shows the chat; the Allow gate asks inline while it or the drop does.
    init(drops: BarDrops = .shared, page: @escaping @MainActor () -> Bool = { AIChatPanel.pageOnScreen(AppWindowController.shared.model) }) {
        self.drops = drops
        model.onScreen = { [weak self] in self?.isShown == true || page() }
    }

    static func register(into registry: inout ActionRegistry) {
        do {
            try registry.register(Action(id: chatID, label: "Open AI chat", module: .apps, defaultKey: Key("q"), tier: .v1, keywords: QuickAIActions.keywords + " chat") {
                AIChatPanel.shared.toggle()
            })
        } catch { ailog.error("AI chat action: \(String(describing: error), privacy: .public)") }
    }

    var isShown: Bool { drops.isOpen(.askAI) }

    /// The AI page is the window's page and the window is on screen: shown, not minimised or covered whole, not parked
    /// on a hidden workspace (AppWindowController.onScreen).
    static func pageOnScreen(_ window: AppWindowModel) -> Bool {
        let ai = AppPlace(.ai)
        return window.onScreen && window.page == ai.page && (ai.section == nil || window.sections[ai.page] == ai.section)
    }

    /// Opens the drop, or keeps it, and sends `question` when there is one; a chat unused for the AI page's idle time
    /// starts over first.
    func show(sending question: String? = nil) {
        model.route = routeName()
        if !isShown {
            _ = model.expire(after: reset(), now: clock())
            drops.open(.askAI, face: face())
            ailog.notice("AI chat opened, \(self.model.turns.count) turns")
        }
        if let question { send(question) }
    }

    func toggle() { isShown ? hide() : show() }

    /// Opens the chat with `text` typed in its input, ready for the rest (the Widgets page's Create with AI); words already
    /// typed there stay, after it.
    func show(typing text: String) {
        show()
        let draft = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.type(draft.hasPrefix(text.trimmingCharacters(in: .whitespaces)) ? model.draft : text + draft)
    }

    /// Ask AI about a capture (story 191): a new chat with the picture waiting on the input and its starters over it,
    /// dropped when the drop closes before it is sent.
    func ask(about picture: AIChat.Image) {
        model.clear()
        model.attachment = picture
        show()
    }

    func send(_ text: String? = nil) {
        let message = text ?? model.draft
        model.send(text, acting: model.attachment == nil ? route(message) : pictureRoute(message))
    }

    func hide() { drops.close(.askAI) }

    /// The panel's content in the picked style at `size`, or filling its window with none; it draws its own notch, so no
    /// panel chrome goes round it. Over Look's Glass its ground is clear, the glass's tint carrying it, as the other
    /// panels' (Sven on build 23: it stayed solid).
    static func content(_ model: AIChatModel, size: CGSize? = size, send: @escaping () -> Void = {}, newChat: @escaping () -> Void = {},
                        look: Look = .shared) -> some View {
        AIChatView(model: model, send: send, newChat: newChat, radius: radius(look), glass: look.material(on: .quickAI) == .glass)
            .frame(width: size?.width, height: size?.height)
            .styled(.quickAI, look: look).pilotTheme(look: look)
    }

    /// The notch's corner: the style's pop corner.
    static func radius(_ look: Look) -> CGFloat { CGFloat(look.chromeTokens(.quickAI).radii.pop) }

    /// `host` over Look's Glass in its style (solid in Toybox), tinted as every Pilot glass is (Look.glassTint, the top
    /// bar's, Q356). The glass rounds every corner and reaches a radius above the panel, so its top corners fall
    /// outside the window and the notch stays square at the top with no mask.
    static func backdrop(_ host: NSView, look: Look) -> MaterialBackdrop {
        let radius = radius(look)
        let backdrop = MaterialBackdrop(content: host, cornerRadius: radius)
        backdrop.show(look.material(on: .quickAI), tint: look.glassTint(on: .quickAI))
        backdrop.effect?.frame.size.height += radius
        return backdrop
    }

    /// `host`, the chat's face, in Ask AI's drop window on Look's Glass, without the window's shadow.
    static func makePanel(_ host: NSView, look: Look) -> KeyPanel {
        BarDrops.panel(backdrop(host, look: look), title: "AI chat", appearance: look.appearance(for: .quickAI))
    }

    /// The chat as Ask AI's drop: filling the drop as it moves between alone and beside the terminal, and its keys.
    private func face() -> BarDropFace {
        let look = Look.shared
        return BarDropFace(panel: { [model] size in
            let host = NSHostingView(rootView: Self.content(model, size: nil, send: { [weak self] in self?.send() },
                                                            newChat: { [weak self] in self?.model.clear() }, look: look))
            host.sizingOptions = []   // the drop's frame is BarDrops', never the chat's content size
            host.frame.size = size
            return Self.makePanel(host, look: look)
        }, keys: { [weak self] in self?.handle($0, $1, $2?.lowercased()) == true },
        // A capture not sent goes with the drop (Sven on build 62: it waited on the AI page's chat after Esc).
        closed: { [weak self] in self?.model.attachment = nil })
    }

    private func handle(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ key: String?) -> Bool {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        switch (code, flags, key) {
        case (36, [], _), (76, [], _): send()
        case (36, [.shift], _), (76, [.shift], _):
            (drops.window(.askAI)?.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
        case (_, [.command], "n"): model.clear()
        case (_, [.command], "v"):
            guard let picture = AIChatModel.pastedPicture() else { return false }
            model.attach(picture)
        case (_, [.command], "."): model.stop()
        default: return false
        }
        return true
    }
}

extension AISettings {
    /// A fallback's notice as a tip near the top of the screen, for the surfaces with no line of their own (an extension's
    /// `ai` action, the bind editor's Suggest).
    nonisolated static let tip: AIFallback.Tell = { notice in
        DispatchQueue.main.async { MainActor.assumeIsolated { HUD.tip(notice.line, seconds: 6, top: true) } }
    }

    /// The provider and model as the chat's header names them: "Claude Code · Sonnet".
    var routeName: String {
        let model = model(for: provider)
        return model?.id == nil ? provider.name : "\(provider.name) · \(model?.title ?? "")"
    }
}
