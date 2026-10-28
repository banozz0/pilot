import Foundation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// The AI chat panel (story 166): the model streams a fake runner's turns with the history before each, Stop and New
/// chat, and the panel opening in Ask AI's bar drop (spec Bar drops T5), closing and reopening on the same conversation,
/// the Allow gate still asking in it. No real AI runs here.
@Suite("AI chat panel", .timeLimit(.minutes(5)))   // AIChatAgentTests.until waits until cancelled: never forever; 5 min as AIChatAgentTests says
@MainActor
struct AIChatPanelTests {
    final class Sent: Sendable { let requests = Mutex<[AIChat.Request]>([]) }

    /// A runner that streams `answer(n)` for the nth turn and hands back a claude session.
    nonisolated static func runner(_ sent: Sent) -> AIChat.Runner {
        { request, text throws(QuickAI.Failure) in
            let n = sent.requests.withLock { $0.append(request); return $0.count }
            text("answer ")
            text("\(n)")
            return AIChat.Reply("answer \(n)", session: AIChat.Session(.claudeCode, "s\(n)"))
        }
    }

    /// A runner that sends a piece, then waits on `gate`.
    nonisolated static func gated(_ gate: AsyncStream<Void>) -> AIChat.Runner {
        { _, text throws(QuickAI.Failure) in
            text("half an ")
            for await _ in gate { break }
            return AIChat.Reply("never")
        }
    }

    func settled(_ model: AIChatModel) async {
        for _ in 0..<200 where model.running { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("Open AI chat is registered on Hyper+Q, beside Ask AI")
    func binds() {
        var registry = ActionRegistry()
        AIChatPanel.register(into: &registry)
        #expect(registry.actions["ai.chat"]?.label == "Open AI chat" && registry.defaults["ai.chat"] == Key("q"))
        #expect(registry.actions["ai.chat"]?.tier == .v1 && registry.actions["ai.chat"]?.module == .apps)
    }

    @Test("Each turn is sent with the turns before it and the session the last answer came from")
    func turns() async {
        let model = AIChatModel(), sent = Sent()
        model.send("first", through: .success(Self.runner(sent)))
        await settled(model)
        model.draft = "  second \n"
        model.send(through: .success(Self.runner(sent)))
        #expect(model.draft.isEmpty, "the input empties as the message goes")
        await settled(model)
        let requests = sent.requests.withLock { $0 }
        #expect(requests.map(\.message) == ["first", "second"])
        #expect(requests.last?.history == [AIChat.Turn(.user, "first"), AIChat.Turn(.assistant, "answer 1")])
        #expect(requests.last?.session == AIChat.Session(.claudeCode, "s1"))
        #expect(model.turns.map(\.text) == ["first", "answer 1", "second", "answer 2"] && model.state == .idle)
        model.send("   ", through: .success(Self.runner(sent)))
        #expect(model.turns.count == 4, "nothing typed sends nothing")
    }

    @Test("Stop keeps what came as the answer, or leaves the message unanswered; a missing provider says why")
    func stopAndFail() async {
        let gate = AsyncStream<Void>.makeStream()
        let model = AIChatModel()
        model.send("long one", through: .success(Self.gated(gate.stream)))
        for _ in 0..<100 where model.streaming.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.streaming == "half an " && model.running)
        model.stop()
        #expect(model.turns.last == AIChat.Turn(.assistant, "half an ") && model.state == .idle)
        gate.continuation.yield()

        let none = AIChatModel()
        none.send("hello", through: .failure(.missing))
        #expect(none.state == .failed(.missing) && none.turns == [AIChat.Turn(.user, "hello")])
        let sent = Sent()
        none.send("again", through: .success(Self.runner(sent)))
        await settled(none)
        #expect(sent.requests.withLock { $0 }.first?.history.isEmpty == true, "the unanswered message is not history")
        none.clear()
        #expect(none.turns.isEmpty && none.state == .idle)
    }

    @Test("ask … opens the panel with the question sent; closing keeps the conversation for the next open; toggle closes", .pilotFocus)
    func panel() async {
        let panel = AIChatPanel(drops: BarDropPanelTests.drops(), page: { false }), sent = Sent()
        panel.route = { _ in .success(AIChatModel.turn(Self.runner(sent))) }
        panel.routeName = { "Claude Code · Sonnet" }
        panel.show(sending: "why is the sky blue")
        defer { panel.hide() }
        #expect(panel.isShown && panel.model.route == "Claude Code · Sonnet")
        await settled(panel.model)
        #expect(panel.model.turns.map(\.text) == ["why is the sky blue", "answer 1"])
        panel.hide()
        #expect(!panel.isShown)
        panel.show()
        #expect(panel.isShown && panel.model.turns.count == 2, "reopening shows the same conversation")
        panel.toggle()
        #expect(!panel.isShown)
    }

    @Test("It opens on Ask AI's bar drop frame: centred under the bar alone, right of the terminal beside it", .pilotFocus)
    func placement() throws {
        let drops = BarDropPanelTests.drops(), spot = BarDropPanelTests.spot
        let panel = AIChatPanel(drops: drops, page: { false })
        panel.show()
        defer { drops.hideAll() }
        let alone = BarDropPanelTests.place([.askAI])[.askAI]
        #expect(drops.window(.askAI)?.frame == alone && alone?.maxY == spot.bar?.minY)
        drops.open(.terminal, face: BarDropPanelTests.face())
        #expect(drops.window(.askAI)?.frame == BarDropPanelTests.place([.askAI, .terminal])[.askAI])
        let content = try #require(drops.window(.askAI)?.contentView)
        #expect(content.frame.size == drops.window(.askAI)?.frame.size, "the chat fills the drop as it narrows")
    }

    @Test("In its drop the chat still asks the Allow gate inline; closed, the gate falls back to Pilot's own prompt", .pilotFocus)
    func allowInline() async throws {
        let drops = BarDropPanelTests.drops()
        let panel = AIChatPanel(drops: drops, page: { false })
        let model = panel.model, release = AsyncStream<Void>.makeStream()
        panel.show()
        defer { drops.hideAll(); model.clear() }
        model.viewers += 1   // the chat view's onAppear, which an unshown test window may not run
        model.send("go", acting: .success(AIChatAgentTests.waiting("t1", "pilot run drive.shell:ls", until: release.stream)))
        await AIChatAgentTests.rowOpen(model)
        let fellBack = AIChatAgentTests.Locked(0)
        let gate = AIChatAgentTests.gate(model, fellBack: fellBack)
        let allowing = Task { try await gate.allow(AIChatAgentTests.shell, peer: nil) {} }
        let asking = try #require(await AIChatAgentTests.asked(model))
        model.answer(true, asked: asking.asked)
        try await allowing.value
        #expect(fellBack.now == 0, "asked on the row in the drop")
        panel.hide()
        await #expect(throws: ControlError.self) { try await gate.allow(AIChatAgentTests.shell, peer: nil) {} }
        #expect(fellBack.now == 1, "the drop closed: Pilot's own prompt asks")
        release.continuation.yield()
        await AIChatAgentTests.settled(model)
    }

    @Test("A chat unused for the AI page's idle time starts over on its next open; Never, a shorter wait or a running answer keeps it", .pilotFocus)
    func idleReset() async {
        let panel = AIChatPanel(drops: BarDropPanelTests.drops(), page: { false }), sent = Sent()
        panel.route = { _ in .success(AIChatModel.turn(Self.runner(sent))) }
        panel.reset = { .minutes30 }
        panel.show(sending: "first")
        defer { panel.hide() }
        await settled(panel.model)
        let last = panel.model.lastUsed
        panel.hide()
        panel.clock = { last.addingTimeInterval(29 * 60) }
        panel.show()
        #expect(panel.model.turns.count == 2, "29 minutes keeps the chat")
        panel.hide()
        panel.reset = { .never }
        panel.clock = { last.addingTimeInterval(24 * 3600) }
        panel.show()
        #expect(panel.model.turns.count == 2, "Never keeps it")
        panel.hide()
        panel.reset = { .minutes30 }
        panel.clock = { last.addingTimeInterval(30 * 60) }
        panel.show(sending: "fresh")
        await settled(panel.model)
        #expect(panel.model.turns.map(\.text) == ["fresh", "answer 2"], "30 minutes on, the open starts a new chat")
        #expect(sent.requests.withLock { $0 }.last?.history.isEmpty == true && sent.requests.withLock { $0 }.last?.session == nil,
                "the new chat resumes no CLI session")

        let gate = AsyncStream<Void>.makeStream()
        let model = AIChatModel()
        model.send("long one", through: .success(Self.gated(gate.stream)))
        #expect(!model.expire(after: .minutes15, now: Date().addingTimeInterval(3600)) && model.running, "an answer streaming is never cut")
        model.stop()
        gate.continuation.yield()
        #expect(model.expire(after: .minutes15, now: Date().addingTimeInterval(3600)) && model.turns.isEmpty)
    }

