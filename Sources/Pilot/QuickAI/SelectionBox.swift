import AppKit
import Carbon.HIToolbox
import Observation
import PilotCore
import SwiftUI

/// What the chat bubble shows (Sven Q217, after Build 55): the selection quoted, the rewrite chips until the first
/// message, and its own conversation, apart from Ask AI's and gone when the bubble closes. A rewrite's answer (a chip or
/// Re-prompt) gets Replace, Copy and Re-prompt (Q218).
@Observable @MainActor
final class SelectionBoxModel {
    /// The bubble's conversation, drawn as Ask AI draws its own (AIChatTranscript, AIChatInput).
    let chat = AIChatModel()
    /// The selection as the bubble quotes it (trimmed), its length, and the app it is in.
    private(set) var quote = ""
    private(set) var characters = 0
    private(set) var app = ""
    /// The chips behind "…" show in place of the row's.
    var more = false
    /// The last turn's instruction when it was a rewrite, which Re-prompt puts back; nil after a question.
    private(set) var rewrite: String?
    /// Re-prompt put an instruction back in the input: the next send runs it as a rewrite.
    var reprompting = false

    /// The last answer, once it is whole.
    var answer: String? {
        guard !chat.running, let last = chat.turns.last, last.role == .assistant else { return nil }
        return last.text
    }

    /// The last answer is a rewrite: the Replace bar shows under it.
    var replaces: Bool { rewrite != nil && answer != nil }
    var started: Bool { !chat.turns.isEmpty || chat.running }

    func open(_ text: String, in app: String) {
        chat.clear()
        (quote, characters, self.app, more, rewrite, reprompting) = (text.trimmingCharacters(in: .whitespacesAndNewlines), text.count, app, false, nil, false)
        chat.draft = ""
        chat.route = AISettings.shared.routeName
    }

    func began(rewrite instruction: String?) {
        rewrite = instruction
        reprompting = false
    }
}

/// AI on selected text: Hyper+Ctrl+A, right-click Ask Pilot AI or the selection pill's Ask AI opens a chat bubble beside
/// the selection. Typed words ask about it (chat only, never `pilot` commands); a chip rewrites it in one shot, its
/// answer shown first, and Replace (⌘Return) puts it over the selection (SelectionEdit), a tip offering Undo after. The bubble is a non-activating panel, so the app keeps
/// its selection.
@MainActor
final class SelectionBox {
    static let shared = SelectionBox()

    static let width: CGFloat = 560
    static let nothingSelected = "No text selected"
    static var password: String { QuickFix.password }
    static let replaced = "Replaced · original in clipboard history", copied = "Copied · ⌘V to paste"
    static let undone = "Original back", notUndone = "Can't undo here · original in clipboard history"

