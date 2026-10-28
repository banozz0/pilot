import Foundation
import PilotCore

extension ControlVerbs {
    /// `ai`: the AI page's buttons (CLI W14). Sign in and Connect open a login the person finishes, so both ask Allow
    /// first; Refresh and Test ask only when they would send a saved key to an address the command can set (the
    /// OpenAI-compatible endpoint's). Each answers the provider's row as `pilot list ai-providers` reads it after; a
    /// login, Refresh or Test that did not take answers ok false with the page's line, as its chip shows it.
    func registerAIVerb(_ s: ControlAI) {
        let subcommands = ["signin", "connect <provider> [--cancel]", "models <provider> [--refresh]", "test"]
        register(ControlVerb("ai", help: "The AI page's Sign in (Claude Code), Connect (the ChatGPT and Google subscriptions), each provider's model list and Refresh, and Test.",
                             usage: "pilot ai signin | ai connect <provider> [--cancel] | ai models <provider> [--refresh] | ai test",
                             flags: [.init("refresh", help: "models: ask the provider for its list now", takesValue: false),
                                     .init("cancel", help: "connect: stop a Connect still waiting on the browser", takesValue: false)],
                             schema: { .object(["subcommands": .array(subcommands.map(JSONValue.string)),
                                                "providers": .array(AIProvider.allCases.map { .string($0.rawValue) })]) },
                             index: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             detail: { word in
                                 switch word {
                                 case "signin": "pilot ai signin: Claude Code's Sign in. Asks Allow, then runs claude auth login in a terminal window you finish; pilot list ai-providers reads signed-in once it took. Says so when already signed in"
                                 case "connect": "pilot ai connect codex: asks Allow, then opens the subscription's sign-in in your browser and waits for it (up to 10 minutes), answering ready or why not. Also Reconnect. --cancel stops one still waiting"
                                 case "models": "pilot ai models <provider>: the model it answers with and the ones on offer, each by the id set ai.model.<provider> takes. --refresh asks the provider for its list first (codex's catalog, an API's models), as Refresh on the page"
                                 case "test": "pilot ai test: asks the picked provider (ai.provider) one tiny question the way AI will, answering ok or the problem and its hint"
                                 default: nil
                                 }
                             }) { call throws(ControlError) in
            let args = call.arguments()
            let sub = args.positional.first
            if let sub, let refusal = ControlVerb.unknownFlag(args.flags, known: sub == "connect" ? ["cancel"] : sub == "models" ? ["refresh"] : [], in: "pilot ai \(sub)") {
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
            case let other?: throw ControlError(.badValue, "no ai \(other); there are signin, connect, models and test")
            case nil: throw ControlError(.badRequest, "say signin, connect, models or test")
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
        guard p.refreshesModels else { throw ControlError(.badValue, "\(p.name)'s models are fixed; pilot ai models \(p.rawValue) lists them") }
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

    /// The question when a saved key would go to an address the command can set (`set ai.baseURL.<id>`), so a caller
    /// cannot point the endpoint elsewhere and send the key there unseen; nil for a fixed address, no key or no address.
    private static func keyLeaves(_ p: AIProvider, _ ai: AISettings, _ button: String) -> ControlGate.Ask? {
        guard p.editsBaseURL, p.key != .none, ai.hasKey(p), ai.baseURL(for: p) != nil else { return nil }
        return ControlGate.Ask("Send AI key", "\(button) sends \(p.name)'s saved key to \(ai.address(for: p))")
    }
}
