import AppKit
import SwiftUI
import ImageScale
import PilotCore

/// Onboarding's Extras step (Sven, 2026-10-28, Q5 to Q7): everything Pilot can download or set up, each skippable, the
/// common ones ticked, the dictation model Sven uses recommended. Nothing runs until Continue; then the downloads carry
/// on in the background, owned by the objects Settings shows them from, and Homebrew's run opens in a Terminal window,
/// where its installer asks for the Mac's password.
@Observable @MainActor
final class OnboardingExtras {
    /// One thing a tick sets up.
    enum Item: CaseIterable, Hashable {
        case voices, command, upscaler, homebrew, mole, mas, npm, cargo, ffmpeg, webp, recommendApps, launchAtLogin

        /// Install › Helpers' helper it is; nil for the rest.
        var helper: Helper? {
            switch self {
            case .homebrew: .homebrew
            case .mole: .mole
            case .mas: .mas
            case .npm: .npm
            case .cargo: .cargo
            default: nil
            }
        }

        var title: String {
            if let helper { return helper.name }
            return switch self {
            case .voices: "Read aloud voices"
            case .command: "The pilot command"
            case .upscaler: "Upscaler, Max quality"
            case .ffmpeg: "ffmpeg"
            case .webp: "webp"
            case .recommendApps: "Recommend apps"
            case .launchAtLogin: "Launch Pilot at login"
            default: ""
            }
        }

        /// What it gives, a helper by the feature it serves (Q555).
        @MainActor var detail: String {
            switch self {
            case .voices: "Kokoro's natural English voices, US and UK, run on this Mac · \(KokoroModel.size)"
            case .command: "lets a terminal or an AI agent read and change Pilot; links ~/.local/bin/pilot"
            case .upscaler: "sharper 4x upscales; the General model is already in Pilot · \(Self.upscalerMegabytes) MB"
            case .homebrew: "Update reads its list of apps and tools; Install and Remove use it too. Asks your Mac's password in Terminal."
            case .mas: "App Store apps in Update too; Install gets free App Store apps itself"
            case .mole: "Clean's preview, the clean itself, and Disk usage · installs through Homebrew"
            case .ffmpeg: "Convert: to MP3 and GIF"
            case .webp: "Convert: to WebP"
            case .npm: "Install's search and Update: npm packages (comes with Node)"
            case .cargo: "Install's search and Update: Rust crates (comes with Rust)"
            case .recommendApps: "Install suggests apps and tools for this Mac; off, its search still finds anything"
            case .launchAtLogin: "so Pilot is there after a restart"
            }
        }

        /// Its tag: "needed" for the helper its feature runs through, "recommended" for the rest ticked from the start.
        var chip: String? { [.homebrew, .mole].contains(self) ? "needed" : recommended ? "recommended" : nil }

        /// Max quality's download, as Upscale's own panel says it.
        static let upscalerMegabytes = Int((Double(UpscaleModel.max.download?.bytes ?? 0) / 1_000_000).rounded())

        /// Ticked from the start (Q6: "tick the common ones").
        var recommended: Bool { ![.npm, .cargo, .ffmpeg, .webp].contains(self) }

        /// The Homebrew formula it installs as; nil for what is not a formula.
        var formula: String? {
            switch self {
            case .ffmpeg: ConvertTool.ffmpeg.formula
            case .webp: ConvertTool.cwebp.formula
            default: helper?.package?.name
            }
        }

        static let brew: [Item] = [.homebrew, .mole, .mas, .npm, .cargo, .ffmpeg, .webp]
    }

    /// The helpers grouped by the feature they serve (Sven, 2026-10-29, Q555, after a stranger run skipped them): Update,
    /// Clean, then the other tools, each saying what it does.
    enum Feature: CaseIterable {
        case update, clean, more

        var items: [Item] {
            switch self {
            case .update: [.homebrew, .mas]
            case .clean: [.mole]
            case .more: [.ffmpeg, .webp, .npm, .cargo]
            }
        }

