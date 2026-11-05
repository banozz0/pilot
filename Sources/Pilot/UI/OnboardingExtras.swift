import AppKit
import SwiftUI
import ImageScale
import PilotCore

/// Try it's optional panel, "More, if you want" (Onboarding 1.1, Q843): the extras that are no part of Set up, each
/// acting on its own button or switch: the AI provider, Extensions, Recommend apps and the upscaler's Max quality.
@MainActor
enum OnboardingExtras {
    static let extensionsDetail = "Pomodoro and the rest of the catalogue, from GitHub"
    static let recommendDetail = "Install suggests apps and tools for this Mac; off, its search still finds anything"
    static let upscalerTitle = "Upscaler, Max quality"
    static var upscalerDetail: String { "sharper 4x upscales; the General model is already in Pilot · \(upscalerMegabytes) MB" }

    /// Max quality's download, as Upscale's own panel says it.
    static let upscalerMegabytes = Int((Double(UpscaleModel.max.download?.bytes ?? 0) / 1_000_000).rounded())

    /// The menu's Extension catalogue, read from GitHub only as it opens.
    static func browseExtensions() { PilotMenu.shared.pick(live: ExtensionCatalogueMenu.title, source: ExtensionCatalogueMenu()) }

    /// Max quality's download, started from the panel; Pilot's menu-bar item shows it as Set up's downloads.
    static func fetchUpscaler() { ExtrasDownloads.shared.start(speech: nil, voices: false, upscaler: true) }

    /// The upscaler's line: on this Mac, its download's state, or nil to offer Download.
    static var upscalerState: String? {
        if let d = ExtrasDownloads.shared.downloads.first(where: { $0.title == upscalerTitle }) { return d.words }
        return UpscaleModels.compiled(.max) != nil ? "On this Mac" : nil
    }

    /// Recommend apps (C5), the same switch as Defaults' and Install's.
    static func recommend(_ on: Bool) {
        Recommendations.shared.show = on
        log.notice("onboarding: recommend apps \(on ? "on" : "off", privacy: .public)")
    }
}

/// The downloads Set up and Try it's upscaler started, held past Welcome's close: Try it, Pilot's menu-bar item and its dropdown show
/// them until each ends (Sven, 2026-10-28, Q543). The speech model and voices are owned by what Settings shows them from,
/// so this keeps only which ones; the upscaler's fetch has no other owner, so its state lives here. Which ones are saved
/// until each is on disk or Sven cancels or removes it, so one cut off by quitting Pilot starts again at the next launch
/// (Sven, 2026-10-29: "I closed Pilot … while the dictation model was being downloaded and the download stopped").
@Observable @MainActor
final class ExtrasDownloads {
    static let shared = ExtrasDownloads()

    /// One download as it stands.
    struct Download {
        let title: String
        let megabytes: Int
        let state: SpeechModel.State

        var isRunning: Bool {
            switch state {
            case .downloading, .preparing: true
            case .absent, .ready, .failed: false
            }
        }

        /// Its share done, nil once failed; the upscaler reports none, so it counts as nothing until done.
        var done: Double? {
            switch state {
            case .downloading(let share): share
            case .preparing, .ready: 1
            case .absent: 0
            case .failed: nil
            }
        }

        var words: String {
            switch state {
            case .absent: "waiting"
            case .downloading(let share): "downloading \(Int(share * 100))%"
            case .preparing: "preparing"
            case .ready: "done"
            case .failed(let why): "failed: \(why)"
            }
        }
    }

    /// The downloads not yet ended: a speech model's raw value, `voices`, `upscaler`.
    static let key = "extras.downloads"
    static let voicesName = "voices", upscalerName = "upscaler"

    private var speech: SpeechChoice?
    private var voices = false
    /// Max quality's download, nil until it starts.
    private var upscaler: SpeechModel.State?
    @ObservationIgnored private let defaults: UserDefaults
    #if DEBUG
    /// A render's downloads in place of the real ones.
    var seeded: [Download]?
    #endif

