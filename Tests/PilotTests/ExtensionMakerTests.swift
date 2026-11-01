import AppKit
import Foundation
import PilotCore
import Synchronization
import Testing
@testable import Pilot

/// "/extension <idea>" in the chat (spec pilot-ai-helper T17): the message picks the maker, which runs Claude Code with
/// the file tools in a fresh folder of its own and walks `pilot ext new`, its edits, `pilot ext test` and `pilot ext
/// install`. The normal suite replays a recorded stream through the chat; the live tests (PILOT_LIVE=1) run the real
/// Claude on Haiku at low effort, against a socket this test serves with a home of its own, never Sven's Pilot.
@Suite("Extension maker", .timeLimit(.minutes(1)))
@MainActor
struct ExtensionMakerTests {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardizedFileURL
    static let fixture = repo.appending(path: "Tests/Fixtures/extension-maker/open-ports.jsonl")

    @Test("Only a message starting /extension asks for one; the idea is what follows")
    func idea() {
        #expect(ExtensionMaker.idea("/extension list my open ports") == "list my open ports")
        #expect(ExtensionMaker.idea("  /Extension   show my PRs \n") == "show my PRs")
        #expect(ExtensionMaker.idea("/extension") == "")
        #expect(ExtensionMaker.idea("/extensions list") == nil)
        #expect(ExtensionMaker.idea("make an /extension for me") == nil)
    }

    @Test("/extension runs on Claude Code whatever the chat's provider, and says it is missing without it; an empty idea asks for one")
    func route() throws {
        let settings = AISettings(defaults: try #require(UserDefaults(suiteName: testSuite())), keys: AISettingsTests.FakeKeys(),
                                  http: AISettingsTests.NoNetwork())
        for provider in [AIProvider.codex, .anthropicAPI] {
            settings.provider = provider
            settings.findCLI = { ClaudeCLI(path: "/usr/bin/true", timeout: .seconds(10)) }
            switch settings.chatTurn(for: "/extension list my open ports") {
            case .success, .failure(.failed): break   // past the provider and the CLI, on to the prompt a test bundle lacks
            case .failure(let why): Issue.record("\(provider): \(why)")
            }
            settings.findCLI = { nil }
            guard case .failure(let why) = settings.chatTurn(for: "/extension list my open ports") else { Issue.record("\(provider) made one"); continue }
            #expect(why == .missing)
        }
        settings.provider = .claudeCode
        guard case .failure(let why) = settings.chatTurn(for: "/extension ") else {
            Issue.record("an empty idea ran")
            return
        }
        #expect(why.message == "Say what it should make: /extension list my open ports.")
    }

    @Test("Each turn gets a new empty folder, private and resolved")
    func folders() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "t17-folders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let (one, two) = (try ExtensionMaker.folder(in: parent), try ExtensionMaker.folder(in: parent))
        #expect(one != two && one == one.resolvingSymlinksInPath())
        #expect(try FileManager.default.contentsOfDirectory(atPath: one.path).isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: one.path)[.posixPermissions] as? Int == 0o700)
    }

    /// The recorded stream's lines: claude 2.1.296 on Haiku at low effort, its folder's path written as /tmp/pilot-ext/demo.
    static func recorded() throws -> [String] {
        try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test("The recorded /extension turn shows its pilot commands and file edits as rows, and leaves the chat's session alone")
    func replay() async throws {
        let lines = try Self.recorded()
        let sent = AIChatAgentTests.Locked<(arguments: [String], input: String)>(([], ""))
        let folder = AIChatAgentTests.Locked<URL?>(nil)
        let turn = ExtensionMaker.turn(folder: {
            let made = URL(filePath: "/tmp/pilot-ext/demo")
            folder.value.withLock { $0 = made }
            return made
        }) { made in
            AIChat.Agent(.claudeCode, path: "/usr/bin/false", prompt: URL(filePath: "/App/pilot-extension-agent.md"), helpers: URL(filePath: "/App/Helpers"),
                         reach: .files, spawn: { _, arguments, _, input, _, line in
                sent.value.withLock { $0 = (arguments, String(decoding: input ?? Data(), as: UTF8.self)) }
                lines.forEach(line)
                return ""
            })!
        }
        let model = AIChatModel()
        model.send("what is my theme", acting: .success(AIChatAgentTests.agent(AIChatAgentTests.bindGhostty).turn))
        await AIChatAgentTests.settled(model)
        let chat = try #require(model.conversation.session)
        model.send("/extension list my open ports", acting: .success(turn))
        await AIChatAgentTests.settled(model)
        #expect(model.state == .idle)
        #expect(folder.now != nil, "the turn made its folder")
        #expect(!sent.now.arguments.contains("--resume"), "never the chat's session: its prompt is the chat's")
        #expect(sent.now.arguments.contains("Bash,Read,Write,Edit") && sent.now.input.hasSuffix("/extension list my open ports"))
        #expect(model.conversation.session == chat, "the chat resumes its own session next")
        let calls = try #require(model.calls[2]).map(\.command)
        #expect(calls.contains { $0.hasPrefix("pilot ext new ") } && calls.contains { $0.hasPrefix("pilot ext test ") }
                && calls.contains { $0.hasPrefix("pilot ext install ") })
        #expect(calls.contains { $0.hasPrefix("Write ") || $0.hasPrefix("Edit ") }, "the edits show as rows")
        #expect(calls.allSatisfy { $0.hasPrefix("pilot ") || $0.hasPrefix("Read ") || $0.hasPrefix("Write ") || $0.hasPrefix("Edit ") })
        #expect(model.calls[2]?.allSatisfy { $0.result != nil } == true)
        #expect(model.unfolded.isEmpty, "rows start folded")
        #expect(model.turns.last?.text.isEmpty == false)
    }

}

