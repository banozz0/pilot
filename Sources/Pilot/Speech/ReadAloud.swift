import AppKit
import AVFoundation
import Carbon.HIToolbox
import Observation
import OSLog
import PilotCore

let speechLog = Logger(subsystem: "dev.banozz.pilot", category: "speech")

/// What speaks: AVSpeechSynthesizer in the app, a fake in the tests, which never play a sound.
@MainActor
protocol Speaker: AnyObject {
    var isSpeaking: Bool { get }
    /// Speaks `text`, in the voice of that identifier (nil: the system's) at AVSpeechUtterance's rate; `done` runs once
    /// when it ends, finished or stopped. A new speak replaces the one under way, whose `done` never runs.
    func speak(_ text: String, voice: String?, rate: Float, done: @escaping @MainActor () -> Void)
    func stop()
}

/// AVSpeechSynthesizer behind Speaker, made on the first speak and let go when speech ends, so an idle Pilot holds none.
@MainActor
final class SystemSpeaker: NSObject, Speaker, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    /// The utterance under way, by identity, and its end: a stopped one's late callback is not the next one's end.
    private var current: (utterance: ObjectIdentifier, done: @MainActor () -> Void)?

    var isSpeaking: Bool { current != nil }

    func speak(_ text: String, voice: String?, rate: Float, done: @escaping @MainActor () -> Void) {
        let synthesizer = synthesizer ?? {
            let made = AVSpeechSynthesizer()
            made.delegate = self
            return made
        }()
        self.synthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        utterance.rate = rate
        current = (ObjectIdentifier(utterance), done)
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    /// Ends at once, as the key expects: a press right after Stop reads again instead of stopping a speech already gone.
    func stop() {
        guard let current else { return }
        self.current = nil
        synthesizer?.stopSpeaking(at: .immediate)
        current.done()
    }

    private func ended(_ utterance: ObjectIdentifier) {
        if let current, current.utterance == utterance {
            self.current = nil
            current.done()
        }
        // Let go once nothing speaks, after a stop's late didCancel too.
        if current == nil { synthesizer = nil }
    }

    nonisolated private func hop(_ utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { hop(utterance) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { hop(utterance) }
}

/// A Kokoro voice's ▶ line from its file (KokoroModel.renderSamples): an AVAudioPlayer made for the one play and let go
/// after, at the picked speed, its pitch kept.
@MainActor
final class SamplePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var done: (@MainActor () -> Void)?

    var isPlaying: Bool { player != nil }

    /// False, and `done` never runs, when the file does not play; else as Speaker's speak.
    func play(_ file: URL, speed: Float, done: @escaping @MainActor () -> Void) -> Bool {
        stop()
        guard let made = try? AVAudioPlayer(contentsOf: file) else { return false }
        made.delegate = self
        made.enableRate = true
        made.rate = speed
        guard made.play() else { return false }
        player = made
        self.done = done
        return true
    }

    func stop() {
        player?.stop()
        ended(player.map(ObjectIdentifier.init))
    }

    private func ended(_ id: ObjectIdentifier?) {
        guard let player, ObjectIdentifier(player) == id else { return }
        let finished = done
        self.player = nil
        done = nil
        finished?()
    }

    nonisolated private func hop(_ player: AVAudioPlayer) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.ended(id) } }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { hop(player) }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) { hop(player) }
}

/// Read aloud's voice and speed (story 190), on the Voice page and through `pilot get|set speech.*`.
@Observable @MainActor
final class ReadAloudSettings {
    static let shared = ReadAloudSettings()
    /// AVSpeechUtterance's rate, the slider's ends kept short of 0 and 1, which nobody can follow.
    static let rates: ClosedRange<Double> = 0.2...0.8
    static let standardRate = Double(AVSpeechUtteranceDefaultSpeechRate)
    static let voiceKey = "speech.voice", rateKey = "speech.rate", mediaKey = "speech.media"

    /// What reading does to the media playing (Sven Q282). Lower volume waits on Sven: lowering one app alone takes a
    /// Core Audio process tap, which asks for System Audio Recording.
    enum Media: String, CaseIterable, Sendable {
        case pause, keep
        var label: String { self == .pause ? "Pause" : "Keep playing" }
    }

    private let defaults: UserDefaults
    /// Where the installed voices come from; `voices` keeps them until macOS says they changed.
    @ObservationIgnored var installed: () -> [SpeechVoice] = { SpeechVoice.installed() }
    /// Kokoro's voices while its model is on disk (KokoroModel tells `neuralChanged` when that changes).
    @ObservationIgnored var neural: () -> [SpeechVoice] = { KokoroModel.shared.voices }
    @ObservationIgnored private var listed: [SpeechVoice]?
    @ObservationIgnored private var watching = false
    @ObservationIgnored var preferred: () -> [String] = { Locale.preferredLanguages }

