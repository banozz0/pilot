import AppKit
import AVFoundation
import Carbon.HIToolbox
import OSLog
import PilotCore

private let whisperLog = Logger(subsystem: "dev.banozz.pilot", category: "dictation")

/// One line pilot-dictate prints (Helpers/pilot-dictate, its main.swift says when each comes).
enum DictateLine: Equatable {
    case listening, preparing, loaded, prepared
    /// The microphone went away mid-take; the take so far follows as text.
    case inputLost
    case progress(Double)
    /// How loud the microphone was, a few readings 0 to 1 per buffer: the pill's waveform.
    case levels([Double])
    /// The words so far, while the pill shows words: never typed.
    case partial(String)
    case text(String)
    case error(String)

    init?(_ line: String) {
        let word = line.prefix { $0 != " " }, rest = String(line.dropFirst(word.count + 1))
        switch word {
        case "listening": self = .listening
        case "preparing": self = .preparing
        case "loaded": self = .loaded
        case "prepared": self = .prepared
        case "input": guard rest == "lost" else { return nil }; self = .inputLost
        case "progress": guard let fraction = Double(rest) else { return nil }; self = .progress(fraction)
        case "level":
            let levels = rest.split(separator: " ").compactMap { Double($0) }
            guard !levels.isEmpty else { return nil }
            self = .levels(levels)
        case "partial": guard let words = try? JSONDecoder().decode(String.self, from: Data(rest.utf8)) else { return nil }; self = .partial(words)
        case "text": guard let text = try? JSONDecoder().decode(String.self, from: Data(rest.utf8)) else { return nil }; self = .text(text)
        case "error": self = .error(rest)
        default: return nil
        }
    }
}

/// A pilot-dictate at work: `finish` closes its stdin (a take ends and is written down), `cancel` stops it.
@MainActor
protocol DictateRun: AnyObject {
    func finish()
    func cancel()
}

/// Starts pilot-dictate; the tests pass a fake, so none downloads, records or loads a model.
@MainActor
protocol DictateHelper {
    /// Nil, logged, when the helper is not in the bundle (swift run, the tests) or does not start. Lines and the exit
    /// reach the main actor in the order the helper printed them.
    func run(_ arguments: [String], heard: @escaping @MainActor (DictateLine) -> Void, ended: @escaping @MainActor (Int32) -> Void) -> DictateRun?
    /// Whether this helper already prepared the model in `folder` on this macOS, read without starting it.
    func prepared(_ folder: URL) async -> Bool
}

extension DictateHelper {
    /// Cannot tell: the prepare runs and the helper decides.
    func prepared(_ folder: URL) async -> Bool { false }
}

/// Contents/Helpers/pilot-dictate, built from Helpers/pilot-dictate by Scripts/build-app.sh.
struct BundledDictateHelper: DictateHelper {
    static let path = Bundle.main.bundleURL.appending(path: "Contents/Helpers/pilot-dictate").path

