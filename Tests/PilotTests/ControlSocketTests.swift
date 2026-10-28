import Foundation
@testable import Pilot
import PilotCore
import Testing

/// The control socket on a temp path (ADR 0013): never the real one, never the running Pilot. The client is blocking
/// and runs off the main actor, as the pilot command will, while the socket answers on the main actor.
@MainActor
@Suite("Control socket")
struct ControlSocketTests {
    static func tempPath() -> URL { URL(filePath: NSTemporaryDirectory()).appending(path: "pilot-\(UUID().uuidString.prefix(8)).sock") }

    /// A served socket on `path`, with the core verbs and a `peer` verb that answers who asked.
    static func served(at path: URL = tempPath()) -> ControlSocket {
        let verbs = ControlVerbs()
        verbs.registerCore()
        verbs.register(ControlVerb("peer", help: "Who asked.") { call in
            .object(["pid": .number(Double(call.peer?.pid ?? -1)), "uid": .number(Double(call.peer?.uid ?? 0))])
        })
        let socket = ControlSocket(path: path, verbs: verbs)
        #expect(socket.start())
        return socket
    }

    /// Runs a client against `socket` off the main actor, on a thread of its own.
    static func client<T: Sendable>(_ socket: ControlSocket, _ body: @escaping @Sendable (Client) throws -> T) async throws -> T {
        let path = socket.path.path(percentEncoded: false)
        return try await onOwnThread { let client = try Client(path); defer { client.close() }; return try body(client) }
    }

    static func object(_ line: String?) throws -> [String: JSONValue] {
        guard let line, case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { throw Client.Failure.noAnswer }
        return object
    }

    @Test("A request on a temp socket path gets {\"ok\":true,\"result\":\"pong\"} with its id")
    func ping() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let answer = try await Self.client(socket) { try $0.ask(#"{"id":1,"verb":"ping","args":[],"cwd":"/tmp"}"#) }
        #expect(try Self.object(answer) == ["id": .number(1), "ok": .bool(true), "result": .string("pong")])
    }

    @Test("The socket file is mode 0600 (stat -f %Lp = 600)")
    func mode() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        #expect(try await ChildProcess.run("/usr/bin/stat", ["-f", "%Lp", socket.path.path(percentEncoded: false)]).trimmingCharacters(in: .whitespacesAndNewlines) == "600")
    }

