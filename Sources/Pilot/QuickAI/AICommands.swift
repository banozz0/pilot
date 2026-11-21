import AppKit
import Carbon.HIToolbox
import Observation
import PilotCore

/// Your own AI command (launcher-best T10; the idea from Raycast's AI Commands and Tinycast's Quick Actions, their docs
/// only): a title, a prompt that may hold the snippets' placeholders, the AI that answers it (the AI page's pick with its
/// fallback, or one provider) and where the answer goes. Its prompt is the instruction; the selection goes with it as
/// data, never as an instruction (SelectionPrompt), so `{selection}` in a prompt reads "the selected text".
struct CustomAICommand: Codable, Equatable, Sendable, Identifiable {
    enum Output: String, Codable, CaseIterable, Sendable {
        /// Over the selection, the original kept in the clipboard history (SelectionEdit.replace).
        case replace
        /// On the clipboard.
        case copy
        /// Into the AI chat, asked there with the selection.
        case chat
    }

    /// Its title in lowercase letters, digits and dashes: the action's id after `ai.command:`, and the word
    /// `pilot ai run` takes.
    var id: String
    var title: String
    var prompt: String
    /// An AIProvider's raw value; nil for the AI page's pick and its fallback.
    var provider: String?
    var output: Output

    var actionID: String { AICommands.prefix + id }

    static func slug(_ title: String) -> String {
        let words = title.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        return words.joined(separator: "-")
    }

    /// The prompt as the AI reads it: its placeholders filled from `values`, `{selection}` named rather than pasted in.
    func instruction(_ values: Placeholders.Values) -> String {
        var named = values
        named.selection = "the selected text"
        let rest = Placeholders.fill(prompt, values, only: [.date, .time, .clipboard, .argument]).text
        return Placeholders.fill(rest, named, only: [.selection]).text
    }
}

/// The saved AI commands, `ai-commands.json` in Pilot's support folder; every edit saved at once. A file that does not
/// read is left alone and nothing saves over it.
@MainActor @Observable
final class AICommandBook {
    static let shared = AICommandBook(url: PilotFolder.support.appending(path: "ai-commands.json"))

    private(set) var commands: [CustomAICommand] = []
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var readable = true

    init(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { commands = try JSONDecoder().decode([CustomAICommand].self, from: Data(contentsOf: url)) } catch {
            ailog.error("ai commands: \(url.path, privacy: .public) unreadable, \(String(describing: error), privacy: .public)")
            readable = false
        }
    }

    func command(_ word: String) -> CustomAICommand? {
        commands.first { $0.id == word } ?? commands.first { $0.title.caseInsensitiveCompare(word) == .orderedSame }
            ?? commands.first { $0.id == CustomAICommand.slug(word) }
    }

    /// Saves `command` over the one with its id, or after the others; else why not, and nothing changes.
    func save(_ command: CustomAICommand) -> String? {
        guard readable else { return "\(url.lastPathComponent) does not read, so nothing is saved over it" }
        var command = command
        command.title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
        command.prompt = command.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        command.id = CustomAICommand.slug(command.title)
        guard !command.id.isEmpty else { return "--title: a title with a letter or a digit" }
        guard !command.prompt.isEmpty else { return "--prompt: what the AI does with the selection" }
        if let p = command.provider, AIProvider(rawValue: p) == nil {
            return "--provider: one of \(AIProvider.allCases.map(\.rawValue).joined(separator: ", ")), or none for the AI page's"
        }
        var next = commands
        if let i = next.firstIndex(where: { $0.id == command.id }) { next[i] = command } else { next.append(command) }
        return write(next)
    }

    func remove(_ id: String) -> String? { write(commands.filter { $0.id != id }) }

    private func write(_ next: [CustomAICommand]) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(next).write(to: url, options: .atomic)
        } catch { return "not saved: \(error.localizedDescription)" }
        commands = next
        return nil
    }
}

/// Runs the AI commands. Each is an action, `ai.command:<id>`, with no default key: built each time from the book, as the
/// rings are, so one added since launch lists in the menu and Binds, binds and goes on a ring; the selection pill lists
/// the first few.
@MainActor
final class AICommands {
    static let shared = AICommands()
    nonisolated static let prefix = "ai.command:"
    static let icon = MenuIcon.glyph("sparkles", .accent)
    /// How many the selection pill shows, after its own buttons.
    static let pillLimit = 3

