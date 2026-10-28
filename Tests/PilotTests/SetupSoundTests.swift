import CoreAudio
import Foundation
import Testing
@testable import Pilot

/// Setup › Sound (card agent-bo-95422800): the output and input device and their volume, changed inside Pilot through
/// CoreAudio. Every case runs on a fake; nothing here reads or changes the Mac's real sound devices.
@MainActor
@Suite("Setup sound")
struct SetupSoundTests {
    /// Three outputs (the speakers have a volume and mute, the HDMI screen sets its own, the TV shows a volume it does
    /// not let apps change but lets them mute) and two inputs. The offscreen renders draw the page on it too.
    final class FakeAudio: AudioSystem {
        var devices: [AudioDirection: [AudioDevice]] = [
            .output: [AudioDevice(id: 10, name: "MacBook Speakers"), AudioDevice(id: 11, name: "LG HDR 4K"), AudioDevice(id: 12, name: "TV")],
            .input: [AudioDevice(id: 20, name: "MacBook Microphone"), AudioDevice(id: 21, name: "AirPods")],
        ]
        var defaults: [AudioDirection: AudioDeviceID] = [.output: 10, .input: 20]
        var volumes: [AudioDeviceID: Float] = [10: 0.5, 12: 0.6, 20: 0.7, 21: 0.3]
        var fixedVolume: Set<AudioDeviceID> = [12]
        var mutes: [AudioDeviceID: Bool] = [10: false, 12: false]
        var setDefaultCalls: [(AudioDeviceID, AudioDirection)] = []
        var setVolumeCalls: [(Float, AudioDeviceID, AudioDirection)] = []
        var setMutedCalls: [(Bool, AudioDeviceID, AudioDirection)] = []
        var changed: ((Bool) -> Void)?
        var watched: [AudioDeviceID] = []
        var listings = 0

        func devices(_ direction: AudioDirection) -> [AudioDevice] { listings += 1; return devices[direction] ?? [] }
        func defaultDevice(_ direction: AudioDirection) -> AudioDeviceID? { defaults[direction] }
        func setDefault(_ id: AudioDeviceID, _ direction: AudioDirection) -> Bool {
            setDefaultCalls.append((id, direction)); defaults[direction] = id; return true
        }
        func volume(_ id: AudioDeviceID, _ direction: AudioDirection) -> AudioLevel? {
            volumes[id].map { AudioLevel(value: $0, settable: !fixedVolume.contains(id)) }
        }
        func setVolume(_ value: Float, _ id: AudioDeviceID, _ direction: AudioDirection) -> Bool {
            setVolumeCalls.append((value, id, direction)); volumes[id] = value; return true
        }
        func muted(_ id: AudioDeviceID, _ direction: AudioDirection) -> Bool? { mutes[id] }
        func setMuted(_ muted: Bool, _ id: AudioDeviceID, _ direction: AudioDirection) -> Bool {
            setMutedCalls.append((muted, id, direction)); mutes[id] = muted; return true
        }
        func watch(_ devices: [AudioDeviceID], changed: @escaping @MainActor (Bool) -> Void) -> Watch {
            watched = devices
            self.changed = changed
            return Watch { [weak self] in self?.watched = []; self?.changed = nil }
        }
    }

    @Test("Each direction lists its devices with the default marked")
    func lists() {
        let audio = FakeAudio(), sound = SetupSound(audio: audio)
        sound.start()
        #expect(sound.side(.output).devices.map(\.name) == ["MacBook Speakers", "LG HDR 4K", "TV"])
        #expect(sound.side(.output).current == 10)
        #expect(sound.side(.input).devices.map(\.name) == ["MacBook Microphone", "AirPods"])
        #expect(sound.side(.input).current == 20)
        #expect(sound.side(.output).volume == AudioLevel(value: 0.5, settable: true) && sound.side(.input).volume?.value == 0.7)
        #expect(sound.side(.output).muted == false && sound.side(.input).muted == nil)
    }

    @Test("Picking an output sets the output once and leaves the input alone")
    func pick() {
        let audio = FakeAudio(), sound = SetupSound(audio: audio)
        sound.start()
        sound.pick(11, .output)
        #expect(audio.setDefaultCalls.count == 1)
        #expect(audio.setDefaultCalls.first?.0 == 11 && audio.setDefaultCalls.first?.1 == .output)
        #expect(sound.side(.output).current == 11 && sound.side(.input).current == 20)
        // Picking the device already in use changes nothing.
        sound.pick(20, .input)
        #expect(audio.setDefaultCalls.count == 1)
    }