    /// The picked voice's identifier; empty is automatic, the best voice for each text's language.
    var voiceID: String {
        didSet { defaults.set(voiceID, forKey: Self.voiceKey) }
    }
    var rate: Double {
        didSet { defaults.set(rate, forKey: Self.rateKey) }
    }
    var media: Media {
        didSet { defaults.set(media.rawValue, forKey: Self.mediaKey) }
    }

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        voiceID = defaults.string(forKey: Self.voiceKey) ?? ""
        let stored = defaults.object(forKey: Self.rateKey) as? Double
        rate = stored.map { min(max($0, Self.rates.lowerBound), Self.rates.upperBound) } ?? Self.standardRate
        media = defaults.string(forKey: Self.mediaKey).flatMap(Media.init) ?? .pause
    }

    /// The installed voices, listed on first use, never at launch, and again after a voice is downloaded or removed.
    var voices: [SpeechVoice] {
        if let listed { return listed }
        if !watching {
            watching = true
            NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.listed = nil
                    self?.revision += 1
                }
            }
        }
        let found = neural() + installed()
        listed = found
        settle(found)
        return found
    }

    /// Kokoro was downloaded or removed: the voices are listed again. Downloaded, Read aloud goes to Automatic, so Kokoro
    /// reads English from then on even where an Apple voice was picked before.
    func neuralChanged(ready: Bool) {
        if ready, !voiceID.isEmpty {
            speechLog.notice("read aloud: Kokoro downloaded, \(self.voiceID, privacy: .public) gives way to automatic")
            voiceID = ""
        }
        listed = nil
        revision += 1
    }

    /// Counts the times the voices changed (a download landed, Kokoro came or went), so the Voice page lists them again.
    private(set) var revision = 0

    /// A voice the list no longer shows (Q238: compact, Eloquence, MacinTalk), picked before, moves to the best installed
    /// voice in its language, else Automatic; a Kokoro voice once Kokoro is removed, to Automatic.
    private func settle(_ voices: [SpeechVoice]) {
        if KokoroVoice.name(of: voiceID) != nil, !voices.contains(where: { $0.id == voiceID }) {
            speechLog.notice("read aloud: \(self.voiceID, privacy: .public) is gone with Kokoro, now automatic")
            voiceID = ""
            return
        }
        guard let picked = voices.first(where: { $0.id == voiceID }), !picked.isBest else { return }
        let best = voices.filter { $0.isBest && $0.base == picked.base }.min { ($0.rank, $0.name) < ($1.rank, $1.name) }
        speechLog.notice("read aloud: \(picked.id, privacy: .public) is no longer listed, now \(best?.id ?? "automatic", privacy: .public)")
        voiceID = best?.id ?? ""
    }

    /// Whether macOS lets Pilot speak in Sven's Personal Voice: unsupported hides the Voice page's row (Sven Q220).
    enum Personal { case unsupported, notAsked, denied, allowed }

    var personal: Personal = ReadAloudSettings.personalNow()

    nonisolated static func personalNow() -> Personal {
        switch AVSpeechSynthesizer.personalVoiceAuthorizationStatus {
        case .unsupported: .unsupported
        case .denied: .denied
        case .authorized: .allowed
        default: .notAsked
        }
    }

    /// The Voice page's Allow: macOS asks once; allowed, the list reads the voices again with it among them.
    func askPersonal() {
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { _ in
            Task { @MainActor [weak self] in
                self?.listed = nil
                self?.personal = ReadAloudSettings.personalNow()
            }
        }
    }

    /// Kokoro's best voice for English once it is downloaded, Automatic or picked; Apple's for every other language, and
    /// with `apple` for what Kokoro could not read.
    func voice(for text: String, apple: Bool = false) -> SpeechVoice? {
        let among = apple ? voices.filter { !$0.neural } : voices
        let picked = voiceID.isEmpty || apple && KokoroVoice.name(of: voiceID) != nil ? nil : voiceID
        return SpeechVoice.pick(for: SpeechVoice.language(of: text), among: among, picked: picked, preferred: preferred())
    }
}

/// Read aloud (story 190, Sven Q145): Hyper+Ctrl+R or Read Aloud with Pilot in the right-click menu speaks the selected
/// text in the best installed voice for its language; the key again, or the tip's Stop, ends it. The selection is read
/// as the selection box reads it (SelectedText), never in a password field.
@MainActor
final class ReadAloud {
    static let shared = ReadAloud()
    static let id = "speech.readAloud"
    static let reading = "Reading aloud"

