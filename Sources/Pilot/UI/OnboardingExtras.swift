import AppKit
import SwiftUI
import ImageScale
import PilotCore

/// Try it's optional panel, "More, if you want" (Onboarding 1.1, Q843): the extras that are no part of Set up, each
/// acting on its own button or switch: the AI provider, Extensions, Recommend apps, the upscaler's Max quality and the
/// terminal (T76).
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

    static let terminalTitle = "Terminal"
    static var terminalDetail: String { "Ghostty for Hyper+T, which otherwise downloads on its first press · \(TerminalPack.pin.megabytes) MB" }

    /// The terminal's line: on this Mac, its download's state, or nil to offer Download.
    static var terminalState: String? {
        if let d = ExtrasDownloads.shared.downloads.first(where: { $0.title == terminalTitle }) { return d.words }
        return TerminalPack.isInstalled() ? "On this Mac" : nil
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
    static let voicesName = "voices", upscalerName = "upscaler", terminalName = "terminal"

    private var speech: SpeechChoice?
    private var voices = false
    /// Max quality's download, nil until it starts.
    private var upscaler: SpeechModel.State?
    /// The terminal pack's download (T76), nil until it starts.
    private(set) var terminal: SpeechModel.State?
    @ObservationIgnored private var terminalTask: Task<Void, Never>?
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
    /// upscaler and the terminal pack from the start. Beyond the saved list only the terminal's folder is listed (T76, Q900):
    /// an older pack there and none for this Pilot is an update's changed pack, fetched now so the next Hyper+T never waits.
    func resume() {
        let names = defaults.stringArray(forKey: Self.key) ?? []
        if !names.isEmpty {
            log.notice("extras: resuming \(names.joined(separator: ", "), privacy: .public)")
            begin(speech: names.lazy.compactMap(SpeechChoice.init).first(where: SpeechChoice.offered.contains), voices: names.contains(Self.voicesName),
                  upscaler: names.contains(Self.upscalerName))
        }
        // The folder is read, and an older pack or a quit's staging deleted, off the main thread; the terminal's fetch, a
        // resumed one or an update's changed pack, starts only after, so the sweep never takes a staging folder in use.
        Task {
            let changedPack = await Task.detached(priority: .utility, operation: { TerminalPack.sweep() }).value
            guard changedPack || names.contains(Self.terminalName) else { return }
            log.notice("extras: fetching the terminal pack\(changedPack ? ", changed by an update" : "", privacy: .public)")
            fetchTerminal()
        }
    }

    /// The terminal pack, from the first press, Settings or the launch; one fetch at a time.
    func fetchTerminal() {
        begin(speech: nil, voices: false, upscaler: false, terminal: true)
    }

    /// Cancel on the first press's progress, and Remove: the download stops and leaves nothing.
    func cancelTerminal() {
        terminalTask?.cancel()
        terminalTask = nil
        terminal = nil
        save()
    }

    /// Starts what is not on disk yet, saves which, and watches them until each ends.
    private func begin(speech: SpeechChoice?, voices: Bool, upscaler: Bool, terminal: Bool = false) {
        if let speech, !SpeechModels.shared.model(speech).isReady {
            self.speech = speech
            SpeechModels.shared.model(speech).download()
        }
        if voices, !KokoroModel.shared.isReady {
            self.voices = true
            KokoroModel.shared.download()
        }
        if upscaler, UpscaleModels.compiled(.max) == nil { fetchUpscaler() }
        if terminal, !TerminalPack.isInstalled(), terminalTask == nil { startTerminal() }
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
        if let terminal, pending(terminal) { names.append(Self.terminalName) }
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

    /// The pinned pack, checked against the running Pilot's own certificate, then the older packs' folders go.
    private func startTerminal() {
        let pin = TerminalPack.pin
        guard let url = TerminalPack.url(for: pin) else { return failTerminal(TerminalPack.Failure("This Pilot names no release to fetch its terminal from")) }
        terminal = .downloading(0)
        terminalTask = Task {
            do {
                // Pilot's own signature is read off the main thread, once (TerminalPack caches it).
                let requirement = try await Task.detached(priority: .utility, operation: { try TerminalPack.pilotRequirement() }).value
                _ = try await TerminalPack.fetch(pin, from: url, requirement: requirement) { share in
                    Task { @MainActor in if case .downloading = self.terminal { self.terminal = .downloading(share) } }
                }
                // Cancelled while it installed: Cancel already cleared the state, and the pack on disk is a good one.
                guard !Task.isCancelled else { return }
                terminalTask = nil
                terminal = .ready
                _ = await Task.detached(priority: .utility, operation: { TerminalPack.sweep() }).value
            } catch is CancellationError {
            } catch {
                // Cancel already cleared the state; a failure that lands after it says nothing.
                guard !Task.isCancelled else { return }
                terminalTask = nil
                failTerminal(error as? TerminalPack.Failure ?? TerminalPack.Failure(error.localizedDescription))
            }
        }
    }

    private func failTerminal(_ failure: TerminalPack.Failure) {
        tblog.error("terminal pack: \(failure.message, privacy: .public)")
        terminal = .failed(failure.message)
    }

    var downloads: [Download] {
        #if DEBUG
        if let seeded { return seeded }
        #endif
        var list: [Download] = []
        if let speech { list.append(Download(title: speech.name, megabytes: speech.megabytes, state: SpeechModels.shared.model(speech).state)) }
        if voices { list.append(Download(title: SetupItem.voices.title, megabytes: KokoroModel.megabytes, state: KokoroModel.shared.state)) }
        if let upscaler { list.append(Download(title: OnboardingExtras.upscalerTitle, megabytes: OnboardingExtras.upscalerMegabytes, state: upscaler)) }
        if let terminal { list.append(Download(title: OnboardingExtras.terminalTitle, megabytes: TerminalPack.pin.megabytes, state: terminal)) }
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
