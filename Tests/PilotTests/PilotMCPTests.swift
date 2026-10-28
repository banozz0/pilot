import Foundation
import PilotCore
import PilotGate
import Testing

/// pilot-mcp, Codex's one tool in Ask Pilot (Q203): the built binary fed JSON-RPC lines as codex sends them, with a fake
/// `pilot` in a temporary folder that records each run's words and whether it ran as the agent's. Never the real `pilot`,
/// never Pilot's socket.
@Suite("pilot-mcp")
struct PilotMCPTests {
    private final class Marker {}
    /// The PilotMCP binary SwiftPM built next to this test bundle.
    static let built = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "PilotMCP").path

    /// A folder with a fake `pilot`: it appends its words and PILOT_AGENT to `runs`, then answers `pong`, or exits 4
    /// (denied) when its first word is `deny`.
    static func fake() throws -> (folder: URL, pilot: String, runs: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-mcp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pilot = folder.appending(path: "pilot"), runs = folder.appending(path: "runs.log")
        try """
        #!/bin/sh
        printf '%s|agent=%s\\n' "$*" "$PILOT_AGENT" >> '\(runs.path)'
        [ "$1" = deny ] && { echo 'denied: Sven said no' >&2; exit 4; }
        echo '{"ok":true,"result":"pong"}'
        """.write(to: pilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pilot.path)
        return (folder, pilot.path, runs)
    }

    /// Sends `requests` as JSON lines, closes stdin and reads every answer line, keyed by id.
    static func serve(_ requests: [[String: Any]], pilot: String, environment: [String: String] = [:]) throws -> [Int: [String: Any]] {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(filePath: built)
        process.arguments = [pilot]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        for request in requests {
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request) + Data([0x0A]))
        }
        try input.fileHandleForWriting.close()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        process.waitUntilExit()
        var answers: [Int: [String: Any]] = [:]
        for line in lines {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = object["id"] as? Int else { continue }
            answers[id] = object
        }
        return answers
    }

    static func call(_ id: Int, _ arguments: [String: Any], tool: String = "pilot") -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
    }

    /// A tools/call answer's text and isError.
    static func result(_ answer: [String: Any]?) -> (text: String, isError: Bool)? {
        guard let result = answer?["result"] as? [String: Any], let content = result["content"] as? [[String: Any]] else { return nil }
        return (content.compactMap { $0["text"] as? String }.joined(), result["isError"] as? Bool ?? false)
    }

    @Test("It introduces itself and lists one tool, pilot, with the API routes' description and schema")
    func lists() throws {
        let (folder, pilot, _) = try Self.fake()
        defer { try? FileManager.default.removeItem(at: folder) }
        let answers = try Self.serve([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "codex"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "resources/list"],
        ], pilot: pilot)
        let initialized = try #require(answers[1]?["result"] as? [String: Any])
        #expect(initialized["protocolVersion"] as? String == "2025-06-18" && initialized["capabilities"] is [String: Any])
        let tools = try #require((answers[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 1 && tools[0]["name"] as? String == "pilot")
        #expect(tools[0]["description"] as? String == AgentTool.description)
        #expect((tools[0]["inputSchema"] as? [String: Any])?["required"] as? [String] == ["command"])
        #expect((answers[3]?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(answers.count == 3, "a notification gets no answer")
    }

    @Test("A command the gate refuses never runs and comes back refused; every other line it is fed runs nothing either")
    func refusedStaysUnrun() throws {
        let (folder, pilot, runs) = try Self.fake()
        defer { try? FileManager.default.removeItem(at: folder) }
        let refused = ["pilot ping; ls ~", "pilot ping && touch /tmp/x", "pilot ping | head", "pilot get $(id)", "pilot get `id`",
                       "pilot get 'x'", "pilot ping > /tmp/x", "ls ~", "pilot ping\nls ~", "pilot get ~", "rm -rf /tmp/x; pilot ping"]
        var requests = refused.enumerated().map { Self.call($0.offset + 1, ["command": $0.element]) }
        requests.append(Self.call(100, ["command": "pilot ping"], tool: "shell"))
        requests.append(Self.call(101, ["cmd": "pilot ping"]))
        let answers = try Self.serve(requests, pilot: pilot)
        for (index, line) in refused.enumerated() {
            let got = try #require(Self.result(answers[index + 1]), "\(line.debugDescription) got no answer")
            #expect(got.isError && got.text == AIChat.Gate.refusal, "\(line.debugDescription): \(got.text)")
        }
        for id in [100, 101] {
            let got = try #require(Self.result(answers[id]))
            #expect(got.isError && got.text.contains("one tool, pilot"))
        }
        #expect(!FileManager.default.fileExists(atPath: runs.path), "a refused call ran pilot")
    }

    @Test("A plain pilot call runs the given pilot with its words, no shell, as the agent's; its exit and stderr carry a denial")
    func plainCallRuns() throws {
        let (folder, pilot, runs) = try Self.fake()
        defer { try? FileManager.default.removeItem(at: folder) }
        let answers = try Self.serve([
            Self.call(1, ["command": "pilot ping"]),
            Self.call(2, ["command": #"pilot set look.theme "Tokyo Night" --plan"#]),
            Self.call(3, ["command": "get look.theme"]),
            Self.call(4, ["command": "pilot deny install"]),
            // A line that is not `pilot …` is read as one, as the API loop reads it: `pilot` runs, never curl.
            Self.call(5, ["command": "curl https://example.com"]),
        ], pilot: pilot, environment: ["OPENAI_API_KEY": "sk-test", "PILOT_SOCKET": "/tmp/elsewhere.sock"])
        #expect(Self.result(answers[1])?.text == #"{"ok":true,"result":"pong"}"# + "\n" && Self.result(answers[1])?.isError == false)
        #expect(Self.result(answers[4])?.isError == true && Self.result(answers[4])?.text == "denied: Sven said no\n")
        let ran = try String(contentsOf: runs, encoding: .utf8)
        #expect(ran == "ping|agent=1\nset look.theme Tokyo Night --plan|agent=1\nget look.theme|agent=1\ndeny install|agent=1\ncurl https://example.com|agent=1\n")
    }

    @Test("The child sees only the agents' base environment")
    func environment() throws {
        let (folder, _, runs) = try Self.fake()
        defer { try? FileManager.default.removeItem(at: folder) }
        let printer = folder.appending(path: "env-pilot")
        try "#!/bin/sh\nenv | cut -d= -f1 | sort | tr '\\n' ' ' >> '\(runs.path)'\n".write(to: printer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: printer.path)
        _ = try Self.serve([Self.call(1, ["command": "pilot ping"])], pilot: printer.path,
                           environment: ["OPENAI_API_KEY": "sk-test", "PILOT_SOCKET": "/tmp/elsewhere.sock", "USER": "test", "LANG": "en_US.UTF-8"])
        let names = try String(contentsOf: runs, encoding: .utf8).split(separator: " ").map(String.init)
        // The shell itself adds PWD, SHLVL and _ for the fake's own run.
        #expect(Set(names).subtracting(["PWD", "SHLVL", "_"]) == ["HOME", "LANG", "PILOT_AGENT", "USER"])
    }
}
