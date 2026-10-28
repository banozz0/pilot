import Foundation
import Synchronization
import Testing
@testable import PilotCore

/// AI chat's conversation (story 166): the history each turn carries, and how each provider is sent a later turn:
/// claude `--resume`, codex `exec resume`, a CLI with no session of its own the earlier turns written out, the APIs the whole history. Every run
/// is faked (PlanCLI's spawn seam, a fake network); nothing logs in or leaves the Mac.
@Suite("AI chat")
struct AIChatTests {
    @Test("A conversation sends each message with the turns before it, keeps the session the answer came from, and leaves out a message that got no answer")
    func history() {
        var chat = AIChat.Conversation()
        let first = chat.send("what is a monad")
        #expect(first.history.isEmpty && first.message == "what is a monad" && first.session == nil)
        chat.answered(AIChat.Reply("A monoid in endofunctors.", session: AIChat.Session(.claudeCode, "s1")))
        let second = chat.send("in plain words")
        #expect(second.history == [AIChat.Turn(.user, "what is a monad"), AIChat.Turn(.assistant, "A monoid in endofunctors.")])
        #expect(second.session == AIChat.Session(.claudeCode, "s1"))
        // No answer (stopped or failed): the message shows but the next turn's history skips it, so roles alternate.
        let third = chat.send("and an example")
        #expect(third.history.count == 2, "the unanswered message is not history yet")
        #expect(chat.turns.count == 4)
        chat.answered(AIChat.Reply("Optional is one."))
        #expect(chat.session == AIChat.Session(.claudeCode, "s1"), "a reply with no session keeps the last one")
        let fourth = chat.send("thanks")
        #expect(fourth.history.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(fourth.history.map(\.text) == ["what is a monad", "A monoid in endofunctors.", "and an example", "Optional is one."])
        #expect(fourth.turns.last == AIChat.Turn(.user, "thanks"))
        chat.clear()
        #expect(chat.turns.isEmpty && chat.session == nil)
    }

    @Test("A CLI resuming its own session is sent the time and the message; any other gets the earlier turns written out first")
    func folding() {
        let history = [AIChat.Turn(.user, "hi"), AIChat.Turn(.assistant, "hello")]
        let resumed = AIChat.Request(history: history, message: "again", session: AIChat.Session(.claudeCode, "s1"), now: Self.malta)
        #expect(resumed.text(for: .claudeCode) == "(\(Self.malta.line))\n\nagain")
        let folded = resumed.text(for: .codex)
        #expect(folded == "Earlier in this conversation:\n\nUser: hi\n\nAssistant: hello\n\nThe user's new message:\n\nagain")
        #expect(AIChat.Request(message: "first").text(for: .codex) == "first")
    }