        var title: String {
            switch self {
            case .update: "Update"
            case .clean: "Clean"
            case .more: "More tools"
            }
        }

        var short: String {
            switch self {
            case .update: "update apps and tools"
            case .clean: "free disk space"
            case .more: "for other features"
            }
        }

        /// What the feature does, over its helpers; nil for More tools, whose rows each say it.
        var line: String? {
            switch self {
            case .update: "Pilot's menu lists every app and tool with a newer version, and updates them after you confirm."
            case .clean: "Pilot's menu shows the caches and leftovers Mole would remove and the space it frees, then cleans after you confirm."
            case .more: nil
            }
        }
    }

    /// The model Sven dictates with (his prefs, `dictation.model` = whisperTurbo).
    static let recommendedSpeech = SpeechChoice.whisperTurbo

    /// The dictation rows: Skip, then every model.
    static let speechChoices: [SpeechChoice?] = [nil] + SpeechChoice.offered
    static func speechTitle(_ choice: SpeechChoice?) -> String { choice.map { "Dictation: \($0.name)" } ?? "Dictation: skip for now" }
    static func speechDetail(_ choice: SpeechChoice?) -> String {
        choice.map { "\($0.size) · \($0.note)" } ?? "Pilot's own dictation runs on this Mac; download a model any time"
    }

    /// The dictation model to download, nil to skip.
    var speech: SpeechChoice? = recommendedSpeech
    private(set) var picked = Set(Item.allCases.filter(\.recommended))
    /// What is on this Mac already: shown as such, never ticked. Read when the step shows.
    private(set) var onMac: Set<Item> = []
    /// A speech model already on this Mac, which dictation uses.
    private(set) var speechOnMac: SpeechChoice?
    /// Whether this Mac's state was read.
    private(set) var loaded = false

    /// Whether Continue started the picks, which stay as they were, for Try it.
    private(set) var started = false
    #if DEBUG
    /// A render's Mac in place of this one's: what is on it.
    var seededOnMac: Set<Item>?
    #endif

    func load() {
        guard !loaded else { return }
        loaded = true
        speechOnMac = SpeechModels.shared.active?.choice
        if speechOnMac != nil { speech = nil }
        #if DEBUG
        if let seededOnMac {
            onMac = seededOnMac
            picked.subtract(onMac)
            return
        }
        #endif
        let helpers = Helper.installed()
        onMac = Set(Item.allCases.filter { item in
            switch item {
            case .voices: KokoroModel.shared.isReady
            case .command: CommandLineLink.shared.state == .linked
            case .upscaler: UpscaleModels.compiled(.max) != nil
            case .homebrew, .mole, .mas, .npm, .cargo: item.helper.map { helpers.contains($0.id) } ?? false
            case .ffmpeg: Homebrew.cli("ffmpeg") != nil
            case .webp: Homebrew.cli("cwebp") != nil
            case .recommendApps, .launchAtLogin: false
            }
        })
        picked.subtract(onMac)
        if !Recommendations.shared.show { picked.remove(.recommendApps) }
        if LoginItem.shared.status == .enabled { onMac.insert(.launchAtLogin); picked.remove(.launchAtLogin) }
    }

    /// A row's switch, both styles'.
    func binding(_ item: Item) -> Binding<Bool> { Binding(get: { self.picked.contains(item) }, set: { self.set(item, $0) }) }

    /// A formula needs Homebrew: ticking one ticks Homebrew, and unticking Homebrew unticks them while it is missing.
    func set(_ item: Item, _ on: Bool) {
        if on { picked.insert(item) } else { picked.remove(item) }
        guard !onMac.contains(.homebrew) else { return }
        if on && item.formula != nil { picked.insert(.homebrew) }
        if !on && item == .homebrew { picked.subtract(Item.brew) }
    }

    /// What a feature says when the helper it needs is neither ticked nor on this Mac: that it asks later; nil once ready.
    func later(_ feature: Feature) -> String? {
        let ready = { (item: Item) in self.picked.contains(item) || self.onMac.contains(item) }
        switch feature {
        case .update: return ready(.homebrew) ? nil : "Update will ask to install Homebrew when you open it."
        case .clean:
            guard !ready(.mole) else { return nil }
            return "Clean will ask to install \(ready(.homebrew) ? "Mole" : "Homebrew and Mole") when you open it."
        case .more: return nil
        }
    }