    init(defaults: UserDefaults = .pilot()) { self.defaults = defaults }

    func start(speech: SpeechChoice?, voices: Bool, upscaler: Bool) {
        if let speech { SpeechModels.shared.pick = speech }
        begin(speech: speech, voices: voices, upscaler: upscaler)
    }

    /// At launch: the downloads a quit cut off start again, the speech model and voices from the files already there, the
    /// upscaler from the start. Nothing is read beyond the saved list unless it names something.
    func resume() {
        let names = defaults.stringArray(forKey: Self.key) ?? []
        guard !names.isEmpty else { return }
        log.notice("extras: resuming \(names.joined(separator: ", "), privacy: .public)")
        begin(speech: names.lazy.compactMap(SpeechChoice.init).first(where: SpeechChoice.offered.contains), voices: names.contains(Self.voicesName),
              upscaler: names.contains(Self.upscalerName))
    }

    /// Starts what is not on disk yet, saves which, and watches them until each ends.
    private func begin(speech: SpeechChoice?, voices: Bool, upscaler: Bool) {
        if let speech, !SpeechModels.shared.model(speech).isReady {
            self.speech = speech
            SpeechModels.shared.model(speech).download()
        }
        if voices, !KokoroModel.shared.isReady {
            self.voices = true
            KokoroModel.shared.download()
        }
        if upscaler, UpscaleModels.compiled(.max) == nil { fetchUpscaler() }
        save()
        watch()
    }

    /// Saves the downloads still to finish: on disk (ready) or cancelled and removed (absent) ends one; a failed one stays,
    /// so the next launch tries it again.
    private func save() {
        func pending(_ state: SpeechModel.State) -> Bool { state != .ready && state != .absent }
        var names: [String] = []
        if let speech, pending(SpeechModels.shared.model(speech).state) { names.append(speech.rawValue) }
        if voices, pending(KokoroModel.shared.state) { names.append(Self.voicesName) }
        if let upscaler, pending(upscaler) { names.append(Self.upscalerName) }
        if names.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(names, forKey: Self.key) }
    }

    /// Saves again at each change of a download's state, until none is left to finish.
    private func watch() {
        guard defaults.stringArray(forKey: Self.key) != nil else { return }
        withObservationTracking { _ = downloads.map(\.state) } onChange: { [weak self] in
            Task { @MainActor in self?.save(); self?.watch() }
        }
    }

    private func fetchUpscaler() {
        upscaler = .downloading(0)
        Task {
            do {
                try await UpscaleModels.fetch(.max, helper: UpscaleModels.helper())
                upscaler = .ready
            } catch {
                upscaler = .failed((error as? UpscaleModels.Failure)?.message ?? error.localizedDescription)
            }
        }
    }

    var downloads: [Download] {
        #if DEBUG
        if let seeded { return seeded }
        #endif
        var list: [Download] = []
        if let speech { list.append(Download(title: speech.name, megabytes: speech.megabytes, state: SpeechModels.shared.model(speech).state)) }
        if voices { list.append(Download(title: SetupItem.voices.title, megabytes: KokoroModel.megabytes, state: KokoroModel.shared.state)) }
        if let upscaler { list.append(Download(title: OnboardingExtras.upscalerTitle, megabytes: OnboardingExtras.upscalerMegabytes, state: upscaler)) }
        return list
    }

    /// The share downloaded by size, a failed one left out; nil once none runs.
    var share: Double? {
        let all = downloads
        guard all.contains(where: \.isRunning) else { return nil }
        let live = all.compactMap { d in d.done.map { (d.megabytes, $0) } }
        let total = live.reduce(0) { $0 + $1.0 }
        return total == 0 ? 0 : live.reduce(0) { $0 + Double($1.0) * $1.1 } / Double(total)
    }
}