    @Test("A stale file at the path is replaced")
    func stale() async throws {
        let path = Self.tempPath()
        try Data("left by a crash".utf8).write(to: path)
        let socket = Self.served(at: path)
        defer { socket.stop() }
        let answer = try await Self.client(socket) { try $0.ask(#"{"verb":"ping"}"#) }
        #expect(try Self.object(answer)["result"] == .string("pong"))
    }

    @Test("A second socket on a live path gives up and leaves the first one answering")
    func livePathKept() async throws {
        let first = Self.served()
        defer { first.stop() }
        #expect(!ControlSocket(path: first.path, verbs: ControlVerbs()).start())
        let answer = try await Self.client(first) { try $0.ask(#"{"verb":"ping"}"#) }
        #expect(try Self.object(answer)["result"] == .string("pong"))
    }

    @Test("Many requests in one write are all answered, a few at a time")
    func flood() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let answers = try await Self.client(socket) { client in
            try client.send((1...200).map { #"{"id":\#($0),"verb":"ping"}"# }.joined(separator: "\n"))
            // Up to the first missing answer: one 60 s wait, not one per request.
            var answers: [String] = []
            while answers.count < 200, let line = client.line() { answers.append(line) }
            return answers
        }
        let ids = try answers.compactMap { line -> Int? in
            guard case .number(let id) = try Self.object(line)["id"] else { return nil }
            return Int(id)
        }
        #expect(ids.sorted() == Array(1...200))
    }

    @Test("A malformed line answers bad-request and the connection stays up; an unknown verb answers unknown-verb")
    func malformedAndUnknown() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let answers = try await Self.client(socket) { client in
            [try client.ask("not json"), try client.ask(#"{"id":"u","verb":"frobnicate"}"#), try client.ask(#"{"id":2,"verb":"ping"}"#)]
        }
        let bad = try Self.object(answers[0])
        #expect(bad["ok"] == .bool(false))
        guard case .object(let error) = bad["error"] else { Issue.record("no error"); return }
        #expect(error["code"] == .string("bad-request"))
        guard case .object(let unknown) = try Self.object(answers[1])["error"] else { Issue.record("no error"); return }
        #expect(unknown["code"] == .string("unknown-verb"))
        #expect(try Self.object(answers[2])["result"] == .string("pong"))
    }

    @Test("A line over 1 MB is refused with bad-request and its connection closed")
    func oversized() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let (answer, after) = try await Self.client(socket) { client in
            try client.send(String(repeating: "x", count: ControlLine.maxBytes + 1))
            return (client.line(), client.line())
        }
        guard case .object(let error) = try Self.object(answer)["error"] else { Issue.record("no error"); return }
        #expect(error["code"] == .string("bad-request"))
        #expect(after == nil)
    }

    @Test("The handler sees the peer's pid and uid, read off the socket")
    func peer() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let answer = try await Self.client(socket) { try $0.ask(#"{"verb":"peer"}"#) }
        #expect(try Self.object(answer)["result"] == .object(["pid": .number(Double(getpid())), "uid": .number(Double(getuid()))]))
    }

    @Test("A client that closes its writing side after its request still gets the answer")
    func halfClosed() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let answer = try await Self.client(socket) { client in
            try client.send(#"{"verb":"version"}"#)
            client.finishWriting()
            return client.line()
        }
        guard case .object(let version) = try Self.object(answer)["result"] else { Issue.record("no version"); return }
        #expect(version["version"] != nil && version["build"] != nil)
    }

    @Test("help and schema name every registered verb over the wire")
    func helpAndSchema() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let (help, schema) = try await Self.client(socket) { client in (try client.ask(#"{"verb":"help"}"#), try client.ask(#"{"verb":"schema"}"#)) }
        let verbs = ["help", "peer", "ping", "schema", "version"]
        guard case .string(let text) = try Self.object(help)["result"] else { Issue.record("no help"); return }
        let lines = text.split(separator: "\n")
        #expect(lines.dropLast().map { String($0.prefix { $0 != " " }) } == verbs)
        #expect(lines.last?.hasPrefix("pilot [--json] <verb>") == true, "the last line says where --json goes")
        guard case .object(let part) = try Self.object(schema)["result"], case .array(let entries) = part["verbs"] else { Issue.record("no schema"); return }
        #expect(entries.count == verbs.count)
    }

    @Test("help <verb> lists its declared flags; help add <collection> its fields; a core verb refuses a flag")
    func helpFlags() async throws {
        let verbs = ControlVerbs()
        verbs.registerCore()
        verbs.register(ControlVerb("open", help: "Opens a page.", usage: "pilot open <page>", flags: [.init("section", help: "a System section")]) { _ in .null })
        verbs.register(ControlCollection("snippets", help: "Text snippets.", fields: [.init("name", help: "its name")], list: { .array([]) }, add: { _ in .null }))
        func ask(_ verb: String, _ args: [String]) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil) }
        #expect(await ask("help", ["open"]).result == .string("pilot open <page>\nOpens a page.\n  --section  a System section"))
        #expect(await ask("help", ["add", "snippets"]).result == .string("pilot add snippets --name <…>\nText snippets.\n  --name  its name"))
        #expect(await ask("help", ["add"]).result == .string("pilot add <collection> --field value … [--plan]\nAdds a row to a collection; --plan collects it into pilot plan."))
        #expect(await ask("help", ["remove", "nope"]).error?.code == .unknownCollection)
        #expect(await ask("ping", ["--json"]).error?.code == .unknownFlag)
    }

    @Test("schema --index, --verb and --collection answer a part; two at once or a bare --verb is bad-request")
    func schemaForms() async throws {
        let verbs = ControlVerbs()
        verbs.registerCore()
        verbs.register(ControlCollection("snippets", help: "Text snippets.", list: { .array([]) }))
        func ask(_ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: "schema", args: args), peer: nil) }
        #expect(await ask().result == verbs.schema)
        #expect(await ask("--index").result == verbs.schemaIndex)
        #expect(await ask("--verb", "ping").result == (try verbs.schema(verb: "ping")))
        #expect(await ask("--collection=snippets").result == (try verbs.schema(collection: "snippets")))
        #expect(await ask("--verb", "nope").error?.code == .unknownVerb)
        #expect(await ask("--verb").error?.code == .badRequest)
        #expect(await ask("--index", "--verb", "ping").error?.code == .badRequest)
        #expect(await ask("--page", "look").error?.code == .unknownFlag)
    }

    @Test("A path past sun_path's 104 bytes fails with a log line, not a crash")
    func pathTooLong() {
        let path = URL(filePath: NSTemporaryDirectory()).appending(path: String(repeating: "p", count: 120) + ".sock")
        #expect(!ControlSocket(path: path, verbs: ControlVerbs()).start())
        #expect(!FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
    }
}

/// Runs blocking work on a thread of its own, never Swift concurrency's pool: a client blocked on an answer held a pool
/// thread till its read timed out, and in the full `swift test` the main thread then stalled up to 70 s (2026-10-11).
func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { done in Thread.detachNewThread { done.resume(with: Result { try body() }) } }
}

/// A blocking line client with a 60 s read timeout, so a missing answer fails the test instead of hanging it. The socket
/// answers on the main actor, which the full `swift test` keeps busy 10 to 15 s at a time with hundreds of queued tests:
/// at 5 s every test here failed there while each passed alone (2026-10-11).
struct Client: Sendable {
    enum Failure: Error { case connect(Int32), noAnswer }
    let fd: Int32

    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        var wait = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { Darwin.close(fd); throw Failure.connect(errno) }
    }

    func send(_ line: String) throws {
        let data = Array((line + "\n").utf8)
        var offset = 0
        while offset < data.count {
            let written = data[offset...].withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
            guard written > 0 else { throw Failure.noAnswer }
            offset += written
        }
    }

    /// The next answer line, or nil at the end of the stream or after 60 s.
    func line() -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return nil
    }

    func ask(_ line: String) throws -> String? { try send(line); return self.line() }
    func finishWriting() { shutdown(fd, SHUT_WR) }
    func close() { Darwin.close(fd) }
}
