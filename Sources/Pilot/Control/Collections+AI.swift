import Foundation
import PilotCore

/// What the AI page reaches (CLI W14): each provider's state as its list shows it, Sign in, Connect, Refresh and Test.
/// A test hands in its own settings (fake Keychain, network and CLIs), terminal and gate, so nothing signs in, nothing
/// is sent and no key is read.
@MainActor
final class ControlAI {
    var gate = AllowPrompt.gate
    lazy var settings = AISettings.shared
    /// The AI chat `ai ask` sends to (P30), never shown by it.
    lazy var chat = AIChatPanel.shared
    /// The chat turn `ai ask` sent, by its index in the chat's turns and its text, while the command waits on its answer:
    /// the one turn `ai ask --stop` may stop.
    var asking: (turn: Int, text: String)?
    /// The visible terminal Claude Code's `auth login` runs in, as the page's Sign in runs it.
    var run: InstallModule.Run = InstallModule.visibleRun
    /// Your own AI commands (launcher-best T10), `pilot list|add|remove ai-commands` and `pilot ai run`.
    lazy var commands = AICommands.shared
}

extension ControlVerbs {
    /// The AI page's provider list as a read-only collection, and `ai` for its buttons (CLI W14). The keys stay in the
    /// Keychain: a row says only whether one is saved.
    func registerAI(_ s: ControlAI) {
        register(ControlCollection("ai-providers", help: "The AI page's providers, each with whether AI can use it and what it still needs (checking, not installed, signed out, not connected, no key, no model, not set), its command's status and path, whether a key is saved (never the key), the model it answers with and the models on offer (set ai.model.<id> takes one), and the Homebrew package to install its command with (pilot install pick <install>). Reading it asks each command whether it is signed in, as opening the page does.",
                                   rowKey: "id", list: {
            await s.settings.refreshCLIs()
            return .array(AIProvider.allCases.map { .object(Self.row($0, s.settings)) })
        }))
        registerAICommands(s)
        registerAIVerb(s)
    }

    /// Your own AI commands (launcher-best T10): each is an action, `ai.command:<id>`, that the menu, Binds, the rings and
    /// the selection pill list.
    func registerAICommands(_ s: ControlAI) {
        let outputs = CustomAICommand.Output.allCases.map(\.rawValue).joined(separator: ", ")
        register(ControlCollection("ai-commands", help: "Your own AI commands, run on the selected text from Hyper+Space, a bind, a ring or the selection pill: "
                                   + "a prompt (the snippets' placeholders fill; {selection} names the selected text, which goes along as data), the AI it asks "
                                   + "(the AI page's with its fallback unless one is named) and where the answer goes (\(outputs)). Each row's action is "
                                   + "its ai.command:<id>; pilot ai run <id> --text <words> answers it.",
                                   fields: [.init("title", help: "its name in the menu and the pill; its id is the title in lowercase, dashes between words"),
                                            .init("prompt", help: "what the AI does with the selection, as \"Make it friendlier\""),
                                            .init("output", help: "where the answer goes: \(outputs) (default replace)", required: false),
                                            .init("provider", help: "the AI that answers: \(AIProvider.allCases.map(\.rawValue).joined(separator: ", ")); none for the AI page's", required: false)],
                                   rowKey: "id", list: { .array(s.commands.book.commands.map { .object(Self.row($0)) }) },
                                   add: { args throws(ControlError) in
            let output = try args.value("output").map { word throws(ControlError) in
                guard let o = CustomAICommand.Output(rawValue: word) else { throw ControlError(.badValue, "--output: one of \(outputs)") }
                return o
            } ?? .replace
            let provider = args.value("provider").flatMap { $0 == "none" ? nil : $0 }
            // A title already saved changes that command in place, its id (and so its binds) kept.
            let title = args.value("title")!
            let kept = s.commands.book.commands.first { $0.id == CustomAICommand.slug(title) }?.id ?? ""
            let command = CustomAICommand(id: kept, title: title, prompt: args.value("prompt")!, provider: provider, output: output)
            switch s.commands.book.save(command) {
            case .failure(let refusal): throw ControlError(.badValue, refusal.line)
            case .success(let id):
                guard let saved = s.commands.book.command(id) else { throw ControlError(.badValue, "not saved") }
                return .object(Self.row(saved))
            }
        }, remove: { args throws(ControlError) in
            let word = try args.word(0, "id; pilot list ai-commands lists them")
            guard let command = s.commands.book.command(word) else { throw ControlError(.badValue, "no AI command \(word)") }
            if let refusal = s.commands.book.remove(command.id) { throw ControlError(.badValue, refusal.line) }
            return .object(Self.row(command))
        }))
    }