    /// The one Terminal run, shown on the step as it will run; nil when nothing needs Homebrew.
    var brewCommand: String? {
        let formulas = Item.brew.filter(picked.contains).compactMap(\.formula)
        let installer = picked.contains(.homebrew) && !onMac.contains(.homebrew) ? Helper.homebrew.install : nil
        return Onboarding.brewCommand(installer: installer, formulas: formulas)
    }

    /// The download size picked, said at the foot.
    var size: String {
        let mb = (speech?.megabytes ?? 0) + (picked.contains(.voices) ? KokoroModel.megabytes : 0)
            + (picked.contains(.upscaler) ? Item.upscalerMegabytes : 0)
        return mb == 0 ? "Nothing to download" : "\(mb) MB to download"
    }

    /// Extras' foot, beside Continue: what it downloads, and plainly that it opens Terminal when Homebrew's run is picked
    /// (Q7: "show that plainly, never run it without the user's click").
    var footNote: String {
        let downloads = "\(size). Downloads carry on in the background."
        return brewCommand == nil ? downloads : downloads + " Continue also opens Terminal for Homebrew and its helpers; Homebrew asks your Mac's password there."
    }

    /// Continue: each pick starts now and carries on after Finish.
    func start(_ model: OnboardingModel) {
        started = true
        ExtrasDownloads.shared.start(speech: speech, voices: picked.contains(.voices), upscaler: picked.contains(.upscaler))
        if picked.contains(.command) { CommandLineLink.shared.makeLink() }
        if Recommendations.shared.show != picked.contains(.recommendApps) { model.recommend(picked.contains(.recommendApps)) }
        if picked.contains(.launchAtLogin) { model.launchAtLogin(true) }
        if let command = brewCommand {
            let hooks = Item.brew.filter(picked.contains).compactMap { $0.formula.flatMap { Package(.formula, $0)?.key } }
                .map { InstallModule.hook("installed", key: $0) }
            VisibleTerminal.run(command, title: "Install Homebrew and helpers", onSuccess: (hooks + [VisibleRun.waitForReturn]).joined(separator: "; "))
        }
        log.notice("onboarding: extras \(self.picked.count) picked, dictation \(self.speech?.rawValue ?? "skipped", privacy: .public)")
    }

    /// Said over the command, plainly (Q7): it runs only on Continue, and Homebrew asks for the password itself.
    static let terminalNote = "Runs in a Terminal window when you press Continue. Homebrew's installer asks for your Mac's password there."
    static let extensionsDetail = "Pomodoro and the rest of the catalogue, from GitHub"

    /// The menu's Extension catalogue, read from GitHub only as it opens.
    static func browseExtensions() { PilotMenu.shared.pick(live: ExtensionCatalogueMenu.title, source: ExtensionCatalogueMenu()) }

    /// Try it's lines: each download Continue started and where it stands.
    var progress: [(title: String, state: String)] {
        guard started else { return [] }
        let lines = ExtrasDownloads.shared.downloads.map { ($0.title, $0.words) }
        return brewCommand == nil ? lines : lines + [("Homebrew and helpers", "in the Terminal window")]
    }
}

/// The downloads Extras' Continue started, held past Welcome's close: Try it, Pilot's menu-bar item and its dropdown show
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
        typealias Item = OnboardingExtras.Item
        var list: [Download] = []
        if let speech { list.append(Download(title: speech.name, megabytes: speech.megabytes, state: SpeechModels.shared.model(speech).state)) }
        if voices { list.append(Download(title: Item.voices.title, megabytes: KokoroModel.megabytes, state: KokoroModel.shared.state)) }
        if let upscaler { list.append(Download(title: Item.upscaler.title, megabytes: Item.upscalerMegabytes, state: upscaler)) }
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
