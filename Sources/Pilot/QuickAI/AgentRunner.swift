import Foundation
import PilotCore

/// The agent runner (spec pilot-ai-helper T14): the AI page's picked subscription as an AIChat.Agent, which may run
/// `pilot` and nothing else, in the CLIs' own folder (AICommand.folder); an API key's provider as an AIChat.APIAgent,
/// Pilot's own loop round the one `pilot` tool (Q193). The chat runs its turns (T16). A message starting /extension runs
/// the second profile instead (T17, ExtensionMaker).
extension AISettings {
    /// Claude Code or codex as an agent, or why there is none; an API key's provider acts through apiAgent(). codex runs in
    /// Pilot's own Codex home with every tool off but pilot-mcp's `pilot` (Q203, AIChat.Agent.codexLock), which replaced
    /// T15's chat-only codex: its read-only sandbox refused the socket and it always loaded ~/.codex.
    func agent() -> Result<AIChat.Agent, QuickAI.Failure> {
        let path: String
        switch provider {
        case .claudeCode:
            guard let cli = findCLI() else { return .failure(.missing) }
            path = cli.path
        case .codex:
            guard let plan = findPlan(.codex) else { return .failure(.notInstalled(.codex)) }
            // Scripts/build-app.sh copies the tool server beside the command.
            guard FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "pilot-mcp").path) else {
                return .failure(.failed("Pilot's tool server for Codex is missing from the app"))
            }
            path = plan.path
        default:
            return .failure(.notSetUp(provider, "\(provider.name) runs no command-line agent"))
        }
        // Scripts/build-app.sh copies the prompt to Resources and the command to Contents/Helpers.
        guard let prompt = BundledJSON.url("pilot-agent", "md") else { return .failure(.failed("Pilot's agent prompt is missing from the app")) }
        return .success(AIChat.Agent(provider, path: path, prompt: prompt, helpers: Self.helpers,
                                     model: model(for: provider)?.id, effort: effort(for: provider))!)
    }

    /// The picked API provider with the `pilot` tool (Q193), on the CLI agents' prompt (the bundle's, unless given); nil
    /// for a subscription.
    func apiAgent(instructions given: String? = nil) -> Result<AIChat.APIAgent, QuickAI.Failure>? {
        guard provider.command == nil else { return nil }
        guard let instructions = given ?? BundledJSON.url("pilot-agent", "md").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
            return .failure(.failed("Pilot's agent prompt is missing from the app"))
        }
        return route().flatMap { route in
            guard let tools = route as? any AIChat.ToolRoute else { return .failure(.unsupported("\(provider.name) takes no tools")) }
            return .success(AIChat.APIAgent(tools, instructions: instructions, helpers: Self.helpers))
        }
    }

    /// The turn `message` gets on the picked provider: /extension's maker; else a subscription's agent, or an API key's
    /// loop, so the chat can change Pilot (or why it cannot); else its chat alone. A message that starts with a skill's
    /// command carries its steps on every one of them (AIChat.Request.skilled, P29).
    func chatTurn(for message: String) -> Result<AIChatModel.Turn, QuickAI.Failure> {
        if let idea = ExtensionMaker.idea(message) { return extensionTurn(idea) }
        let turn: Result<AIChatModel.Turn, QuickAI.Failure> =
            if provider.command != nil { agent().map { $0.turn } }
            else if let api = apiAgent() { api.map { $0.turn } }
            else { chatRunner().map(AIChatModel.turn) }
        return turn.map { AISkills.skilled($0) }
    }

    /// /extension on Claude Code alone: codex has no confined file tools, the API keys only `pilot`.
    private func extensionTurn(_ idea: String) -> Result<AIChatModel.Turn, QuickAI.Failure> {
        guard provider == .claudeCode else {
            return .failure(.unsupported("/extension needs Claude Code; pick it on the AI page"))
        }
        guard !idea.isEmpty else { return .failure(.unsupported("Say what it should make: /extension list my open ports")) }
        guard let cli = findCLI() else { return .failure(.missing) }
        guard let prompt = AISkills.url(ExtensionMaker.skill) else {
            return .failure(.failed("Pilot's extension prompt is missing from the app"))
        }
        let (model, effort, helpers) = (model(for: .claudeCode)?.id, effort(for: .claudeCode), Self.helpers)
        return .success(ExtensionMaker.turn { folder in
            ExtensionMaker.agent(cli: cli.path, prompt: prompt, helpers: helpers, folder: folder, model: model, effort: effort)
        })
    }

    /// Where `pilot` is in the bundle: first on the agent's PATH.
    static var helpers: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory) }
}

