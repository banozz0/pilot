import Foundation
import os
import Synchronization

/// The AI page's Fallback (P95, Sven Q4, 2026-11-09): when the chosen AI fails for usage, billing or sign-in, the request
/// goes once to the one other AI picked there, on that AI's own model, and the surface says so. One fallback, once; never
/// after any words or command of the answer have reached the person; any failure not recognised here shows as before.
public enum AIFallback {
    /// Why the chosen AI could not answer, in the words every surface shows.
    public enum Reason: Equatable, Sendable {
        case usage, billing, signIn

        public func sentence(_ provider: AIProvider) -> String {
            switch self {
            case .usage: "\(provider.name) is out of usage."
            case .billing: "\(provider.name) has a billing problem."
            case .signIn: "\(provider.name) is signed out."
            }
        }
    }

    /// Which AI answered, and why it was not the chosen one.
    public struct Notice: Equatable, Sendable {
        public let answered: AIProvider
        public let first: AIProvider
        public let reason: Reason

        public init(answered: AIProvider, first: AIProvider, reason: Reason) {
            self.answered = answered; self.first = first; self.reason = reason
        }

        /// "Answered by Codex. Claude Code is out of usage."
        public var line: String { "Answered by \(answered.spoken). \(reason.sentence(first))" }
    }

    public typealias Tell = @Sendable (Notice) -> Void

    /// Keeps the notice of a run, for a surface that builds its runner before the run and shows the notice after it.
    public final class Heard: Sendable {
        private let kept = Mutex<Notice?>(nil)

        public init() {}

        public var tell: Tell { { [self] notice in kept.withLock { $0 = notice } } }
        public var notice: Notice? { kept.withLock { $0 } }
        public func take() -> Notice? { kept.withLock { kept in defer { kept = nil }; return kept } }
    }

    /// When the fallback takes over, as Pilot's questions and the AI page word it.
    public static let when = "fails for usage, billing or sign-in"

    /// The chosen AI's route with the fallback behind it. The fallback's route is built only if it is needed: an API one
    /// reads its key from the Keychain.
    public struct Route: AIChat.Route {
        let first: any AIChat.Route, chosen: AIProvider, second: AIProvider
        let next: @Sendable @MainActor () -> Result<any AIChat.Route, QuickAI.Failure>
        let told: Tell

        public init(first: any AIChat.Route, chosen: AIProvider, second: AIProvider, told: @escaping Tell,
                    next: @escaping @Sendable @MainActor () -> Result<any AIChat.Route, QuickAI.Failure>) {
            self.first = first; self.chosen = chosen; self.second = second; self.told = told; self.next = next
        }

        public func run(_ job: QuickAI.Job, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> String {
            let got = try await attempt(first: chosen, second: second, { spoke throws(QuickAI.Failure) in
                try await first.run(job) { spoke(); text($0) }
            }, then: { () throws(QuickAI.Failure) in
                try await next().get().run(job, text: text)
            })
            if let notice = got.notice { told(notice) }
            return got.answer
        }

        public func chat(_ request: AIChat.Request, text: @escaping @Sendable (String) -> Void) async throws(QuickAI.Failure) -> AIChat.Reply {
            let got = try await attempt(first: chosen, second: second, { spoke throws(QuickAI.Failure) in
                try await first.chat(request) { spoke(); text($0) }
            }, then: { () throws(QuickAI.Failure) in
                try await next().get().chat(request, text: text)
            })
            var reply = got.answer
            reply.notice = got.notice?.line
            return reply
        }
    }

    private static let log = Logger(subsystem: "dev.banozz.pilot", category: "quick-ai")

    /// Whether any of the answer has reached the person yet.
    private final class Spoke: Sendable {
        private let did = Mutex(false)
        var mark: @Sendable () -> Void { { [self] in did.withLock { $0 = true } } }
        var happened: Bool { did.withLock { $0 } }
    }

