import AppKit
import Carbon.HIToolbox
import PilotCore
import Synchronization

/// Fix selected text in place (Quick AI, S3): Hyper+Ctrl+F, or Fix with Pilot in the right-click menu, sends the
/// selection to Claude and puts the fix over it at once, the original going to the clipboard (and so its history).
/// No panel: a tip near the top of the screen says what happened.
@MainActor
final class QuickFix {
    static let shared: QuickFix = QuickFix()
    /// A fix's streamed pieces go unused.
    typealias Runner = QuickAI.Runner

    static let working = "Fixing…", fixed = "Fixed · original in clipboard", copied = "Fix copied · ⌘V to paste"
    static let unchanged = "Nothing to fix", nothingSelected = "No text selected"
    static let password = "A password field has the keyboard, so Pilot leaves it alone."

    /// A run's notice, when the fallback answered it (AIFallback); it joins the tip that ends the run.
    let heard = AIFallback.Heard()
    /// The route picked on the AI page, read on every run.
    var route: () -> Result<Runner, QuickAI.Failure> = { AISettings.shared.runner(told: QuickFix.shared.heard.tell) }
    var selection: () async -> SelectedText? = { await SelectedText.focused() }
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    /// The fix over the selection with Cmd+V, then the original on the clipboard in place of Sven's copy (PasteBack).
    var paste: (_ fix: String, _ original: String) -> Void = { SnippetPaster().paste($0, thenCopy: $1) }
    /// On the clipboard as an ordinary copy, so the history keeps it.
    var copy: (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
    /// A tip near the top of the screen; `.infinity` stays up until the next replaces it.
    var tip: (String, TimeInterval) -> Void = { HUD.tip($0, seconds: $1, top: true) }

    private var task: Task<Void, Never>?
    private var serving = false

    /// Hyper+Ctrl+F: the focused app's selection, fixed in place. A second press drops the first run.
    func fixSelection() {
        guard !secureInput() else { return say(Self.password, 3) }
        task?.cancel()
        task = Task { await fix() }
    }

    /// Pastes once the app that had the selection is still in front with the same text selected; anything else copies
    /// the fix instead, so a click elsewhere meanwhile never gets it pasted into the wrong place.
    func fix() async {
        guard let source = await selection() else { return say(Self.nothingSelected, 3) }
        guard let runner = start() else { return }
        let result = await Self.attempt(runner, source.text)
        guard !Task.isCancelled, let fixed = finish(result, for: source.text) else { return }
        let unchanged = frontmost() == source.pid ? await selection()?.text == source.text : false
        guard !Task.isCancelled else { return }
        guard unchanged else {
            copy(fixed)
            end(Self.copied)
            return ailog.notice("quick AI fix copied: \(source.app, privacy: .public) no longer has the text selected")
        }
        paste(fixed, source.text)
        end(Self.fixed)
        ailog.notice("quick AI fix pasted into \(source.app, privacy: .public), \(fixed.count) characters")
    }

    /// Fix with Pilot (the right-click Services menu): the fix for `text`, nil having said why. A service answers only
    /// when its method returns and the app that asked waits for it, so the selection cannot change; the wait spins this
    /// run loop, so the tap (on the main run loop) and Pilot's panels keep running meanwhile. One at a time.
    func fixForService(_ text: String) -> String? {
        guard !serving else { return nil }
        serving = true
        defer { serving = false }
        guard let runner = start() else { return nil }
        let box = Outcome()
        Task.detached { box.set(await Self.attempt(runner, text)) }
        var result = box.get()
        while result == nil {
            RunLoop.current.run(mode: .default, before: .now + 0.05)
            result = box.get()
        }
        guard let result, let fixed = finish(result, for: text) else { return nil }
        copy(text)
        end(Self.fixed)
        ailog.notice("quick AI fix returned to the service, \(fixed.count) characters")
        return fixed
    }

    /// The run's last tip, with the notice when the fallback answered, up longer so it can be read.
    private func end(_ text: String) {
        let told = heard.take()?.line
        say(told.map { "\(text). \($0)" } ?? text, told == nil ? 3 : 6)
    }

    /// A tip; while the service waits, only once its answer is back: placing a tip asks Accessibility for the focused
    /// window, which the app waiting on the service cannot answer.
    private func say(_ text: String, _ seconds: TimeInterval) {
        guard serving else { return tip(text, seconds) }
        DispatchQueue.main.async { [tip] in tip(text, seconds) }
    }

    /// The picked route's runner with the working tip up (not for the service: its app shows it waits), or nil having
    /// said what is missing (no claude, no API key).
    private func start() -> Runner? {
        _ = heard.take()
        switch route() {
        case .failure(let why):
            say(why.title, 3)
            return nil
        case .success(let runner):
            if !serving { say(Self.working, .infinity) }
            return runner
        }
    }

    private nonisolated static func attempt(_ run: Runner, _ text: String) async -> Result<String, QuickAI.Failure> {
        do throws(QuickAI.Failure) { return .success(try await run(.fix(text)) { _ in }) } catch { return .failure(error) }
    }

    /// The fix inside the selection's own outer whitespace, or nil having said why there is none.
    private func finish(_ result: Result<String, QuickAI.Failure>, for text: String) -> String? {
        switch result {
        case .failure(let why):
            ailog.notice("quick AI fix failed: \(why.message, privacy: .public)")
            say(why.title, 4)
            return nil
        case .success(let answer):
            let fixed = QuickAI.fitted(answer, to: text)
            guard fixed != text else { end(Self.unchanged); return nil }
            return fixed
        }
    }

    /// The service's result, set off the main thread and read by its wait.
    private final class Outcome: Sendable {
        private let value = Mutex<Result<String, QuickAI.Failure>?>(nil)
        func set(_ result: Result<String, QuickAI.Failure>) { value.withLock { $0 = result } }
        func get() -> Result<String, QuickAI.Failure>? { value.withLock { $0 } }
    }
}