    let model = SelectionBoxModel()
    /// One-shot rewrites (the chips, Re-prompt).
    var route: () -> Result<QuickAI.Runner, QuickAI.Failure> = { AISettings.shared.runner() }
    /// Questions about the selection: the AI page's provider as a chat, no tools.
    var chatRoute: () -> Result<AIChat.Runner, QuickAI.Failure> = { AISettings.shared.chatRunner() }
    var edit: SelectionEdit = .shared
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var tip: (String, TimeInterval, HUD.TipAction?) -> Void = { HUD.tip($0, seconds: $1, action: $2, top: true) }
    /// Shows the panel beside the selection, or hides it.
    var present: (SelectionBox, CGRect?) -> Void = { $0.showPanel(near: $1) }
    var dismiss: (SelectionBox) -> Void = { $0.hidePanel() }
    /// Calls back on the first key any other app gets; the returned closure stops watching.
    var watchKeys: (@escaping @MainActor () -> Void) -> () -> Void = { reached in
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in MainActor.assumeIsolated { reached() } }
        return { monitor.map(NSEvent.removeMonitor) }
    }

    private(set) var target: SelectionTarget?
    private var task: Task<Void, Never>?
    private var panel: KeyPanel?
    private var monitors: [Any] = []
    /// The replacement Undo may still take back: only until a key reaches the app after it (Moody, T2), as a key typed
    /// since would be what the app's own Undo takes back.
    private(set) var undoable: SelectionEdit.Replacement?
    private var stopWatching: (() -> Void)?

    var isShown: Bool { target != nil }

    /// The action (Hyper+Ctrl+A): the front app's selection, then the bubble. Never in a password field.
    func open() {
        guard !secureInput() else { return tip(Self.password, 3, nil) }
        task?.cancel()
        task = Task {
            guard let found = await edit.capture() else { return tip(edit.miss, 3, nil) }
            guard !Task.isCancelled else { return }
            show(found)
        }
    }

    /// Ask Pilot AI from the right-click menu: the service hands over the text, the target is found for it.
    func open(service text: String) {
        task?.cancel()
        task = Task {
            guard let found = await edit.capture(given: text), !Task.isCancelled else { return }
            show(found)
        }
    }

    /// The pill's Ask AI: the selection it already read.
    func open(_ found: SelectionTarget) {
        task?.cancel()
        show(found)
    }

    private func show(_ found: SelectionTarget) {
        target = found
        model.open(found.text, in: found.app)
        present(self, found.bounds)
        ailog.notice("selection box opened on \(found.text.count) characters in \(found.app, privacy: .public)")
    }

    /// The typed words: a question about the selection, or after Re-prompt the edited instruction as a rewrite.
    func sendDraft() {
        let words = model.chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !model.chat.running else { return }
        model.chat.draft = ""
        if model.reprompting { rewrite(words, label: words) } else { ask(words) }
    }

    func send(_ preset: SelectionPrompt.Preset) { rewrite(preset.instruction, label: preset.label) }

    /// A question: the selection rides in every message (SelectionPrompt.ask), the transcript shows the words alone.
    func ask(_ question: String) {
        guard let target, !model.chat.running else { return }
        model.began(rewrite: nil)
        model.chat.send(question, through: chatRoute().map { Self.asking($0, about: target.text) })
    }

    /// One rewrite of the selection, shown under `label`; its answer fitted to the selection, ready to Replace.
    func rewrite(_ instruction: String, label: String) {
        guard let target, !model.chat.running else { return }
        model.began(rewrite: instruction)
        model.chat.send(label, through: route().map { Self.rewriting(target.text, instruction, with: $0) })
    }

    // The runners are built out here, not inline in `map`: Swift 6.3's IRGen crashed on a typed-throws closure there.

    nonisolated static func asking(_ run: @escaping AIChat.Runner, about text: String) -> AIChat.Runner {
        { request, piece throws(QuickAI.Failure) in
            var asked = request
            asked.message = SelectionPrompt.ask(request.message, about: text)
            return try await run(asked, piece)
        }
    }

    nonisolated static func rewriting(_ text: String, _ instruction: String, with run: @escaping QuickAI.Runner) -> AIChat.Runner {
        { _, _ throws(QuickAI.Failure) in
            AIChat.Reply(SelectionPrompt.answer(try await run(.rewrite(text, instruction: instruction)) { _ in }, for: text))
        }
    }

    /// Re-prompt: the last rewrite's instruction back in the input, to edit and run again as a rewrite.
    func reprompt() {
        guard let instruction = model.rewrite, !model.chat.running else { return }
        model.chat.draft = instruction
        model.reprompting = true
        if let panel { DispatchQueue.main.async { _ = HUD.focusSearch(in: panel) } }
    }

    /// Replace (⌘Return): the bubble goes, so the app's own window has the keyboard again, then the last answer goes
    /// over the selection; a tip offers Undo.
    func replace() {
        guard let target, let answer = model.answer else { return }
        close()
        task = Task {
            // The app's window takes the keyboard back once the panel is gone.
            try? await Task.sleep(for: .milliseconds(80))
            switch await edit.replace(target, with: answer) {
            case .replaced(let done):
                offerUndo(done)
            case .copied:
                tip(Self.copied, 3, nil)
            }
        }
    }

    /// The tip with Undo, for as long as it shows and no key has reached the app since the replace; a key takes Undo
    /// away (the original stays in the clipboard history).
    private func offerUndo(_ done: SelectionEdit.Replacement) {
        endUndo()
        undoable = done
        stopWatching = watchKeys { [weak self] in
            guard let self, self.undoable != nil else { return }
            self.endUndo()
            self.tip(Self.replaced, 3, nil)
        }
        tip(Self.replaced, Self.undoSeconds, HUD.TipAction(title: "Undo") { self.undo() })
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            self?.endUndo()
        }
    }

    static let undoSeconds: TimeInterval = 6

    /// The tip's Undo: nothing once a key reached the app or the tip ran out.
    func undo() {
        guard let done = undoable else { return }
        endUndo()
        Task { tip(await edit.undo(done) ? Self.undone : Self.notUndone, 3, nil) }
    }

    private func endUndo() {
        stopWatching?()
        stopWatching = nil
        undoable = nil
    }

    func copyAnswer() {
        guard let answer = model.answer else { return }
        edit.world.copy(answer)
        close()
        tip(Self.copied, 3, nil)
    }

    /// Escape, the X or a click outside: a run still going is stopped and the conversation goes.
    func close() {
        task?.cancel()
        task = nil
        target = nil
        model.chat.clear()
        model.began(rewrite: nil)
        dismiss(self)
    }
}

