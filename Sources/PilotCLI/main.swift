import Foundation

// pilot: the command that talks to the running Pilot over its control socket (ADR 0013). A dumb pipe: it sends the verb,
// the words after it and the cwd as they are, prints the answer and exits with its code. Every verb, check and message
// lives in Pilot, so this file never changes when a verb is added. Foundation only, never PilotCore.
//   pilot [--json] <verb> [<word>…]
// At a terminal an answer prints as text (TextAnswer.swift); piped, redirected or with --json it prints as JSON.
// With --stdin among the words it also reads stdin to its end and sends it once as the request's secret, never as a word
// (`pbpaste | pilot set ai.key.openAI --stdin`): shell history and the words never hold it, and it is never printed.
// Exits 0 ok, 1 error, 2 usage, 3 Pilot not running, 4 denied. PILOT_SOCKET replaces the socket's path, for tests.
// PILOT_AGENT=1 (Pilot's AI agent, AIChat.Agent.environment) marks the request as the agent's, whose changes Pilot plans.
// No fixed wait: the wait is the answer's. Pilot owns the clock, and an Allow prompt answers denied after 60 s.

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// Fixture children are explicitly pinned before any default socket/home lookup. Other CLI
// socket overrides keep their existing behavior; the marker opts into this strict contract.
let fixtureEnvironment = ProcessInfo.processInfo.environment
if let manifest = fixtureEnvironment["PILOT_THEME_FIXTURE"] {
    do {
        guard !manifest.isEmpty, !fixtureEnvironment.keys.contains(where: { $0.hasPrefix("PILOT_SANDBOX") }),
              ["CFFIXED_USER_HOME", "PILOT_LIVE", "PILOT_FOCUS"].allSatisfy({ fixtureEnvironment[$0] == nil }),
              let bytes = FileManager.default.contents(atPath: manifest),
              let config = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let root = config["root"] as? String, root.hasPrefix("/"),
              URL(fileURLWithPath: root).resolvingSymlinksInPath().path == root,
              manifest.hasPrefix(root + "/"), URL(fileURLWithPath: manifest).resolvingSymlinksInPath().path == manifest,
              config["effects"] as? String == "recording",
              let socket = config["socket"] as? String, socket == fixtureEnvironment["PILOT_SOCKET"],
              let binding = config["binding"] as? [String: Any], let app = binding["root"] as? String else {
            fail("invalid isolated theme fixture configuration; no socket fallback", 2)
        }
        let paths = ["packs", "writablePacks", "state", "control", "wallpaperState", "nativeState"].compactMap { config[$0] as? String }
        guard paths.count == 6, (paths + [socket, app]).allSatisfy({
            $0.hasPrefix(root + "/") && URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == $0
        }), socket.utf8.count < 100,
              let attributes = try? FileManager.default.attributesOfItem(atPath: socket),
              attributes[.type] as? FileAttributeType == .typeSocket,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            fail("invalid isolated theme fixture roots/socket; no socket fallback", 2)
        }
    } catch { fail("invalid isolated theme fixture configuration; no socket fallback", 2) }
}

var words = Array(CommandLine.arguments.dropFirst())
// The command's own flag comes before the verb; every word after the verb is Pilot's.
let raw = words.first == "--json"
if raw { words.removeFirst() }
guard var verb = words.first else { fail("usage: pilot [--json] <verb> [<word>…]; pilot help lists the verbs", 2) }
if verb == "--help" || verb == "-h" { verb = "help" }

