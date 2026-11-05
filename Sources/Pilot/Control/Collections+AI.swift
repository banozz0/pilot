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
        registerAIVerb(s)
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
