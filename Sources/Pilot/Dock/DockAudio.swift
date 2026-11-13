import AppKit
import CoreAudio
import Foundation
import os

/// What the visualizer hears (rice round, Sven 2026-11-13, Q220 A): a Core Audio process tap on what the Mac plays,
/// started only while the gate is open (DockAudioGate: the output device runs and the now-playing reader says a player
/// plays), never at launch and never while silent. The tap asks macOS for System Audio Recording Only
/// (`NSAudioCaptureUsageDescription`, Packaging/Info.plist) the first time it starts; the visualizer's switch starts one
/// for a moment so the ask comes on that press. Denied, the tap hears zeros and the bars stay flat.

/// The last samples of both channels, written by a source's own thread, read by the frame clock. Fixed storage, so the
/// audio thread never allocates.
final class DockSampleRing: @unchecked Sendable {
    static let capacity = 4096
    private struct Store {
        var left = [Float](repeating: 0, count: DockSampleRing.capacity)
        var right = [Float](repeating: 0, count: DockSampleRing.capacity)
        var at = 0
        var rate: Double = 48_000
        /// The loudest sample since the last read: the frame clock's way to tell a silent tap from a playing one.
        var peak: Float = 0
    }
    private let store = OSAllocatedUnfairLock(initialState: Store())

    var rate: Double {
        get { store.withLock { $0.rate } }
        set { store.withLock { $0.rate = newValue } }
    }

    /// `frames` samples per channel; `right` nil writes `left` to both (a mono source).
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int, stride: Int = 1) {
        // Unchecked: the pointers are the caller's buffers, read only inside the lock.
        store.withLockUnchecked { s in
            for i in 0..<frames {
                let l = left[i * stride], r = right?[i * stride] ?? l
                s.left[s.at] = l
                s.right[s.at] = r
                s.at = (s.at + 1) % Self.capacity
                s.peak = max(s.peak, abs(l), abs(r))
            }
        }
    }

    /// The newest `count` samples of each channel, oldest first, and the loudest sample since the last read.
    func read(_ count: Int) -> (left: [Float], right: [Float], peak: Float) {
        store.withLock { s in
            let n = min(count, Self.capacity)
            var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let j = (s.at - n + i + Self.capacity) % Self.capacity
                l[i] = s.left[j]
                r[i] = s.right[j]
            }
            let peak = s.peak
            s.peak = 0
            return (l, r, peak)
        }
    }

    func clear() {
        store.withLock { s in
            for i in 0..<Self.capacity { s.left[i] = 0; s.right[i] = 0 }
            s.peak = 0
        }
    }
}

/// Where the samples come from: the real tap, or the sandbox's synthetic music.
@MainActor
protocol DockAudioSource: AnyObject {
    /// What it is, as `pilot dock visualizer` says.
    var name: String { get }
    /// Starts hearing what plays into `ring`; throws why it cannot.
    func start(into ring: DockSampleRing) throws
    func stop()
    /// The switch's press: starts for a moment so macOS asks for its permission then, not when music first plays.
    func ask() async
}

/// Whether anything plays: the output device running for some app, and what the now-playing reader says (nil when it
/// cannot say). `start` calls `changed` with both now and on every change, until `stop`.
@MainActor
protocol DockAudioWatch: AnyObject {
    var name: String { get }
    func start(_ changed: @escaping @MainActor (_ deviceRunning: Bool, _ playing: Bool?) -> Void)
    func stop()
}

enum DockAudioError: Error, CustomStringConvertible {
    case status(String, OSStatus), noDevice, notHere

    var description: String {
        switch self {
        case .status(let step, let status): "the visualizer's tap could not \(step) (Core Audio \(status))"
        case .noDevice: "no output device to listen to"
        case .notHere: "no tap here: the sandbox has no audio source"
        }
    }
}

private func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
}

private func defaultOutput() -> AudioObjectID? {
    var device = AudioObjectID(kAudioObjectUnknown)
    guard audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device) == noErr,
          device != kAudioObjectUnknown else { return nil }
    return device
}

/// The real watch: one Core Audio listener on the default output device's "running somewhere" (no permission; round 1
/// saw it flip at a player's start and end), moved to the new device when the default changes; and, while the device
/// runs, the now-playing reader held, so a paused player that keeps the device open closes the gate. Nothing runs and
/// nothing is polled while the device is idle.
@MainActor
final class CoreAudioWatch: DockAudioWatch {
    let name = "core audio"
    private var changed: (@MainActor (Bool, Bool?) -> Void)?
    private var device: AudioObjectID?
    private var running = false
    private var playing: Bool?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var nowPlaying: Task<Void, Never>?
    private var nowPlayingReader: NowPlaying { .shared }

