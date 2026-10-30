import Foundation
import Observation
import PilotCore

/// Read aloud's neural voices (Sven Q264, after Build 64: the Apple voices "sound ass"): Kokoro-82M (hexgrad, Apache 2.0)
/// on this Mac, spoken by pilot-dictate's `speak` in a child that lives only while it reads, never in Pilot. Downloaded
/// on Sven's click into Speech/kokoro beside the speech models, never in the bundle, and removed from Voice › Read aloud.
/// Measured on Sven's M4 (2026-10-17): 133 MB fetched, 374 MB on disk once Core ML compiled it; first sound 1.0 to 1.4 s
/// after the key, a sentence or a paragraph alike; the child peaks at 216 MB for a sentence and 423 MB for a paragraph.
/// Most of that wait is the child's first synthesis (2.1 to 3.1 s on 2026-10-19, under load), so ▶ on the Voice page plays
/// each voice's line from a file made once (`renderSamples`) instead.
@Observable @MainActor
final class KokoroModel {
    static let shared: KokoroModel = {
        let model = KokoroModel()
        model.onChange = { ReadAloudSettings.shared.neuralChanged(ready: model.isReady) }
        return model
    }()
    /// Speak.modelName in Helpers/pilot-dictate, the ready file's content.
    static let helperName = "kokoro/english"
    static let megabytes = 133
    static var size: String { "\(megabytes) MB" }
    static let note = "Neural voices on this Mac, US and UK English · hexgrad, Apache 2.0, through FluidAudio"

    let folder: URL
    private(set) var state: SpeechModel.State {
        didSet { if (state == .ready) != isReady { isReady = state == .ready; onChange?() } }
    }
    /// Stored apart from `state`, so a view that asks only this is not drawn again at each percent of a download.
    private(set) var isReady: Bool
    /// Told when the voices come or go.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let helper: DictateHelper
    @ObservationIgnored private var run: DictateRun?
    @ObservationIgnored private var failure: String?
    /// Counts runs, so a stopped one's late lines and exit never touch the next.
    @ObservationIgnored private var generation = 0
    /// The run under way makes the ▶ lines; the Voice page wants them while it is open.
    @ObservationIgnored private var rendering = false
    @ObservationIgnored private var samplesWanted = false

    init(base: URL = SpeechModels.standardBase, helper: DictateHelper = BundledDictateHelper()) {
        folder = base.appending(path: "kokoro")
        self.helper = helper
        let ready = Self.onDisk(folder)
        isReady = ready
        state = ready ? .ready : .absent
    }

    static func onDisk(_ folder: URL) -> Bool {
        (try? String(contentsOf: folder.appending(path: SpeechModel.readyFile), encoding: .utf8)) == helperName
    }

    /// The voices Read aloud offers while the model is on disk.
    var voices: [SpeechVoice] { isReady ? KokoroVoice.all.map(\.voice) : [] }

    /// Fetches the model and every listed voice, then has the helper speak a line once so the first read is quick.
    func download() {
        guard run == nil, !isReady else { return }
        failure = nil
        state = .downloading(0)
        SpeechModel.markDownloading(folder, true)
        generation += 1
        let mine = generation
        run = helper.run(["download", folder.path, Self.helperName], heard: { [weak self] line in
            guard let self, generation == mine else { return }
            switch line {
            case .progress(let fraction): state = .downloading(fraction)
            case .preparing: state = .preparing
            case .error(let reason): failure = reason
            default: break
            }
        }, ended: { [weak self] status in
            guard let self, generation == mine else { return }
            run = nil
            state = Self.onDisk(folder) ? .ready : .failed(failure ?? "The download stopped (exit \(status)). Try again.")
            if state == .ready { SpeechModel.markDownloading(folder, false) }
            speechLog.notice("kokoro: download ended \(status)")
            if samplesWanted { renderSamples(true) }
        })
        if run == nil { state = .failed("The speech helper is missing from this build of Pilot.") }
        speechLog.notice("kokoro: download")
    }