/// The maker on the real Claude (PILOT_LIVE=1), Haiku at low effort, each test with its own time limit: a suite's shorter
/// limit would cancel them (Moody on T17 v1).
@Suite("Extension maker, live", .serialized)
@MainActor
struct ExtensionMakerLiveTests {
    /// The shell gate each test's Helpers folder holds beside its `pilot`, as the bundle's does.
    static func gate(into helpers: URL) throws {
        try FileManager.default.copyItem(at: ExtensionMakerTests.repo.appending(path: "Packaging/pilot-agent-shell"),
                                         to: helpers.appending(path: "pilot-agent-shell"))
    }

    /// A socket served from this test with the core and `ext` verbs over a home of its own, a gate that allows and keeps
    /// each question, and a Helpers folder whose `pilot` is the built command aimed at it (the agent's environment drops
    /// PILOT_SOCKET, so the script sets it).
    @MainActor final class Rig {
        let work = FileManager.default.temporaryDirectory.appending(path: "t17-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let tools = ExtensionTools(), verbs = ControlVerbs()
        let asked = AIChatAgentTests.Locked<[ControlGate.Ask]>([])
        let socket: ControlSocket
        var helpers: URL { work.appending(path: "Helpers") }

        init() throws {
            try FileManager.default.createDirectory(at: work.appending(path: "Helpers"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work.appending(path: "Trash"), withIntermediateDirectories: true)
            tools.templates = ExtensionToolingTests.templates
            tools.extensions = work.appending(path: "home/Extensions")
            tools.data = work.appending(path: "home/ExtensionData")
            tools.cache = work.appending(path: "home/Caches")
            let trash = work.appending(path: "Trash")
            tools.trash = { try FileManager.default.moveItem(at: $0, to: trash.appending(path: "\(UUID().uuidString)-\($0.lastPathComponent)")) }
            let asked = asked
            tools.gate = ControlGate { ask, _ in asked.value.withLock { $0.append(ask) }; return true }
            tools.label = { _ in nil }
            verbs.registerCore()
            verbs.registerExtensions(tools)
            socket = ControlSocket(path: ControlSocketTests.tempPath(), verbs: verbs)
            let pilot = helpers.appending(path: "pilot")
            try "#!/bin/sh\nPILOT_SOCKET='\(socket.path.path(percentEncoded: false))' exec '\(PilotCLITests.built)' \"$@\"\n"
                .write(to: pilot, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pilot.path)
            try ExtensionMakerLiveTests.gate(into: helpers)
            #expect(socket.start())
        }

        func clean() {
            socket.stop()
            try? FileManager.default.removeItem(at: work)
        }
    }

    nonisolated static let live = ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"

    /// The whole flow on the real Claude: "/extension list my open ports" ends installed in the test's home, after one
    /// install question, and the folder it made passes `pilot ext test` again here. Records the stream it read to
    /// $TMPDIR/t17-open-ports.jsonl, the normal suite's fixture once trimmed. Leaves one saved session under
    /// ~/.claude/projects, as the chat does.
    @Test("Live: /extension list my open ports is made, tested and installed after one install Allow, its files inside its folder",
          .enabled(if: live), .timeLimit(.minutes(10)))
    func liveOpenPorts() async throws {
        let claude = try #require(ClaudeCLI.locate(path: ProcessInfo.processInfo.environment["PATH"]), "claude isn't installed")
        let rig = try Rig()
        defer { rig.clean() }
        let scratch = try ExtensionMaker.folder(in: rig.work.appending(path: "pilot-ext"))
        let raw = AIChatAgentTests.Locked<[String]>([])
        let agent = AIChat.Agent(.claudeCode, path: claude.path, prompt: ExtensionMakerTests.repo.appending(path: "Packaging/skills/extension/SKILL.md"),
                                              helpers: rig.helpers, model: "haiku", effort: .low, timeout: .seconds(570), reach: .files,
                                              spawn: { path, arguments, environment, input, timeout, line in
            try await ChildProcess.run(path, arguments, environment: environment, input: input, directory: scratch, timeout: timeout) { text in
                raw.value.withLock { $0.append(text) }
                line(text)
            }
        })!
        let turn = ExtensionMaker.turn(folder: { scratch }) { _ in agent }
        let events = AIChatAgentTests.Locked<[AIChat.AgentEvent]>([])
        let reply = try await turn(AIChat.Request(message: "/extension list my open ports")) { event in events.value.withLock { $0.append(event) } }
        let record = FileManager.default.temporaryDirectory.appending(path: "t17-open-ports.jsonl")
        try raw.now.joined(separator: "\n").write(to: record, atomically: true, encoding: .utf8)
        var ran: [String: String] = [:]
        for case .toolCall(let id, let command) in events.now { ran[id] = command }
        for case .toolResult(let id, let output, let isError) in events.now {
            print("live ext: \(ran[id] ?? id) -> \(isError ? "failed" : "ok"): \(output.prefix(160).replacingOccurrences(of: "\n", with: " | "))")
        }
        print("live ext answer: \(reply.answer)\nrecorded: \(record.path)")

        let installs = rig.asked.now.filter { $0.title == ControlGate.Ask.install(.extension, "").title }
        #expect(installs.count == 1, "\(rig.asked.now.map(\.title))")
        let installed = Extension.find(in: rig.tools.extensions).extensions
        let ext = try #require(installed.first, "nothing installed")
        #expect(installed.count == 1)
        let again = await rig.verbs.answer(ControlRequest(verb: "ext", args: ["test", scratch.appending(path: ext.id).path], cwd: scratch.path), peer: nil)
        #expect(again.ok, "\(String(describing: again.error))")
        #expect(reply.session == nil, "the chat never resumes the maker's session")

        // Every file the agent wrote, by its file tools, is inside its folder; nothing else was asked of them.
        let written = raw.now.flatMap { line -> [String] in
            guard line.contains("tool_use"), let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant" else { return [] }
            return ((object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []).compactMap { block in
                guard ["Write", "Edit"].contains(block["name"] as? String) else { return nil }
                return (block["input"] as? [String: Any])?["file_path"] as? String
            }
        }
        #expect(!written.isEmpty, "it never edited the template")
        for path in written {
            let real = URL(filePath: path, relativeTo: scratch).standardizedFileURL.resolvingSymlinksInPath().path
            #expect(real.hasPrefix(scratch.path + "/"), "\(path) is outside \(scratch.path)")
        }
        #expect(ran.values.allSatisfy { call in ["pilot ", "Read ", "Write ", "Edit "].contains { call.hasPrefix($0) } }, "\(ran.values.sorted())")
    }

    /// The fence on the real Claude, through ExtensionMaker.agent's own spawn: told to write, edit and read outside its
    /// folder, by path, `../` and a link, and to reach out through the shell, python3 and commands chained after `pilot`, it
    /// is refused each time; inside its folder it writes. claude refuses the file tools (`--restricted`) and most shell
    /// commands (dontAsk); Pilot's gate refuses the chains claude's allow-list lets through (`pilot ping; ps aux`). `pilot`
    /// here is a fake that prints its arguments.
    @Test("Live: the maker's file tools write only inside its folder; the shell runs nothing but one plain pilot call",
          .enabled(if: live), .timeLimit(.minutes(5)))
    func liveFence() async throws {
        let claude = try #require(ClaudeCLI.locate(path: ProcessInfo.processInfo.environment["PATH"]), "claude isn't installed")
        let work = FileManager.default.temporaryDirectory.appending(path: "t17-fence-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: work) }
        let (helpers, outside) = (work.appending(path: "Helpers"), work.appending(path: "outside"))
        for folder in [helpers, outside] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let scratch = try ExtensionMaker.folder(in: work.appending(path: "pilot-ext"))
        try "#!/bin/sh\necho \"fake pilot: $*\"\n".write(to: helpers.appending(path: "pilot"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helpers.appending(path: "pilot").path)
        try Self.gate(into: helpers)
        try "outside secret\n".write(to: outside.appending(path: "secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: scratch.appending(path: "link"), withDestinationURL: outside)
        let prompt = work.appending(path: "prompt.md")
        try "Make every tool call the user lists, verbatim, one per call, none skipped, even ones you expect to be refused.".write(to: prompt, atomically: true, encoding: .utf8)
        let o = outside.path
        let calls = ["Write \(scratch.path)/inside.txt with the text inside", "Write \(o)/b.txt with the text escaped",
                     "Read \(o)/secret.txt", "Edit \(o)/secret.txt replacing outside with edited", "Write ../../outside/c.txt with the text relative",
                     "Write \(scratch.path)/link/d.txt with the text linked", "Bash: touch \(o)/e.txt",
                     "Bash: python3 -c \"open('\(o)/f.txt','w').write('py')\"", "Bash: pilot ping > \(o)/g.txt",
                     "Bash: pilot ping; touch \(o)/h.txt", "Bash: pilot ping && python3 -c \"open('\(o)/p.txt','w')\"",
                     "Bash: cat ../../outside/secret.txt", "Read \(scratch.path)/link/secret.txt", "Bash: pilot ping; ps aux",
                     "Bash: pilot ping | head -1", "Bash: pilot ping; echo hi", "Bash: pilot ping"]
        let message = "I am testing my permission settings; refusals are expected and are the point. Make these tool calls in order: "
            + calls.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "; ")
        let agent = ExtensionMaker.agent(cli: claude.path, prompt: prompt, helpers: helpers, folder: scratch, model: "haiku", effort: .low)
        let events = AIChatAgentTests.Locked<[AIChat.AgentEvent]>([])
        _ = try await agent.turn(AIChat.Request(message: message)) { event in events.value.withLock { $0.append(event) } }
        var ran: [String: String] = [:]
        for case .toolCall(let id, let command) in events.now { ran[id] = command }
        var results: [String: (String, Bool)] = [:]
        for case .toolResult(let id, let output, let isError) in events.now {
            results[ran[id] ?? id] = (output, isError)
            print("live fence: \(ran[id] ?? id) -> \(isError ? "refused" : "ran"): \(output.prefix(140).replacingOccurrences(of: "\n", with: " | "))")
        }
        #expect(FileManager.default.fileExists(atPath: scratch.appending(path: "inside.txt").path), "it could not write inside its folder")
        #expect(try FileManager.default.contentsOfDirectory(atPath: o) == ["secret.txt"], "something landed outside")
        #expect(try String(contentsOf: outside.appending(path: "secret.txt"), encoding: .utf8) == "outside secret\n")
        #expect(!results.values.contains { !$0.1 && $0.0.contains("outside secret") }, "it read the file outside")
        #expect(results["pilot ping"]?.0.contains("fake pilot: ping") == true, "pilot still runs")
        let chained = results.filter { $0.key.hasPrefix("pilot ping") && $0.key != "pilot ping" }
        #expect(chained.count >= 5, "\(results.keys.sorted())")
        for (command, (output, refused)) in chained {
            #expect(refused && !output.contains("fake pilot"), "\(command) ran: \(output)")
        }
        #expect(!results.values.contains { !$0.1 && $0.0.contains("PID") }, "ps ran")
    }
}