    static func row(_ c: CustomAICommand) -> [String: JSONValue] {
        ["id": .string(c.id), "title": .string(c.title), "prompt": .string(c.prompt), "output": .string(c.output.rawValue),
         "provider": c.provider.map(JSONValue.string) ?? .null, "action": .string(c.actionID)]
    }

    /// `ai run <command> [--text <words>]`: the command's answer for the words given, else the selection (the sandbox's
    /// PILOT_SANDBOX_SELECTION, else the front app's through Accessibility alone), after Allow, as it sends them to the AI.
    /// The answer comes back to the command only: nothing is pasted, copied or sent to the chat.
    static func runCommand(_ args: ControlArguments, _ s: ControlAI, call: ControlCall) async throws(ControlError) -> JSONValue {
        let word = try args.word(1, "command; pilot list ai-commands lists them")
        guard let command = s.commands.book.command(word) else {
            throw ControlError(.badValue, "no AI command \(word); pilot list ai-commands lists them")
        }
        let given = args.value("text")
        var read = given
        if read == nil { read = await PlaceholderReads.selection() }
        guard let text = read, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError(.notReady, "no text selected; --text gives the words")
        }
        let provider = command.provider.flatMap(AIProvider.init(rawValue:))
        let to = provider.map { destination(s.settings, provider: $0) } ?? destinations(s.settings)
        return try await s.gate.allow(ControlGate.Ask("Run AI command", "\(command.title) sends \(given == nil ? "the selected text" : "the words given") to \(to): "
                                                      + ControlGate.Ask.visible(text) + "; the answer comes back to the command"),
                                      peer: call.peer) { () throws(ControlError) in
            _ = s.commands.heard.take()
            let runner: QuickAI.Runner
            switch s.commands.route(command, settings: s.settings) {
            case .failure(let why): throw ControlError(.notReady, "\(why.title)\(why.hint.map { ": \($0)" } ?? "")")
            case .success(let r): runner = r
            }
            switch await s.commands.answer(command, on: text, runner: runner) {
            case .failure(let why): throw ControlError(.badValue, "\(why.title)\(why.hint.map { ": \($0)" } ?? "")")
            case .success(let reply):
                var out: [String: JSONValue] = ["id": .string(command.id), "title": .string(command.title), "output": .string(command.output.rawValue),
                                                "provider": .string(to), "reply": .string(reply)]
                out["notice"] = s.commands.heard.take().map { .string($0.line) }
                return .object(out)
            }
        }
    }

    /// A provider as the page's list and its rows show it.
    static func row(_ p: AIProvider, _ ai: AISettings) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .string(p.rawValue), "title": .string(p.title), "name": .string(p.name),
                                        "picked": .bool(ai.provider == p), "ready": .bool(ai.ready(p)),
                                        "model": ai.model(for: p).map { .string(word($0)) } ?? .null, "models": models(p, ai)]
        row["need"] = ai.need(p).map(JSONValue.string)
        if p.command != nil {
            let (status, path): (String, String?) = switch ai.status(p) {
            case .checking: ("checking", nil)
            case .missing: ("missing", nil)
            case .signedOut(let path): ("signed-out", path)
            case .signedIn(let path): ("signed-in", path)
            }
            row["status"] = .string(status)
            row["path"] = path.map(JSONValue.string)
        }
        if p.isPlan { row["connecting"] = .bool(ai.connecting(p)) }
        if p.key != .none { row["key"] = .string(ai.hasKey(p) ? "set" : "unset") }
        row["install"] = p.installPackage.map(JSONValue.string)
        return row
    }

    /// The models the page offers, each by the word `set ai.model.<id>` takes.
    static func models(_ p: AIProvider, _ ai: AISettings) -> JSONValue {
        .array(ai.models(for: p).map { .object(["id": .string(word($0)), "title": .string($0.title)]) })
    }

    /// A model as the command names it: its id, or "default" for the CLI's own (a nil id), as Settings+AI does.
    static func word(_ model: AIModelChoice) -> String { model.id ?? "default" }
}
