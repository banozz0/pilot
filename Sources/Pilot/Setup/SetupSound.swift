import CoreAudio
import Foundation
import Observation

/// Setup › Sound (card agent-bo-95422800): the output and input device and their volume and mute, read when the page
/// shows and followed while it does, so a change in Control Centre or from the volume keys shows here too.
@Observable @MainActor
final class SetupSound {
    struct Side: Equatable {
        var devices: [AudioDevice] = []
        var current: AudioDeviceID?
        /// nil: the device has no volume to read; a level that is not settable shows read-only, with no slider.
        var volume: AudioLevel?
        /// nil: the device has no mute Pilot can set.
        var muted: Bool?
    }

    private(set) var sides: [AudioDirection: Side] = [:]
    /// The last change macOS refused, said on the page.
    private(set) var problem: String?
    @ObservationIgnored private let audio: AudioSystem
    @ObservationIgnored private var watch: (devices: [AudioDeviceID], watch: Watch)?
    /// A read is on its way: true when it re-reads everything.
    @ObservationIgnored private var pending: Bool?

    init(audio: AudioSystem) {
        self.audio = audio
    }

    func side(_ direction: AudioDirection) -> Side { sides[direction] ?? Side() }

    /// The page shows: read everything and follow changes.
    func start() { refresh() }

    /// The page went or its window left the screen: stop following, and drop a read already on its way.
    func stop() {
        watch?.watch.cancel()
        watch = nil
        pending = nil
    }

    func pick(_ id: AudioDeviceID, _ direction: AudioDirection) {
        guard id != side(direction).current else { return }
        let name = side(direction).devices.first { $0.id == id }?.name ?? String(id)
        report(audio.setDefault(id, direction), "macOS refused \(name) as the \(direction.rawValue)")
        refresh()
    }

    /// What a slider shows: the output reads empty while muted and its level comes back on unmute. The input keeps its level.
    func shownLevel(_ direction: AudioDirection) -> Float {
        direction == .output && side(direction).muted == true ? 0 : side(direction).volume?.value ?? 0
    }

    func setVolume(_ value: Float, _ direction: AudioDirection) {
        guard side(direction).volume?.settable == true, let id = side(direction).current else { return }
        guard report(audio.setVolume(value, id, direction), "macOS refused the \(direction.rawValue) volume") else { return }
        sides[direction]?.volume = AudioLevel(value: value, settable: true)
        // The output's mute follows its level, as macOS's slider does: above zero it sounds, at zero it is muted. The input's
        // mute stays the person's own, so a nudge of its level never opens a muted microphone.
        let silent = value <= 0
        if direction == .output, let muted = side(.output).muted, muted != silent { setMuted(silent, .output) }
    }

    func setMuted(_ muted: Bool, _ direction: AudioDirection) {
        guard side(direction).muted != nil, let id = side(direction).current else { return }
        if report(audio.setMuted(muted, id, direction), "macOS refused to \(muted ? "mute" : "unmute") the \(direction.rawValue)") {
            sides[direction]?.muted = muted
        }
    }

    /// Mutes or unmutes: the top bar's volume click (card agent-bo-95422852).
    func toggleMute(_ direction: AudioDirection) {
        if let muted = side(direction).muted { setMuted(!muted, direction) }
    }

    /// A notification: a volume or mute re-reads only those, a default or the device list everything; a burst of them
    /// (a device switch fires several) reads once.
    /// One that lands after the page stopped (already queued when its listener went) is dropped.
    func changed(devices: Bool) {
        guard watch != nil else { return }
        if let full = pending { pending = full || devices; return }
        pending = devices
        DispatchQueue.main.async { [weak self] in
            guard let self, let full = pending else { return }
            pending = nil
            guard watch != nil else { return }
            if full { refresh() } else { readLevels() }
        }
    }

    private func refresh() {
        for direction in AudioDirection.allCases {
            sides[direction] = Side(devices: audio.devices(direction), current: audio.defaultDevice(direction))
        }
        readLevels()
        let ids = AudioDirection.allCases.compactMap { side($0).current }
        guard ids != watch?.devices else { return }
        watch?.watch.cancel()
        watch = (ids, audio.watch(ids) { [weak self] devices in self?.changed(devices: devices) })
    }

    private func readLevels() {
        for direction in AudioDirection.allCases {
            guard let id = side(direction).current else { continue }
            sides[direction]?.volume = audio.volume(id, direction)
            sides[direction]?.muted = audio.muted(id, direction)
        }
    }

    @discardableResult
    private func report(_ ok: Bool, _ refusal: String) -> Bool {
        problem = ok ? nil : refusal
        if !ok { slog.error("setup: \(refusal, privacy: .public)") }
        return ok
    }
}