    var book: AICommandBook = .shared
    let heard = AIFallback.Heard()
    var edit: SelectionEdit = .shared
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var tip: (String, TimeInterval) -> Void = { HUD.tip($0, seconds: $1, top: true) }
    private var task: Task<Void, Never>?

    /// The action an `ai.command:` id names; nil for any other id or a command since removed.
    static func dynamic(_ id: String, book: AICommandBook = .shared) -> Action? {
        guard id.hasPrefix(prefix), let command = book.command(String(id.dropFirst(prefix.count))) else { return nil }
        return Action(id: command.actionID, label: command.title, module: .apps, tier: .v1,
                      keywords: QuickAIActions.keywords + " command selection") { AICommands.shared.run(command.id) }
    }

    /// Every command as the menu, Binds and `pilot actions` list it.
    static func infos(book: AICommandBook = .shared) -> [BindsPage.ActionInfo] {
        book.commands.map { .init(id: $0.actionID, label: $0.title, module: Module.apps.rawValue, icon: icon,
                                  keywords: QuickAIActions.keywords + " command selection") }
    }

    /// The route `command` runs on: its own provider, or the AI page's pick with its fallback.
    func route(_ command: CustomAICommand, settings: AISettings = .shared) -> Result<QuickAI.Runner, QuickAI.Failure> {
        guard let p = command.provider.flatMap(AIProvider.init(rawValue:)) else { return settings.runner(told: heard.tell) }
        return settings.route(of: p).map { $0.run(_:text:) }
    }

    /// The command's answer for `text`, the prompt's placeholders read now; `{selection}` is `text` itself.
    func answer(_ command: CustomAICommand, on text: String, runner: QuickAI.Runner) async -> Result<String, QuickAI.Failure> {
        let job = QuickAI.Job.rewrite(text, instruction: command.instruction(values(for: command.prompt)))
        do throws(QuickAI.Failure) { return .success(try await runner(job) { _ in }) } catch { return .failure(error) }
    }

    /// The clock, the clipboard and its history, each read only when the prompt holds its placeholder.
    private func values(for prompt: String) -> Placeholders.Values {
        let needs = Placeholders.summary(of: prompt)
        let pasteboard = NSPasteboard.general
        let clipboard = needs.kinds.contains(.clipboard) && pasteboard.accessBehavior != .alwaysDeny ? pasteboard.string(forType: .string) : nil
        return Placeholders.Values(now: PlaceholderReads.now(), clipboard: clipboard, earlierClips: PlaceholderReads.earlierClips(needs.clipboardDepth))
    }

    /// The action: the front app's selection, then the answer where the command sends it. A second run drops the first.
    func run(_ id: String) {
        guard let command = book.command(id) else { return tip("No AI command \(id)", 3) }
        guard !secureInput() else { return tip(QuickFix.password, 3) }
        task?.cancel()
        task = Task {
            guard let found = await edit.capture() else { return tip(edit.miss, 3) }
            await run(command, on: found)
        }
    }

    /// `command` on a selection already read: the pill's button, or the action's run.
    func run(_ command: CustomAICommand, on found: SelectionTarget) async {
        guard !Task.isCancelled else { return }
        if command.output == .chat {
            let values = values(for: command.prompt)
            return AIChatPanel.shared.show(sending: command.instruction(values) + "\n\n" + found.text)
        }
        _ = heard.take()
        let runner: QuickAI.Runner
        switch route(command) {
        case .failure(let why): return tip(why.title, 3)
        case .success(let r): runner = r
        }
        tip("\(command.title)…", .infinity)
        let result = await answer(command, on: found.text, runner: runner)
        guard !Task.isCancelled else { return }
        switch result {
        case .failure(let why):
            ailog.notice("ai command failed: \(why.message, privacy: .public)")
            tip(why.title, 4)
        case .success(let reply):
            let told = heard.take()?.line
            switch command.output {
            case .replace:
                let done = switch await edit.replace(found, with: QuickAI.fitted(reply, to: found.text)) {
                case .replaced: "\(command.title) · original in clipboard history"
                case .copied: "\(command.title) copied · ⌘V to paste"
                }
                tip(told.map { "\(done). \($0)" } ?? done, told == nil ? 3 : 6)
            case .copy, .chat:
                edit.world.copy(reply)
                tip(told.map { "\(command.title) copied. \($0)" } ?? "\(command.title) copied", told == nil ? 3 : 6)
            }
            ailog.notice("ai command answered, \(reply.count) characters, \(command.output.rawValue, privacy: .public)")
        }
    }
}
