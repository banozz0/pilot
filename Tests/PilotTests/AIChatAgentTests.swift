import Foundation
import Observation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// The chat drives Pilot (spec pilot-ai-helper T16): an agent turn's `pilot` commands land as rows under the message
/// that asked, each with what came back, and the Allow gate asks on the open row while the chat shows, else Pilot's own
/// prompt. The turn runs through the real runner (AIChat.Agent) on a recorded claude stream; no AI, CLI or Pilot runs.
/// The limit only ends a wait that never comes. It counts the time every other suite's synchronous main-actor test holds
/// the main thread, which a turn's hops queue behind: 44-52 s in Build 65's second full run, past 60 s in its first.
@Suite("AI chat agent", .timeLimit(.minutes(5)))
@MainActor
struct AIChatAgentTests {
    /// A value the closures share.
    final class Locked<T: Sendable>: Sendable {
        let value: Mutex<T>
        init(_ value: T) { self.value = Mutex(value) }
        var now: T { value.withLock { $0 } }
    }

    /// "bind Hyper+T to Ghostty", recorded 2026-10-12 from claude 2.1.296 on Haiku at low effort (`--model haiku --effort
    /// low`, the T14 flags) against a fake `pilot` that printed canned answers, never Pilot; trimmed to the fields read,
    /// the 32 text deltas joined into three.
    static let bindGhostty = [
        #"{"type":"system","subtype":"init","session_id":"8c1378dc-ba49-4123-95e2-acb665c431a8","tools":["Bash"],"model":"claude-haiku-5-5","permissionMode":"dontAsk"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_018MG5AyWqTszs8bBETnnaCo","name":"Bash","input":{"command":"pilot help bind","description":"Show help for the bind verb"}}]},"session_id":"8c1378dc-ba49-4123-95e2-acb665c431a8"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_018MG5AyWqTszs8bBETnnaCo","type":"tool_result","content":"{\"verb\":\"bind\",\"usage\":\"pilot bind <action> <key> [--mods shift,ctrl,alt,cmd] [--plain] [--replace]\",\"help\":\"Binds an action to a key under Hyper. Open an app with apps.open:<bundle id>.\"}","is_error":false}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01AGQdLHgt6rfFg2kYHAmN1f","name":"Bash","input":{"command":"pilot bind apps.open:com.mitchellh.ghostty t","description":"Bind Hyper+T to open Ghostty"}}]},"session_id":"8c1378dc-ba49-4123-95e2-acb665c431a8"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01AGQdLHgt6rfFg2kYHAmN1f","type":"tool_result","content":"{\"action\":\"apps.open:com.mitchellh.ghostty\",\"custom\":true,\"key\":\"Hyper+T\",\"off\":false}","is_error":false}]}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bound Hyper+T to open Ghostty (`apps.open:com.mitchellh.ghostty`). I didn't read the bind back, since the"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" bind command's output already confirms the key and action. I also didn't check that Ghostty's"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" bundle ID is `com.mitchellh.ghostty`. If Hyper+T doesn't launch it, that ID is the first thing to check."}}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Bound Hyper+T to open Ghostty (`apps.open:com.mitchellh.ghostty`). I didn't read the bind back, since the bind command's output already confirms the key and action. I also didn't check that Ghostty's bundle ID is `com.mitchellh.ghostty`. If Hyper+T doesn't launch it, that ID is the first thing to check."}]},"session_id":"8c1378dc-ba49-4123-95e2-acb665c431a8"}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Bound Hyper+T to open Ghostty (`apps.open:com.mitchellh.ghostty`). I didn't read the bind back, since the bind command's output already confirms the key and action. I also didn't check that Ghostty's bundle ID is `com.mitchellh.ghostty`. If Hyper+T doesn't launch it, that ID is the first thing to check.","session_id":"8c1378dc-ba49-4123-95e2-acb665c431a8"}"#,
    ]

    /// The runner on a replayed stream: the spawn seam hands each line on and records the command line.
    nonisolated static func agent(_ lines: [String], arguments: Locked<[String]>? = nil) -> AIChat.Agent {
        AIChat.Agent(.claudeCode, path: "/usr/bin/false", prompt: URL(fileURLWithPath: "/App/pilot-agent.md"),
                     helpers: URL(fileURLWithPath: "/App/Contents/Helpers"), spawn: { _, args, _, _, _, line in
            arguments?.value.withLock { $0 = args }
            lines.forEach(line)
            return ""
        })!
    }

