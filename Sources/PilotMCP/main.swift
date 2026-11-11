import Foundation
import PilotGate

// pilot-mcp: Codex's one tool in Ask Pilot (ADR 0013, Q203). Codex runs with its shell, file and web tools off
// (AIChat.Agent.codexArguments) and this as its only MCP server: JSON-RPC lines on stdin and stdout, one tool, `pilot`,
// whose input is one `pilot …` command line. Each call is judged by the agents' one rule (PilotGate's AgentGate, the shell
// gate's expression): refused, it never runs and the model hears why; else the `pilot` named on the command line runs
// with its words, no shell between, in the agents' environment (PILOT_AGENT=1), so its changes wait on the same plan card
// and Allow as Claude Code's. Codex starts its MCP servers itself, outside its sandbox, which is how `pilot` reaches
// Pilot's socket where Codex's read-only sandbox refused it (spec pilot-ai-helper T15, probe O).
//   pilot-mcp <path to pilot>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: pilot-mcp <path to pilot>\n".utf8))
    exit(2)
}
let pilot = CommandLine.arguments[1]
/// How long one `pilot` may take: past the Allow gate's 60 s, so a question left unanswered comes back denied.
let callTimeout: TimeInterval = 120

func send(_ object: [String: Any]) {
    guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

func text(_ output: String, failed: Bool) -> [String: Any] {
    ["content": [["type": "text", "text": AgentTool.cut(output)]], "isError": failed]
}

/// Runs `pilot` with `words`: its answer, or its error (stderr, else stdout) when it exits non-zero (4 is denied).
func run(_ words: [String]) -> (output: String, failed: Bool) {
    let parent = ProcessInfo.processInfo.environment
    var environment = AgentTool.environment()
    if parent["PILOT_THEME_FIXTURE"] != nil || parent["PILOT_SOCKET"] != nil {
        guard let manifest = parent["PILOT_THEME_FIXTURE"], !manifest.isEmpty,
              let socket = parent["PILOT_SOCKET"], !socket.isEmpty,
              !parent.keys.contains(where: { $0.hasPrefix("PILOT_SANDBOX") }),
              ["CFFIXED_USER_HOME", "PILOT_LIVE", "PILOT_FOCUS"].allSatisfy({ parent[$0] == nil }) else {
            return ("invalid isolated theme fixture environment; no socket fallback", true)
        }
        // The actual CLI validates explicit recording stores/socket before connecting.
        environment["PILOT_THEME_FIXTURE"] = manifest
        environment["PILOT_SOCKET"] = socket
    }
    let process = Process()
    process.executableURL = URL(filePath: pilot)
    process.arguments = words
    process.environment = environment
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return ("pilot did not start: \(error.localizedDescription)", true) }
    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + callTimeout, execute: timer)
    // Both pipes drain at once, so a full one never stalls the other.
    nonisolated(unsafe) var said = Data()
    let reading = DispatchGroup()
    DispatchQueue.global().async(group: reading) { said = err.fileHandleForReading.readDataToEndOfFile() }
    let answer = out.fileHandleForReading.readDataToEndOfFile()
    reading.wait()
    process.waitUntilExit()
    timer.cancel()
    if process.terminationReason == .uncaughtSignal { return ("pilot did not answer in time", true) }
    let stdout = String(decoding: answer, as: UTF8.self), stderr = String(decoding: said, as: UTF8.self)
    guard process.terminationStatus == 0 else { return (stderr.isEmpty ? stdout : stderr, true) }
    return (stdout, false)
}

func call(_ params: [String: Any]) -> [String: Any] {
    guard params["name"] as? String == AgentTool.name,
          let command = ((params["arguments"] as? [String: Any])?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return text("Pilot has one tool, pilot, which takes {\"command\": \"pilot …\"}.", failed: true) }
    guard let words = AgentGate.words(command) else { return text(AgentGate.refusal, failed: true) }
    let (output, failed) = run(words)
    return text(output, failed: failed)
}

while let line = readLine(strippingNewline: true) {
    guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let method = message["method"] as? String else { continue }
    // A notification (initialized, cancelled) has no id and gets no answer.
    guard let id = message["id"] else { continue }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18", "capabilities": ["tools": [String: Any]()],
                   "serverInfo": ["name": "pilot", "version": "1"]])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": [["name": AgentTool.name, "description": AgentTool.description, "inputSchema": AgentTool.schema]]])
    case "tools/call":
        reply(id, call(params))
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Pilot's tool server has no \(method)"]])
    }
}
