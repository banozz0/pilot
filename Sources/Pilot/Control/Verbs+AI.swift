import Foundation
import PilotCore

extension ControlVerbs {
    /// `ai`: the AI page's buttons (CLI W14). Sign in and Connect open a login the person finishes, so both ask Allow
    /// first; Refresh and Test ask only when they would send a saved key to an address the command can set (the
    /// OpenAI-compatible endpoint's). Each answers the provider's row as `pilot list ai-providers` reads it after; a
    /// login, Refresh or Test that did not take answers ok false with the page's line, as its chip shows it.
    func registerAIVerb(_ s: ControlAI) {
        let subcommands = ["signin", "connect <provider> [--cancel]", "models <provider> [--refresh]", "test", "ask <text> [--new] [--stop]"]
        register(ControlVerb("ai", help: "The AI page's Sign in (Claude Code), Connect (the ChatGPT and Google subscriptions), each provider's model list and Refresh, and Test; ask sends to the AI chat and answers.",
                             usage: "pilot ai signin | ai connect <provider> [--cancel] | ai models <provider> [--refresh] | ai test | ai ask <text> [--new] | ai ask --stop",
                             flags: [.init("refresh", help: "models: ask the provider for its list now", takesValue: false),
                                     .init("cancel", help: "connect: stop a Connect still waiting on the browser", takesValue: false),
                                     .init("new", help: "ask: start a new chat first; alone, New chat", takesValue: false),
                                     .init("stop", help: "ask: stop the answer pilot ai ask asked for, still coming", takesValue: false)],
                             schema: { .object(["subcommands": .array(subcommands.map(JSONValue.string)),
                                                "providers": .array(AIProvider.allCases.map { .string($0.rawValue) })]) },
                             index: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             detail: { word in
                                 switch word {
                                 case "signin": "pilot ai signin: Claude Code's Sign in. Asks Allow, then runs claude auth login in a terminal window you finish; pilot list ai-providers reads signed-in once it took. Says so when already signed in"
                                 case "connect": "pilot ai connect codex: asks Allow, then opens the subscription's sign-in in your browser and waits for it (up to 10 minutes), answering ready or why not. Also Reconnect. --cancel stops one still waiting"
                                 case "models": "pilot ai models <provider>: the model it answers with and the ones on offer, each by the id set ai.model.<provider> takes. --refresh asks the provider for its list first (codex's catalog, an API's models), as Refresh on the page"
                                 case "test": "pilot ai test: asks the picked provider (ai.provider) one tiny question the way AI will, answering ok or the problem and its hint"
                                 case "ask": "pilot ai ask <text>: asks Allow, then sends it to the AI chat as its input's Return does, on the AI page's provider, and answers the reply once it has come, with the pilot commands an agent ran for it. --new starts a new chat first (alone: New chat). --stop stops an answer it asked for still coming, what came so far kept, and answers only stopped. A chat unused for the AI page's idle time starts over first; a capture waiting on its input refuses, and /extension and /widget are typed in the chat itself"
                                 default: nil
                                 }
                             }) { call throws(ControlError) in
            let args = call.arguments()
            let sub = args.positional.first
            let known = switch sub { case "connect": ["cancel"]; case "models": ["refresh"]; case "ask": ["new", "stop"]; default: [String]() }
            if let sub, let refusal = ControlVerb.unknownFlag(args.flags, known: known, in: "pilot ai \(sub)") {
                throw refusal
            }
            switch sub {
            case "signin": return try await Self.signIn(s, peer: call.peer)
            case "connect":
                let p = try Self.provider(try args.word(1, "provider: codex"))
                return args.has("cancel") ? try Self.cancel(p, s) : try await Self.connect(p, s, peer: call.peer)
            case "models":
                let p = try Self.provider(try args.word(1, "provider; pilot list ai-providers lists them"))
                return try await Self.models(p, refresh: args.has("refresh"), s, peer: call.peer)
            case "test": return try await Self.test(s, peer: call.peer)
            case "ask": return try await Self.ask(args, s, call: call)
            case let other?: throw ControlError(.badValue, "no ai \(other); there are signin, connect, models, test and ask")
            case nil: throw ControlError(.badRequest, "say signin, connect, models, test or ask")
            }
        })
    }

