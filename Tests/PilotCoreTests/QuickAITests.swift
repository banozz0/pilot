import Foundation
import Testing
@testable import PilotCore

/// Quick AI (card agent-bo-95423050): Sven's own Claude plan through the Claude Code CLI. Every run here is a stub
/// `claude` script in a fresh temporary folder; the one real call waits for PILOT_LIVE=1.
@Suite("Quick AI")
struct QuickAITests {
    /// A `claude` that runs `body` under /bin/sh in a folder of its own; `args` beside it holds the arguments it was given.
    static func stub(_ body: String) throws -> ClaudeCLI {
        let folder = FileManager.default.temporaryDirectory.appending(path: "quick-ai-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "claude")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(folder.path)/args'\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return ClaudeCLI(path: script.path, timeout: .seconds(10))
    }

    static func delta(_ text: String) -> String {
        #"printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}'"#
    }

    static func result(_ text: String, error: Bool = false) -> String {
        #"printf '%s\n' '{"type":"result","subtype":"success","is_error":\#(error),"result":"\#(text)"}'"#
    }

    /// Collects the streamed pieces across the reading thread.
    final class Pieces: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
        var joined: String { lock.withLock { all.joined() } }
    }

    @Test("The CLI runs printing stream JSON with partial messages, no tools, no saved session, safe mode and low effort, the text never in its arguments")
    func arguments() {
        let args = QuickAI.arguments(for: .ask("what is a monad"))
        let high = QuickAI.arguments(for: .ask("x"), effort: .high)
        #expect(high.firstIndex(of: "--effort").map { high[$0 + 1] } == "high")
        #expect(args.starts(with: ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]))
        for flag in ["--no-session-persistence", "--safe-mode"] { #expect(args.contains(flag)) }
        #expect(args.firstIndex(of: "--tools").map { args[$0 + 1] } == "")
        #expect(args.firstIndex(of: "--effort").map { args[$0 + 1] } == "low")
        #expect(args.firstIndex(of: "--system-prompt").map { args[$0 + 1].hasPrefix(QuickAI.askPrompt) } == true)
        #expect(!args.contains("--model"))
        #expect(!args.contains { $0.contains("monad") })
        let fix = QuickAI.arguments(for: .fix("teh"))
        #expect(fix.firstIndex(of: "--system-prompt").map { fix[$0 + 1].hasPrefix(QuickAI.fixPrompt) } == true)
    }

    @Test("A stream line gives a piece of text, the final result or its error, and nothing for anything else")
    func events() {
        #expect(QuickAI.event(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Fo"}}}"#) == .text("Fo"))
        #expect(QuickAI.event(#"{"type":"result","subtype":"success","is_error":false,"result":"Four"}"#) == .result("Four", isError: false))
        #expect(QuickAI.event(#"{"type":"result","subtype":"error","is_error":true,"result":"Not logged in"}"#) == .result("Not logged in", isError: true))
        #expect(QuickAI.event(#"{"type":"stream_event","event":{"type":"message_start"}}"#) == nil)
        #expect(QuickAI.event(#"{"type":"system","subtype":"init"}"#) == nil)
        #expect(QuickAI.event("not json") == nil)
    }

    @Test("claude is found on PATH first, then in the folders Install looks in (~/.local/bin among them); nil when it is nowhere")
    func locate() {
        let local = NSString(string: "~/.local/bin/claude").expandingTildeInPath
        #expect(ClaudeCLI.locate(path: "/usr/bin:/a/bin", isExecutable: { $0 == "/a/bin/claude" || $0 == local })?.path == "/a/bin/claude")
        #expect(ClaudeCLI.locate(path: nil, isExecutable: { $0 == local })?.path == local)
        #expect(ClaudeCLI.locate(path: "/usr/bin", isExecutable: { $0 == "/opt/homebrew/bin/claude" })?.path == "/opt/homebrew/bin/claude")
        #expect(ClaudeCLI.locate(path: "/usr/bin", isExecutable: { _ in false }) == nil)
    }

    @Test("A fix keeps the selection's own leading and trailing spaces and line breaks")
    func fitted() {
        #expect(QuickAI.fitted("The fox.", to: "  teh fox\n") == "  The fox.\n")
        #expect(QuickAI.fitted("\nThe fox.\n\n", to: "teh fox") == "The fox.")
    }

    @Test("Typing ask and a question at the root gives one Ask AI row; ask alone a row saying to type one; a word starting with ask none")
    func entries() {
        let rows = QuickAI.entries(for: "ask what is a monad ")
        #expect(rows.map(\.target) == [.ask("what is a monad")])
        #expect(rows.first?.isAnswer == true && rows.first?.title == "Ask AI" && rows.first?.subtitle == "what is a monad")
        #expect(rows.first?.frecencyKey == nil)
        #expect(QuickAI.entries(for: "asking for it").isEmpty && QuickAI.entries(for: "ask").isEmpty)
        for bare in ["ask ", "ask a", "Ask  "] {
            let hint = QuickAI.entries(for: bare)
            #expect(hint.count == 1 && hint.first?.isAnswer == true && hint.first?.detail == "Type your question", "\(bare)")
            #expect(hint.first?.fills?.hasSuffix(" ") == true, "Return keeps the search and waits for the question")
        }
        #expect(RootAnswers.entries(for: "Ask why is the sky blue", now: .now).map(\.target) == [.ask("why is the sky blue")])
    }

    @Test("A run hands the text on stdin, streams each piece as it arrives and returns the result")
    func streams() async throws {
        let cli = try Self.stub("read -r line\n\(Self.delta("got "))\n\(Self.delta("'\"$line\"'"))\n\(Self.result("got hello there"))")
        let pieces = Pieces()
        let answer = try await cli.run(.ask("hello there")) { pieces.add($0) }
        #expect(answer == "got hello there")
        #expect(pieces.joined == "got hello there")
        let args = try String(contentsOf: URL(filePath: cli.path).deletingLastPathComponent().appending(path: "args"), encoding: .utf8)
        #expect(args.contains("stream-json") && !args.contains("hello"))
    }

    @Test("A failed run asks whether Claude Code is signed in: signed out says so, signed in gives the CLI's own message")
    func failures() async throws {
        let auth = { (loggedIn: Bool) in "if [ \"$1\" = auth ]; then echo '{\"loggedIn\": \(loggedIn)}'; exit \(loggedIn ? 0 : 1); fi" }
        let out = try Self.stub("\(auth(false))\n\(Self.result("Invalid API key · Please run /login", error: true))\nexit 1")
        await #expect(throws: QuickAI.Failure.signedOut) { try await out.run(.ask("hi")) { _ in } }
        let broken = try Self.stub("\(auth(true))\necho 'API Error: 529 overloaded' >&2\nexit 1")
        await #expect(throws: QuickAI.Failure.failed("API Error: 529 overloaded")) { try await broken.run(.ask("hi")) { _ in } }
        let errored = try Self.stub("\(auth(true))\n\(Self.result("Prompt is too long", error: true))")
        await #expect(throws: QuickAI.Failure.failed("Prompt is too long")) { try await errored.run(.ask("hi")) { _ in } }
    }

    @Test("A run past the timeout is killed and says it timed out")
    func timeout() async throws {
        var cli = try Self.stub("exec sleep 30")
        cli.timeout = .milliseconds(300)
        let start = ContinuousClock.now
        await #expect(throws: QuickAI.Failure.timedOut) { try await cli.run(.fix("teh")) { _ in } }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("A cancelled run kills the child at once")
    func cancel() async throws {
        let cli = try Self.stub("exec sleep 30")
        let task = Task { try await cli.run(.ask("hi")) { _ in } }
        try await Task.sleep(for: .milliseconds(300))
        // Timed from the cancel, not the start: a loaded Mac's slow spawn is not the kill (Build 65 took 5.7 s overall).
        // The child lives 30 s and the stub's clock is 10 s, so ending well inside 5 s means the cancel ended it.
        let cancelled = ContinuousClock.now
        task.cancel()
        await #expect(throws: QuickAI.Failure.cancelled) { try await task.value }
        #expect(ContinuousClock.now - cancelled < .seconds(5))
    }

    @Test("The real claude answers an ask", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func live() async throws {
        let cli = try #require(ClaudeCLI.locate(path: ProcessInfo.processInfo.environment["PATH"]))
        let pieces = Pieces()
        let answer = try await cli.run(.ask("Reply with the single word pong.")) { pieces.add($0) }
        #expect(answer.lowercased().contains("pong"))
        #expect(pieces.joined == answer)
    }
}