    /// At launch: a download a quit cut off goes on from the files already there (SpeechModel.downloadingFile).
    func resume() {
        if !isReady, SpeechModel.wasCutOff(folder) { download() }
    }

    func cancel() {
        let stopping = run
        run = nil
        rendering = false
        generation += 1
        stopping?.cancel()
        if !isReady {
            state = .absent
            SpeechModel.markDownloading(folder, false)
        }
    }

    /// Deletes the folder, model, voices and Core ML's compile of it alike; Read aloud speaks in Apple's voices again.
    func remove() {
        cancel()
        do { try FileManager.default.removeItem(at: folder) } catch { speechLog.error("kokoro: \(String(describing: error), privacy: .public)") }
        state = .absent
        speechLog.notice("kokoro: removed")
    }

    /// Reads the folder again after something outside moved it (Uninstall's Trash): gone, Read aloud speaks in Apple's
    /// voices again.
    func refresh() { state = Self.onDisk(folder) ? .ready : .absent }

    /// As SpeechModel's: a new helper loads the voice once in the background, a minute after launch (Engine), and does
    /// nothing when it already has.
    func prepareInBackground() {
        guard isReady, run == nil else { return }
        generation += 1
        let mine = generation
        run = helper.run(["prepare", folder.path], heard: { line in
            if line == .prepared { speechLog.notice("kokoro: prepared for this helper") }
        }, ended: { [weak self] _ in
            guard let self, generation == mine else { return }
            run = nil
            if samplesWanted { renderSamples(true) }
        })
    }

    /// Each voice's ▶ line, one WAV per voice (Speak.samples).
    var samples: URL { folder.appending(path: "samples") }

    /// The ▶ line of the voice with that id, once its file is made.
    func sample(of id: String) -> URL? {
        guard isReady, let name = KokoroVoice.name(of: id) else { return nil }
        let file = samples.appending(path: "\(name).wav")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The Voice page open (true) or closed: while it is open, one child makes the ▶ lines still missing, once; closing it
    /// ends the child, the files made kept. Never at idle.
    func renderSamples(_ wanted: Bool) {
        samplesWanted = wanted
        guard wanted else {
            if rendering { cancel() }
            return
        }
        guard isReady, run == nil else { return }
        let missing = KokoroVoice.all.filter { sample(of: KokoroVoice.prefix + $0.name) == nil }
        guard !missing.isEmpty else { return }
        generation += 1
        let mine = generation
        rendering = true
        run = helper.run(["samples", folder.path] + missing.flatMap { [$0.name, $0.voice.sample] }, heard: { _ in }, ended: { [weak self] status in
            guard let self, generation == mine else { return }
            run = nil
            rendering = false
            speechLog.notice("kokoro: samples ended \(status)")
        })
        if run == nil { rendering = false }
        speechLog.notice("kokoro: making \(missing.count) samples")
    }
}

/// One of Kokoro's voices as hexgrad grades it (huggingface.co/hexgrad/Kokoro-82M, VOICES.md, read 2026-10-17).
struct KokoroVoice {
    /// Kokoro's name for it: af_heart is American, female, Heart.
    let name: String
    let grade: String

    /// A voice's id in `speech.voice`: kokoro/af_heart.
    static let prefix = "kokoro/"
    /// The grades in VOICES.md, best first.
    static let grades = ["A", "A-", "B+", "B", "B-", "C+", "C", "C-", "D+", "D", "D-", "F+", "F"]
    /// The worst grade the list shows unfolded, C; the rest wait behind More voices.
    static let shownRank = grades.firstIndex(of: "C")!