    /// A fake `claude` that records its pid in `pids`; slow, it starts a `sleep` child (recorded too) and streams half an
    /// answer, then waits on it.
    static func fakeClaude(slow: Bool) throws -> (path: String, pids: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pids = dir.appending(path: "pids"), path = dir.appending(path: "claude")
        let stream = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half"}}}"#
        let script = """
            #!/bin/bash
            [ "$1" = auth ] && { echo '{"loggedIn":true}'; exit 0; }
            cat > /dev/null
            echo $$ >> '\(pids.path)'
            \(slow ? "sleep 30 & echo $! >> '\(pids.path)'; echo '\(stream)'; wait" : "")
            echo '{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s1"}'
            """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return (path.path, pids)
    }

    nonisolated static func alive(_ pids: URL) -> [pid_t] {
        let text = (try? String(contentsOf: pids, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { pid_t($0) }.filter { kill($0, 0) == 0 }
    }

    @Test("No claude child outlives its turn: a finished turn's has exited, and New chat or the idle reset kills a running one and its children")
    func childrenEnd() async throws {
        let fast = try Self.fakeClaude(slow: false)
        let model = AIChatModel()
        model.send("hi", through: .success(ClaudeCLI(path: fast.path).chat(_:text:)))
        await settled(model)
        #expect(model.turns.last == AIChat.Turn(.assistant, "done"))
        let ran = (try? String(contentsOf: fast.pids, encoding: .utf8)) ?? ""
        #expect(!ran.isEmpty && Self.alive(fast.pids).isEmpty, "the finished turn's claude has exited")

        let slow = try Self.fakeClaude(slow: true)
        model.send("long one", through: .success(ClaudeCLI(path: slow.path).chat(_:text:)))
        for _ in 0..<300 where model.streaming.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(Self.alive(slow.pids).count == 2, "claude and its child run while the answer streams")
        model.clear()
        for _ in 0..<200 where !Self.alive(slow.pids).isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(Self.alive(slow.pids).isEmpty, "New chat (and the idle reset, which is New chat) ends claude and its child")
        #expect(model.turns.isEmpty && !model.running)
    }
}