    var speaker: any Speaker = SystemSpeaker()
    /// Kokoro's voices; Apple's speaker reads instead when it fails.
    var neural = KokoroSpeaker()
    /// ▶ on a Kokoro voice plays its line from the file made for it, at once, where there is one.
    var samplePlayer = SamplePlayer()
    var sample: (SpeechVoice) -> URL? = { $0.neural ? KokoroModel.shared.sample(of: $0.id) : nil }
    var settings: ReadAloudSettings = .shared
    /// Pauses the media playing while a selection is read, as dictation does, and plays it again after.
    var media = MediaPause(media: BundledMediaControl())
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    var selection: () async -> String? = { await SelectedText.focused()?.text }
    var tip: (String) -> Void = { HUD.tip($0, seconds: 3, top: true) }
    /// Puts up the lasting tip with Stop near the top, clear of the text being read; the closure it returns takes the
    /// tip down if it is still the one up. Escape or a click closes the tip alone: the key or Stop ends the speech.
    var showReading: (String, @escaping @MainActor () -> Void) -> () -> Void = { text, stop in
        HUD.tip(text, seconds: .infinity, action: HUD.TipAction(title: "Stop", run: stop), top: true)
        let mine = HUD.tipModel
        return { if let mine, HUD.tipModel === mine { HUD.dismissTip() } }
    }

    /// The selection still being read.
    private var task: Task<Void, Never>?
    private var hideTip: (() -> Void)?
    /// A new read takes over the one under way: its end leaves the media paused.
    private var replacing = false

    var isBusy: Bool { task != nil || speaker.isSpeaking || neural.isSpeaking || samplePlayer.isPlaying }

    static func register(into registry: inout ActionRegistry) {
        do {
            try registry.register(Action(id: id, label: "Read selected text aloud", module: .apps, defaultKey: Key("r", .ctrl), tier: .v1,
                                         keywords: "speak speech tts text to speech voice") { ReadAloud.shared.toggle() })
        } catch { speechLog.error("read aloud: \(String(describing: error), privacy: .public)") }
    }

    /// The action: stops speech under way, or a read still finding the selection; else reads the front app's selection.
    func toggle() {
        if isBusy { return stop() }
        guard !secureInput() else { return tip(QuickFix.password) }
        task = Task {
            let text = await selection()
            guard !Task.isCancelled else { return }
            task = nil
            guard let text else { return tip(SelectionBox.nothingSelected) }
            speak(text)
        }
    }

    /// Read Aloud with Pilot from the right-click menu: the service hands over the text, read in place of what was being
    /// read, the media Pilot paused for it kept paused. A whole file's Read aloud (story 199) comes here too, `note` on
    /// the tip saying how much of it is read.
    func read(service text: String, note: String? = nil) {
        replacing = true
        stop()
        replacing = false
        speak(text, note: note)
    }

    private func speak(_ text: String, note: String? = nil) {
        let voice = settings.voice(for: text)
        if settings.media == .pause { media.takeStarted() }
        showTip(voice, note)
        say(text, voice, done: { [weak self] in self?.ended() }, fellBack: { [weak self] in self?.showTip($0, note) })
        speechLog.notice("read aloud: \(text.count) characters in \(voice?.id ?? "the system voice", privacy: .public)")
    }

    private func showTip(_ voice: SpeechVoice?, _ note: String? = nil) {
        hideTip?()
        let line = [Self.reading, voice?.name, note].compactMap(\.self).joined(separator: " · ")
        hideTip = showReading(line) { [weak self] in self?.stop() }
    }

    /// `voice` reads `text`; a Kokoro voice that makes no sound (its helper missing, or failing before a word) hands it
    /// to the best Apple voice, `fellBack` told which. Without `fellBack` (▶ on one voice) it just ends.
    private func say(_ text: String, _ voice: SpeechVoice?, done: @escaping @MainActor () -> Void,
                     fellBack: (@MainActor (SpeechVoice?) -> Void)? = nil) {
        let rate = Float(settings.rate)
        guard let voice, voice.neural else { return speaker.speak(text, voice: voice?.id, rate: rate, done: done) }
        neural.speak(text, voice: voice.id, rate: rate, done: done) { [weak self] in
            guard let self, let fellBack else { return done() }
            let apple = settings.voice(for: text, apple: true)
            speechLog.error("read aloud: \(voice.id, privacy: .public) failed, \(apple?.id ?? "the system voice", privacy: .public) reads instead")
            fellBack(apple)
            speaker.speak(text, voice: apple?.id, rate: rate, done: done)
        }
    }

    /// The Voice page's ▶ (Sven Q219): a line in that voice at the picked speed, in place of whatever was speaking;
    /// `done` runs once it ends or is stopped. A Kokoro voice plays its file; one not made yet is spoken as before.
    func preview(_ voice: SpeechVoice, done: @escaping @MainActor () -> Void) {
        stop()
        if let file = sample(voice), samplePlayer.play(file, speed: KokoroSpeaker.speed(Float(settings.rate)), done: done) { return }
        say(voice.sample, voice, done: done)
    }

    func stop() {
        task?.cancel()
        task = nil
        speaker.stop()
        neural.stop()
        samplePlayer.stop()
        ended()
    }

    private func ended() {
        hideTip?()
        hideTip = nil
        if !replacing { media.takeEnded() }
    }
}