    private static func provider(_ word: String) throws(ControlError) -> AIProvider {
        guard let p = AIProvider(rawValue: word) else {
            throw ControlError(.badValue, "no AI provider \(word); they are \(AIProvider.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return p
    }

    /// The provider's row after the button, with whether it took and, when not, the page's line for why.
    private static func answer(_ p: AIProvider, _ s: ControlAI, failed: QuickAI.Failure?, more: [String: JSONValue] = [:]) -> JSONValue {
        var out = row(p, s.settings).merging(more) { $1 }
        out["ok"] = .bool(failed == nil)
        out["problem"] = failed.map { .string($0.title) }
        out["hint"] = failed?.hint.map(JSONValue.string)
        return .object(out)
    }

    /// Sign in: `claude auth login` in a terminal the person sees, as the page runs it when Claude Code is signed out.
    private static func signIn(_ s: ControlAI, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        await s.settings.refreshCLI(.claudeCode)
        switch s.settings.status(.claudeCode) {
        case .checking, .missing:
            throw ControlError(.notReady, "Claude Code is not installed; pilot install search claude finds it")
        case .signedIn: return answer(.claudeCode, s, failed: nil, more: ["note": .string("already signed in")])
        case .signedOut(let path):
            let command = "\(VisibleRun.quoted(path)) auth login"
            return try await s.gate.allow(ControlGate.Ask("Sign in to Claude", "\(command), in a terminal window"), peer: peer) { () throws(ControlError) in
                s.run(command, "Sign in to Claude", "true")
                return answer(.claudeCode, s, failed: nil, more: [
                    "ran": .string(command),
                    "note": .string("finish signing in in the terminal window; pilot list ai-providers reads signed-in once it took"),
                ])
            }
        }
    }

    /// Connect or Reconnect: the subscription's own sign-in in the browser, awaited as the page awaits it. A second
    /// request while one waits joins it without asking again.
    private static func connect(_ p: AIProvider, _ s: ControlAI, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard let account = p.account else {
            throw ControlError(.badValue, p == .claudeCode ? "Claude Code signs in with pilot ai signin" : "\(p.name) takes no sign-in; Connect is for codex")
        }
        let joining = s.settings.connecting(p)
        if !joining, s.settings.findPlan(p) == nil {
            await s.settings.refreshCLI(p)
            throw ControlError(.notReady, "\(p.name) is not installed; pilot install pick \(p.installPackage ?? "") installs it")
        }
        let ask = joining ? nil : ControlGate.Ask("Connect \(account)", "\(p.command ?? p.name) login: opens \(account)'s sign-in in your browser")
        return try await s.gate.allow(ask, peer: peer) { () throws(ControlError) in
            answer(p, s, failed: await s.settings.connect(p))
        }
    }

    private static func cancel(_ p: AIProvider, _ s: ControlAI) throws(ControlError) -> JSONValue {
        guard s.settings.connecting(p) else { throw ControlError(.notReady, "no Connect for \(p.name) is waiting") }
        s.settings.cancelConnect(p)
        return .object(["id": .string(p.rawValue), "cancelled": .bool(true)])
    }

    /// The model list, refreshed first when asked, as Refresh fills the page's picker.
    private static func models(_ p: AIProvider, refresh: Bool, _ s: ControlAI, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard refresh else {
            return .object(["id": .string(p.rawValue), "model": s.settings.model(for: p).map { .string(word($0)) } ?? .null, "models": models(p, s.settings)])
        }
        return try await s.gate.allow(keyLeaves(p, s.settings, "Refresh"), peer: peer) { () throws(ControlError) in
            answer(p, s, failed: await s.settings.refreshModels(for: p))
        }
    }

    /// Test: one tiny question through the picked provider.
    private static func test(_ s: ControlAI, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let p = s.settings.provider
        return try await s.gate.allow(keyLeaves(p, s.settings, "Test"), peer: peer) { () throws(ControlError) in
            answer(p, s, failed: await s.settings.test())
        }
    }

    /// `ai ask` (P30): the AI chat's input, New chat and Stop. A message goes out after Allow, never showing the chat, and
    /// the answer comes back once the turn ends, as the chat shows it; the chat keeps the turn, so opening it shows it too.
    /// The chat's own agent may not ask the chat: its turn is the one running. Only the asked turn comes back, never
    /// Sven's own, and --stop stops only a turn `ai ask` sent.
    private static func ask(_ args: ControlArguments, _ s: ControlAI, call: ControlCall) async throws(ControlError) -> JSONValue {
        guard !call.agent else { throw ControlError(.denied, "the AI chat's own agent cannot ask the AI chat; answer in your own words") }
        let model = s.chat.model
        let text = args.positional.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if args.has("stop") {
            guard text.isEmpty, !args.has("new") else { throw ControlError(.badRequest, "--stop takes no text and no --new") }
            guard model.running, let asking = s.asking, mine(asking.turn, model, asking.text) else {
                throw ControlError(.notReady, "no answer pilot ai ask asked for is coming, so there is nothing to stop")
            }
            model.stop()
            return .object(["stopped": .bool(true)])
        }
        guard !text.isEmpty else {
            guard args.has("new") else { throw ControlError(.badRequest, "say what to ask: pilot ai ask <text>") }
            model.clear()
            return .object(["new": .bool(true), "turns": .number(0)])
        }
        guard !model.running else { throw ControlError(.notReady, "an answer is still coming in the AI chat; ask once it has come") }
        // The chat's idle time runs out here too, as its panel opening runs it, so a stale chat never goes along.
        _ = model.expire(after: s.chat.reset(), now: s.chat.clock())
        let attached = "a capture waits on the AI chat's input; send or drop it there first"
        guard model.attachment == nil else { throw ControlError(.notReady, attached) }
        // /extension and /widget build files with a confined agent, not a chat turn: only the chat itself starts one.
        guard ExtensionMaker.idea(text) == nil, WidgetMaker.idea(text) == nil else {
            throw ControlError(.badRequest, "\(ExtensionMaker.command) and \(WidgetMaker.command) build in the AI chat itself; type it there")
        }
        let new = args.has("new")
        // Built inside the call, so the gate reads it again after Allow: a turn added, or the provider, its model or its
        // address changed while it was up denies.
        return try await s.gate.allow(ControlGate.Ask("Ask AI", (new || model.turns.isEmpty ? "in a new chat, "
                                                                  : "in the open chat, its \(model.turns.count) earlier turn\(model.turns.count == 1 ? "" : "s") going with it, ")
                                          + "sends to \(destination(s.settings)): \(ControlGate.Ask.visible(text)); the answer comes back to the command"),
                                      peer: call.peer) { () throws(ControlError) in
            let route = destination(s.settings)
            guard !model.running else { throw ControlError(.notReady, "an answer started while asking, so nothing was sent") }
            guard model.attachment == nil else { throw ControlError(.notReady, attached) }
            if new { model.clear() }
            s.chat.send(text)
            let asked = model.turns.count - 1
            guard mine(asked, model, text) else { throw ControlError(.notReady, "the AI chat did not take the message") }
            s.asking = (asked, text)
            defer { s.asking = nil }
            ailog.notice("AI chat: a message from the pilot command, \(text.count) characters")
            // The main actor stays free while it streams, so a second command can stop it; a turn past the longest a chat
            // turn runs is stopped.
            let end = ContinuousClock.now + chatTimeout
            while model.running, mine(asked, model, text) {
                guard ContinuousClock.now < end else {
                    model.stop()
                    throw ControlError(.timeout, "no answer in \(chatTimeout.components.seconds) s, the longest a turn it starts runs, so it was stopped")
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            // A turn that failed fails the command, with the chat's line for why; the chat keeps the message.
            if mine(asked, model, text), case .failed(let failure) = model.state {
                throw ControlError(.badValue, "\(failure.title)\(failure.hint.map { ": \($0)" } ?? "")")
            }
            return reply(asked, text, model, provider: route)
        }
    }

    /// Where a message to `provider` (the AI page's, unless given) goes: the provider and its model, its address when the
    /// command can set that (`set ai.baseURL.<id>`), and its saved key when one would go there too.
    static func destination(_ ai: AISettings, provider: AIProvider? = nil) -> String {
        let p = provider ?? ai.provider
        let model = ai.model(for: p)
        let name = model?.id == nil ? p.name : "\(p.name) · \(ControlGate.Ask.visible(model?.title ?? ""))"
        let address = p.editsBaseURL ? " at \(ControlGate.Ask.visible(ai.address(for: p)))" : ""
        let key = p.editsBaseURL && p.key != .none && ai.hasKey(p) && ai.baseURL(for: p) != nil ? ", with \(p.name)'s saved key" : ""
        return name + address + key
    }

    /// The longest a turn `ai ask` can start runs: an agent's or an API agent's (AIChat.Agent, AIToolLoop: 300 s); a
    /// chat-only provider's answer stops sooner.
    private static let chatTimeout: Duration = .seconds(300)

    /// Whether the chat's turn at `asked` is still the message `ai ask` sent, not one Sven sent after New chat.
    private static func mine(_ asked: Int, _ model: AIChatModel, _ text: String) -> Bool {
        model.turns.indices.contains(asked) && model.turns[asked].role == .user && model.turns[asked].text == text && model.turns.count <= asked + 2
    }

    /// The asked turn's answer as the chat shows it: the reply and the commands an agent ran for it; cleared when New chat
    /// took it away.
    private static func reply(_ asked: Int, _ text: String, _ model: AIChatModel, provider: String) -> JSONValue {
        let turns = model.turns
        guard mine(asked, model, text) else { return .object(["cleared": .bool(true), "provider": .string(provider)]) }
        var out: [String: JSONValue] = ["turns": .number(Double(turns.count)), "provider": .string(provider)]
        if turns.indices.contains(asked + 1), turns[asked + 1].role == .assistant { out["reply"] = .string(turns[asked + 1].text) }
        if let calls = model.calls[asked], !calls.isEmpty {
            out["commands"] = .array(calls.map { .object(["command": .string($0.command), "failed": .bool($0.failed)]) })
        }
        return .object(out)
    }

    /// The question when a saved key would go to an address the command can set (`set ai.baseURL.<id>`), so a caller
    /// cannot point the endpoint elsewhere and send the key there unseen; nil for a fixed address, no key or no address.
    private static func keyLeaves(_ p: AIProvider, _ ai: AISettings, _ button: String) -> ControlGate.Ask? {
        guard p.editsBaseURL, p.key != .none, ai.hasKey(p), ai.baseURL(for: p) != nil else { return nil }
        return ControlGate.Ask("Send AI key", "\(button) sends \(p.name)'s saved key to \(ai.address(for: p))")
    }
}