// MARK: - The panel

extension SelectionBox {
    /// Before the first message: the header, the quote, the chips and the input; after it, room for the turns, which
    /// scroll.
    static func height(started: Bool) -> CGFloat { started ? 460 : 214 }

    /// The bubble's frame: under the selection, else above it when there is no room below, else near the top of the
    /// screen; always inside `screen` (a visible frame, AppKit coordinates).
    static func frame(size: CGSize, selection: CGRect?, screen: CGRect) -> CGRect {
        let gap: CGFloat = 8
        let x: CGFloat, y: CGFloat
        if let s = selection, screen.intersects(s) {
            x = s.minX
            y = s.minY - gap - size.height >= screen.minY ? s.minY - gap - size.height : s.maxY + gap
        } else {
            x = screen.midX - size.width / 2
            y = screen.maxY - screen.height * 0.18 - size.height
        }
        return CGRect(x: min(max(x, screen.minX + gap), screen.maxX - size.width - gap),
                      y: min(max(y, screen.minY + gap), screen.maxY - size.height - gap), width: size.width, height: size.height)
    }

    static func content(_ box: SelectionBox, look: Look = .shared) -> some View {
        SelectionBoxView(model: box.model, send: { box.send($0) }, sendDraft: box.sendDraft, replace: box.replace, copy: box.copyAnswer,
                         reprompt: box.reprompt, close: box.close)
            .frame(width: width)
            .styled(.quickAI, look: look).pilotTheme(look: look)
    }

    func showPanel(near selection: CGRect?) {
        hidePanel()
        let look = Look.shared
        let host = NSHostingView(rootView: Self.content(self, look: look))
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = SelectionTools.panelID
        panel.contentView = host
        panel.appearance = look.appearance(for: .quickAI)
        panel.level = HUD.level
        let screen = NSScreen.screens.first { selection.map($0.frame.intersects) ?? false } ?? Screens.focusedScreen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(Self.frame(size: CGSize(width: Self.width, height: Self.height(started: model.started)), selection: selection, screen: visible),
                       display: false)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        // The input takes the keyboard once the panel is key.
        DispatchQueue.main.async { [weak panel] in if let panel { _ = HUD.focusSearch(in: panel) } }
        follow(panel, screen: visible)
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
                guard let self, let panel, panel.isKeyWindow else { return event }
                return self.key(event) ? nil : event
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
        ].compactMap { $0 }
    }

    /// Grows once the first message goes, its top edge kept, and lifted to stay on screen.
    private func follow(_ panel: KeyPanel, screen: CGRect) {
        withObservationTracking { _ = model.started } onChange: { [weak self, weak panel] in
            DispatchQueue.main.async {
                guard let self, let panel, self.panel === panel else { return }
                var frame = panel.frame
                let height = Self.height(started: self.model.started)
                if height != frame.height {
                    frame.origin.y = max(frame.origin.y + frame.height - height, screen.minY + 8)
                    frame.size.height = height
                    panel.setFrame(frame, display: true, animate: false)
                }
                self.follow(panel, screen: screen)
            }
        }
    }

    /// Return sends, ⌘Return replaces, Escape closes, before the panel sees them; Shift+Return and the rest go on to
    /// the input.
    private func key(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch (Int(event.keyCode), mods) {
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): sendDraft()
        case (kVK_Return, .command), (kVK_ANSI_KeypadEnter, .command): replace()
        case (kVK_Escape, []): close()
        default: return false
        }
        return true
    }

    func hidePanel() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}
