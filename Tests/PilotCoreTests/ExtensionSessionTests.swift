import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423245 (ADR 0010): a session command's program starts as its view opens and stays alive, answering a
/// query message for each search; a close message, stdin closed and a stop half a second later end it. A detail answer is
/// markdown, facts beside it and actions. The fixtures are tiny shell programs in a temporary folder; a run that is not
/// about time gets 30 s, so a shell slow to start under a full suite's load still answers.
@Suite("Extension sessions")
struct ExtensionSessionTests {
    private func command(_ body: String, session: Bool = true, mode: String = "list", filter: String? = nil) throws -> (Extension.Command, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-sess-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fields = (session ? #", "session": true"# : "") + (filter.map { #", "filter": "\#($0)""# } ?? "")
        try Data(#"{"id": "demo", "title": "Demo", "commands": [{"name": "rows", "title": "Rows", "mode": "\#(mode)", "run": "go"\#(fields)}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        let program = dir.appending(path: "go")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        return (try Extension(folder: dir).commands[0], dir)
    }

    /// Answers each line with one item: its title the program's pid, its subtitle the line it read; a close message
    /// leaves a mark and ends it.
    private let echo = #"""
        while IFS= read -r line; do
          case "$line" in *'"type":"close"'*) echo closed > closed; exit 0;; esac
          esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
          printf '{"type":"list","items":[{"title":"%s","subtitle":"%s"}]}\n' "$$" "$esc"
        done
        """#

    @Test("A session command filters itself; session on a command that is not a list, or with Pilot's filter, is refused")
    func manifest() throws {
        let (rows, a) = try command("true")
        defer { try? FileManager.default.removeItem(at: a) }
        #expect(rows.session && rows.filter == .program)
        let (oneShot, b) = try command("true", session: false)
        defer { try? FileManager.default.removeItem(at: b) }
        #expect(!oneShot.session)
        #expect(throws: Extension.Problem.sessionNeedsOwnList(command: "rows")) { try command("true", mode: "no-view") }
        #expect(throws: Extension.Problem.sessionNeedsOwnList(command: "rows")) { try command("true", filter: "pilot") }
        let (detail, c) = try command("true", session: false, mode: "detail")
        defer { try? FileManager.default.removeItem(at: c) }
        #expect(detail.mode == .detail)
    }

    @Test("One process answers three searches, the run message first, then a query message each; close ends it")
    func threeQueries() async throws {
        let (rows, dir) = try command(echo)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = ExtensionSession(rows, context: .string("ctx"), inputs: .sample, timeout: .seconds(30))
        var answers: [Extension.Item] = []
        for query in ["", "p", "pi"] {
            guard case .items(let items) = await session.ask(query) else { Issue.record("no items for \(query)"); return }
            answers += items
        }
        let pid = try #require(session.pid)
        #expect(answers.map(\.title) == Array(repeating: "\(pid)", count: 3), "one process answered all three")
        #expect(answers.map(\.subtitle) == [#"{"command":"rows","context":"ctx","extension":"demo","paths":{"cache":"/tmp/pilot-ext-cache","data":"/tmp/pilot-ext-data"},"preferences":{},"query":"","type":"run"}"#,
                                            #"{"text":"p","type":"query"}"#, #"{"text":"pi","type":"query"}"#])
        session.close()
        await session.ended()
        #expect(kill(pid, 0) != 0, "process \(pid) still runs")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "closed").path), "the close message reached it")
    }

    @Test("A session that stops answering gives the error row and is killed; later searches get the error, no new process")
    func silent() async throws {
        let (rows, dir) = try command("while IFS= read -r line; do :; done")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = ExtensionSession(rows, context: nil, inputs: .sample, timeout: .seconds(1))
        #expect(await session.ask("") == .error("did not answer in 1 s"))
        let pid = try #require(session.pid)
        await session.ended()
        #expect(kill(pid, 0) != 0, "process \(pid) still runs")
        #expect(await session.ask("p") == .error("did not answer in 1 s"))
        #expect(session.pid == pid)
    }

    @Test("A line a session program prints outside the message format answers no search; the next message does")
    func plainLines() async throws {
        let (rows, dir) = try command(#"""
            while IFS= read -r line; do
              echo "debug: got a line"; echo '{"note":"no type"}'
              printf '{"type":"list","items":[{"title":"%s"}]}\n' "${#line}"
            done
            """#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = ExtensionSession(rows, context: nil, inputs: .sample, timeout: .seconds(30))
        defer { session.close() }
        for query in ["", "p"] {
            guard case .items(let items) = await session.ask(query) else { Issue.record("no items for \(query)"); return }
            #expect(items.count == 1, "query \(query)")
        }
    }

    @Test("A session program that exits gives its stderr as the error row")
    func exits() async throws {
        let (rows, dir) = try command("read -r line; echo boom >&2; exit 3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = ExtensionSession(rows, context: nil, inputs: .sample, timeout: .seconds(30))
        #expect(await session.ask("") == .error("stopped with an error: boom"))
    }

    @Test("A detail answer decodes its markdown, facts and actions, an unknown action dropped")
    func detail() throws {
        let line = ##"{"type":"detail","markdown":"# pilot\nA Mac launcher","metadata":[{"label":"Stars","text":"12"}],"##
            + #""actions":[{"type":"copy","text":"example/repo","title":"Copy name"},{"type":"someday"}]}"#
        guard case .detail(let detail) = ExtensionRun.answer(line) else { Issue.record("no detail"); return }
        #expect(detail.markdown == "# pilot\nA Mac launcher")
        #expect(detail.metadata == [Extension.Detail.Fact(label: "Stars", text: "12")])
        #expect(detail.actions == [Extension.Item.Action(kind: .copy("example/repo"), title: "Copy name")])
        #expect(detail.dropped == 1)
        #expect(ExtensionRun.answer(#"{"type":"detail"}"#) == .detail(Extension.Detail(markdown: "", metadata: [], actions: [])))
    }

    @Test("A detail is one answer row: its actions under Cmd+K, Return's first, the detail carried for the panel to draw")
    func detailRow() throws {
        let (rows, dir) = try command("true", session: false, mode: "detail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let detail = Extension.Detail(markdown: "Hi", metadata: [], actions: [.copy("x"), .open("https://example.com")])
        let row = ExtensionList.detail(detail, of: rows)
        #expect(row.isAnswer && row.extensionDetail == detail)
        #expect(row.ownActions == ["Copy", "Open"])
        #expect(ExtensionList.item(at: row, in: [Extension.Item(title: "", actions: detail.actions)])?.actions == detail.actions)
    }
}
