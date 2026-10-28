import Foundation
import Testing
@testable import PilotCore

/// The bw session for Bitwarden's fill (card agent-bo-95422814, Sven's option 1 on 2026-10-05): Sven types his master
/// password into bw in a visible terminal; bw writes only the session key into a pipe Pilot reads; the vault keeps it
/// in memory (BitwardenFillTests). Never runs bw: a shell stands in for it, and every key here is fake.
@Suite("Bitwarden session", .serialized)
@MainActor
struct BitwardenSessionTests {
    static let key = "ZmFrZS1zZXNzaW9uLWtleS1mb3ItdGVzdHMtb25seS0wMTIzNDU2Nzg5"

    @Test("The unlock command sends bw's --raw output into the pipe and ends bw at its limit; Pilot waits longer than that")
    func command() {
        #expect(BitwardenUnlock.command(bw: "/opt/homebrew/bin/bw", pipe: "/tmp/p d/session", limit: 300)
                == "/usr/bin/perl -MPOSIX -e '\(BitwardenUnlock.alarmThenExec)' 300 '/opt/homebrew/bin/bw' unlock --raw > '/tmp/p d/session'"
                + "; s=$?; stty sane 2>/dev/null; exit $s")
        // The tap comes back on only after the read ends, which is after bw's prompt is gone.
        #expect(BitwardenUnlock.readWait > .seconds(BitwardenUnlock.limit))
    }

    @Test("A prompt left open ends at the limit: a stand-in bw that would wait 10 s is gone within the limit")
    func promptEnds() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-bw-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appending(path: "bw")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let pipe = try SessionPipe()
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-c", BitwardenUnlock.command(bw: fake.path, pipe: pipe.path.path, limit: 1)]
        try shell.run()
        let start = ContinuousClock.now
        let read = await pipe.read(timeout: .seconds(5))
        #expect(read == nil)
        #expect(ContinuousClock.now - start < .seconds(3))  // ended by the limit, not by the read's own wait
        shell.waitUntilExit()
        #expect(shell.terminationStatus != 0)
    }

    @Test("Pilot's keyboard tap is off from before the terminal opens until the pipe is done, whatever comes back")
    func keysOffWhileTyping() async {
        for answer in [Data(Self.key.utf8), nil] {
            var steps: [String] = []
            let key = await BitwardenUnlock.run(pauseKeys: { steps.append("tap off") }, resumeKeys: { steps.append("tap on") },
                                                openTerminal: { steps.append("terminal") },
                                                read: { steps.append("read"); return answer })
            #expect(steps == ["tap off", "terminal", "read", "tap on"])
            #expect(key == (answer == nil ? nil : Self.key))
        }
    }

    @Test("A key is one token of at least 20 characters; anything else is no key")
    func validates() {
        #expect(BitwardenUnlock.key(from: Data("\(Self.key)\n".utf8)) == Self.key)
        #expect(BitwardenUnlock.key(from: Data()) == nil)
        #expect(BitwardenUnlock.key(from: Data("short".utf8)) == nil)
        #expect(BitwardenUnlock.key(from: Data("? Master password: [hidden]\n\(Self.key)".utf8)) == nil)
    }

    @Test("The pipe is private, gives back what a writer sends, and is gone after")
    func roundTrip() async throws {
        let pipe = try SessionPipe()
        let attributes = try FileManager.default.attributesOfItem(atPath: pipe.path.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: pipe.path.path)[.posixPermissions] as? Int) == 0o600)
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", "printf '%s' \"$KEY\" > \"$PIPE\""]
        writer.environment = ["KEY": Self.key, "PIPE": pipe.path.path]
        try writer.run()
        let start = ContinuousClock.now
        let read = await pipe.read(timeout: .seconds(5))
        #expect(BitwardenUnlock.key(from: read ?? Data()) == Self.key)
        #expect(ContinuousClock.now - start < .seconds(2))  // the writer closing ends the read, not the deadline
        #expect(!FileManager.default.fileExists(atPath: pipe.path.deletingLastPathComponent().path))
    }

    @Test("A writer that opens the pipe and never writes (a prompt left open) is given up on at the deadline")
    func silentWriter() async throws {
        let pipe = try SessionPipe()
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/bin/sh")
        writer.arguments = ["-c", "exec 3> \"$PIPE\"; sleep 5"]
        writer.environment = ["PIPE": pipe.path.path]
        try writer.run()
        defer { writer.terminate() }
        let start = ContinuousClock.now
        let read = await pipe.read(timeout: .milliseconds(500))
        #expect(read == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: pipe.path.deletingLastPathComponent().path))
    }

    @Test("A pipe nobody writes to gives up after its wait and cleans up")
    func timesOut() async throws {
        let pipe = try SessionPipe()
        let read = await pipe.read(timeout: .seconds(5), openWithin: .milliseconds(300))
        #expect(read == nil)
        #expect(!FileManager.default.fileExists(atPath: pipe.path.deletingLastPathComponent().path))
    }
}
