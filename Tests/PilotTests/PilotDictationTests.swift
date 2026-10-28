import AVFoundation
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Pilot's own dictation (story 194) over a fake pilot-dictate: no test downloads a model, records or pastes for real.
@MainActor
@Suite("Pilot dictation")
struct PilotDictationTests {
    final class FakeRun: DictateRun {
        var finished = false, cancelled = false
        func finish() { finished = true }
        func cancel() { cancelled = true }
    }

    /// Each start of the helper, with the callbacks the test plays the helper's lines into.
    final class FakeHelper: DictateHelper {
        struct Started {
            let arguments: [String]
            let heard: @MainActor (DictateLine) -> Void
            let ended: @MainActor (Int32) -> Void
            let run: FakeRun
        }
        var started: [Started] = []
        var missing = false

        func run(_ arguments: [String], heard: @escaping @MainActor (DictateLine) -> Void, ended: @escaping @MainActor (Int32) -> Void) -> DictateRun? {
            guard !missing else { return nil }
            let run = FakeRun()
            started.append(Started(arguments: arguments, heard: heard, ended: ended, run: run))
            return run
        }

        var last: Started { started[started.count - 1] }
    }

    /// What the pill and its toasts were told, in order, and the ✕, ✓ and Undo they would press.
    final class FakeShow: DictationShowing {
        var events: [String] = []
        var cancel: @MainActor () -> Void = {}, finish: @MainActor () -> Void = {}, recover: @MainActor (String) -> Void = { _ in }
        func bind(cancel: @escaping @MainActor () -> Void, finish: @escaping @MainActor () -> Void, recover: @escaping @MainActor (String) -> Void) {
            self.cancel = cancel; self.finish = finish; self.recover = recover
        }
        func started(microphone: String?, words: Bool) { events.append("started \(microphone ?? "?")\(words ? " words" : "")") }
        func levels(_ levels: [Double]) { events.append("levels \(levels)") }
        func words(_ words: String) { events.append("words \(words)") }
        func writing() { events.append("writing") }
        func ended() { events.append("ended") }
        func recoverable(_ text: String) { events.append("recoverable \(text)") }
    }

    /// What was asked of the media and the pauses still waiting for their answer.
    final class FakeMedia: MediaControlling {
        var asked: [String] = []
        var answers: [@MainActor (Bool) -> Void] = []
        func pauseIfPlaying(_ done: @escaping @MainActor (Bool) -> Void) { asked.append("pause"); answers.append(done) }
        func play() { asked.append("play") }
    }

    /// A PilotDictation over fakes: its Speech folder fresh in /tmp, the microphone granted, the front app 7. `model` is
    /// Whisper large-v3 turbo's.
    @MainActor
    final class Rig {
        let helper = FakeHelper()
        let base = FileManager.default.temporaryDirectory.appending(path: "speech-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: testSuite())!
        var grant = AVAuthorizationStatus.authorized
        var pasted: [String] = [], copied: [String] = [], tips: [String] = []
        /// Each paste's ask to leave its words on the clipboard after.
        var kept: [Bool] = []
        var front: pid_t = 7
        var secure = false
        var microphoneConnected = true
        var later: [@MainActor () -> Void] = []
        var cancelledTimers = 0
        let shown = FakeShow()
        let media = FakeMedia()
        lazy var models = SpeechModels(base: base, helper: helper, defaults: defaults)
        var model: SpeechModel { models.model(.whisperTurbo) }
        var folder: URL { model.folder }
        lazy var microphone = MicrophoneGrant(read: { self.grant }, request: { false })
        lazy var pilot = PilotDictation(models: models, helper: helper, microphone: microphone, defaults: defaults,
                                        paste: { self.pasted.append($0); self.kept.append($1) },
                                        copy: { self.copied.append($0) }, frontApp: { self.front }, secureInput: { self.secure },
                                        tell: { text, _, _ in self.tips.append(text) },
                                        after: { _, then in self.later.append(then); return Watch { self.cancelledTimers += 1 } },
                                        show: shown, media: media, microphoneName: { "AB13X USB Audio (USB)" },
                                        hasMicrophone: { self.microphoneConnected })

        /// A model as the helper leaves it once downloaded and prepared; before `models` is first read, it is on disk
        /// from the start.
        @discardableResult
        func onDisk(_ choice: SpeechChoice = .whisperTurbo) throws -> Rig {
            let folder = base.appending(path: choice.rawValue)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(choice.helperName.utf8).write(to: folder.appending(path: SpeechModel.readyFile))
            return self
        }
    }