    /// A turn that runs one command, `id`, and waits on `release` before it answers: the gate asks meanwhile.
    nonisolated static func waiting(_ id: String, _ command: String, until release: AsyncStream<Void>) -> AIChatModel.Turn {
        { _, event throws(QuickAI.Failure) in
            event(.toolCall(id: id, command: command))
            for await _ in release { break }
            event(.toolResult(id: id, output: "{}", isError: false))
            return AIChat.Reply("done")
        }
    }

    /// Words, a command and its result, more words, then a wait on `release`.
    nonisolated static func paragraphTurn(until release: AsyncStream<Void>) -> AIChatModel.Turn {
        { _, event throws(QuickAI.Failure) in
            event(.text("Checking."))
            event(.toolCall(id: "a", command: "pilot help"))
            event(.toolResult(id: "a", output: "ok", isError: false))
            event(.text("Done."))
            for await _ in release { break }
            return AIChat.Reply("Done.")
        }
    }

    /// A turn that reads the routes, then binds a shell command, and waits there as the gate asks.
    nonisolated static let shellBind: AIChatModel.Turn = { _, event throws(QuickAI.Failure) in
        event(.toolCall(id: "u1", command: "pilot help bind routes"))
        event(.toolResult(id: "u1", output: "drive.shell:<command>  runs a shell command", isError: false))
        event(.toolCall(id: "u2", command: "pilot bind 'drive.shell:brew upgrade' u"))
        try? await Task.sleep(for: .seconds(60))
        return AIChat.Reply("")
    }

    /// What the renders draw: the recorded bind answered, its bind row unfolded to the bind it made; `asking`, a second
    /// message whose turn read the routes (unfolded) and waits on the gate for a shell bind, asked on its row. New chat
    /// (clear) ends the question.
    static func conversation(asking: Bool) async -> AIChatModel {
        let model = AIChatModel()
        model.route = "Claude Code · Sonnet"
        model.viewers += 1
        model.send("bind Hyper+T to Ghostty", acting: .success(agent(bindGhostty).turn))
        await settled(model)
        guard asking else {
            if let bind = model.calls[0]?.last { model.toggle(bind.id) }
            return model
        }
        model.send("and Hyper+U runs brew upgrade", acting: .success(shellBind))
        await until { model.calls[2]?.count == 2 }
        model.toggle("u1")
        if let ask = ControlGate.Ask.run("drive.shell:brew upgrade") { Task { _ = await model.decide(ask, program: "pilot, from claude") } }
        _ = await asked(model)
        return model
    }