    /// Every American and British voice, best first (Speak.voices fetches them all).
    static let all = [
        ("af_heart", "A"), ("af_bella", "A-"), ("af_nicole", "B-"), ("bf_emma", "B-"), ("af_aoede", "C+"), ("af_kore", "C+"),
        ("af_sarah", "C+"), ("am_fenrir", "C+"), ("am_michael", "C+"), ("am_puck", "C+"), ("af_alloy", "C"), ("af_nova", "C"),
        ("bf_isabella", "C"), ("bm_fable", "C"), ("bm_george", "C"), ("af_sky", "C-"), ("bm_lewis", "D+"), ("af_jessica", "D"),
        ("af_river", "D"), ("am_echo", "D"), ("am_eric", "D"), ("am_liam", "D"), ("am_onyx", "D"), ("bf_alice", "D"),
        ("bf_lily", "D"), ("bm_daniel", "D"), ("am_santa", "D-"), ("am_adam", "F+"),
    ].map { KokoroVoice(name: $0.0, grade: $0.1) }

    static func name(of id: String) -> String? { id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil }

    /// As Read aloud lists it: Heart, in American or British English, ranked by its grade.
    var voice: SpeechVoice {
        SpeechVoice(id: Self.prefix + name, name: name.dropFirst(3).capitalized, language: name.hasPrefix("b") ? "en-GB" : "en-US",
                    quality: .standard, neuralRank: Self.grades.firstIndex(of: grade) ?? Self.grades.count)
    }
}

/// Kokoro through pilot-dictate's `speak`: the text goes in on stdin and the child plays it, a sentence at a time; Stop
/// ends the child, and its sound with it. Unlike Speaker it can fail before it says anything, so Read aloud hands the
/// text to an Apple voice.
@MainActor
final class KokoroSpeaker {
    private let model: KokoroModel
    private var session: ChildProcess.Session?
    private var current: (@MainActor () -> Void)?
    /// The child said speaking: its sound started.
    private var spoke = false
    private var generation = 0

    init(model: KokoroModel = .shared) { self.model = model }

    var isSpeaking: Bool { current != nil }

    /// AVSpeechUtterance's rate, 0.5 Apple's own, as Kokoro's speed, 1 its own.
    static func speed(_ rate: Float) -> Float { min(max(rate / Float(ReadAloudSettings.standardRate), 0.5), 2) }

    /// As Speaker's speak; `failed` instead of `done` when no sound came out.
    func speak(_ text: String, voice: String, rate: Float, done: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void) {
        drop()
        let path = BundledDictateHelper.path
        guard model.isReady, let name = KokoroVoice.name(of: voice), FileManager.default.isExecutableFile(atPath: path) else { return failed() }
        let speed = Self.speed(rate)
        let mine = generation
        spoke = false
        current = done
        do {
            let child = try ChildProcess.Session(path, ["speak", model.folder.path, name, String(format: "%.2f", speed)], lines: { [weak self] line in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(line, mine) } }
            }, ended: { [weak self] status, stderr in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(mine, status, stderr, failed: failed) } }
            })
            child.send(Data(text.utf8))
            child.closeInput()
            session = child
        } catch {
            current = nil
            speechLog.error("kokoro: \(String(describing: error), privacy: .public)")
            failed()
        }
    }

    private func heard(_ line: String, _ run: Int) {
        guard run == generation else { return }
        if line == "speaking" { spoke = true } else if line.hasPrefix("error") { speechLog.error("kokoro: \(line, privacy: .public)") }
    }

    /// The child is gone: the read ended, or failed before a sound and goes to `failed`.
    private func ended(_ run: Int, _ status: Int32, _ stderr: String, failed: @MainActor () -> Void) {
        guard run == generation else { return }
        session = nil
        let finished = current
        current = nil
        if status == 0 || spoke {
            finished?()
            return
        }
        speechLog.error("kokoro: speak exited \(status): \(stderr, privacy: .public)")
        failed()
    }

    func stop() {
        let finished = current
        drop()
        finished?()
    }

    /// Ends the read under way without its `done`, as a new speak replaces it.
    private func drop() {
        generation += 1
        current = nil
        session?.stop()
        session = nil
    }
}
