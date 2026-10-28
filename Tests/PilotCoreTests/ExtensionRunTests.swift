import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423242 (ADR 0010): an extension command runs as a child process. Pilot writes one JSON line on its
/// stdin and reads the JSON lines it prints; the child gets a small fixed environment, never Pilot's own and never the
/// link token. The fixtures are tiny shell programs in a temporary folder.
@Suite("Extension runs")
struct ExtensionRunTests {
    private func command(_ body: String, name: String = "go") throws -> (Extension.Command, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-run-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"id": "demo", "title": "Demo", "commands": [{"name": "\#(name)", "title": "Go", "mode": "no-view", "run": "go"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        let program = dir.appending(path: "go")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        return (try Extension(folder: dir).commands[0], dir)
    }

    /// Pilot's own environment as a test pretends it: the link token sitting in it must never reach the child.
    private let pilot = ["PATH": "/usr/bin:/bin", "HOME": "/Users/test", "USER": "test", "TMPDIR": "/tmp/", "PILOT_LINK_TOKEN_SAMPLE": "lt-7f3a",
                         "SSH_AUTH_SOCK": "/tmp/agent", "ANTHROPIC_API_KEY_SAMPLE": "sk-nope"]

    @Test("A no-view command's HUD message is what it shows")
    func hud() async throws {
        let (go, dir) = try command(#"echo '{"type": "hud", "text": "Copied 3 links"}'"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ExtensionRun.noView(go, inputs: .sample, environment: pilot) == .hud("Copied 3 links"))
    }

    @Test("Stdin carries the run message, and the command runs in its own folder")
    func stdin() async throws {
        let (go, dir) = try command("cat; pwd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = try await ExtensionRun.output(go, inputs: .sample, environment: pilot)
        let lines = output.split(separator: "\n").map(String.init)
        let message = try JSONDecoder().decode([String: JSONValue].self, from: Data(lines[0].utf8))
        #expect(message.filter { $0.key != "preferences" && $0.key != "paths" } == ["type": .string("run"), "extension": .string("demo"),
                                                                                  "command": .string("go")])
        #expect(lines.last.map { URL(filePath: $0).resolvingSymlinksInPath().path } == dir.resolvingSymlinksInPath().path)
    }

    @Test("The child's environment is the fixed list, its PATH reaching Homebrew; no link token, no key, nothing else of Pilot's")
    func environment() async throws {
        let (go, dir) = try command("env")
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = try await ExtensionRun.output(go, inputs: .sample, environment: pilot)
        let env = Dictionary(output.split(separator: "\n").compactMap { line -> (String, String)? in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        }) { a, _ in a }
        #expect(!output.contains("lt-7f3a") && !output.contains("sk-nope"))
        // /bin/sh adds PWD, SHLVL and _ of its own.
        #expect(Set(env.keys).subtracting(["PWD", "SHLVL", "_", "OLDPWD"]) == ["PATH", "HOME", "USER", "LANG", "TMPDIR", "PILOT_EXTENSION_ID"])
        #expect(env["PILOT_EXTENSION_ID"] == "demo" && env["HOME"] == "/Users/test" && env["LANG"] == "en_US.UTF-8")
        #expect(env["PATH"] == "\(dir.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "its folder, Homebrew's, the system's")
    }

    @Test("Plain output's last line is the HUD line, an error message wins, and silence says nothing")
    func outcomes() {
        #expect(ExtensionRun.outcome(of: "working\ndone: 3 files\n") == .hud("done: 3 files"))
        #expect(ExtensionRun.outcome(of: #"{"type": "error", "text": "No token"}"# + "\n" + #"{"type": "hud", "text": "ok"}"#)
                == .error("No token"))
        #expect(ExtensionRun.outcome(of: #"{"type": "hud", "text": "a"}"# + "\nplain\n") == .hud("a"), "a HUD message beats a plain line")
        #expect(ExtensionRun.outcome(of: #"{"type": "someday", "x": 1}"#) == .hud(nil), "an unknown message is skipped")
        #expect(ExtensionRun.outcome(of: "") == .hud(nil))
    }

    @Test("A command still running at its timeout is stopped with the children it started, even one ignoring SIGTERM, and says so",
          arguments: ["sleep 60", "trap '' TERM; sleep 60; sleep 60", "sleep 60 & sleep 60 & wait",
                      // A child started after the timeout, in the half second before SIGKILL, as a loaded Mac starts the
                      // script's children late: it held stdout open for its whole life.
                      "trap '' TERM; sleep 0.6; sleep 60; true",
                      // A child whose parent is gone before the listing, as one forked late is: no one's descendant, still
                      // in the command's process group, holding stdout (full runs, 2026-10-10).
                      "(sleep 60 &); sleep 60"])
    func timeout(body: String) async throws {
        let (go, dir) = try command(body)
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = ContinuousClock.now
        #expect(await ExtensionRun.noView(go, inputs: .sample, environment: pilot, timeout: .milliseconds(300)) == .timedOut)
        // The children held its stdout open, so the run ended only once they were gone too: a run that waited them out
        // takes a minute. Half of that is the bound, so a loaded Mac's slow kill (5.4 s once, lane 1 m122) still passes.
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test("A command that exits non-zero fails with what it printed to stderr")
    func fails() async throws {
        let (go, dir) = try command("echo 'no network' >&2; exit 3")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await ExtensionRun.noView(go, inputs: .sample, environment: pilot) == .failed("no network"))
    }
}

/// Card agent-bo-95423243: a list command's program answers the run message, which carries the search, with
/// {"type":"list","items":[...]}; a slow, failing or garbled answer is one error row.
@Suite("Extension lists")
struct ExtensionListTests {
    private func command(_ body: String, filter: String? = nil) throws -> (Extension.Command, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-list-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let field = filter.map { #", "filter": "\#($0)""# } ?? ""
        try Data(#"{"id": "demo", "title": "Demo", "icon": "🧪", "commands": [{"name": "rows", "title": "Rows", "mode": "list", "run": "go"\#(field)}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        let program = dir.appending(path: "go")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        return (try Extension(folder: dir).commands[0], dir)
    }

    private let list = #"""
        {"type": "list", "items": [
          {"id": "pilot", "title": "pilot", "subtitle": "banozz/pilot", "icon": "📦", "keywords": "mac",
           "actions": [{"type": "open", "url": "https://github.com/example/repo"}, {"type": "copy", "text": "example/repo"}]},
          {"title": "cockpit", "actions": [{"type": "copy", "text": "example/cockpit"}, {"type": "someday"}]}]}
        """#.replacingOccurrences(of: "\n", with: " ")

    @Test("A list command's filter is Pilot's unless it says self")
    func filter() throws {
        let (pilot, a) = try command("true"), (own, b) = try command("true", filter: "self")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(pilot.filter == .pilot && own.filter == .program)
    }

    @Test("The program's items arrive in order with their actions; an action type Pilot does not know is dropped")
    func items() async throws {
        let (rows, dir) = try command("echo '\(list)'")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .items(let items) = await ExtensionRun.list(rows, query: "", inputs: .sample) else { Issue.record("no items"); return }
        #expect(items.map(\.title) == ["pilot", "cockpit"])
        #expect(items[0].subtitle == "banozz/pilot" && items[0].icon == "📦" && items[0].keywords == "mac")
        #expect(items[0].actions == [.open("https://github.com/example/repo"), .copy("example/repo")])
        #expect(items[1].actions == [.copy("example/cockpit")])
    }

    @Test("The run message carries the search")
    func query() async throws {
        // The program answers with one item titled after the line it read.
        let (rows, dir) = try command(#"read -r line; printf '{"type":"list","items":[{"title":%s}]}\n' "$(printf '%s' "$line" | sed 's/"/\\"/g; s/^/"/; s/$/"/')""#)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .items(let items) = await ExtensionRun.list(rows, query: "pil ot", inputs: .sample) else { Issue.record("no items"); return }
        let message = try JSONDecoder().decode([String: JSONValue].self, from: Data(items[0].title.utf8))
        #expect(message["query"] == .string("pil ot") && message["command"] == .string("rows"))
    }

    @Test("Slow, failing, garbled or empty answers come back as the reason the error row shows")
    func errors() async throws {
        for (body, reason) in [("exec sleep 5", "did not answer in 0.3 s"), ("echo nope >&2; exit 2", "stopped with an error: nope"),
                               ("echo 'not json'", "sent a line Pilot can't read"), ("true", "sent no list"),
                               (#"echo '{"type": "error", "text": "No token set"}'"#, "says: No token set")] {
            let (rows, dir) = try command(body)
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(await ExtensionRun.list(rows, query: "", inputs: .sample, timeout: .milliseconds(body.contains("sleep") ? 300 : 2000)) == .error(reason),
                    "\(body)")
        }
    }

    @Test("A list that does not answer in time is stopped: its process is gone when the error row comes back")
    func stopped() async throws {
        let (rows, dir) = try command("echo $$ > pid; exec sleep 5")
        defer { try? FileManager.default.removeItem(at: dir) }
        // The real limit: a new program's first launch can wait on macOS's scan of it, so a shorter one may stop it unstarted.
        #expect(await ExtensionRun.list(rows, query: "", inputs: .sample) == .error("did not answer in 2 s"))
        let pid = try #require(pid_t(String(decoding: try Data(contentsOf: dir.appending(path: "pid")), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0, "process \(pid) still runs")
    }

    @Test("Items become menu rows: the extension's own order as answers when it filters, ranked rows when Pilot does")
    func entries() throws {
        let (rows, dir) = try command("true")
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = [Extension.Item(id: "a", title: "pilot", subtitle: "banozz/pilot", icon: "📦", keywords: "mac", actions: [.copy("x")]),
                     Extension.Item(title: "cockpit", actions: [])]
        let ranked = ExtensionList.entries(items, of: rows)
        #expect(ranked.map(\.title) == ["pilot", "cockpit"])
        #expect(ranked.map(\.isAnswer) == [false, false])
        #expect(ranked[0].subtitle == "banozz/pilot" && ranked[0].keywords == "mac" && ranked[0].icon?.emoji == "📦")
        #expect(ranked[0].ownActions == ["Copy"] && ranked[1].ownActions == [])
        #expect(ranked[1].icon?.emoji == "🧪", "an item without an icon wears its command's")
        #expect(ExtensionList.item(at: ranked[1], in: items) == items[1])
        let (own, ownDir) = try command("true", filter: "self")
        defer { try? FileManager.default.removeItem(at: ownDir) }
        #expect(ExtensionList.entries(items, of: own).allSatisfy { $0.isAnswer }, "the program's order is kept")
        #expect(ExtensionList.url("https://github.com/banozz0") == URL(string: "https://github.com/banozz0"))
        #expect(ExtensionList.url("raycast://x")?.scheme == "raycast")
        #expect(ExtensionList.url("/Applications") == URL(filePath: "/Applications"))
        #expect(ExtensionList.url("~/Downloads") == URL(filePath: NSHomeDirectory() + "/Downloads"))
        #expect(ExtensionList.url("just words") == nil)
        let error = ExtensionList.error("did not answer in 2 s", of: rows, in: "Demo")
        #expect(error.title == "Demo did not answer in 2 s" && error.isAnswer)
        #expect(ExtensionList.item(at: error, in: items) == nil)
    }
}

extension ExtensionRun.Inputs {
    /// Inputs for a run that is not about preferences: none set, folders that are never made.
    static let sample = ExtensionRun.Inputs(preferences: [:], data: URL(filePath: "/tmp/pilot-ext-data"), cache: URL(filePath: "/tmp/pilot-ext-cache"))
}