    @Test("The helper's lines read back; anything else is ignored")
    func lines() {
        #expect(DictateLine("listening") == .listening && DictateLine("preparing") == .preparing && DictateLine("prepared") == .prepared)
        #expect(DictateLine("progress 0.42") == .progress(0.42))
        #expect(DictateLine(#"text "Hola, \"Sven\"\nbye""#) == .text("Hola, \"Sven\"\nbye"))
        #expect(DictateLine("error microphone") == .error("microphone"))
        #expect(DictateLine("error no input device") == .error("no input device") && DictateLine("input lost") == .inputLost && DictateLine("input x") == nil)
        #expect(DictateLine("progress lots") == nil && DictateLine("[WhisperKit] loading") == nil && DictateLine("text unquoted") == nil)
        #expect(DictateLine("done") == nil)
        #expect(DictateLine(#"partial "Hola, ma""#) == .partial("Hola, ma") && DictateLine("partial unquoted") == nil)
        #expect(DictateLine("level 0.12 0.40 1.00 0.00") == .levels([0.12, 0.4, 1, 0]) && DictateLine("level") == nil && DictateLine("level x") == nil)
    }

    @Test("Without a model on disk a press says where to download and starts nothing; with one it listens")
    func engineSelection() throws {
        let bare = Rig()
        #expect(bare.pilot.toggle() == false && bare.helper.started.isEmpty)
        #expect(bare.tips == ["Download a speech model first, in Voice › Dictation"])

        let ready = try Rig().onDisk()
        ready.model.prepareInBackground()
        let prepare = ready.helper.last
        #expect(prepare.arguments == ["prepare", ready.folder.path])
        #expect(ready.pilot.toggle() && ready.helper.last.arguments == ["listen", ready.folder.path])
        #expect(prepare.run.cancelled && ready.model.isReady, "a take stops the background prepare, the model stays")
        // A folder holding another model's name is not this one: not on disk.
        try Data("whisperkit/large-v2".utf8).write(to: ready.folder.appending(path: SpeechModel.readyFile))
        #expect(!SpeechModel.onDisk(ready.folder, .whisperTurbo))
    }

    @Test("Download: progress, then preparing, then ready once the helper wrote ready; a failure keeps its reason; cancel and remove")
    func download() throws {
        let rig = Rig(), model = rig.model
        #expect(model.state == .absent)
        model.download()
        #expect(rig.helper.last.arguments == ["download", rig.folder.path, "whisperkit/large-v3-v20240930_turbo_632MB"])
        #expect(model.state == .downloading(0))
        rig.helper.last.heard(.progress(0.5))
        #expect(model.state == .downloading(0.5))
        rig.helper.last.heard(.preparing)
        #expect(model.state == .preparing)
        _ = try rig.onDisk()
        rig.helper.last.ended(0)
        #expect(model.state == .ready && model.isReady)

        model.remove()
        #expect(model.state == .absent && !FileManager.default.fileExists(atPath: rig.folder.path))

        model.download()
        rig.helper.last.heard(.error("offline"))
        rig.helper.last.ended(1)
        #expect(model.state == .failed("offline"))

        model.download()
        let cancelled = rig.helper.last
        model.cancel()
        cancelled.ended(15)
        #expect(cancelled.run.cancelled && model.state == .absent, "a cancel is not a failure")
        // Download again before the cancelled run's exit arrives: that late exit leaves the new download alone.
        model.download()
        cancelled.heard(.error("killed"))
        cancelled.ended(15)
        rig.helper.last.heard(.progress(0.3))
        #expect(model.state == .downloading(0.3))
        model.cancel()

        rig.helper.missing = true
        model.download()
        #expect(model.state == .failed("The speech helper is missing from this build of Pilot."))
    }