    /// Runs the chosen AI, then, on a failure with a Reason and nothing yet shown, `fallback` once. `run` calls its argument
    /// as each piece of the answer reaches the person. The notice is nil when the chosen AI answered. A fallback that fails
    /// too throws both reasons; a stop stays a stop.
    public static func attempt<Answer: Sendable>(
        first: AIProvider, second: AIProvider,
        _ run: (@escaping @Sendable () -> Void) async throws(QuickAI.Failure) -> Answer,
        then fallback: () async throws(QuickAI.Failure) -> Answer
    ) async throws(QuickAI.Failure) -> (answer: Answer, notice: Notice?) {
        let spoke = Spoke()
        let failure: QuickAI.Failure
        do throws(QuickAI.Failure) {
            return (try await run(spoke.mark), nil)
        } catch {
            failure = error
        }
        guard !spoke.happened, !Task.isCancelled, let reason = failure.fallbackReason else { throw failure }
        log.notice("AI fallback: \(first.rawValue, privacy: .public) failed (\(String(describing: reason), privacy: .public)), asking \(second.rawValue, privacy: .public)")
        do throws(QuickAI.Failure) {
            return (try await fallback(), Notice(answered: second, first: first, reason: reason))
        } catch {
            guard error != .cancelled else { throw .cancelled }
            log.notice("AI fallback: \(second.rawValue, privacy: .public) failed too: \(error.message, privacy: .public)")
            throw .bothFailed(reason, first: first, second: second, error)
        }
    }

    /// Lower case, the curly apostrophe codex prints made straight.
    private static func normal(_ said: String) -> String { said.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") }

    /// Throttling that says it is no usage limit: checked first, as its words hold "usage limit" (claude 2.1.319's binary).
    private static let notLimits = ["not your usage limit", "temporarily limiting"]

    /// Being out of usage, as claude 2.1.319's binary (its limit prefixes and its "usage limit reached"), codex-cli 0.167.0's
    /// binary and error.rs, and Anthropic's and OpenAI's error docs word it. A per-minute "rate limit" is not here: it
    /// passes in a moment, so it shows as before.
    private static let usage = [
        "you've hit your", "you've reached your", "you're out of usage credits", "your org is out of usage", "your seat type doesn't include",
        "your usage allocation has been disabled", "your group's usage limit is set to $0", "requires usage credits", "you're out of extra usage",
        "usage limit reached", "usage is paused for your organization",
        "quota exceeded", "to use codex with your chatgpt plan", "is out of credits", "you hit your spend cap",
        "you have reached your", "spend limit reached", "exceeded your current quota",
    ]

    /// A billing problem: claude's and Anthropic's own words, OpenAI's table, and any HTTP 402 (AIStream.failure's suffix).
    private static let billing = [
        "payment is past due", "can't use your claude subscription", "credit balance is too low", "credit balance too low",
        "credit balance exhausted", "http 402",
    ]

    /// Sign-in, for the failures the routes could not name as signed out: claude's own check and messages, codex's token
    /// refusals and its 401, and OpenAI's.
    private static let signIn = [
        "not logged in", "run /login", "authentication failed", "authentication required", "invalid api key", "invalid auth token",
        "oauth token expired", "oauth token revoked", "login expired", "failed to authenticate",
        "could not be refreshed", "log out and sign in again", "unexpected status 401",
        "incorrect api key provided", "invalid authentication",
    ]

    /// The reason a provider's own words give; nil for anything else, which never falls back.
    static func reason(said: String) -> Reason? {
        let said = normal(said)
        guard !notLimits.contains(where: said.contains) else { return nil }
        if usage.contains(where: said.contains) { return .usage }
        if billing.contains(where: said.contains) { return .billing }
        return signIn.contains(where: said.contains) ? .signIn : nil
    }
}

extension QuickAI.Failure {
    /// Why this failure may go to the fallback; nil shows it as it is.
    public var fallbackReason: AIFallback.Reason? {
        switch self {
        case .signedOut, .notConnected, .keyRejected: .signIn
        case .failed(let said), .api(_, let said): AIFallback.reason(said: said)
        default: nil
        }
    }
}

extension AIChat.AgentEvent {
    /// Whether the person has seen this: words, or a command, which a second run would repeat.
    public var speaks: Bool {
        switch self {
        case .text, .toolCall, .toolResult: true
        case .session, .done: false
        }
    }
}

extension AIProvider {
    /// The provider mid-sentence: "Answered by the endpoint."
    public var spoken: String { self == .openAICompatible ? "the endpoint" : name }
}