    func run(_ arguments: [String], heard: @escaping @MainActor (DictateLine) -> Void, ended: @escaping @MainActor (Int32) -> Void) -> DictateRun? {
        guard FileManager.default.isExecutableFile(atPath: Self.path) else {
            whisperLog.error("pilot-dictate is not in the bundle")
            return nil
        }
        let command = arguments.first ?? ""
        do {
            let session = try ChildProcess.Session(Self.path, arguments, lines: { line in
                guard let parsed = DictateLine(line) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { heard(parsed) } }
            }, ended: { status, stderr in
                if status != 0 { whisperLog.error("pilot-dictate \(command, privacy: .public) exited \(status): \(stderr, privacy: .public)") }
                DispatchQueue.main.async { MainActor.assumeIsolated { ended(status) } }
            })
            whisperLog.notice("pilot-dictate \(command, privacy: .public) started, pid \(session.pid)")
            return Run(session: session)
        } catch {
            whisperLog.error("pilot-dictate: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Whether this helper already prepared the model in `folder` on this macOS, read off the main thread without
    /// starting it, so a launch spawns no prepare that would find nothing to do (lean audit 2026-11-05: two 12.5 MiB
    /// children a launch). The helper's own rule, Dictate.isPrepared in Helpers/pilot-dictate: the folder's `prepared`
    /// stamp names this helper's code signature and this macOS build, and every part of that compile is still in Core
    /// ML's cache. In doubt, false, and the helper decides as before.
    func prepared(_ folder: URL) async -> Bool {
        let helper = URL(filePath: Self.path)
        return await Task.detached(priority: .utility) { Self.stamped(folder, helper: helper) }.value
    }

    nonisolated private static func stamped(_ folder: URL, helper: URL) -> Bool {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let os = SystemReader.sysctlString("kern.osversion"),
              let written = try? String(contentsOf: folder.appending(path: "prepared"), encoding: .utf8) else { return false }
        let stamp = hash.map { String(format: "%02x", $0) }.joined() + " " + os
        guard written.hasPrefix(stamp + " "), let parts = Int(written.dropFirst(stamp.count + 1)), parts > 0 else { return false }
        // Finished bundles in the cache folder for this macOS build; a `.tmp.<pid>` one is a compile cut off.
        let cache = folder.appending(path: "Library/Caches/pilot-dictate/com.apple.e5rt.e5bundlecache/\(os)")
        let bundles = FileManager.default.enumerator(atPath: cache.path)
        var compiled = 0
        while let item = bundles?.nextObject() as? String {
            if bundles?.level == 2, item.hasSuffix(".bundle"), !item.contains(".tmp.") { compiled += 1 }
            if (bundles?.level ?? 0) >= 2 { bundles?.skipDescendants() }
        }
        return compiled >= parts
    }

    final class Run: DictateRun {
        let session: ChildProcess.Session
        init(session: ChildProcess.Session) { self.session = session }
        func finish() { session.closeInput() }
        func cancel() { session.stop() }
    }
}

/// The microphone grant: Pilot's own dictation asks for it (onboarding, General, Voice › Dictation),
/// and its child records under it. Read when a page shows it or a take starts, never at launch or polled: Mode lights
/// holds Pilot's dictation, and so this, from the first bar drawn.
@Observable @MainActor
final class MicrophoneGrant {
    static let shared = MicrophoneGrant()

    /// Nil until first read.
    private(set) var status: AVAuthorizationStatus?
    @ObservationIgnored private let read: @MainActor () -> AVAuthorizationStatus
    @ObservationIgnored private let request: @MainActor () async -> Bool

    init(read: @escaping @MainActor () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
         request: @escaping @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.read = read
        self.request = request
    }

    var isGranted: Bool { status == .authorized }

    func refresh() {
        let now = read()
        if now != status { status = now }
    }

    /// macOS's own prompt the first time; once answered, the Privacy pane, where only Sven can change it.
    func ask() async {
        refresh()
        if status == .notDetermined { _ = await request() } else if status != .authorized { Self.openSettings() }
        refresh()
    }

    static func openSettings() { SystemModule.pane("com.apple.preference.security?Privacy_Microphone") }

    /// The tip for a press on a Mac with no input device, said by Pilot or by the helper (Q393).
    static let noInputTip = "No microphone connected"

    /// The tip for a take the grant stops, with the pane one click away.
    static let offTip = "Not listening: Microphone is off for Pilot"
    static let open = HUD.TipAction(title: "Open") { openSettings() }
}

/// The speech models Pilot's own dictation offers (story 194; Parakeet and the small Whisper added 2026-10-16, Sven:
/// "download more speech models … Parakeet, the best one"; Parakeet Ultra in place of TDT v3 in 1.0.2, Q719). Each has a
/// folder of its own under Speech, named by its raw value. Measured on Sven's M4 (2026-10-16): see SPEC story 194.
enum SpeechChoice: String, CaseIterable, Sendable {
    case parakeetUltra, whisperTurbo, whisperSmall
    /// Parakeet TDT v3 in Speech/parakeet, which Ultra replaced: never offered or downloaded again, dictated on until
    /// Ultra is on disk, removed on Sven's click.
    case parakeetV3 = "parakeet"

    /// What a page, onboarding and `pilot set` offer.
    static let offered: [SpeechChoice] = [.parakeetUltra, .whisperTurbo, .whisperSmall]

    /// The model this one took the place of, whose files dictation keeps using until this one is on disk.
    var replaces: SpeechChoice? { self == .parakeetUltra ? .parakeetV3 : nil }
    var replacement: SpeechChoice? { Self.allCases.first { $0.replaces == self } }

    var name: String {
        switch self {
        case .parakeetUltra: "Parakeet Ultra"
        case .parakeetV3: "Parakeet TDT v3"
        case .whisperTurbo: "Whisper large-v3 turbo"
        case .whisperSmall: "Whisper small"
        }
    }

    var megabytes: Int {
        switch self {
        case .parakeetUltra: 632
        case .parakeetV3: 469
        case .whisperTurbo: 632
        case .whisperSmall: 214
        }
    }

    var size: String { "\(megabytes) MB" }

    /// What sets it apart, in a few words, with the credit its licence asks for.
    var note: String {
        switch self {
        case .parakeetUltra: "the fastest, best in English · Moondream on NVIDIA's Parakeet, CC BY 4.0, through FluidAudio"
        case .parakeetV3: "the fastest and lightest, best in English · NVIDIA, CC BY 4.0, through FluidAudio"
        case .whisperTurbo: "the most accurate, Spanish and 98 more languages · OpenAI, MIT"
        case .whisperSmall: "a third of the size, best in English · OpenAI, MIT"
        }
    }

    /// Its name to pilot-dictate (Dictate.Model): the engine, then that engine's name for it. The helper writes it into
    /// the folder's ready file last and reads it back from there.
    var helperName: String {
        switch self {
        case .parakeetUltra: "fluidaudio/ultra"
        case .parakeetV3: "fluidaudio/v3"
        case .whisperTurbo: "whisperkit/large-v3-v20240930_turbo_632MB"
        case .whisperSmall: "whisperkit/small_216MB"
        }
    }
}

/// One speech model, downloaded on Sven's click into Application Support, never in the bundle, and deleted from the
/// same page. On disk means downloaded and prepared: the helper writes `ready` last, holding the model's name, so a
/// download cut short never counts.
@Observable @MainActor
final class SpeechModel {
    enum State: Equatable {
        case absent, downloading(Double), preparing, ready
        case failed(String)
    }

    /// Dictate.readyFile in Helpers/pilot-dictate.
    static let readyFile = "ready"
    /// Written as a download starts and gone once it is on disk or cancelled: one left at launch was cut off by a quit,
    /// and starts again (Sven, 2026-10-29: "the download stopped"). Kokoro's folder keeps one too.
    static let downloadingFile = "downloading"

    static func markDownloading(_ folder: URL, _ on: Bool) {
        let marker = folder.appending(path: downloadingFile)
        if on {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    static func wasCutOff(_ folder: URL) -> Bool { FileManager.default.fileExists(atPath: folder.appending(path: downloadingFile).path) }

    let choice: SpeechChoice
    let folder: URL
    private(set) var state: State
    /// Whether its folder is there, a download cut short included: what Remove the old v3 files offers to delete.
    private(set) var hasFiles: Bool
    @ObservationIgnored private let helper: DictateHelper
    /// Told when a download leaves the model on disk.
    @ObservationIgnored var onReady: (@MainActor () -> Void)?
    @ObservationIgnored private var run: DictateRun?
    @ObservationIgnored private var failure: String?
    /// Counts runs, so a stopped one's last lines and exit, which come up to seconds later, never touch the next.
    @ObservationIgnored private var generation = 0

    init(_ choice: SpeechChoice, base: URL, helper: DictateHelper) {
        self.choice = choice
        folder = base.appending(path: choice.rawValue)
        self.helper = helper
        state = Self.onDisk(folder, choice) ? .ready : .absent
        hasFiles = FileManager.default.fileExists(atPath: folder.path)
    }

    var isReady: Bool { state == .ready }

    static func onDisk(_ folder: URL, _ choice: SpeechChoice) -> Bool {
        (try? String(contentsOf: folder.appending(path: readyFile), encoding: .utf8)) == choice.helperName
    }

    /// Fetches and prepares the model; Download again after a failure or a cancel picks up the files already there. One
    /// no longer offered never downloads, nor resumes.
    func download() {
        guard run == nil, !isReady, SpeechChoice.offered.contains(choice) else { return }
        failure = nil
        state = .downloading(0)
        Self.markDownloading(folder, true)
        hasFiles = true
        generation += 1
        let mine = generation
        run = helper.run(["download", folder.path, choice.helperName], heard: { [weak self] line in
            if self?.generation == mine { self?.heard(line) }
        }, ended: { [weak self] status in if self?.generation == mine { self?.ended(status) } })
        if run == nil { state = .failed("The speech helper is missing from this build of Pilot.") }
        whisperLog.notice("speech model \(self.choice.rawValue, privacy: .public): download")
    }

    /// At launch: a download a quit cut off goes on from the files already there.
    func resume() {
        if !isReady, Self.wasCutOff(folder) { download() }
    }

    func cancel() {
        let stopping = run
        run = nil
        generation += 1
        stopping?.cancel()
        if !isReady {
            state = .absent
            Self.markDownloading(folder, false)
        }
    }

    /// Deletes the model's folder; it waits for Download again.
    func remove() {
        cancel()
        do { try FileManager.default.removeItem(at: folder) } catch { whisperLog.error("speech model: \(String(describing: error), privacy: .public)") }
        state = .absent
        hasFiles = FileManager.default.fileExists(atPath: folder.path)
        whisperLog.notice("speech model \(self.choice.rawValue, privacy: .public): removed")
    }

    /// Reads the folder again after something outside moved it (Uninstall's Trash): gone, it waits for Download again.
    func refresh() {
        state = Self.onDisk(folder, choice) ? .ready : .absent
        hasFiles = FileManager.default.fileExists(atPath: folder.path)
    }

    /// The folder's size on disk in MB, the Neural Engine's compile included; nil once it is gone.
    nonisolated static func megabytes(_ folder: URL) -> Int? {
        let files = FileManager.default
        guard files.fileExists(atPath: folder.path), let walk = files.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return nil }
        var bytes = 0
        for case let file as URL in walk { bytes += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0 }
        return bytes / 1_000_000
    }

    /// The Neural Engine's compile of the model lives in its folder (Helpers/pilot-dictate, Dictate), and a new helper, a
    /// new macOS or a compile gone would make the first dictation wait minutes: the helper compiles it again in the
    /// background, a minute after launch (Engine), and does nothing when it already has.
    func prepareInBackground() {
        guard isReady, run == nil else { return }
        generation += 1
        let mine = generation
        run = helper.run(["prepare", folder.path], heard: { line in
            if line == .prepared { whisperLog.notice("speech model: prepared for this helper") }
        }, ended: { [weak self] _ in
            guard let self, generation == mine else { return }
            run = nil
        })
        // Takes wait on its compile (Dictate.load's lock), so a prepare still running after 10 minutes, past the longest
        // compile measured (8 min, behind three others, 2026-10-31), counts as hung and stops; the next take compiles itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.prepareLimit) { [weak self] in
            guard let self, generation == mine, run != nil else { return }
            whisperLog.error("speech model \(self.choice.rawValue, privacy: .public): prepare still running after \(Int(Self.prepareLimit)) s, stopped")
            cancel()
        }
    }

    static let prepareLimit: TimeInterval = 600

    /// `prepareInBackground` at launch, unless the helper already prepared this model (DictateHelper.prepared): an
    /// unchanged helper spawns nothing.
    func prepareIfStale() async {
        guard isReady, run == nil, !(await helper.prepared(folder)) else { return }
        prepareInBackground()
    }

    private func heard(_ line: DictateLine) {
        switch line {
        case .progress(let fraction): state = .downloading(fraction)
        case .preparing: state = .preparing
        case .error(let reason): failure = reason
        default: break
        }
    }

    private func ended(_ status: Int32) {
        run = nil
        if Self.onDisk(folder, choice) {
            state = .ready
            Self.markDownloading(folder, false)
            onReady?()
        } else {
            state = .failed(failure ?? "The download stopped (exit \(status)). Try again.")
        }
        whisperLog.notice("speech model \(self.choice.rawValue, privacy: .public): download ended \(status)")
    }
}

/// Every speech model and the one in use (`dictation.model`): Sven's pick while on disk. The first model to reach the
/// disk becomes the pick, and after that only Use changes it, so a later download never swaps the model he is used to;
/// with the pick gone, the first one on disk in SpeechChoice's order takes over. A pick of a replaced model (Parakeet v3)
/// becomes its replacement, which dictates on the old files until it is downloaded itself.
@Observable @MainActor
final class SpeechModels {
    static let shared = SpeechModels()
    static let key = "dictation.model"
    static let standardBase = PilotFolder.support.appending(path: "Speech")

    let all: [SpeechModel]
    /// The Speech folder that holds each model's folder, and the takes a quit left (PilotDictation.collectKept).
    let base: URL
    var pick: SpeechChoice? { didSet { defaults.set(pick?.rawValue, forKey: Self.key) } }
    @ObservationIgnored private let defaults: UserDefaults

    init(base: URL = standardBase, helper: DictateHelper = BundledDictateHelper(), defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        self.base = base
        Self.moveSingleModel(in: base)
        all = SpeechChoice.allCases.map { SpeechModel($0, base: base, helper: helper) }
        let saved = defaults.string(forKey: Self.key).flatMap(SpeechChoice.init)
        pick = saved?.replacement ?? saved
        if let saved, saved.replacement != nil {
            defaults.set(pick?.rawValue, forKey: Self.key)
            whisperLog.notice("speech model: the pick \(saved.rawValue, privacy: .public) moved to \(self.pick?.rawValue ?? "", privacy: .public)")
        }
        for model in all { model.onReady = { [weak self] in self?.settle() } }
        settle()
    }

    func model(_ choice: SpeechChoice) -> SpeechModel { all.first { $0.choice == choice }! }

    /// The models a page lists: all but a replaced one.
    var offered: [SpeechModel] { all.filter { SpeechChoice.offered.contains($0.choice) } }

    /// The model dictation uses: the pick while on disk, the model it replaced while that one is, else the first one on disk.
    var active: SpeechModel? { pick.flatMap(usable) ?? all.first(where: \.isReady) }

    private func usable(_ choice: SpeechChoice) -> SpeechModel? {
        [choice, choice.replaces].compactMap { $0 }.map(model).first(where: \.isReady)
    }

    func remove(_ choice: SpeechChoice) {
        model(choice).remove()
        settle()
    }

    func refresh(_ choice: SpeechChoice) {
        model(choice).refresh()
        settle()
    }

    func prepareIfStale() async { await active?.prepareIfStale() }

    /// At launch: each download a quit cut off, from Settings or setup alike, starts again.
    func resume() { all.forEach { $0.resume() } }

    /// No pick on disk: the first model that is becomes it, or its replacement when it was replaced.
    private func settle() {
        guard pick.flatMap(usable) == nil, let first = all.first(where: \.isReady) else { return }
        pick = first.choice.replacement ?? first.choice
        defaults.set(pick?.rawValue, forKey: Self.key)
    }

    /// Build 53 kept its one model, Whisper large-v3 turbo, in Speech itself: it moves into its own folder with the
    /// name the helper reads now, and its prepared stamp goes so the background prepare checks it once more. Can go once
    /// no Mac has a Build 53 model left (Sven's alone had one).
    static func moveSingleModel(in base: URL) {
        let files = FileManager.default, old = base.appending(path: SpeechModel.readyFile)
        guard (try? String(contentsOf: old, encoding: .utf8)) == "large-v3-v20240930_turbo_632MB" else { return }
        let folder = base.appending(path: SpeechChoice.whisperTurbo.rawValue)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.moveItem(at: base.appending(path: "models"), to: folder.appending(path: "models"))
            try Data(SpeechChoice.whisperTurbo.helperName.utf8).write(to: folder.appending(path: SpeechModel.readyFile))
            try files.removeItem(at: old)
            try? files.removeItem(at: base.appending(path: "prepared"))
            whisperLog.notice("speech model: moved Build 53's Whisper into its own folder")
        } catch {
            whisperLog.error("speech model: moving Build 53's Whisper: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Voice › Words (Q598): the words and replacements Sven taught dictation (DictationWords), in the Speech folder beside
/// the models, where pilot-dictate reads the words for Whisper's prompt. Every change is written at once.
@Observable @MainActor
final class DictationVocabulary {
    static let shared = DictationVocabulary()

    let file: URL
    private(set) var taught: DictationWords

    init(file: URL = DictationWords.file(in: SpeechModels.standardBase)) {
        self.file = file
        taught = DictationWords.read(file)
    }

    func learn(_ word: String) { change { $0.learn(word) } }
    func forget(word: String) { change { $0.words.removeAll { $0 == word } } }
    func replace(_ heard: String, with written: String) { change { $0.replace(heard, with: written) } }
    func forget(_ replacement: DictationWords.Replacement) { change { $0.replacements.removeAll { $0 == replacement } } }

    private func change(_ edit: (inout DictationWords) -> Void) {
        var next = taught
        edit(&next)
        guard next != taught else { return }
        taught = next
        do { try next.write(to: file) } catch {
            whisperLog.error("dictation words: not saved: \(String(describing: error), privacy: .public)")
        }
        whisperLog.notice("dictation words: \(next.words.count) words, \(next.replacements.count) replacements")
    }
}

/// Voice › Recent takes (Q599): the last 20 takes' text as the model wrote it, when, how long, by which model and into
/// which app, in one file in Pilot's folder; Clear empties it. No audio is kept, but for a take whose model was still loading
/// at its stop, until it is written down (PilotDictation.collectKept).
@Observable @MainActor
final class DictationTakes {
    static let shared = DictationTakes()

    let file: URL
    private(set) var takes: [DictationTake]

    init(file: URL = PilotFolder.support.appending(path: "dictation-takes.json")) {
        self.file = file
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        takes = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([DictationTake].self, from: $0) } ?? []
    }

    func add(_ take: DictationTake) {
        takes = DictationTake.adding(take, to: takes)
        save()
    }

    func clear() {
        takes = []
        try? FileManager.default.removeItem(at: file)
        whisperLog.notice("dictation takes: cleared")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(takes).write(to: file, options: .atomic)
        } catch {
            whisperLog.error("dictation takes: not saved: \(String(describing: error), privacy: .public)")
        }
    }
}

/// What shows while Pilot dictates (DictationOverlay, Q239): the pill and its toasts. The tests pass a recorder.
@MainActor
protocol DictationShowing: AnyObject {
    /// The ✕, ✓ and Undo the pill and its toast offer.
    func bind(cancel: @escaping @MainActor () -> Void, finish: @escaping @MainActor () -> Void, recover: @escaping @MainActor (String) -> Void)
    /// A take started on this microphone (nil: its name is unknown); `words`: the pill shows the words as they are said.
    func started(microphone: String?, words: Bool)
    func levels(_ levels: [Double])
    /// The words so far, for a pill that shows them.
    func words(_ words: String)
    /// The take ended and is being written down.
    func writing()
    /// Nothing is recording or being written down for Sven any more: the pill goes.
    func ended()
    /// A cancelled take's words: the recover toast holds them for Undo and drops them as it goes.
    func recoverable(_ text: String)
}

/// Pilot's own dictation (story 194): the Dictation binds record the default input in pilot-dictate,
/// a child that lives only while it works, and paste what the speech model wrote down into the app in front through the snippet
/// paste (SnippetPaster). Never into a password field, and never into another app than the one in front when the take
/// ended: that text goes to the clipboard instead.
@Observable @MainActor
final class PilotDictation {
    static let shared = PilotDictation()

    enum State: Equatable { case idle, starting, listening, writing }

    /// What the pill shows while Sven speaks (Sven, 2026-10-17): the waveform, or the words as they are said.
    enum WhileSpeaking: String, CaseIterable, Sendable {
        case waveform, words
        var label: String { self == .waveform ? "Waveform" : "Words" }
    }

    /// Where a take shows (Sven, 2026-11-01): the floating pill, Pilot's top bar, or both. The top bar while it is off
    /// falls back to the pill.
    enum ShowIn: String, CaseIterable, Sendable {
        case pill, topBar, both
        var label: String {
            switch self {
            case .pill: "Floating pill"
            case .topBar: "Top bar"
            case .both: "Both"
            }
        }
    }

    static let openVoice = HUD.TipAction(title: "Open") { AppWindowController.shared.open(.voice) }
    /// Dictate.keptPrefix in Helpers/pilot-dictate: a take's audio or text a quit left beside the models.
    static let keptPrefix = "take-"

    static let whileSpeakingKey = "dictation.whileSpeaking", copyKey = "dictation.copy", pauseMediaKey = "dictation.pauseMedia"
    static let showInKey = "dictation.showIn", waveColourKey = "dictation.waveColour", barSideKey = "dictation.barSide"

    private(set) var state = State.idle {
        didSet { if isLive != (oldValue == .starting || oldValue == .listening) { onLive(isLive) } }
    }
    /// Starting or listening: the take Esc cancels (HyperTap.cancelsDictationOnEscape).
    var isLive: Bool { state == .starting || state == .listening }
    /// Told as a take becomes live and as it stops being live.
    @ObservationIgnored var onLive: @MainActor (Bool) -> Void = { _ in }
    var whileSpeaking: WhileSpeaking { didSet { defaults.set(whileSpeaking.rawValue, forKey: Self.whileSpeakingKey) } }
    var showIn: ShowIn { didSet { defaults.set(showIn.rawValue, forKey: Self.showInKey) } }
    /// Where in the top bar a take shows (Sven on build 9): left just after Pilot's mark, the centre beside its items, or
    /// right before the status items.
    var barSide: TopBarSide { didSet { defaults.set(barSide.rawValue, forKey: Self.barSideKey) } }
    /// The waveform's colour, saved as "plain", "theme" or "#RRGGBB": nil is Plain, the look before this setting (white
    /// on the pill, the bar's own ink in the top bar).
    var waveColour: ColourChoice? { didSet { defaults.set(waveColour?.rawValue ?? ColourChoice.plain, forKey: Self.waveColourKey) } }
    /// A typed take's words are left on the clipboard too. Off, the paste puts Sven's own copy back, as before this
    /// setting: the words pass through the clipboard for half a second and the history skips them.
    var copiesText: Bool { didSet { defaults.set(copiesText, forKey: Self.copyKey) } }
    /// A take pauses what is playing and plays it again after (MediaPause).
    var pausesMedia: Bool { didSet { defaults.set(pausesMedia, forKey: Self.pauseMediaKey) } }
    /// The microphone records for Pilot: Mode lights' microphone light.
    var isListening: Bool { state == .listening }

    let models: SpeechModels
    /// What Sven taught dictation, and the takes kept for Voice › Recent takes.
    let vocabulary: DictationVocabulary
    let takes: DictationTakes
    @ObservationIgnored private let helper: DictateHelper
    @ObservationIgnored private let microphone: MicrophoneGrant
    @ObservationIgnored private let defaults: UserDefaults
    /// The text, and whether it stays on the clipboard after.
    @ObservationIgnored private let paste: @MainActor (String, Bool) -> Void
    @ObservationIgnored private let copy: @MainActor (String) -> Void
    @ObservationIgnored private let frontApp: @MainActor () -> pid_t?
    @ObservationIgnored private let secureInput: @MainActor () -> Bool
    @ObservationIgnored private let tell: @MainActor (String, TimeInterval, HUD.TipAction?) -> Void
    @ObservationIgnored private let after: Watch.After
    @ObservationIgnored private let show: DictationShowing
    @ObservationIgnored private let media: MediaPause
    @ObservationIgnored private let microphoneName: @MainActor () -> String?
    /// The Mac has a default input that records: false and a press says so rather than start the helper.
    @ObservationIgnored private let hasMicrophone: @MainActor () -> Bool
    /// The take the pill shows; nil while idle. A take left to finish in the background is no longer it.
    @ObservationIgnored private var current: Take?
    /// The slow-model tip's timer, for the take being written down.
    @ObservationIgnored private var slowTip: Watch?
    /// A lasting tip of ours is up and goes when the take is written down.
    @ObservationIgnored private var waitingTip = false
    /// The kept takes' audio being written down now, by file name, so none is written down twice.
    @ObservationIgnored private var recovering: [String: DictateRun] = [:]

    /// One take, in its own pilot-dictate. Each keeps what it was spoken to, so a take left to finish in the background
    /// (✕ while it is written down, or a press that starts the next one) types or offers its own words when they come and
    /// never touches the take after it (Sven, 2026-10-23: a take whose model compiled again for 2.5 minutes left the next
    /// press refused with "Still writing down the last take").
    @MainActor
    final class Take {
        var run: DictateRun?
        var target: pid_t?
        /// ✕ ended it: its words go to the recover toast rather than typed.
        var cancelled = false
        var loaded = false
        /// It said its text or an error, so an exit after says nothing more.
        var answered = false
        let started = ContinuousClock.now
        var stopped: ContinuousClock.Instant?

        /// Milliseconds since `instant`, for the log.
        func ms(since instant: ContinuousClock.Instant?) -> Int {
            instant.map { Int((ContinuousClock.now - $0).inSeconds * 1000) } ?? -1
        }
    }

    init(models: SpeechModels = .shared, vocabulary: DictationVocabulary = .shared, takes: DictationTakes = .shared,
         helper: DictateHelper = BundledDictateHelper(), microphone: MicrophoneGrant = .shared,
         defaults: UserDefaults = .pilot(),
         paste: @escaping @MainActor (String, Bool) -> Void = { SnippetPaster().paste($0, thenCopy: $1 ? $0 : nil) },
         copy: @escaping @MainActor (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) },
         frontApp: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         secureInput: @escaping @MainActor () -> Bool = { IsSecureEventInputEnabled() },
         tell: @escaping @MainActor (String, TimeInterval, HUD.TipAction?) -> Void = { HUD.tip($0, seconds: $1, action: $2) },
         after: @escaping Watch.After = Watch.after, show: DictationShowing = DictationOverlay.shared,
         media: MediaControlling = BundledMediaControl(),
         microphoneName: @escaping @MainActor () -> String? = { let audio = CoreAudioSystem(); return audio.defaultDevice(.input).flatMap(audio.name) },
         hasMicrophone: @escaping @MainActor () -> Bool = {
             let audio = CoreAudioSystem()
             return audio.defaultDevice(.input).map { id in audio.devices(.input).contains { $0.id == id } } ?? false
         }) {
        self.models = models
        self.vocabulary = vocabulary
        self.takes = takes
        self.helper = helper
        self.microphone = microphone
        self.defaults = defaults
        whileSpeaking = defaults.string(forKey: Self.whileSpeakingKey).flatMap(WhileSpeaking.init) ?? .waveform
        showIn = defaults.string(forKey: Self.showInKey).flatMap(ShowIn.init) ?? .pill
        barSide = defaults.string(forKey: Self.barSideKey).flatMap(TopBarSide.init) ?? .left
        waveColour = defaults.string(forKey: Self.waveColourKey).flatMap(ColourChoice.init(rawValue:))
        copiesText = defaults.bool(forKey: Self.copyKey)
        pausesMedia = defaults.bool(forKey: Self.pauseMediaKey)
        self.media = MediaPause(media: media)
        self.paste = paste
        self.copy = copy
        self.frontApp = frontApp
        self.secureInput = secureInput
        self.tell = tell
        self.after = after
        self.show = show
        self.microphoneName = microphoneName
        self.hasMicrophone = hasMicrophone
        show.bind(cancel: { [weak self] in self?.cancel() }, finish: { [weak self] in self?.finish() },
                  recover: { [weak self] in self?.recover($0) })
    }

    /// The pill's ✓: the take ends and is typed, as a second press of the key does.
    func finish() {
        if state == .starting || state == .listening { stop() }
    }

    /// The pill's ✕: the take ends and is written down, but kept for Undo instead of typed. Cancelled while written
    /// down, the same. Either way it finishes in the background and Pilot is idle at once: the next press starts a take.
    /// Its helper is left to finish rather than stopped, since one compiling the model leaves it compiled for the next.
    func cancel() {
        guard let take = current else { return }
        take.cancelled = true
        stop()
        whisperLog.notice("pilot dictation: cancelled, written down in the background for Undo")
        // No "getting ready, your words follow" left up: none will be typed.
        detach()
        show.ended()
    }

    /// The recover toast's Undo: the cancelled take's words typed into the app in front now.
    func recover(_ text: String) {
        deliver(text, by: nil)
    }

    /// Dictate on or off; true when it started or stopped a take. A press while the last take is written down starts the
    /// next one; the last one is typed once it is.
    @discardableResult
    func toggle() -> Bool {
        switch state {
        case .idle, .writing: return begin()
        case .starting, .listening: stop(); return true
        }
    }

    /// Dictate while held: the press starts a take, the release ends it.
    func hold(_ down: Bool) {
        if down { _ = begin() } else if state == .starting || state == .listening { stop() }
    }

    /// A take that is still written down goes on in the background, and a new one starts; nothing while one is live.
    private func begin() -> Bool {
        guard !isLive else { return false }
        if state == .writing, let take = current {
            whisperLog.notice("pilot dictation: last take still written down (\(take.loaded ? "model loaded" : "model loading", privacy: .public), \(take.ms(since: take.stopped)) ms after its stop), it goes on in the background")
            detach()
            guard start() else { show.ended(); return false }
            tell("Listening. Your last take is typed once it is written down", 3, nil)
            return true
        }
        return start()
    }

    /// The take the pill shows goes on in the background: Pilot is idle, its tip and timer gone.
    private func detach() {
        current = nil
        state = .idle
        dismissWaitingTip()
    }

    private func start() -> Bool {
        guard let model = models.active else {
            tell("Download a speech model first, in Voice › Dictation", 4, Self.openVoice)
            return false
        }
        guard hasMicrophone() else {
            tell(MicrophoneGrant.noInputTip, 4, nil)
            return false
        }
        microphone.refresh()
        switch microphone.status {
        case .authorized: break
        case .notDetermined:
            let microphone = microphone
            Task { @MainActor in await microphone.ask() }
            tell("Allow the microphone for Pilot, then press again", 4, nil)
            return false
        default:
            tell(MicrophoneGrant.offTip, 4, MicrophoneGrant.open)
            return false
        }
        // A background prepare goes on: the take's helper waits for its compile (Dictate.load's lock) and loads from it,
        // where stopping it threw minutes of compiling away and the take started its own from nothing.
        let words = whileSpeaking == .words, take = Take()
        take.run = helper.run(["listen", model.folder.path] + (words ? ["--words"] : []),
                              heard: { [weak self] in self?.heard($0, take) }, ended: { [weak self] in self?.ended($0, take) })
        guard take.run != nil else {
            tell("The speech helper is missing from this build of Pilot", 4, nil)
            return false
        }
        current = take
        state = .starting
        show.started(microphone: microphoneName(), words: words)
        if pausesMedia { media.takeStarted() }
        whisperLog.notice("pilot dictation: start")
        return true
    }

    /// Ends the take. A stop before the microphone came up ends an empty one.
    private func stop() {
        guard let take = current, let run = take.run, take.stopped == nil else { return }
        take.target = frontApp()
        take.stopped = .now
        run.finish()
        // What was playing goes on while the take is written down, once the microphone is done: it records the 0.4 s
        // tail on (Dictate.tail), and through the speakers the music came into the take's end. A take started meanwhile
        // plays it at its own end.
        _ = after(0.5) { [weak self] in
            guard let self, state != .starting, state != .listening else { return }
            media.takeEnded()
        }
        state = .writing
        show.writing()
        whisperLog.notice("pilot dictation: stop, model \(take.loaded ? "loaded" : "still loading", privacy: .public)")
        // The model normally loads while Sven speaks; still loading now means the Neural Engine is compiling it.
        slowTip = after(4) { [weak self] in
            guard let self, current === take, state == .writing, !take.loaded else { return }
            waitingTip = true
            tell("\(models.active?.choice.name ?? "The speech model") is getting ready, a one-time wait of up to five minutes. "
                 + "Your words follow.", .infinity, nil)
        }
    }

    /// A line from `take`'s helper; one left to finish in the background only answers with its words.
    private func heard(_ line: DictateLine, _ take: Take) {
        if take !== current {
            switch line { case .loaded, .text, .error: break; default: return }
        }
        switch line {
        case .listening: if state == .starting { state = .listening }
        case .preparing:
            tell("Listening. \(models.active?.choice.name ?? "The speech model") is getting ready for this build of Pilot, "
                 + "so the text takes longer this once", 5, nil)
        case .loaded:
            take.loaded = true
            whisperLog.notice("pilot dictation: model loaded \(take.ms(since: take.started)) ms after the start")
        case .inputLost:
            tell("The microphone went away: writing down what you said", 3, nil)
            stop()
        case .levels(let levels): show.levels(levels)
        // Replacements once, on the helper's own words: Undo's words come back through deliver already replaced.
        case .partial(let words): show.words(vocabulary.taught.replaced(words))
        case .text(let text):
            take.answered = true
            whisperLog.notice("pilot dictation: text \(take.ms(since: take.stopped)) ms after the stop")
            keep(text, take)
            deliver(vocabulary.taught.replaced(text), by: take)
        case .error(let reason):
            take.answered = true
            switch reason {
            case "microphone": tell(MicrophoneGrant.offTip, 4, MicrophoneGrant.open)
            case "no input device": tell(MicrophoneGrant.noInputTip, 4, nil)
            default: tell("Dictation failed: \(reason)", 4, nil)
            }
        case .progress, .prepared: break
        }
    }

    /// The take's words as the model wrote them, for Voice › Recent takes.
    private func keep(_ text: String, _ take: Take) {
        // Words said into a password field are never typed, so never kept either.
        guard !text.isEmpty, !secureInput() else { return }
        let seconds = take.stopped.map { ($0 - take.started).inSeconds }
        let app = take.target.flatMap(NSRunningApplication.init(processIdentifier:))?.localizedName
        takes.add(DictationTake(text: text, at: .now, seconds: seconds, model: models.active?.choice.name, app: app))
    }

    /// `take`'s helper is gone. Each take has its own, so the next press starts a fresh one; one that quit before its
    /// words says so rather than leave the take silently empty.
    private func ended(_ status: Int32, _ take: Take) {
        take.run = nil
        whisperLog.notice("pilot dictation: helper ended \(status), \(take.ms(since: take.stopped)) ms after the stop\(take === self.current ? "" : ", in the background", privacy: .public)")
        if !take.answered, !take.cancelled, status != 0 {
            tell("Dictation stopped: the speech helper quit (exit \(status)). Press again to dictate.", 4, nil)
        }
        // A take an earlier Pilot left may have been written down meanwhile. A helper that failed leaves its kept audio
        // (Dictate.kept), which gets its one retry now rather than wait for the next launch.
        collectKept(audio: status != 0)
        guard take === current else { return }
        current = nil
        media.takeEnded()
        state = .idle
        dismissWaitingTip()
        show.ended()
    }

    /// Takes a quit or relaunch left beside the models (Helpers/pilot-dictate main.swift; Sven, 2026-10-31: three takes
    /// lost while the model compiled): the text of one written down after Pilot went, and with `audio` the audio of one
    /// whose helper is gone, which the model in use writes down now. Text as each take ends; audio a minute after launch
    /// (Engine) and as a take whose helper failed ends, never on a press, where its load would hold up the take's. Both go to Voice › Recent takes with a tip,
    /// never typed into what is in front by now.
    func collectKept(audio: Bool = false) {
        let files = FileManager.default, prefix = Self.keptPrefix
        let kept = ((try? files.contentsOfDirectory(at: models.base, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
        func modified(_ file: URL) -> Date { (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now }
        // Words are never kept while a password field has the keyboard (keep): the text files wait for the next look.
        // The audio retry goes on whatever it says, since secure input can stay on for hours; a text it brings back
        // then waits as a file too (add(kept:)).
        for file in kept where file.pathExtension == "txt" && !secureInput() {
            if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty { add(kept: text, at: modified(file)) }
            try? files.removeItem(at: file)
        }
        guard audio else { return }
        let model = models.active
        for file in kept where file.pathExtension == "wav" {
            let name = file.lastPathComponent
            guard recovering[name] == nil, let pid = pid_t(file.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)),
                  !Self.isHelper(pid) else { continue }
            // No model left to write it down (removed meanwhile): the audio goes rather than wait for one.
            guard let model else {
                try? files.removeItem(at: file)
                whisperLog.notice("pilot dictation: a take left by helper \(pid) dropped, no speech model on disk")
                continue
            }
            let at = modified(file)
            // One retry: the helper takes the WAV away once it answers or fails, and its end does if it was killed or
            // crashed, so no audio waits beside the models for a second try.
            recovering[name] = helper.run(["transcribe", model.folder.path, file.path], heard: { [weak self] line in
                if case .text(let text) = line, !text.isEmpty { self?.add(kept: text, at: at) }
            }, ended: { [weak self] status in
                if FileManager.default.fileExists(atPath: file.path) {
                    try? FileManager.default.removeItem(at: file)
                    whisperLog.error("pilot dictation: a take left by helper \(pid) could not be written down (exit \(status)), dropped")
                }
                self?.recovering[name] = nil
            })
            whisperLog.notice("pilot dictation: a take left by helper \(pid) is written down again")
        }
    }

    private func add(kept text: String, at: Date) {
        // A password field took the keyboard meanwhile: back beside the models, Sven's alone, for the next look.
        if secureInput() {
            var file = models.base.appending(path: "\(Self.keptPrefix)\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? file.setResourceValues(values)
            return
        }
        takes.add(DictationTake(text: text, at: at, model: models.active?.choice.name))
        whisperLog.notice("pilot dictation: a take Pilot could not type, \(text.count) characters, kept in Recent takes")
        tell("A take Pilot could not type is in Voice › Recent takes", 5, Self.openVoice)
    }

    /// Whether `pid` is a pilot-dictate still at work, whose take is its own to answer.
    static func isHelper(_ pid: pid_t) -> Bool { SecureInputMonitor.processName(pid) == "pilot-dictate" }

    private func dismissWaitingTip() {
        slowTip?.cancel()
        slowTip = nil
        if waitingTip { waitingTip = false; HUD.dismissTip() }
    }

    /// The take's text into the app it was spoken to; nil `take`: Undo's, into the app in front now.
    private func deliver(_ text: String, by take: Take?) {
        if take == nil || take === current { dismissWaitingTip() }
        if let take, take.cancelled {
            guard !text.isEmpty else { return }
            return show.recoverable(text)
        }
        guard !text.isEmpty else { return tell("No words heard", 2, nil) }
        if secureInput() { return tell("Not typed: a password field has the keyboard", 3, nil) }
        if let target = take?.target, frontApp() != target {
            copy(text)
            return tell("Dictation copied: the app you spoke to is no longer in front", 4, nil)
        }
        paste(text, copiesText)
        whisperLog.notice("pilot dictation: \(text.count) characters pasted\(self.copiesText ? ", left on the clipboard" : "")")
    }
}