    private static var somewhere = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var defaultDevice = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start(_ changed: @escaping @MainActor (Bool, Bool?) -> Void) {
        stop()
        self.changed = changed
        let follow: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.attach() } }
        defaultListener = follow
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDevice, .main, follow)
        attach()
    }

    func stop() {
        if let defaultListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDevice, .main, defaultListener) }
        defaultListener = nil
        detach()
        changed = nil
        running = false
        playing = nil
        reader(false)
    }

    /// Listens to the default output device, the old one let go.
    private func attach() {
        detach()
        device = defaultOutput()
        if let device {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in MainActor.assumeIsolated { self?.read() } }
            deviceListener = listener
            AudioObjectAddPropertyListenerBlock(device, &Self.somewhere, .main, listener)
        }
        read()
    }

    private func detach() {
        if let device, let deviceListener { AudioObjectRemovePropertyListenerBlock(device, &Self.somewhere, .main, deviceListener) }
        device = nil
        deviceListener = nil
    }

    private func read() {
        var on: UInt32 = 0
        let now = device.map { audioProperty($0, kAudioDevicePropertyDeviceIsRunningSomewhere, &on) == noErr && on != 0 } ?? false
        running = now
        reader(now)
        tell()
    }

    /// The now-playing reader, held only while the device runs: its child (pilot-media) never runs for a silent Mac.
    private func reader(_ on: Bool) {
        if on, nowPlaying == nil {
            nowPlaying = Task { await nowPlayingReader.watch() }
            followPlaying()
        } else if !on {
            nowPlaying?.cancel()
            nowPlaying = nil
            playing = nil
        }
    }

    /// What the reader says, read again at each change it makes; nil while it cannot say (no helper, nothing read yet).
    private func followPlaying() {
        guard nowPlaying != nil else { return }
        let reader = nowPlayingReader
        let said: Bool? = withObservationTracking {
            reader.problem == nil ? reader.track?.playing : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPlaying() }
        }
        if said != playing {
            playing = said
            tell()
        }
    }

    private func tell() { changed?(running, running ? playing : nil) }
}

/// The real tap: every process's sound but Pilot's own, mixed to stereo, unmuted and private, in an aggregate device on
/// the default output, its samples written to the ring on Core Audio's thread. Torn down whole at stop.
@MainActor
final class CoreAudioTapSource: DockAudioSource {
    let name = "core audio tap"
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "dev.banozz.pilot.dock-tap", qos: .userInteractive)

    func start(into ring: DockSampleRing) throws {
        stop()
        guard let output = defaultOutput() else { throw DockAudioError.noDevice }
        var uidRef: Unmanaged<CFString>?
        var status = audioProperty(output, kAudioDevicePropertyDeviceUID, &uidRef)
        guard status == noErr, let uid = uidRef?.takeRetainedValue() else { throw DockAudioError.status("read the output device", status) }
        // Pilot's own sound left out, its process object found from its pid.
        var me = AudioObjectID(kAudioObjectUnknown)
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        description.name = "Pilot dock visualizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw DockAudioError.status("make the tap", status) }
        var format = AudioStreamBasicDescription()
        if audioProperty(tap, kAudioTapPropertyFormat, &format) == noErr, format.mSampleRate > 0 { ring.rate = format.mSampleRate }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = max(1, Int(format.mChannelsPerFrame))
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pilot dock visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else { stop(); throw DockAudioError.status("make its device", status) }
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, Self.reader(ring, interleaved: interleaved, channels: channels))
        guard status == noErr, let proc else { stop(); throw DockAudioError.status("listen", status) }
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { stop(); throw DockAudioError.status("start", status) }
    }

    /// The IO block, made outside the main actor: Core Audio calls it on its own thread, where a main-actor closure would
    /// trap on its isolation check.
    nonisolated private static func reader(_ ring: DockSampleRing, interleaved: Bool, channels: Int) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            if interleaved {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
                ring.write(left: samples, right: channels > 1 ? samples + 1 : nil, frames: frames, stride: channels)
            } else {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
                ring.write(left: samples, right: right.map { UnsafePointer($0) }, frames: frames)
            }
        }
    }

    func stop() {
        if aggregate != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    /// A tap of its own started for a moment, beside any running one: macOS asks for System Audio Recording Only the
    /// first time one starts.
    func ask() async {
        let probe = CoreAudioTapSource()
        do { try probe.start(into: DockSampleRing()) } catch {
            docklog.error("dock visualizer ask: \(String(describing: error), privacy: .public)")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        probe.stop()
    }
}