    @Test("The volume slider sets the default output's volume and nothing else")
    func volume() {
        let audio = FakeAudio(), sound = SetupSound(audio: audio)
        sound.start()
        sound.setVolume(0.4, .output)
        #expect(audio.setVolumeCalls.count == 1)
        #expect(audio.setVolumeCalls.first?.0 == 0.4 && audio.setVolumeCalls.first?.1 == 10 && audio.setVolumeCalls.first?.2 == .output)
        #expect(sound.side(.output).volume?.value == 0.4 && sound.side(.input).volume?.value == 0.7)
        sound.setMuted(true, .output)
        #expect(audio.setMutedCalls.count == 1 && audio.setMutedCalls.first?.1 == 10)
        #expect(sound.side(.output).muted == true)
    }

    @Test("A device with no volume shows none; one whose volume apps may not change shows it read-only, its mute still works")
    func noVolume() {
        let audio = FakeAudio(), sound = SetupSound(audio: audio)
        sound.start()
        sound.pick(11, .output)
        #expect(sound.side(.output).volume == nil && sound.side(.output).muted == nil)
        sound.setVolume(0.9, .output)
        #expect(audio.setVolumeCalls.isEmpty)
        sound.pick(12, .output)
        #expect(sound.side(.output).volume == AudioLevel(value: 0.6, settable: false))
        sound.setVolume(0.9, .output)
        #expect(audio.setVolumeCalls.isEmpty && sound.side(.output).volume?.value == 0.6)
        sound.setMuted(true, .output)
        #expect(audio.setMutedCalls.count == 1 && audio.setMutedCalls.first?.1 == 12 && sound.side(.output).muted == true)
    }

    @Test("Leaving the screen stops following: a read already on its way when the page stops reads nothing")
    func stopDropsPendingRead() async throws {
        let audio = FakeAudio(), sound = SetupSound(audio: audio)
        sound.start()
        let changed = try #require(audio.changed)
        let listed = audio.listings
        audio.defaults[.output] = 11
        changed(true)
        sound.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(audio.listings == listed && audio.watched.isEmpty && audio.changed == nil)
        #expect(sound.side(.output).current == 10)
        // Back on screen: read again and follow again.
        sound.start()
        #expect(sound.side(.output).current == 11 && audio.watched == [11, 20])
    }

    @Test("A change made elsewhere shows on the page: a default change re-reads all, a volume change only the levels")
    func followsChanges() async throws {
        let audio = FakeAudio(), sound = SetupSound(audio: audio)
        sound.start()
        #expect(audio.watched == [10, 20])
        let changed = try #require(audio.changed)
        // A volume change from the keys: the levels are read again, the device lists are not.
        let listed = audio.listings
        audio.volumes[20] = 0.1
        changed(false)
        try await Self.until { sound.side(.input).volume?.value == 0.1 }
        #expect(audio.listings == listed)
        // A burst for one switch in Control Centre: the default moves, read once.
        audio.defaults[.output] = 11
        changed(true); changed(false); changed(true)
        try await Self.until { sound.side(.output).current == 11 }
        #expect(audio.listings == listed + 2)
        // The page watches the new default's volume now.
        #expect(audio.watched == [11, 20])
        sound.stop()
        #expect(audio.changed == nil && audio.watched.isEmpty)
    }

    @Test("A notification that lands after the page stopped is dropped and never blocks the ones after the next start")
    func lateNotification() async throws {
        let audio = FakeAudio(), sound = SetupSound(audio: audio)
        sound.start()
        let old = try #require(audio.changed)
        sound.stop()
        old(true)
        try await Task.sleep(for: .milliseconds(50))
        sound.start()
        let changed = try #require(audio.changed)
        audio.volumes[20] = 0.2
        changed(false)
        try await Self.until { sound.side(.input).volume?.value == 0.2 }
    }

    /// The page's reads after a notification run on the next turn of the main queue.
    static func until(_ done: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(done())
    }

    @Test("Nothing is read before the page shows")
    func lazy() {
        let audio = FakeAudio()
        let sound = SetupSound(audio: audio)
        #expect(sound.side(.output).devices.isEmpty && audio.changed == nil && audio.listings == 0)
    }

    /// The real devices on this Mac, read-only: opt-in like every live test.
    @Test("CoreAudio lists this Mac's devices and their defaults", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func live() {
        let audio = CoreAudioSystem()
        for direction in AudioDirection.allCases {
            let devices = audio.devices(direction), current = audio.defaultDevice(direction)
            #expect(!devices.isEmpty)
            #expect(devices.contains { $0.id == current })
            print("live: \(direction) \(devices.map(\.name)) default \(devices.first { $0.id == current }?.name ?? "none") volume \(String(describing: current.flatMap { audio.volume($0, direction) }))")
        }
    }
}
