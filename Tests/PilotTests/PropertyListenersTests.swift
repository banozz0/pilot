import CoreAudio
import Foundation
import Testing
@testable import Pilot

/// The listeners behind the microphone, camera and sound watches (Build 55: main thread at 110% CPU for 58 minutes, each
/// callback re-adding a set of listeners the block API never removed). On a fake system, but the live test's.
@MainActor
@Suite("Property listeners")
struct PropertyListenersTests {
    /// Records each add and remove; `onAdd` runs inside an add, as a framework calling back at once would.
    final class FakeSystem: @unchecked Sendable {
        var added: [PropertyKey] = [], removed: [PropertyKey] = []
        var onAdd: ((UnsafeMutableRawPointer) -> Void)?
        var system: PropertyListeners.System {
            PropertyListeners.System(add: { key, context in
                self.added.append(key)
                self.onAdd?(context)
                return true
            }, remove: { key, _ in self.removed.append(key) })
        }
    }

    static func key(_ n: UInt32) -> PropertyKey { PropertyKey(n, 1) }

    /// Lets the main queue's pending hops run.
    static func drain() async {
        for _ in 0..<5 { await Task.yield(); try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("A burst of callbacks from any thread is one re-arm and one read")
    func burst() async throws {
        let fake = FakeSystem()
        var reads = 0, context: UnsafeMutableRawPointer?
        fake.onAdd = { context = $0 }
        let watch = PropertyListeners(fake.system, wanted: { [Self.key(1), Self.key(2)] }, changed: { reads += 1 })
        #expect(watch.arm() && watch.arms == 1)
        // 200 callbacks on many threads at once, as CoreAudio's own thread would send them.
        nonisolated(unsafe) let ctx = try #require(context)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in PropertyListeners.fire(ctx) }
        await Self.drain()
        #expect(watch.arms == 2 && reads == 1)
        // Nothing new was wanted: the re-arm added and removed nothing.
        #expect(fake.added.count == 2 && fake.removed.isEmpty)
        watch.disarm()
    }

    @Test("A listener that calls back while it is being added never re-enters the re-arm, and the calls settle")
    func noReentry() async {
        let fake = FakeSystem()
        var reads = 0
        fake.onAdd = { PropertyListeners.fire($0) }
        var wanted: Set<PropertyKey> = [Self.key(1)]
        let watch = PropertyListeners(fake.system, wanted: { wanted }, changed: { reads += 1 })
        watch.arm()
        wanted.insert(Self.key(2))
        await Self.drain()
        // The add's callback asked once; the re-arm it ran added key 2, whose callback asked once more; then quiet.
        #expect(!watch.reentered && watch.arms == 3 && reads == 2)
        await Self.drain()
        #expect(watch.arms == 3 && reads == 2)
        watch.disarm()
    }

    @Test("A re-arm adds only the processes that came and removes only those that went; disarm removes the rest")
    func diff() {
        let fake = FakeSystem()
        var wanted: Set<PropertyKey> = [Self.key(1), Self.key(2)]
        let watch = PropertyListeners(fake.system, wanted: { wanted }, changed: {})
        watch.arm()
        wanted = [Self.key(2), Self.key(3)]
        watch.arm()
        #expect(Set(fake.added) == [Self.key(1), Self.key(2), Self.key(3)] && fake.added.count == 3 && fake.removed == [Self.key(1)])
        #expect(watch.listening == [Self.key(2), Self.key(3)])
        watch.disarm()
        #expect(Set(fake.removed) == [Self.key(1), Self.key(2), Self.key(3)] && watch.listening.isEmpty)
    }

    @Test("A callback after disarm reads nothing")
    func afterDisarm() async {
        let fake = FakeSystem()
        var reads = 0
        var context: UnsafeMutableRawPointer?
        fake.onAdd = { context = $0 }
        let watch = PropertyListeners(fake.system, wanted: { [Self.key(1)] }, changed: { reads += 1 })
        watch.arm()
        watch.disarm()
        PropertyListeners.fire(try! #require(context))
        await Self.drain()
        #expect(reads == 0)
    }

    /// CoreAudio itself: added and removed five times, the process-list listener is gone, so a silent `afplay` (its
    /// process joining and leaving the list) calls nothing. The block API failed this: each round left one behind.
    @Test("Live: a removed CoreAudio listener is really gone", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func live() async throws {
        let signal = PropertyListeners.Signal()
        var calls = 0
        signal.fired = { calls += 1 }
        let key = PropertyKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        for _ in 0..<5 {
            #expect(PropertyListeners.System.audio.add(key, signal.context))
            PropertyListeners.System.audio.remove(key, signal.context)
        }
        let wav = FileManager.default.temporaryDirectory.appending(path: "pilot-silent-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try Self.silence().write(to: wav)
        let play = Process()
        play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        play.arguments = ["-v", "0", wav.path]
        try play.run()
        play.waitUntilExit()
        try await Task.sleep(for: .milliseconds(800))
        #expect(calls == 0)
        // And one left on does hear it.
        #expect(PropertyListeners.System.audio.add(key, signal.context))
        defer { PropertyListeners.System.audio.remove(key, signal.context) }
        let again = Process()
        again.executableURL = play.executableURL
        again.arguments = play.arguments
        try again.run()
        again.waitUntilExit()
        try await Task.sleep(for: .milliseconds(800))
        #expect(calls >= 1)
    }

    /// A tenth of a second of silence as a WAV file.
    static func silence() -> Data {
        let samples = 4410, bytes = samples * 2
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes); d.append(Data(count: bytes))
        return d
    }
}