    /// Waits until `done`, woken by each change to what it reads on the model, never by a clock: in the full suite other
    /// tests hold the main thread for seconds, and a deadline ran out before the turn's main-queue hops landed. The
    /// suite's time limit cancels a wait that never comes, which wakes it and ends the loop.
    static func until(_ done: @escaping @MainActor () -> Bool) async {
        while !done(), !Task.isCancelled {
            let wake = Wake()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
                    wake.wait(changed)
                    withObservationTracking { _ = done() } onChange: { wake.fire() }
                }
            } onCancel: { wake.fire() }
        }
    }

    /// One wait's continuation, resumed once: by a change, or by cancellation, even one that came before the wait.
    final class Wake: Sendable {
        private let state = Mutex<(waiting: CheckedContinuation<Void, Never>?, fired: Bool)>((nil, false))

        func wait(_ continuation: CheckedContinuation<Void, Never>) {
            let fired = state.withLock { s in
                if !s.fired { s.waiting = continuation }
                return s.fired
            }
            if fired { continuation.resume() }
        }

        func fire() {
            let waiting = state.withLock { s in
                defer { (s.waiting, s.fired) = (nil, true) }
                return s.waiting
            }
            waiting?.resume()
        }
    }

    static func settled(_ model: AIChatModel) async { await until { !model.running } }

    /// Waits until the running turn's last row is open, so the gate has a row to ask on.
    static func rowOpen(_ model: AIChatModel) async {
        await until { model.calls[model.turns.count - 1]?.last.map { $0.result == nil } ?? false }
    }

    static func asked(_ model: AIChatModel) async -> AIChatModel.Asking? {
        await until { model.calls.values.joined().contains { $0.asking != nil } }
        return model.calls.values.joined().compactMap(\.asking).first
    }

    @Test("A recorded turn through the runner shows each pilot command it ran, what came back, and the bind it made")
    func fixtureThroughRunner() async throws {
        let arguments = Locked<[String]>([])
        let model = AIChatModel()
        model.send("bind Hyper+T to Ghostty", acting: .success(Self.agent(Self.bindGhostty, arguments: arguments).turn))
        await Self.settled(model)
        #expect(model.state == .idle)
        #expect(arguments.now.contains("Bash(pilot *)"), "the turn ran the agent's command line, pilot alone allowed")
        let calls = try #require(model.calls[0])
        #expect(calls.map(\.command) == ["pilot help bind", "pilot bind apps.open:com.mitchellh.ghostty t"])
        #expect(calls.allSatisfy { !$0.failed && $0.asking == nil })
        #expect(calls.last?.result == #"{"action":"apps.open:com.mitchellh.ghostty","custom":true,"key":"Hyper+T","off":false}"#)
        #expect(model.turns.count == 2 && model.turns[1].text.hasPrefix("Bound Hyper+T to open Ghostty"))
        #expect(model.conversation.session == AIChat.Session(.claudeCode, "8c1378dc-ba49-4123-95e2-acb665c431a8"))
        #expect(model.unfolded.isEmpty, "rows start folded")
        model.toggle(calls[1].id)
        #expect(model.unfolded == [calls[1].id])
        model.toggle(calls[1].id)
        #expect(model.unfolded.isEmpty)
    }

    @Test("A wait that never comes ends when its test is cancelled, as the time limit cancels it, before or during the wait")
    func untilCancels() async {
        let model = AIChatModel()
        let during = Task { @MainActor in await Self.until { model.running } }
        await Task.yield()
        during.cancel()
        await during.value
        let before = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await Self.until { model.running }
        }
        await before.value
    }

    @Test("A chat-only provider's words still stream as before, with no rows")
    func chatOnly() async {
        let model = AIChatModel()
        model.send("hi", through: .success(AIChatPanelTests.runner(AIChatPanelTests.Sent())))
        await Self.settled(model)
        #expect(model.turns.map(\.text) == ["hi", "answer 1"] && model.calls.isEmpty)
    }

    @Test("Words after a command start a paragraph while they stream")
    func paragraphs() async {
        let release = AsyncStream<Void>.makeStream()
        let model = AIChatModel()
        model.send("go", acting: .success(Self.paragraphTurn(until: release.stream)))
        await Self.until { model.streaming.hasSuffix("Done.") }
        #expect(model.streaming == "Checking.\n\nDone.")
        #expect(model.calls[0]?.map(\.result) == ["ok"])
        release.continuation.yield()
        await Self.settled(model)
    }

    // MARK: The gate inline

    /// A gate whose decider is the chat's, falling back to Deny where Pilot's prompt would ask (no prompt in tests). Its
    /// clock outlasts the suite's time limit: in the full suite other tests hold the main thread for 40 s and more, and a
    /// 5 s clock answered first, denying before the test saw the question (then waited on forever) or clicked Allow.
    static func gate(_ model: AIChatModel, wait: Duration = .seconds(3600), fellBack: Locked<Int>? = nil) -> ControlGate {
        ControlGate(wait: wait) { ask, _ in
            if let answer = await model.decide(ask, program: "pilot, from claude") { return answer }
            fellBack?.value.withLock { $0 += 1 }
            return false
        }
    }

    static let shell = ControlGate.Ask("Run shell", "brew upgrade")

    @Test("While the chat shows, the gate asks on the open row: Allow runs it once, Deny runs nothing, the row clears")
    func allowAndDeny() async throws {
        let release = AsyncStream<Void>.makeStream()
        let model = AIChatModel()
        model.viewers = 1
        defer { model.clear() }
        model.send("bind Hyper+U to brew upgrade", acting: .success(Self.waiting("t1", "pilot bind 'drive.shell:brew upgrade' u", until: release.stream)))
        await Self.rowOpen(model)
        let gate = Self.gate(model)
        let ran = Locked(0)
        let allowing = Task { try await gate.allow(Self.shell, peer: nil) { ran.value.withLock { $0 += 1 } } }
        let asking = try #require(await Self.asked(model))
        #expect(asking.program == "pilot, from claude" && asking.ask == Self.shell)
        #expect(model.calls[0]?.first?.id == "t1", "the question sits on the command's own row")
        model.answer(true, asked: asking.asked)
        try await allowing.value
        #expect(ran.now == 1 && model.calls[0]?.first?.asking == nil)

        let denying = Task { try await gate.allow(Self.shell, peer: nil) { ran.value.withLock { $0 += 1 } } }
        let next = try #require(await Self.asked(model))
        #expect(next.asked != asking.asked, "each showing has its own token")
        model.answer(true, asked: asking.asked)
        #expect(model.calls[0]?.first?.asking == next, "a click drawn for the answered question leaves the next one waiting")
        model.answer(false, asked: next.asked)
        await #expect(throws: ControlError.self) { try await denying.value }
        #expect(ran.now == 1 && model.calls[0]?.first?.asking == nil)
        release.continuation.yield()
        await Self.settled(model)
    }

    @Test("No answer in time denies and clears the row; Stop and New chat deny")
    func timeoutStopClear() async throws {
        let release = AsyncStream<Void>.makeStream()
        let model = AIChatModel()
        model.viewers = 1
        defer { model.clear() }
        model.send("go", acting: .success(Self.waiting("t1", "pilot run drive.shell:ls", until: release.stream)))
        await Self.rowOpen(model)
        // The question is not waited for: on a held main thread the clock can end it before the test would see it.
        let fellBack = Locked(0)
        let quick = Self.gate(model, wait: .milliseconds(300), fellBack: fellBack)
        let timedOut = await #expect(throws: ControlError.self) { try await quick.allow(Self.shell, peer: nil) {} }
        #expect(timedOut?.message.hasPrefix("no answer") == true && fellBack.now == 0, "the row's question, unanswered, denies")
        await Self.until { model.calls[0]?.first?.asking == nil }
        #expect(model.calls[0]?.first?.asking == nil, "the clock running out takes the question off the row")

        let gate = Self.gate(model)
        let stopping = Task { try await gate.allow(Self.shell, peer: nil) {} }
        _ = try #require(await Self.asked(model))
        model.stop()
        await #expect(throws: ControlError.self) { try await stopping.value }
        #expect(model.calls[0]?.first?.asking == nil && !model.running)
        #expect(model.calls[0]?.first?.result == "stopped" && model.calls[0]?.first?.failed == true, "a stopped turn's open row stops spinning")

        let next = AsyncStream<Void>.makeStream()
        model.send("again", acting: .success(Self.waiting("t2", "pilot run drive.shell:ls", until: next.stream)))
        await Self.rowOpen(model)
        let clearing = Task { try await gate.allow(Self.shell, peer: nil) {} }
        _ = try #require(await Self.asked(model))
        model.clear()
        await #expect(throws: ControlError.self) { try await clearing.value }
        release.continuation.yield()
        next.continuation.yield()
    }

    @Test("Pilot's prompt asks instead when no surface shows the chat, no turn runs, no row is open, or the chat closes mid-question")
    func fallsBack() async throws {
        let release = AsyncStream<Void>.makeStream()
        let model = AIChatModel()
        defer { model.clear() }
        let fellBack = Locked(0)
        let gate = Self.gate(model, fellBack: fellBack)
        await #expect(throws: ControlError.self) { try await gate.allow(Self.shell, peer: nil) {} }
        #expect(fellBack.now == 1, "no turn runs")

        model.send("go", acting: .success(Self.waiting("t1", "pilot run drive.shell:ls", until: release.stream)))
        await Self.rowOpen(model)
        await #expect(throws: ControlError.self) { try await gate.allow(Self.shell, peer: nil) {} }
        #expect(fellBack.now == 2, "no surface shows the chat")

        model.viewers = 1
        model.onScreen = { false }
        await #expect(throws: ControlError.self) { try await gate.allow(Self.shell, peer: nil) {} }
        #expect(fellBack.now == 3, "its window is minimised or hidden")
        model.onScreen = { true }
        model.viewers = 0

        model.viewers = 1
        let closing = Task { try await gate.allow(Self.shell, peer: nil) {} }
        _ = try #require(await Self.asked(model))
        model.viewers = 0
        await #expect(throws: ControlError.self) { try await closing.value }
        #expect(fellBack.now == 4 && model.calls[0]?.first?.asking == nil, "closing hands the question to the prompt")

        model.viewers = 1
        release.continuation.yield()
        await Self.until { model.calls[0]?.first?.result != nil }
        #expect(await model.decide(Self.shell, program: "x") == nil, "every row has its result: nothing to ask on")
    }

    @Test("AllowPrompt asks through the chat first and takes its answer without showing its own prompt")
    func promptRoutes() async {
        let saved = AllowPrompt.inline
        defer { AllowPrompt.inline = saved }
        let seen = Locked<[String]>([])
        AllowPrompt.inline = { ask, program in seen.value.withLock { $0.append("\(program): \(ask.text)") }; return true }
        #expect(await AllowPrompt.decide(Self.shell, peer: nil) == true)
        AllowPrompt.inline = { _, _ in false }
        #expect(await AllowPrompt.decide(Self.shell, peer: nil) == false)
        #expect(seen.now == ["a program: Run shell: brew upgrade"])
    }
}