    @Test("A take: listening lights up, the press again ends it, Whisper's text is pasted into the app in front; a press while it is written down starts the next, the last typed into its own app when it comes, and a helper that quits says so")
    func take() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        #expect(pilot.toggle() && pilot.state == .starting && !pilot.isListening)
        rig.helper.last.heard(.listening)
        #expect(pilot.isListening)
        #expect(pilot.toggle() && rig.helper.last.run.finished && pilot.state == .writing && !pilot.isListening)
        rig.helper.last.heard(.loaded)
        rig.helper.last.heard(.text("Hola, mañana a las tres."))
        rig.helper.last.ended(0)
        #expect(rig.pasted == ["Hola, mañana a las tres."] && pilot.state == .idle)
        // Loaded meanwhile: the slow-model tip's timer is cancelled, and would show nothing anyway.
        #expect(rig.cancelledTimers == 1)
        rig.later.forEach { $0() }
        #expect(rig.tips.isEmpty)

        // Pressed again while the take is written down (Sven, 2026-10-23: refused with "Still writing down the last take").
        rig.later = []
        pilot.toggle()
        pilot.toggle()
        let first = rig.helper.last
        rig.front = 9
        #expect(pilot.toggle() && rig.helper.started.count == 3 && pilot.state == .starting)
        #expect(rig.tips == ["Listening. Your last take is typed once it is written down"])
        first.heard(.loaded)
        first.heard(.text("Primero"))
        first.ended(0)
        #expect(rig.pasted.count == 1 && rig.copied == ["Primero"], "spoken to app 7, typed only there")
        #expect(pilot.state == .starting && rig.shown.events.last == "started AB13X USB Audio (USB)")
        // The first take's slow-model tip shows nothing now it is in the background.
        rig.later.forEach { $0() }
        #expect(rig.tips.last == "Dictation copied: the app you spoke to is no longer in front")
        rig.helper.last.heard(.listening)
        pilot.toggle()
        rig.helper.last.ended(9)
        #expect(rig.tips.last == "Dictation stopped: the speech helper quit (exit 9). Press again to dictate." && pilot.state == .idle)
        // No microphone for the next one: the press says so and the written-down pill goes with it.
        pilot.toggle()
        pilot.toggle()
        rig.microphoneConnected = false
        #expect(!pilot.toggle() && pilot.state == .idle && rig.shown.events.last == "ended")
    }

