import Foundation
@testable import Pilot
import PilotCore
import Testing

/// The pilot command (ADR 0013) against a temp socket served by Pilot's own ControlSocket, through PILOT_SOCKET: never
/// the real socket, never the running Pilot. The command runs as a child off the main actor, where the socket answers.
@MainActor
@Suite("pilot command")
struct PilotCLITests {
    private final class Marker {}
    /// The PilotCLI binary SwiftPM built next to this test bundle.
    nonisolated static let built = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "PilotCLI").path

    struct Run: Sendable { let status: Int32; let out: String; let err: String }

    /// Runs the command with `words` against `socket`, from `cwd`, on a thread of its own while it waits (ControlSocketTests);
    /// `stdin` is piped in, else stdin is empty; `terminal` makes stdin a pseudo-terminal instead, as a shell's is.
    static func pilot(_ words: [String], socket: String, cwd: String = NSTemporaryDirectory(), stdin: String = "",
                      terminal: Bool = false) async throws -> Run {
        try await onOwnThread {
            let process = Process()
            process.executableURL = URL(filePath: built)
            process.arguments = words
            process.environment = ["PILOT_SOCKET": socket]
            process.currentDirectoryURL = URL(filePath: cwd)
            let out = Pipe(), err = Pipe(), input = Pipe()
            process.standardOutput = out
            process.standardError = err
            // The terminal's other end stays open until the command is done, so its stdin never reads as closed.
            let primary = terminal ? posix_openpt(O_RDWR | O_NOCTTY) : -1
            defer { if primary >= 0 { close(primary) } }
            if terminal {
                guard primary >= 0, grantpt(primary) == 0, unlockpt(primary) == 0, let name = ptsname(primary) else { throw CocoaError(.fileNoSuchFile) }
                process.standardInput = FileHandle(fileDescriptor: open(name, O_RDWR | O_NOCTTY), closeOnDealloc: true)
            } else {
                process.standardInput = input
            }
            try process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
            let output = out.fileHandleForReading.readDataToEndOfFile(), error = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Run(status: process.terminationStatus, out: String(decoding: output, as: UTF8.self), err: String(decoding: error, as: UTF8.self))
        }
    }

    /// A served socket with the core verbs, one that echoes what reached Pilot, and two that fail.
    static func served() -> ControlSocket {
        let verbs = ControlVerbs()
        verbs.registerCore()
        verbs.register(ControlVerb("echo", help: "What reached Pilot.") { call in
            .object(["words": .array(call.words.map(JSONValue.string)), "cwd": .string(call.cwd ?? "")])
        })
        verbs.register(ControlVerb("broken", help: "Fails.") { _ throws(ControlError) in throw ControlError(.badValue, "colour must be a hex value") })
        verbs.register(ControlVerb("refuse", help: "Denied.") { _ throws(ControlError) in throw ControlError(.denied, "Sven said no") })
        let socket = ControlSocket(path: ControlSocketTests.tempPath(), verbs: verbs)
        #expect(socket.start())
        return socket
    }

    @Test("pilot ping prints pong and exits 0")
    func ping() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let run = try await Self.pilot(["ping"], socket: socket.path.path(percentEncoded: false))
        #expect(run.status == 0 && run.out == "pong\n" && run.err.isEmpty)
    }

    @Test("An error answer prints its message on stderr and exits 1; denied exits 4")
    func errors() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let path = socket.path.path(percentEncoded: false)
        let broken = try await Self.pilot(["broken"], socket: path)
        #expect(broken.status == 1 && broken.err == "colour must be a hex value\n" && broken.out.isEmpty)
        let refused = try await Self.pilot(["refuse"], socket: path)
        #expect(refused.status == 4 && refused.err == "Sven said no\n")
        let unknown = try await Self.pilot(["frobnicate"], socket: path)
        #expect(unknown.status == 1 && unknown.err.contains("no verb frobnicate"))
    }

    @Test("No socket exits 3 with \"Pilot isn't running\"; no verb exits 2")
    func notRunningAndUsage() async throws {
        let missing = ControlSocketTests.tempPath().path(percentEncoded: false)
        let run = try await Self.pilot(["ping"], socket: missing)
        #expect(run.status == 3 && run.err.hasPrefix("Pilot isn't running"))
        let usage = try await Self.pilot([], socket: missing)
        #expect(usage.status == 2 && usage.err.hasPrefix("usage: pilot"))
    }

    @Test("--json prints the raw answer; any other result prints as pretty JSON")
    func json() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let path = socket.path.path(percentEncoded: false)
        let raw = try await Self.pilot(["--json", "ping"], socket: path)
        #expect(raw.status == 0 && raw.out == #"{"id":1,"ok":true,"result":"pong"}"# + "\n")
        let failed = try await Self.pilot(["--json", "refuse"], socket: path)
        #expect(failed.status == 4 && failed.out.contains(#""code":"denied""#) && failed.err.isEmpty)
        let version = try await Self.pilot(["version"], socket: path)
        #expect(version.status == 0 && version.out.hasPrefix("{\n") && version.out.contains(#""build" : "#))
    }

    @Test("The words after the verb and the cwd reach Pilot as they are, flags and --json included")
    func dumbPipe() async throws {
        let socket = Self.served()
        defer { socket.stop() }
        let cwd = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path(percentEncoded: false)
        let run = try await Self.pilot(["--json", "echo", "a b", "--json", "--flag", "x"], socket: socket.path.path(percentEncoded: false), cwd: cwd)
        let answer = try JSONDecoder().decode(ControlAnswer.self, from: Data(run.out.utf8))
        guard case .object(let result) = answer.result else { Issue.record("no result: \(run.out)"); return }
        #expect(result["words"] == .array(["a b", "--json", "--flag", "x"].map(JSONValue.string)))
        guard case .string(let seen) = result["cwd"] else { Issue.record("no cwd"); return }
        #expect(URL(filePath: seen, directoryHint: .isDirectory).resolvingSymlinksInPath() == URL(filePath: cwd, directoryHint: .isDirectory).resolvingSymlinksInPath())
    }

    // MARK: Secrets over stdin (D1)

    /// The settings rig's verbs on a temp socket: its fake Keychains, every Allow answered as the rig says.
    static func served(_ rig: SettingsSchemaTests.Rig) -> ControlSocket {
        let socket = ControlSocket(path: ControlSocketTests.tempPath(), verbs: rig.verbs)
        #expect(socket.start())
        return socket
    }

    @Test("A key piped to set --stdin is saved trimmed and answers set, never printed; --unset removes it")
    func secretFromStdin() async throws {
        let rig = SettingsSchemaTests.Rig()
        let socket = Self.served(rig)
        defer { socket.stop() }
        let path = socket.path.path(percentEncoded: false)
        let saved = try await Self.pilot(["set", "giphy.key", "--stdin"], socket: path, stdin: " gif-t1\n")
        #expect(saved.status == 0 && saved.out == "set\n" && saved.err.isEmpty && rig.giphy.read() == "gif-t1")
        let raw = try await Self.pilot(["--json", "set", "giphy.key", "--stdin"], socket: path, stdin: "gif-t2")
        #expect(raw.status == 0 && raw.out == #"{"id":1,"ok":true,"result":"set"}"# + "\n" && rig.giphy.read() == "gif-t2")
        let removed = try await Self.pilot(["set", "giphy.key", "--unset"], socket: path)
        #expect(removed.status == 0 && removed.out == "unset\n" && rig.giphy.read() == nil)
        #expect(rig.asked.count == 3 && !rig.asked.joined().contains("gif-t"))
    }

    @Test("A key typed as a word is refused naming the key, not the value; an empty pipe and Deny keep the key")
    func secretRefused() async throws {
        let rig = SettingsSchemaTests.Rig(allow: false)
        try rig.giphy.write("gif-t1")
        let socket = Self.served(rig)
        defer { socket.stop() }
        let path = socket.path.path(percentEncoded: false)
        let word = try await Self.pilot(["set", "giphy.key", "gif-t2"], socket: path)
        #expect(word.status == 1 && word.err.contains("giphy.key") && word.err.contains("--stdin") && !word.err.contains("gif-t2") && word.out.isEmpty)
        let empty = try await Self.pilot(["set", "giphy.key", "--stdin"], socket: path, stdin: "\n")
        #expect(empty.status == 1 && empty.err.contains("nothing on stdin"))
        let denied = try await Self.pilot(["set", "giphy.key", "--stdin"], socket: path, stdin: "gif-t2")
        #expect(denied.status == 4 && !denied.err.contains("gif-t2") && denied.out.isEmpty)
        #expect(rig.giphy.read() == "gif-t1")
    }

    @Test("--stdin on a terminal exits 2 with a fixed text that repeats none of the words, before reaching Pilot")
    func secretFromTerminal() async throws {
        let missing = ControlSocketTests.tempPath().path(percentEncoded: false)
        let run = try await Self.pilot(["set", "giphy.key", "gif-t2", "--stdin"], socket: missing, terminal: true)
        #expect(run.status == 2 && run.err == "--stdin reads a pipe, not a terminal: pbpaste | pilot set <key> --stdin\n" && run.out.isEmpty)
    }

    // MARK: The link on General

    static func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-link-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A stand-in bundle command at `<root>/Pilot.app/Contents/Helpers/pilot`.
    static func command(in root: URL) throws -> URL {
        let command = root.appending(path: "Pilot.app/Contents/Helpers/pilot")
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path(percentEncoded: false))
        return command
    }

    @Test("The button links ~/.local/bin/pilot to the bundle's copy, making the folder; an older Pilot's link is replaced")
    func link() throws {
        let root = try Self.tempFolder()
        let link = CommandLineLink(command: try Self.command(in: root), folder: root.appending(path: "home/.local/bin"))
        #expect(link.state == .notLinked)
        link.makeLink()
        #expect(link.state == .linked && link.problem == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.link.path(percentEncoded: false)) == link.command.path(percentEncoded: false))

        let older = try Self.command(in: root.appending(path: "old"))
        try FileManager.default.removeItem(at: link.link)
        try FileManager.default.createSymbolicLink(at: link.link, withDestinationURL: older)
        link.refresh()
        #expect(link.state == .notLinked)
        link.makeLink()
        #expect(link.state == .linked)
    }

    @Test("A file or a foreign link at ~/.local/bin/pilot is taken and left alone; a bare binary has nothing to link")
    func taken() throws {
        let root = try Self.tempFolder()
        let folder = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("someone else's".utf8).write(to: folder.appending(path: "pilot"))
        let link = CommandLineLink(command: try Self.command(in: root), folder: folder)
        #expect(link.state == .taken)
        link.makeLink()
        #expect(try String(contentsOf: link.link, encoding: .utf8) == "someone else's")

        try FileManager.default.removeItem(at: link.link)
        try FileManager.default.createSymbolicLink(atPath: link.link.path(percentEncoded: false), withDestinationPath: "/opt/homebrew/bin/pilot")
        link.refresh()
        #expect(link.state == .taken)

        #expect(CommandLineLink(command: root.appending(path: "nowhere/pilot"), folder: folder).state == .noCommand)
    }

    @Test("The login shell's PATH after the marker says whether the folder is on it")
    func onPath() {
        let folder = URL(filePath: "/Users/x/.local/bin", directoryHint: .isDirectory)
        let m = CommandLineLink.marker
        #expect(CommandLineLink.contains(shellOutput: "welcome!\n\(m)/usr/bin:/Users/x/.local/bin/:/bin\n", folder: folder) == true)
        #expect(CommandLineLink.contains(shellOutput: "\(m)/usr/bin:/bin\n", folder: folder) == false)
        #expect(CommandLineLink.contains(shellOutput: "no marker here", folder: folder) == nil)
    }
}