    @Test("claude keeps the chat's session and resumes it by id; the result line's session_id is read")
    func claude() {
        let first = QuickAI.chatArguments(session: nil, model: "sonnet", effort: .medium, now: Self.malta)
        #expect(!first.contains("--no-session-persistence") && !first.contains("--resume"))
        #expect(first.contains("--safe-mode") && first.suffix(2) == ["--model", "sonnet"])
        #expect(first[first.firstIndex(of: "--system-prompt")! + 1] == AIChat.prompt(at: Self.malta))
        #expect(first[first.firstIndex(of: "--effort")! + 1] == "medium")
        let next = QuickAI.chatArguments(session: "5e1d")
        #expect(next.suffix(2) == ["--resume", "5e1d"])
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"hi","session_id":"5e1d-77"}"#
        #expect(QuickAI.session(result) == "5e1d-77")
        #expect(QuickAI.session(#"{"type":"system","subtype":"init","session_id":"x"}"#) == nil)
        // The one-shot is unchanged: no session kept.
        #expect(QuickAI.arguments(for: .ask("q")).contains("--no-session-persistence"))
    }

    @Test("codex keeps its thread on the first turn and resumes it next turn with the message on stdin; with no thread it is sent the turns before")
    func plans() async throws {
        let calls = PlanCLITests.Calls()
        let codex = PlanCLITests.cli(.codex, lines: PlanCLITests.codexAnswer, calls: calls)
        var chat = AIChat.Conversation()
        let first = try await codex.chat(chat.send("teh cat sat")) { _ in }
        #expect(first == AIChat.Reply("the cat sat", session: AIChat.Session(.codex, "01a1")))
        chat.answered(first)
        let opening = try #require(calls.list.first?.arguments)
        #expect(opening.prefix(1) == ["exec"] && !opening.contains("--ephemeral") && opening.contains("--sandbox"))
        #expect(opening.last?.hasPrefix(AIChat.prompt) == true)
        _ = try await codex.chat(chat.send("and the dog", now: Self.malta)) { _ in }
        let resume = try #require(calls.list.last)
        #expect(resume.arguments.prefix(2) == ["exec", "resume"] && resume.arguments.suffix(2) == ["01a1", "-"])
        #expect(resume.arguments.contains("sandbox_mode=\"read-only\"") && !resume.arguments.contains("--sandbox"))
        #expect(resume.input == Data("(\(Self.malta.line))\n\nand the dog".utf8), "a resumed thread is sent the time and the message")

        let foldCalls = PlanCLITests.Calls()
        let fold = PlanCLITests.cli(.codex, lines: PlanCLITests.codexAnswer, calls: foldCalls)
        let reply = try await fold.chat(AIChat.Request(history: [AIChat.Turn(.user, "hi"), AIChat.Turn(.assistant, "hello")], message: "again",
                                                       session: AIChat.Session(.claudeCode, "s1"))) { _ in }
        #expect(reply == AIChat.Reply("the cat sat", session: AIChat.Session(.codex, "01a1")))
        let input = String(decoding: try #require(foldCalls.list.last?.input), as: UTF8.self)
        #expect(input.hasPrefix("Earlier in this conversation:") && input.hasSuffix("again"))
        #expect(foldCalls.list.last?.arguments.contains("resume") == false)
    }

    @Test("The APIs are sent the whole history after the chat's prompt, oldest first")
    func apis() async throws {
        let request = AIChat.Request(history: [AIChat.Turn(.user, "hi"), AIChat.Turn(.assistant, "hello")], message: "again")
        let http = QuickAIRouteTests.FakeHTTP([QuickAIRouteTests.delta("yes"), QuickAIRouteTests.stop("end_turn")])
        let reply = try await AnthropicAPI(key: "k", model: QuickAIRouteTests.opus, http: http).chat(request) { _ in }
        #expect(reply == AIChat.Reply("yes"))
        let data = try #require(http.request?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["system"] as? String == request.prompt && request.prompt.hasPrefix(AIChat.prompt))
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "hi"], ["role": "assistant", "content": "hello"], ["role": "user", "content": "again"]])

        let openAI = OpenAIChat.body(system: AIChat.prompt, turns: request.turns, model: "gpt-5-mini", provider: .openAI)
        let sent = try #require(openAI["messages"] as? [[String: String]])
        #expect(sent.map { $0["role"] } == ["system", "user", "assistant", "user"] && sent.first?["content"] == AIChat.prompt)
        #expect(openAI["reasoning_effort"] as? String == "low")
    }

    // MARK: The time (Sven 2026-10-10: "whats the time in uk right now" got "I can't see the current time")

    /// Saturday 10 October 2026, 12:32 UTC, on a Mac in Malta.
    static let malta = AIChat.Now(Date(timeIntervalSince1970: 1_791_635_520), timeZone: TimeZone(identifier: "Europe/Malta")!,
                                  locale: Locale(identifier: "en_MT"))

    @Test("The time line names the weekday, date, local time, time zone with its offset, and the locale")
    func nowLine() {
        #expect(Self.malta.line == "It is now Saturday 10 October 2026, 14:32 local time (time zone Europe/Malta, UTC+02:00); the user's locale is en_MT.")
        let newYork = AIChat.Now(Self.malta.date, timeZone: TimeZone(identifier: "America/New_York")!, locale: Locale(identifier: "en_US"))
        #expect(newYork.line.contains("Saturday 10 October 2026, 08:32 local time (time zone America/New_York, UTC-04:00)"))
        #expect(AIChat.prompt(at: Self.malta) == AIChat.prompt + " " + Self.malta.line)
    }

    @Test("Each turn carries the time it is sent, not the first turn's")
    func freshPerTurn() {
        var chat = AIChat.Conversation()
        let first = chat.send("time?", now: Self.malta)
        chat.answered(AIChat.Reply("14:32", session: AIChat.Session(.claudeCode, "s1")))
        let later = AIChat.Now(Self.malta.date.addingTimeInterval(3600), timeZone: Self.malta.timeZone, locale: Self.malta.locale)
        let second = chat.send("and now?", now: later)
        #expect(first.prompt.contains("14:32") && second.prompt.contains("15:32") && !second.prompt.contains("14:32"))
        #expect(second.text(for: .claudeCode).hasPrefix("(It is now Saturday 10 October 2026, 15:32"))
        #expect(chat.send("default").now.date.timeIntervalSinceNow > -5, "a turn sent without a time takes the clock's")
    }

    @Test("Every chat route's prompt carries the time: claude, codex, the Anthropic and OpenAI-shaped APIs")
    func timeInEveryChatRoute() async throws {
        let line = Self.malta.line
        let claude = QuickAI.chatArguments(session: nil, now: Self.malta)
        #expect(claude[claude.firstIndex(of: "--system-prompt")! + 1].hasSuffix(line))

        let calls = PlanCLITests.Calls()
        _ = try await PlanCLITests.cli(.codex, lines: PlanCLITests.codexAnswer, calls: calls).chat(AIChat.Request(message: "time?", now: Self.malta)) { _ in }
        #expect(try #require(calls.list.last?.arguments).contains { $0.contains(line) }, "codex's instruction carries the time")

        let request = AIChat.Request(message: "time?", now: Self.malta)
        let anthropic = QuickAIRouteTests.FakeHTTP([QuickAIRouteTests.delta("14:32"), QuickAIRouteTests.stop("end_turn")])
        _ = try await AnthropicAPI(key: "k", model: QuickAIRouteTests.opus, http: anthropic).chat(request) { _ in }
        let bodyA = try #require(anthropic.request?.httpBody)
        let sentA = try #require(JSONSerialization.jsonObject(with: bodyA) as? [String: Any])
        #expect((sentA["system"] as? String)?.hasSuffix(line) == true)

        for provider in [AIProvider.openAI, .ollama, .openAICompatible] {
            let http = QuickAIRouteTests.FakeHTTP([#"data: {"choices":[{"delta":{"content":"14:32"}}]}"#, "data: [DONE]"])
            _ = try await OpenAIChat(provider: provider, base: URL(string: "http://localhost:1/v1")!, key: nil, model: "m", http: http)
                .chat(request) { _ in }
            let body = try #require(http.request?.httpBody)
            let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let system = (sent["messages"] as? [[String: String]])?.first
            #expect(system?["role"] == "system" && system?["content"]?.hasSuffix(line) == true, "\(provider)")
        }
    }

    @Test("Quick AI's ask and fix carry the time too, read on each run")
    func timeInJobs() {
        let zone = "time zone \(TimeZone.current.identifier)"
        for job in [QuickAI.Job.ask("q"), .fix("teh")] {
            let claude = QuickAI.arguments(for: job)
            #expect(claude[claude.firstIndex(of: "--system-prompt")! + 1].contains(zone))
            #expect(PlanCLI.prompt(for: job).contains(zone))
            #expect((AnthropicAPI.body(for: job, model: QuickAIRouteTests.opus)["system"] as? String)?.contains(zone) == true)
            let openAI = OpenAIChat.body(for: job, model: "gpt-5-mini", provider: .openAI)["messages"] as? [[String: String]]
            #expect(openAI?.first?["content"]?.contains(zone) == true)
        }
        #expect(QuickAI.Job.fix("x").prompt(at: Self.malta) == QuickAI.fixPrompt + " " + Self.malta.line)
    }

    @Test("A chat starts over after the idle time picked; Never keeps it")
    func reset() {
        let last = Self.malta.date
        #expect(AIChat.Reset.standard == .minutes30)
        #expect(!AIChat.Reset.minutes30.expired(last: last, now: last.addingTimeInterval(29 * 60 + 59)))
        #expect(AIChat.Reset.minutes30.expired(last: last, now: last.addingTimeInterval(30 * 60)))
        #expect(AIChat.Reset.hours4.expired(last: last, now: last.addingTimeInterval(4 * 3600)))
        #expect(!AIChat.Reset.never.expired(last: .distantPast, now: last))
        #expect(AIChat.Reset.allCases.map(\.title) == ["Never", "15 min", "30 min", "1 h", "4 h"])
    }
}