/// Pilot's AI skills (P29, Sven Q268): Packaging/skills/<name>/SKILL.md, in the bundle's Resources/skills, read once, in
/// the Skills list's order. A new skill is its file and its name here.
enum AISkills {
    static let names = ["binds", "preset", "layouts", "settings", "explain", "troubleshoot", "catalogue", ExtensionMaker.skill]
        + (CataloguePublish.available ? ["publish"] : [])
    /// The guide topics before P29, which `pilot guide` still answers.
    static let renamed = ["extensions": "catalogue", "troubleshooting": "troubleshoot"]
    static let all = load()

    /// The skills the chat's agent follows: all but /extension, the maker's own turn.
    static let guides = guides(all)

    static func guides(_ skills: [AISkill]) -> [AISkill] { skills.filter { $0.name != ExtensionMaker.skill } }

    /// `run` with each skill's steps in the messages that pick it.
    static func skilled(_ run: @escaping AIChatModel.Turn, _ skills: [AISkill] = guides) -> AIChatModel.Turn {
        { request, event throws(QuickAI.Failure) in try await run(request.skilled(skills), event) }
    }

    static func url(_ name: String) -> URL? { BundledJSON.url("SKILL", "md", in: "skills/\(name)") }

    /// Each named skill whose file `read` hands back and parses; a test reads the repo's.
    static func load(_ read: (String) -> String? = { url($0).flatMap { try? String(contentsOf: $0, encoding: .utf8) } }) -> [AISkill] {
        names.compactMap { read($0).flatMap(AISkill.init) }
    }
}

/// "/extension <idea>" in the chat (spec pilot-ai-helper T17): Claude Code with the file tools as well as `pilot`, in a
/// fresh folder of its own under the temporary folder, on the extension skill (Packaging/skills/extension), which walks it through
/// `pilot ext new`, its edits, `pilot ext test` and `pilot ext install` (each run and the install wait on Allow). What
/// holds it (ADR 0013, probes A–G, 2026-10-12): `--restricted` keeps Read, Write and Edit inside that folder; dontAsk
/// refuses shell commands that write or name a path outside it, but lets read-only ones chained after `pilot` run
/// (`pilot ping; ps aux`), so Pilot's shell gate (pilot-agent-shell, AIChat.Agent.environment) runs only one plain
/// `pilot …` call. python3 is not allowed: it would write anywhere. `pilot` itself reaches past the folder only through
/// Pilot: `ext new --dir` makes a template folder anywhere outside Extensions unasked; the install and every other
/// change go through the Allow gate.
enum ExtensionMaker {
    static let skill = "extension"
    static let command = "/" + skill

    /// What follows /extension, trimmed; nil when the message does not start with it.
    static func idea(_ message: String) -> String? { AISkill.words(after: command, in: message) }

    /// A new empty folder for one /extension turn, private, inside the temporary folder (which `pilot ext test` and
    /// `install` read unasked); left behind for macOS to clear, so a denied install's extension is still there. Foundation's
    /// resolve keeps /var/folders, not /private/var: claude resolves the folder and each path itself before comparing.
    static func folder(in parent: URL = FileManager.default.temporaryDirectory.appending(path: "pilot-ext")) throws -> URL {
        let folder = parent.appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.resolvingSymlinksInPath()
    }

    /// The maker's agent, its child run in `folder`; ten minutes a turn, since it writes, tests and installs.
    static func agent(cli: String, prompt: URL, helpers: URL, folder: URL, model: String?, effort: AIEffort) -> AIChat.Agent {
        AIChat.Agent(.claudeCode, path: cli, prompt: prompt, helpers: helpers, model: model, effort: effort, timeout: .seconds(600), reach: .files,
                     spawn: { path, arguments, environment, input, timeout, line in
            try await ChildProcess.run(path, arguments, environment: environment, input: input, directory: folder, timeout: timeout, lines: line)
        })!
    }

    /// One /extension turn in a new folder, on its own session: claude keeps a session's first prompt (AIChat.Request.text),
    /// so it never resumes the chat's, and the chat never resumes its; the earlier turns go as text.
    static func turn(folder: @escaping @Sendable () throws -> URL = { try folder() }, _ agent: @escaping @Sendable (URL) -> AIChat.Agent) -> AIChatModel.Turn {
        { request, event throws(QuickAI.Failure) in
            let made: URL
            do { made = try folder() } catch { throw .failed("no folder for the extension: \(error.localizedDescription)") }
            var fresh = request
            fresh.session = nil
            var reply = try await agent(made).turn(fresh, event: event)
            reply.session = nil
            return reply
        }
    }
}