let args = Array(words.dropFirst())
var request: [String: Any] = ["id": 1, "verb": verb, "args": args, "cwd": FileManager.default.currentDirectoryPath]
if ProcessInfo.processInfo.environment["PILOT_AGENT"] == "1" { request["agent"] = true }
if args.prefix(while: { $0 != "--" }).contains("--stdin") {
    // Read whole before connecting, so Pilot never waits on a slow pipe. A terminal would echo what is typed.
    // A fixed text: the words may hold the very value that belongs on stdin.
    guard isatty(STDIN_FILENO) == 0 else { fail("--stdin reads a pipe, not a terminal: pbpaste | pilot set <key> --stdin", 2) }
    let limit = 64 << 10
    // A pipe hands its text over in pieces: read to its end, or one byte past the limit.
    // A read that fails mid-pipe stops here rather than send part of a key.
    var input = Data()
    do {
        while input.count <= limit, let piece = try FileHandle.standardInput.read(upToCount: limit + 1 - input.count), !piece.isEmpty {
            input.append(piece)
        }
    } catch { fail("--stdin could not read the pipe: \(error.localizedDescription)", 1) }
    guard input.count <= limit, let secret = String(data: input, encoding: .utf8) else { fail("--stdin takes UTF-8 text up to 64 KB", 2) }
    request["secret"] = secret
}

let path = ProcessInfo.processInfo.environment["PILOT_SOCKET"]
    ?? URL.applicationSupportDirectory.appending(path: "Pilot/pilot.sock").path(percentEncoded: false)

var address = sockaddr_un()
let pathBytes = Array(path.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("the socket path is past 104 bytes: \(path)", 1) }
address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("no socket: \(String(cString: strerror(errno)))", 1) }
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else {
    if errno == ENOENT || errno == ECONNREFUSED { fail("Pilot isn't running: start Pilot, then try again", 3) }
    fail("can't reach Pilot at \(path): \(String(cString: strerror(errno)))", 1)
}

var line = try! JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes])
line.append(0x0A)
let sent = line.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
        let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
        if written > 0 { offset += written } else if errno != EINTR { return false }
    }
    return true
}
guard sent else { fail("Pilot closed the socket: \(String(cString: strerror(errno)))", 1) }
shutdown(fd, SHUT_WR)

/// The answer: the first line that carries `ok`.
func answer() -> (line: Data, object: [String: Any]) {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while true {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["ok"] != nil { return (Data(line), object) }
        }
        let count = read(fd, &chunk, chunk.count)
        if count > 0 { buffer.append(contentsOf: chunk[..<count]); continue }
        if count < 0, errno == EINTR { continue }
        fail("Pilot closed the socket without an answer", 1)
    }
}

// JSONSerialization's string bridge drops an embedded U+FEFF on this platform. Decode
// the result losslessly for piped JSON, so theme previews retain their exact BOM bytes.
private enum WireValue: Codable {
    case string(String), integer(Int64), unsigned(UInt64), number(Double), bool(Bool), object([String: WireValue]), array([WireValue]), null
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let x = try? value.decode(String.self) { self = .string(x) }
        else if let x = try? value.decode(Bool.self) { self = .bool(x) }
        else if let x = try? value.decode(Int64.self) { self = .integer(x) }
        else if let x = try? value.decode(UInt64.self) { self = .unsigned(x) }
        else if let x = try? value.decode(Double.self) { self = .number(x) }
        else if let x = try? value.decode([String: WireValue].self) { self = .object(x) }
        else { self = .array(try value.decode([WireValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let x): try value.encode(x)
        case .integer(let x): try value.encode(x)
        case .unsigned(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .bool(let x): try value.encode(x)
        case .object(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        case .null: try value.encodeNil()
        }
    }
}

let (answerLine, object) = answer()
close(fd)
let ok = object["ok"] as? Bool == true
let error = object["error"] as? [String: Any]
let code: Int32 = ok ? 0 : error?["code"] as? String == "denied" ? 4 : 1

if raw {
    FileHandle.standardOutput.write(answerLine + Data([0x0A]))
    exit(code)
}
guard ok else { fail(error?["message"] as? String ?? "Pilot answered an error with no message", code) }
switch object["result"] {
case nil, is NSNull: break
case let text as String: print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
case let result? where printsText(terminal: isatty(STDOUT_FILENO) == 1, words: words):
    let text = readable(result)
    if !text.isEmpty { print(text) }
case _?:
    let wire = try! JSONDecoder().decode([String: WireValue].self, from: answerLine)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let pretty = try! encoder.encode(wire["result"] ?? .null)
    FileHandle.standardOutput.write(pretty + Data([0x0A]))
}
exit(0)
