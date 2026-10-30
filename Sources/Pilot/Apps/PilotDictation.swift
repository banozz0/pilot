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
/// "download more speech models … Parakeet, the best one"). Each has a folder of its own under
/// Speech, named by its raw value. Measured on Sven's M4 (2026-10-16): see SPEC story 194.
enum SpeechChoice: String, CaseIterable, Sendable {
    case parakeet, whisperTurbo, whisperSmall

    var name: String {
        switch self {
        case .parakeet: "Parakeet TDT v3"
        case .whisperTurbo: "Whisper large-v3 turbo"
        case .whisperSmall: "Whisper small"
        }
    }

    var megabytes: Int {
        switch self {
        case .parakeet: 469
        case .whisperTurbo: 632
        case .whisperSmall: 214
        }
    }

    var size: String { "\(megabytes) MB" }

    /// What sets it apart, in a few words, with the credit its licence asks for.
    var note: String {
        switch self {
        case .parakeet: "the fastest and lightest, best in English · NVIDIA, CC BY 4.0, through FluidAudio"
        case .whisperTurbo: "the most accurate, Spanish and 98 more languages · OpenAI, MIT"
        case .whisperSmall: "a third of the size, best in English · OpenAI, MIT"
        }
    }

    /// Its name to pilot-dictate (Dictate.Model): the engine, then that engine's name for it. The helper writes it into
    /// the folder's ready file last and reads it back from there.
    var helperName: String {
        switch self {
        case .parakeet: "fluidaudio/v3"
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
    @ObservationIgnored private let helper: DictateHelper
    /// Told when a download leaves the model on disk.
    @ObservationIgnored var onReady: (@MainActor () -> Void)?
    @ObservationIgnored private var run: DictateRun?
    @ObservationIgnored private var failure: String?
    /// `run` is the background prepare, not a download.
    @ObservationIgnored private var preparingInBackground = false
    /// Counts runs, so a stopped one's last lines and exit, which come up to seconds later, never touch the next.
    @ObservationIgnored private var generation = 0

    init(_ choice: SpeechChoice, base: URL, helper: DictateHelper) {
        self.choice = choice
        folder = base.appending(path: choice.rawValue)
        self.helper = helper
        state = Self.onDisk(folder, choice) ? .ready : .absent
    }

    var isReady: Bool { state == .ready }

    static func onDisk(_ folder: URL, _ choice: SpeechChoice) -> Bool {
        (try? String(contentsOf: folder.appending(path: readyFile), encoding: .utf8)) == choice.helperName
    }

    /// Fetches and prepares the model; Download again after a failure or a cancel picks up the files already there.
    func download() {
        guard run == nil, !isReady else { return }
        failure = nil
        state = .downloading(0)
        Self.markDownloading(folder, true)
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
        whisperLog.notice("speech model \(self.choice.rawValue, privacy: .public): removed")
    }

    /// Reads the folder again after something outside moved it (Uninstall's Trash): gone, it waits for Download again.
    func refresh() { state = Self.onDisk(folder, choice) ? .ready : .absent }

    /// The Neural Engine keeps its compile of the model for one helper's code signature, so a Pilot with a new helper
    /// would make the first dictation wait minutes: the helper compiles it again in the background, a minute after launch
    /// (Engine), and does nothing when it already has.
    func prepareInBackground() {
        guard isReady, run == nil else { return }
        generation += 1
        let mine = generation
        run = helper.run(["prepare", folder.path], heard: { line in
            if line == .prepared { whisperLog.notice("speech model: prepared for this helper") }
        }, ended: { [weak self] _ in
            guard let self, generation == mine else { return }
            run = nil
            preparingInBackground = false
        })
        preparingInBackground = run != nil
    }

    /// A take is starting: its own helper compiles the model if it must, so the background one stops rather than compile
    /// it twice at once.
    func stopPreparing() {
        guard preparingInBackground else { return }
        preparingInBackground = false
        cancel()
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
/// with the pick gone, the first one on disk in SpeechChoice's order takes over.
@Observable @MainActor
final class SpeechModels {
    static let shared = SpeechModels()
    static let key = "dictation.model"
    static let standardBase = PilotFolder.support.appending(path: "Speech")

    let all: [SpeechModel]
    var pick: SpeechChoice? { didSet { defaults.set(pick?.rawValue, forKey: Self.key) } }
    @ObservationIgnored private let defaults: UserDefaults

    init(base: URL = standardBase, helper: DictateHelper = BundledDictateHelper(), defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        Self.moveSingleModel(in: base)
        all = SpeechChoice.allCases.map { SpeechModel($0, base: base, helper: helper) }
        pick = defaults.string(forKey: Self.key).flatMap(SpeechChoice.init)
        for model in all { model.onReady = { [weak self] in self?.settle() } }
        settle()
    }

    func model(_ choice: SpeechChoice) -> SpeechModel { all.first { $0.choice == choice }! }

    /// The model dictation uses: the pick while on disk, else the first one on disk.
    var active: SpeechModel? { pick.map(model).flatMap { $0.isReady ? $0 : nil } ?? all.first(where: \.isReady) }

    func remove(_ choice: SpeechChoice) {
        model(choice).remove()
        settle()
    }

    func refresh(_ choice: SpeechChoice) {
        model(choice).refresh()
        settle()
    }

    func prepareInBackground() { active?.prepareInBackground() }

    /// At launch: each download a quit cut off, from Settings or setup alike, starts again.
    func resume() { all.forEach { $0.resume() } }

    func stopPreparing() { all.forEach { $0.stopPreparing() } }

    /// No pick on disk: the first model that is becomes it.
    private func settle() {
        guard pick.map(model)?.isReady != true, let first = all.first(where: \.isReady) else { return }
        pick = first.choice
        defaults.set(first.choice.rawValue, forKey: Self.key)
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

    static let whileSpeakingKey = "dictation.whileSpeaking", copyKey = "dictation.copy", pauseMediaKey = "dictation.pauseMedia"

    private(set) var state = State.idle {
        didSet { if isLive != (oldValue == .starting || oldValue == .listening) { onLive(isLive) } }
    }
    /// Starting or listening: the take Esc cancels (HyperTap.cancelsDictationOnEscape).
    var isLive: Bool { state == .starting || state == .listening }
    /// Told as a take becomes live and as it stops being live.
    @ObservationIgnored var onLive: @MainActor (Bool) -> Void = { _ in }
    var whileSpeaking: WhileSpeaking { didSet { defaults.set(whileSpeaking.rawValue, forKey: Self.whileSpeakingKey) } }
    /// A typed take's words are left on the clipboard too. Off, the paste puts Sven's own copy back, as before this
    /// setting: the words pass through the clipboard for half a second and the history skips them.
    var copiesText: Bool { didSet { defaults.set(copiesText, forKey: Self.copyKey) } }
    /// A take pauses what is playing and plays it again after (MediaPause).
    var pausesMedia: Bool { didSet { defaults.set(pausesMedia, forKey: Self.pauseMediaKey) } }
    /// The microphone records for Pilot: Mode lights' microphone light.
    var isListening: Bool { state == .listening }

    let models: SpeechModels
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

    init(models: SpeechModels = .shared, helper: DictateHelper = BundledDictateHelper(), microphone: MicrophoneGrant = .shared,
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
        self.helper = helper
        self.microphone = microphone
        self.defaults = defaults
        whileSpeaking = defaults.string(forKey: Self.whileSpeakingKey).flatMap(WhileSpeaking.init) ?? .waveform
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
            tell("Download a speech model first, in Voice › Dictation", 4, HUD.TipAction(title: "Open") { AppWindowController.shared.open(.voice) })
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
        models.stopPreparing()
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
            tell("\(models.active?.choice.name ?? "The speech model") is getting ready, a one-time wait of up to three minutes. "
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
        case .partial(let words): show.words(words)
        case .text(let text):
            take.answered = true
            whisperLog.notice("pilot dictation: text \(take.ms(since: take.stopped)) ms after the stop")
            deliver(text, by: take)
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

    /// `take`'s helper is gone. Each take has its own, so the next press starts a fresh one; one that quit before its
    /// words says so rather than leave the take silently empty.
    private func ended(_ status: Int32, _ take: Take) {
        take.run = nil
        whisperLog.notice("pilot dictation: helper ended \(status), \(take.ms(since: take.stopped)) ms after the stop\(take === self.current ? "" : ", in the background", privacy: .public)")
        if !take.answered, !take.cancelled, status != 0 {
            tell("Dictation stopped: the speech helper quit (exit \(status)). Press again to dictate.", 4, nil)
        }
        guard take === current else { return }
        current = nil
        media.takeEnded()
        state = .idle
        dismissWaitingTip()
        show.ended()
    }

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