    @Test("The pill: shown with the microphone's name as a take starts, its waveform fed, ✓ ends the take and types it as a press does")
    func pillFinish() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        #expect(pilot.toggle())
        rig.helper.last.heard(.listening)
        rig.helper.last.heard(.levels([0.1, 0.5]))
        rig.shown.finish()
        #expect(rig.helper.last.run.finished && !rig.helper.last.run.cancelled && pilot.state == .writing)
        rig.shown.finish()
        rig.helper.last.heard(.text("Hola"))
        rig.helper.last.ended(0)
        #expect(rig.pasted == ["Hola"])
        #expect(rig.shown.events == ["started AB13X USB Audio (USB)", "levels [0.1, 0.5]", "writing", "ended"])
    }

    @Test("✕ hands the take's words to the recover toast instead of typing them; Undo types them into the app in front now")
    func cancelRecovers() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        pilot.toggle()
        rig.helper.last.heard(.listening)
        rig.shown.cancel()
        // Written down, not dropped: the helper's stdin closes as for ✓.
        #expect(rig.helper.last.run.finished && !rig.helper.last.run.cancelled)
        #expect(rig.shown.events == ["started AB13X USB Audio (USB)", "writing", "ended"])
        // The slow-model tip's timer is stopped: no "your words follow" for words that will not be typed.
        #expect(rig.cancelledTimers == 1)
        rig.helper.last.heard(.text("Lo que dije"))
        rig.helper.last.ended(0)
        #expect(rig.pasted.isEmpty && rig.tips.isEmpty)
        #expect(rig.shown.events.last == "recoverable Lo que dije")
        rig.front = 9
        rig.shown.recover("Lo que dije")
        #expect(rig.pasted == ["Lo que dije"] && rig.copied.isEmpty)
    }

    @Test("✕ while the take is written down keeps it too and frees the next press at once; a cancelled take with no words offers nothing; the next take types again")
    func cancelWhileWriting() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        pilot.toggle()
        pilot.toggle()
        let first = rig.helper.last
        // Its model compiling again for minutes (Sven, 2026-10-23): Pilot is idle at once, and a press starts the next take.
        rig.shown.cancel()
        #expect(pilot.state == .idle && !first.run.cancelled)
        #expect(pilot.toggle() && rig.helper.started.count == 2 && rig.tips.isEmpty)
        first.heard(.text(""))
        first.ended(0)
        #expect(rig.tips.isEmpty && !rig.shown.events.contains { $0.hasPrefix("recoverable") })
        #expect(pilot.state == .starting && rig.shown.events.last == "started AB13X USB Audio (USB)", "the first take's end leaves the next one's pill")
        pilot.toggle()
        rig.helper.last.heard(.text("Otra vez"))
        #expect(rig.pasted == ["Otra vez"])
    }

    @Test("Held: the press starts, the release ends; a model still compiling after the release says so")
    func held() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        pilot.hold(true)
        rig.helper.last.heard(.listening)
        pilot.hold(true)
        #expect(rig.helper.started.count == 1, "a repeat press starts nothing more")
        pilot.hold(false)
        #expect(rig.helper.last.run.finished)
        rig.later.forEach { $0() }
        #expect(rig.tips == ["Whisper large-v3 turbo is getting ready, a one-time wait of up to three minutes. Your words follow."])
    }

    @Test("Never typed into a password field or another app than the one spoken to; no words, nothing pasted")
    func guards() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        func take(_ text: String, change: () -> Void = {}) {
            pilot.toggle()
            rig.helper.last.heard(.listening)
            pilot.toggle()
            change()
            rig.helper.last.heard(.text(text))
            rig.helper.last.ended(0)
        }
        take("secret") { rig.secure = true }
        rig.secure = false
        take("moved") { rig.front = 8 }
        rig.front = 7
        take("")
        #expect(rig.pasted.isEmpty && rig.copied == ["moved"])
        #expect(rig.tips == ["Not typed: a password field has the keyboard", "Dictation copied: the app you spoke to is no longer in front",
                             "No words heard"])
    }

    @Test("The microphone: never asked, macOS asks and nothing starts; denied, the tip opens the Privacy pane; the helper's own no too")
    func microphone() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        rig.grant = .notDetermined
        #expect(!pilot.toggle() && rig.helper.started.isEmpty)
        rig.grant = .denied
        #expect(!pilot.toggle() && rig.helper.started.isEmpty)
        #expect(rig.tips == ["Allow the microphone for Pilot, then press again", "Not listening: Microphone is off for Pilot"])
        rig.grant = .authorized
        pilot.toggle()
        rig.helper.last.heard(.error("microphone"))
        rig.helper.last.ended(3)
        #expect(rig.tips.last == "Not listening: Microphone is off for Pilot" && pilot.state == .idle)
    }

    @Test("No microphone: a press says so and starts nothing, the light stays off; the helper's own no too; one gone mid-take types the take so far")
    func noMicrophone() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        rig.microphoneConnected = false
        #expect(!pilot.toggle() && rig.helper.started.isEmpty && pilot.state == .idle && !pilot.isListening)
        pilot.hold(true)
        pilot.hold(false)
        #expect(rig.helper.started.isEmpty && rig.shown.events.isEmpty)
        #expect(rig.tips == ["No microphone connected", "No microphone connected"])
        rig.microphoneConnected = true
        pilot.toggle()
        rig.helper.last.heard(.error("no input device"))
        rig.helper.last.ended(4)
        #expect(rig.tips.last == "No microphone connected" && pilot.state == .idle && !pilot.isListening)
        pilot.toggle()
        rig.helper.last.heard(.listening)
        rig.helper.last.heard(.inputLost)
        #expect(rig.helper.last.run.finished && pilot.state == .writing && !pilot.isListening)
        rig.helper.last.heard(.text("Hasta aquí"))
        rig.helper.last.ended(0)
        #expect(rig.pasted == ["Hasta aquí"] && pilot.state == .idle)
    }

    @Test("Status lights' privacy light follows Pilot's own listening")
    func statusLight() throws {
        let rig = try Rig().onDisk()
        let lights = StatusLightsTests.Fakes().lights(pilotListening: { rig.pilot.isListening })
        #expect(lights.lights.isEmpty)
        rig.pilot.toggle()
        rig.helper.last.heard(.listening)
        #expect(lights.lights.map(\.title) == ["Pilot dictation"])
        rig.pilot.toggle()
        #expect(lights.lights.isEmpty)
    }

    @Test("Each model downloads into its own folder by the name the helper reads; the first one on disk becomes the pick, a later one does not take it")
    func choices() throws {
        let rig = Rig(), models = rig.models
        #expect(models.active == nil && models.pick == nil)
        #expect(SpeechChoice.allCases.map(\.helperName) == ["fluidaudio/v3", "whisperkit/large-v3-v20240930_turbo_632MB", "whisperkit/small_216MB"])
        models.model(.whisperSmall).download()
        #expect(rig.helper.last.arguments == ["download", rig.base.appending(path: "whisperSmall").path, "whisperkit/small_216MB"])
        try rig.onDisk(.whisperSmall)
        rig.helper.last.ended(0)
        #expect(models.pick == .whisperSmall && models.active?.choice == .whisperSmall)
        #expect(rig.defaults.string(forKey: SpeechModels.key) == "whisperSmall")

        models.model(.parakeet).download()
        try rig.onDisk(.parakeet)
        rig.helper.last.ended(0)
        #expect(models.active?.choice == .whisperSmall, "a later download never swaps the model in use")
        models.pick = .parakeet
        rig.pilot.toggle()
        #expect(rig.helper.last.arguments == ["listen", rig.base.appending(path: "parakeet").path])
        rig.helper.last.ended(0)

        models.remove(.parakeet)
        #expect(models.pick == .whisperSmall && !FileManager.default.fileExists(atPath: rig.base.appending(path: "parakeet").path))
        #expect(models.model(.whisperSmall).isReady, "removing one leaves the others")
    }

    @Test("While you speak at Words: the helper is asked for partials, they reach the pill, and only the take's text is typed")
    func words() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        #expect(pilot.whileSpeaking == .waveform, "Waveform until Sven picks Words")
        pilot.toggle()
        #expect(rig.helper.last.arguments == ["listen", rig.folder.path], "Waveform asks the helper for no partials")
        rig.helper.last.heard(.partial("ignored"))
        rig.helper.last.ended(0)

        pilot.whileSpeaking = .words
        #expect(rig.defaults.string(forKey: PilotDictation.whileSpeakingKey) == "words")
        pilot.toggle()
        #expect(rig.helper.last.arguments == ["listen", rig.folder.path, "--words"])
        rig.helper.last.heard(.listening)
        rig.helper.last.heard(.partial("Hola"))
        rig.helper.last.heard(.partial("Hola, mañana"))
        pilot.toggle()
        rig.helper.last.heard(.text("Hola, mañana a las tres."))
        rig.helper.last.ended(0)
        #expect(rig.pasted == ["Hola, mañana a las tres."])
        #expect(rig.shown.events.suffix(5) == ["started AB13X USB Audio (USB) words", "words Hola", "words Hola, mañana", "writing", "ended"],
                "\(rig.shown.events)")
        // A fresh PilotDictation over the same defaults reads the pick back.
        let again = PilotDictation(models: rig.models, helper: rig.helper, microphone: rig.microphone, defaults: rig.defaults,
                                   paste: { _, _ in }, copy: { _ in }, show: FakeShow())
        #expect(again.whileSpeaking == .words)
    }

    @Test("Copy to clipboard: off by default, so the paste puts the user's copy back as before; on, the words stay; the moved-app fallback copies either way")
    func copyToClipboard() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        func take(_ text: String, change: () -> Void = {}) {
            pilot.toggle()
            rig.helper.last.heard(.listening)
            pilot.toggle()
            change()
            rig.helper.last.heard(.text(text))
            rig.helper.last.ended(0)
        }
        #expect(!pilot.copiesText)
        take("uno")
        pilot.copiesText = true
        #expect(rig.defaults.bool(forKey: PilotDictation.copyKey))
        take("dos")
        #expect(rig.pasted == ["uno", "dos"] && rig.kept == [false, true] && rig.copied.isEmpty)
        // The recover toast's Undo types through the same paste, so it follows the setting too.
        rig.shown.recover("tres")
        #expect(rig.kept.last == true)
        pilot.copiesText = false
        take("cuatro") { rig.front = 8 }
        #expect(rig.copied == ["cuatro"] && rig.pasted.count == 3, "the app moved: copied though the setting is off")
    }

    @Test("Pause media: off, a take leaves the media alone; on, it pauses what plays and plays it again once the microphone stops, only if it paused it")
    func pauseMedia() throws {
        let rig = try Rig().onDisk(), pilot = rig.pilot
        #expect(!pilot.pausesMedia)
        pilot.toggle()
        pilot.toggle()
        rig.helper.last.ended(0)
        #expect(rig.media.asked.isEmpty)

        pilot.pausesMedia = true
        #expect(rig.defaults.bool(forKey: PilotDictation.pauseMediaKey))
        pilot.toggle()
        rig.media.answers.removeFirst()(true)
        #expect(rig.media.asked == ["pause"])
        pilot.toggle()
        #expect(rig.media.asked == ["pause", "play"], "played again as the take stops, not after it is typed")
        rig.helper.last.ended(0)
        #expect(rig.media.asked == ["pause", "play"], "once")

        // Nothing was playing: nothing to play after.
        rig.media.asked = []
        pilot.toggle()
        rig.media.answers.removeFirst()(false)
        pilot.toggle()
        rig.helper.last.ended(0)
        #expect(rig.media.asked == ["pause"])

        // The take ends before the pause answered: it plays again once the answer says it paused.
        rig.media.asked = []
        pilot.toggle()
        pilot.toggle()
        rig.helper.last.ended(0)
        rig.media.answers.removeFirst()(true)
        #expect(rig.media.asked == ["pause", "play"])

        // A take that fails as it starts plays it again too.
        rig.media.asked = []
        pilot.toggle()
        rig.media.answers.removeFirst()(true)
        rig.helper.last.heard(.error("microphone"))
        rig.helper.last.ended(3)
        #expect(rig.media.asked == ["pause", "play"])
    }

    @Test("Build 53's single Whisper in Speech itself moves into its own folder, named for the helper, its prepared stamp gone")
    func movesBuild53Model() throws {
        let rig = Rig(), files = FileManager.default
        try files.createDirectory(at: rig.base.appending(path: "models/argmaxinc"), withIntermediateDirectories: true)
        try Data("large-v3-v20240930_turbo_632MB".utf8).write(to: rig.base.appending(path: "ready"))
        try Data("abc".utf8).write(to: rig.base.appending(path: "prepared"))
        #expect(rig.models.active?.choice == .whisperTurbo && rig.models.pick == .whisperTurbo)
        let folder = rig.base.appending(path: "whisperTurbo")
        #expect(files.fileExists(atPath: folder.appending(path: "models/argmaxinc").path))
        #expect(try String(contentsOf: folder.appending(path: "ready"), encoding: .utf8) == "whisperkit/large-v3-v20240930_turbo_632MB")
        #expect(!files.fileExists(atPath: rig.base.appending(path: "ready").path) && !files.fileExists(atPath: rig.base.appending(path: "prepared").path))
    }
}
