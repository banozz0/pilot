import AVFoundation
import CoreAudio
import FluidAudio
import Foundation
import os
import Security
import WhisperKit

/// Pilot's own dictation (story 194): each speech model in a folder of its own Pilot can delete, read only on this Mac.
/// Pilot names a model by its engine and that engine's name for it (SpeechModel.Choice): `whisperkit/<variant>`, argmax's
/// Core ML builds of Whisper, or `fluidaudio/ultra`, Moondream's Parakeet Ultra (post-trained from NVIDIA's Parakeet TDT
/// v3) in FluidInference's Core ML build. `fluidaudio/v3` still loads: a Mac that had v3 dictates on it until Ultra is
/// downloaded (1.0.2, Q719).
///
/// Measured on Sven's M4 (2026-10-16, 11 s of speech, model on disk): Whisper large-v3 turbo, 632 MB, loads in 1.2 s and
/// transcribes in 0.9 s at a 163 MB footprint; whisper.cpp's turbo (q5_0, Metal) took 2.8 s at 880 MB. A model's first
/// load compiles it for the Neural Engine, about four minutes for Whisper turbo (242 to 248 s, 2026-10-31), and Core ML keeps that compile under the
/// home's Library/Caches/<process name>, per macOS build. ~/Library/Caches is purgeable: macOS's low-disk purge and Mole's
/// clean emptied it and the next take compiled for minutes again (Sven, 2026-10-31: "it keeps happening"), so the helper
/// takes the model's folder as its home (main.swift) and the compile lives and goes with the model. The download prepares
/// it before the model counts as ready, and `prepare` again after a new helper, a new macOS or a compile gone.
public enum Dictate {
    /// The file Pilot reads for "on disk": written once the model is downloaded and prepared, holding the model's name,
    /// which every later load reads back from here.
    public static let readyFile = "ready"
    /// The code signature of the helper that last compiled the model and the macOS build, `preparedFile`'s content.
    static let preparedFile = "prepared"
    /// Held while a helper loads the model from the folder (`loadingAlone`).
    static let lockFile = "loading.lock"
    /// A take's audio or text waiting beside the models for Pilot: `take-<pid>.wav` or `.txt` (`keep`).
    public static let keptPrefix = "take-"
    /// The shortest take worth transcribing; Whisper makes words up from shorter ones.
    static let shortest = WhisperKit.sampleRate / 2
    /// The stretch `speech(in:)` judges at once: a tenth of a second, as WhisperKit's EnergyVAD does.
    static let frame = WhisperKit.sampleRate / 10
    /// How loud (RMS) a frame must be to count as speech, -40 dB: over a quiet room, under a quiet voice. Below it is
    /// silence, where Whisper writes "Thank you." or the last words again on its own (Sven, 2026-10-19: "writes stuff
    /// when i'm not dictating").
    static let speaking: Float = 0.01
    /// The quiet kept either side of the speech, so a word's soft start and end stay in.
    static let margin = WhisperKit.sampleRate * 3 / 10
    /// The fewest frames in a row that make a sound rather than a click: a key press or a mouse click is one frame,
    /// the shortest word three.
    static let sound = 3
    /// The quiet kept after the take's last sound, for a voice trailing off under any level.
    static let afterSound = WhisperKit.sampleRate / 2
    /// The most of the take a partial pass reads; past it, the take up to a pause is written down for good. Under
    /// Whisper's 30 s window with room for the speech that comes during a pass.
    static let window = WhisperKit.sampleRate * 20
    /// How long the microphone records on after the stop: the buffer still on its way (WhisperKit's stopRecording removes
    /// the tap at once, dropping it) and the end of the word the press landed on.
    static let tail = Duration.milliseconds(400)

    /// A model as Pilot names it.
    enum Model {
        case whisper(variant: String)
        case parakeet(AsrModelVersion, Repo)

        init(_ name: String) throws {
            let parts = name.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", maxSplits: 1).map(String.init)
            switch (parts.count == 2 ? parts[0] : "", parts.last ?? "") {
            case ("whisperkit", let variant): self = .whisper(variant: variant)
            case ("fluidaudio", "ultra"): self = .parakeet(.ultra, .parakeetUltra)
            case ("fluidaudio", "v3"): self = .parakeet(.v3, .parakeetV3)
            default: throw DictateError.unknownModel(name)
            }
        }

        /// WhisperKit's layout under `base`: the model in its Hugging Face folder, the tokenizer in its own;
        /// FluidAudio's: its repository's folder.
        func folder(_ base: URL) -> URL {
            switch self {
            case .whisper(let variant): base.appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)")
            case .parakeet(_, let repo): base.appending(path: repo.folderName)
            }
        }
    }

    enum DictateError: Error, CustomStringConvertible {
        case unknownModel(String)
        var description: String {
            switch self { case .unknownModel(let name): "this helper knows no model named \(name)" }
        }
    }

    /// Downloads the model `name`, then prepares it; `ready` written last, so a download cut short never counts.
    /// `progress` hears 0 to 1 while files arrive; `preparing` once, when they are all there.
    public static func download(to base: URL, model name: String, progress: @escaping @Sendable (Double) -> Void,
                                preparing announce: @escaping @Sendable () -> Void) async throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let model = try Model(name)
        let once = OSAllocatedUnfairLock(initialState: false)
        let preparing: @Sendable () -> Void = { if once.withLock({ said in defer { said = true }; return !said }) { announce() } }
        switch model {
        case .whisper(let variant):
            let folder = try await WhisperKit.download(variant: variant, downloadBase: base) { progress($0.fractionCompleted) }
            preparing()
            // Prewarm compiles each part for the Neural Engine and unloads it again, so the compile peaks one part at a
            // time; the load then fetches the tokenizer beside the model.
            _ = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: base, verbose: false, logLevel: .error,
                                                      prewarm: true, load: true, download: false))
        case .parakeet(let version, _):
            // FluidAudio downloads, then compiles each part in this process; its downloading phase is the first half of its
            // fraction (ModelHub's ProgressReporter, downloadPhaseWeight 0.5 in 0.17.7).
            _ = try await AsrModels.download(to: model.folder(base), version: version) { report in
                if case .compiling = report.phase { preparing() } else { progress(min(report.fractionCompleted * 2, 1)) }
            }
            preparing()
        }
        stampPrepared(base)
        try Data(name.utf8).write(to: base.appending(path: readyFile))
    }

    /// Compiles the model for this helper unless it already was; false when there was nothing to do.
    public static func prepare(_ base: URL) async throws -> Bool {
        guard !isPrepared(base) else { return false }
        _ = try await load(base)
        return true
    }

    /// Whether this helper on this macOS compiled the model last and every part of that compile is still there, so
    /// loading it takes a second, not minutes. In doubt, not: a needless prepare is a load from the compile, a wrong yes
    /// is minutes of "Listening…" with no words.
    public static func isPrepared(_ base: URL) -> Bool {
        guard let stamp, let written = try? String(contentsOf: base.appending(path: preparedFile), encoding: .utf8),
              written.hasPrefix(stamp + " "), let parts = Int(written.dropFirst(stamp.count + 1)), parts > 0 else { return false }
        return compiled(base) >= parts
    }

    /// How many parts of the model Core ML's compile holds in the folder: finished bundles in its cache for this macOS
    /// build. A `.tmp.<pid>` one is a compile under way or cut off. A part that runs off the Neural Engine has none, so
    /// the stamp keeps the count a whole load left (Whisper turbo 3 of its 5 parts) and fewer means a part is gone; a
    /// stamp of 0 never counts, since a compile that left nothing is no compile.
    static func compiled(_ base: URL) -> Int {
        let cache = base.appending(path: "Library/Caches/\(ProcessInfo.processInfo.processName)/com.apple.e5rt.e5bundlecache/\(osBuild)")
        let bundles = FileManager.default.enumerator(atPath: cache.path)
        var count = 0
        while let path = bundles?.nextObject() as? String {
            if bundles?.level == 2, path.hasSuffix(".bundle"), !path.contains(".tmp.") { count += 1 }
            if (bundles?.level ?? 0) >= 2 { bundles?.skipDescendants() }
        }
        return count
    }

    /// The model `ready` names, from disk only; this helper is stamped as having compiled it. One load at a time per
    /// folder, across helpers: a press while another take's helper compiles the model waits for that compile and then
    /// loads from it, where it compiled a copy of its own alongside (four at once on 2026-10-31, 430 MB each, each slowing
    /// the others). The lock goes with the process, so a helper that dies never holds it.
    public static func load(_ base: URL) async throws -> any Transcriber {
        try await alone(base) { try await loadModel(base) }
    }

    /// `work` while this process holds the folder's lock: a load, or a download, whose compile a relaunch's resume would
    /// otherwise run a second time into the same folder. The lock goes with the process.
    public static func alone<T>(_ base: URL, _ work: () async throws -> T) async throws -> T {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let lock = open(base.appending(path: lockFile).path, O_CREAT | O_RDWR, 0o600)
        if lock >= 0 {
            await withCheckedContinuation { (locked: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread { flock(lock, LOCK_EX); locked.resume() }
            }
        }
        defer { if lock >= 0 { close(lock) } }
        return try await work()
    }

    private static func loadModel(_ base: URL) async throws -> any Transcriber {
        let model = try Model(String(contentsOf: base.appending(path: readyFile), encoding: .utf8))
        let transcriber: any Transcriber
        switch model {
        case .whisper:
            let kit = try await WhisperKit(WhisperKitConfig(
                modelFolder: model.folder(base).path, tokenizerFolder: base, verbose: false, logLevel: .error, load: true, download: false))
            transcriber = WhisperTranscriber(kit: kit, prompt: promptTokens(words(beside: base), kit.tokenizer))
        case .parakeet(let version, _):
            let asr = AsrManager(config: .default)
            try await asr.loadModels(try AsrModels.loadLocal(from: model.folder(base), version: version))
            transcriber = ParakeetTranscriber(asr: asr)
        }
        stampPrepared(base)
        return transcriber
    }

    /// The file Pilot keeps Sven's words in (DictationWords), in the Speech folder that holds each model's folder.
    static let wordsFile = "vocabulary.json"
    /// The most prompt tokens: the prompt shares Whisper's 224-token context with the text it writes, so it stays small.
    static let promptCap = 60

    /// The words Sven taught dictation, as one line for Whisper's prompt: "Claude, Codex, Ghostex"; nil when there are
    /// none. Read from the file beside the model's folder, never from the arguments.
    public static func words(beside base: URL) -> String? {
        struct Taught: Decodable { let words: [String]? }
        let file = base.deletingLastPathComponent().appending(path: wordsFile)
        guard let data = try? Data(contentsOf: file), let words = (try? JSONDecoder().decode(Taught.self, from: data))?.words else { return nil }
        let line = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
        return line.isEmpty ? nil : line
    }

    /// `line` as Whisper's prompt tokens, a sentence: " I use Claude, Codex, Ghostex." Special tokens dropped (WhisperKit
    /// adds <|startofprev|> itself), the list cut to `promptCap` at a word's end. A bare list lost a take's first word
    /// ("Ask Claude to open…" came back "Claude to open…") and, without its full stop, went title case with no
    /// punctuation; the sentence kept every clip whole (bleed check, 2026-10-30). Nil without words or a tokenizer.
    static func promptTokens(_ line: String?, _ tokenizer: (any WhisperTokenizer)?) -> [Int]? {
        guard let line, let tokenizer else { return nil }
        func encode(_ text: String) -> [Int] { tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin } }
        let lead = encode(" I use"), stop = encode(".")
        var list: [Int] = []
        for word in line.components(separatedBy: ", ") {
            let next = encode((list.isEmpty ? " " : ", ") + word)
            guard lead.count + list.count + next.count + stop.count <= promptCap else { break }
            list += next
        }
        return list.isEmpty ? nil : lead + list + stop
    }

    /// After a whole load: this helper, this macOS and the parts compiled. The compile stays out of backups, rebuilt in minutes.
    static func stampPrepared(_ base: URL) {
        guard let stamp else { return }
        let file = base.appending(path: preparedFile), written = "\(stamp) \(compiled(base))"
        if (try? String(contentsOf: file, encoding: .utf8)) != written { try? Data(written.utf8).write(to: file) }
        excludeFromBackup(base.appending(path: "Library"))
    }

    /// Kept takes and the compile never reach Time Machine.
    public static func excludeFromBackup(_ item: URL) {
        var item = item, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? item.setResourceValues(values)
    }

    /// This helper and this macOS: a new helper prepares once more, and Core ML's cache keeps a folder per macOS build.
    /// `preparedFile` holds it, a space, and the parts compiled (`compiled`).
    static let stamp = signature.map { "\($0) \(osBuild)" }

    /// The macOS build, "26B123", the name of Core ML's cache folder for it.
    static let osBuild: String = {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var build = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0 else { return "" }
        return String(decoding: build.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    /// The take's audio while the model loads, beside the models (`keptPrefix`), so a Pilot quit or relaunched meanwhile
    /// finds it next time rather than lose it (Sven, 2026-10-31: the words never arrived); gone once answered.
    /// "wav" for that, "txt" for its text when Pilot is gone by the time it is written down.
    public static func kept(_ type: String, beside base: URL) -> URL {
        base.deletingLastPathComponent().appending(path: "\(keptPrefix)\(getpid()).\(type)")
    }

    /// `samples` as a 16 kHz mono WAV that `samples(of:)` reads back.
    static func write(_ samples: [Float], to file: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(WhisperKit.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let audio = try AVAudioFile(forWriting: file, settings: format.settings)
        try audio.write(from: buffer)
        audio.close()
        excludeFromBackup(file)
    }

    /// This helper's code directory hash.
    static let signature: String? = {
        var me: SecCode?, code: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }()

    /// Records the default input until `tail` after `stop` answers, the model loading meanwhile so the wait after it is
    /// the transcription alone; nil when `stop` cancels the take. `said` hears listening once the input records, preparing
    /// when the model must be compiled first, loaded once it is up, and a level line per buffer while it records. With
    /// `words`, a partial line too each time the words so far change (`partials`); the text is still the whole take's.
    /// The input going away mid-take ends it as `stop` would, the take so far written down, and says `inputLost`.
    public static func listen(_ base: URL, words: Bool = false, said: @escaping @Sendable (String) -> Void,
                              stop: @escaping @Sendable () async -> Bool) async throws -> String? {
        let recording = Recording(keepsRecent: words)
        enum End { case stopped, cancelled, lost }
        // Whichever comes first: `stop`'s answer, or the input gone.
        let (ends, end) = AsyncStream.makeStream(of: End.self)
        try recording.start(buffer: { said(Self.levelLine($0)) }, lost: { said(inputLost); end.yield(.lost) })
        said("listening")
        if !isPrepared(base) { said("preparing") }
        let up = OSAllocatedUnfairLock(initialState: false)
        let transcriber = Task {
            let transcriber = try await loaded(base, said)
            up.withLock { $0 = true }
            return transcriber
        }
        let partials = words ? Task { await Self.partials(transcriber, recording, said) } : nil
        Task { end.yield(await stop() ? .cancelled : .stopped) }
        var ending = End.stopped
        for await first in ends { ending = first; break }
        partials?.cancel()
        if ending == .cancelled { _ = recording.stop(); transcriber.cancel(); return nil }
        // The press often lands on the last word, and the input hands its audio over a buffer late: the microphone
        // records on a moment so the take holds everything said up to the key (Sven, 2026-10-23: "doesn't grab the last
        // few words"). An input that went away has nothing more to give.
        if ending == .stopped { try? await Task.sleep(for: tail) }
        let samples = recording.stop()
        // Still loading, which can be minutes: the take waits on disk too, until main.swift answers it.
        if !up.withLock({ $0 }), speech(in: samples) != nil { try? write(samples, to: kept("wav", beside: base)) }
        // The last partial finishes first: one model never decodes twice at once, and no partial comes after the text.
        await partials?.value
        return try await transcribe(transcriber.value, samples)
    }

    /// The words so far while Sven speaks, FluidVoice's way (ASRService.processStreamingChunk, read 2026-10-17): the model
    /// in use writes down the take since `anchor` again once a second of it is in, each pass starting only after the last,
    /// so a slow model updates less often rather than falling behind. A pass runs only when more speech came since the
    /// last one: in a pause the words stay as they are, never rewritten or made up from the quiet. Once the speech since
    /// `anchor` passes `window`, the take up to its quietest moment is written down for good and the anchor moves there,
    /// so the words already shown keep their start (a window sliding with the take cut its first word differently each
    /// pass and rewrote all of it, Sven's 70 s takes on 2026-10-19) and a pass's cost stays bounded.
    static func partials(_ loading: Task<any Transcriber, Error>, _ recording: Recording, _ said: @Sendable (String) -> Void) async {
        guard let transcriber = try? await loading.value else { return }
        let clock = ContinuousClock()
        // The words before `anchor`, final; where the last pass's speech ended, in the take.
        var settled = "", anchor = 0, heard = 0, last = ""
        let after = { (words: String) in [settled, words].filter { !$0.isEmpty }.joined(separator: " ") }
        while !Task.isCancelled {
            let samples = recording.samples(from: anchor), start = clock.now
            if samples.count >= WhisperKit.sampleRate, let speech = speech(in: samples), anchor + speech.upperBound > heard {
                if speech.upperBound > window {
                    let cut = quietest(samples, in: window / 2..<window)
                    let words = (try? await transcribe(transcriber, Array(samples[..<cut]))) ?? ""
                    settled = after(words)
                    anchor += cut
                    recording.drop(before: anchor)
                    continue
                }
                heard = anchor + speech.upperBound
                if let words = try? await transcribe(transcriber, samples), !Task.isCancelled {
                    let all = after(words)
                    if !all.isEmpty, all != last {
                        last = all
                        said(partialLine(all))
                    }
                }
            }
            try? await Task.sleep(for: partialGap(after: clock.now - start))
        }
    }

    /// Where the speech in `samples` starts and ends, `margin` kept either side; nil when fewer than two frames are loud
    /// enough, a click or a breath.
    static func speech(in samples: [Float]) -> Range<Int>? {
        let voiced = AudioProcessor.calculateVoiceActivityInChunks(of: samples, chunkCount: (samples.count + frame - 1) / frame,
                                                                   frameLengthSamples: frame, energyThreshold: speaking)
        guard voiced.count(where: { $0 }) >= 2, let first = voiced.firstIndex(of: true), let last = voiced.lastIndex(of: true) else { return nil }
        return max(0, first * frame - margin)..<min(samples.count, (last + 1) * frame + margin)
    }

    /// How loud each `frame` of `samples` is (RMS).
    static func loudness(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: frame).map { AudioProcessor.calculateAverageEnergy(of: Array(samples[$0..<min($0 + frame, samples.count)])) }
    }

    /// How loud a frame must be to count as sound: 6 dB over the room (the take's quietest tenth), at least -50 dB and at
    /// most `speaking`, so a voice trailing off at -44 dB in a quiet room still counts.
    static func soundLevel(_ loudness: [Float]) -> Float {
        let room = loudness.sorted().dropFirst(loudness.count / 10).first ?? 0
        return min(speaking, max(0.003, room * 2))
    }

    /// The end of the last `sound` in `loudness` louder than `level`, in samples; nil when it holds none.
    static func soundEnd(_ loudness: [Float], over level: Float) -> Int? {
        var run = 0, end: Int?
        for (index, frameLoudness) in loudness.enumerated() {
            run = frameLoudness > level ? run + 1 : 0
            if run >= sound { end = (index + 1) * frame }
        }
        return end
    }

    /// The start of the quietest frame in `range`, where a cut splits no word.
    static func quietest(_ samples: [Float], in range: Range<Int>) -> Int {
        stride(from: range.lowerBound, to: min(range.upperBound, samples.count - frame), by: frame)
            .map { ($0, AudioProcessor.calculateAverageEnergy(of: Array(samples[$0..<$0 + frame]))) }
            .min { $0.1 < $1.1 }?.0 ?? range.upperBound
    }

    /// The rest between two passes: as long as the last pass took, from 0.2 s to 0.6 s. Parakeet, a tenth of a second a
    /// pass, updates about four times a second; Whisper turbo, which takes about as long as a pass may rest, keeps the
    /// model busy no more than it did at FluidVoice's fixed 0.6 s.
    static func partialGap(after pass: Duration) -> Duration { min(.milliseconds(600), max(.milliseconds(200), pass)) }

    /// "partial <JSON string>": the words so far, which Pilot shows and never types.
    public static func partialLine(_ words: String) -> String {
        "partial " + String(decoding: (try? JSONEncoder().encode(words)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private static func loaded(_ base: URL, _ said: @Sendable (String) -> Void) async throws -> any Transcriber {
        let transcriber = try await load(base)
        said("loaded")
        return transcriber
    }

    /// How loud each quarter of one buffer was (about 25 ms at 16 kHz), 0 silent to 1 loud on a decibel scale from
    /// -55 dB: "level 0.12 0.40 0.38 0.05", Pilot's waveform while Sven speaks.
    public static func levelLine(_ buffer: [Float]) -> String {
        let parts = 4, size = max(1, buffer.count / parts)
        let levels = (0..<parts).map { i -> String in
            let slice = buffer.dropFirst(i * size).prefix(size)
            guard !slice.isEmpty else { return "0" }
            let rms = (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
            let level = min(1, max(0, (20 * log10(max(rms, 1e-7)) + 55) / 45))
            return String(format: "%.2f", level)
        }
        return "level " + levels.joined(separator: " ")
    }

    /// The take's text, in the language it was spoken in; empty for a take too short or too quiet to hold words. It is
    /// read from its speech's start to the last sample recorded: the quiet before is cut off, the end never, since last
    /// words said softer than `speaking` (a voice trailing off, -44 dB in a WAV) fell past the speech's end and were
    /// never written down (Sven, 2026-10-24: "not getting all my words, especially the last few ones"). Whisper cuts the
    /// quiet after on its own (WhisperTranscriber.text).
    public static func transcribe(_ transcriber: any Transcriber, _ samples: [Float]) async throws -> String {
        guard let speech = speech(in: samples), speech.count >= shortest else { return "" }
        return try await transcriber.text(Array(samples[speech.lowerBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A WAV or any file AVFoundation reads, as 16 kHz mono samples.
    public static func samples(of file: URL) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: file.path)
    }

    /// The line for a Mac with no microphone: no default input, or one with no channels or a 0 Hz format, which
    /// AVAudioEngine's input tap refuses with an uncaught exception (Sven's Mac mini, Q393).
    public static let noInput = "error no input device"
    /// The line for the input going away mid-take, after which the take so far is written down.
    public static let inputLost = "input lost"

    /// No input device to record: thrown before the input tap is installed.
    public struct NoInputDevice: Error {}

    /// Whether the Mac has a default input with an input stream, from CoreAudio alone: no Microphone grant needed.
    public static var hasInputDevice: Bool {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return false }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &bytes) == noErr && bytes > 0
    }

    /// Whether macOS lets this process record; a child of Pilot.app asks for Pilot's grant.
    public static var microphoneAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
}

/// A loaded model, writing a take down.
public protocol Transcriber: Sendable {
    func text(_ samples: [Float]) async throws -> String
}

/// Whisper, the language detected once a take, a long take cut at its pauses.
final class WhisperTranscriber: Transcriber, @unchecked Sendable {
    let kit: WhisperKit
    /// Sven's words as the decoder's prompt (Dictate.promptTokens), so Whisper spells them as taught; nil for none.
    let prompt: [Int]?
    /// The take's language, read once from its first `solid` of speech and kept for the rest. Read again in each 30 s
    /// piece, a piece Whisper decoded again at a higher temperature drew its language at random too, and English came
    /// back Spanish (Sven, 2026-10-19).
    private let kept = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// The speech the language is read from; a shorter take, a single piece, keeps Whisper's own pick.
    static let solid = WhisperKit.sampleRate * 8
    /// The silence put after the take: WhisperKit never reads a take's last second as a piece of its own (VADAudioChunker's
    /// windowPadding, 1 s in 1.1.1), so a word after the last pause of a take just over 30 s went missing ("Yes." of a
    /// 30.9 s WAV). Whisper pads each window with the same zeros.
    static let padding = [Float](repeating: 0, count: WhisperKit.sampleRate)

    init(kit: WhisperKit, prompt: [Int]? = nil) {
        self.kit = kit
        self.prompt = prompt
        // WhisperKit cuts a take over 30 s in the longest quiet of each piece's second half, by an energy threshold of
        // its own (0.02, -34 dB) where a voice at a usual microphone level reads as quiet: the cut fell mid-word, and the
        // piece after it came back as one made-up line (Sven, 2026-10-19: about half of a 2 minute take typed). The
        // helper's speech threshold puts the cut in a pause.
        kit.voiceActivityDetector = EnergyVAD(energyThreshold: Dictate.speaking)
    }

    func text(_ take: [Float]) async throws -> String {
        // Whisper reads the take to `afterSound` past its last sound. Read to the last sample, the pause before the stop,
        // the key's click and the tail came in, and on a take over 30 s WhisperKit made them a piece of their own that
        // Whisper wrote "Thank you.", "you" or "*sounds of breath*" for (Sven, 2026-10-29: "most of the times it ends
        // with 'thank you'"). In a room too loud to tell a soft last word from it the take stays whole, and so does it
        // for Parakeet, which writes nothing over quiet and lost a soft last word cut this way.
        let loudness = Dictate.loudness(take), level = Dictate.soundLevel(loudness)
        let samples: [Float]
        if level < Dictate.speaking {
            guard let end = Dictate.soundEnd(loudness, over: level) else { return "" }
            samples = Array(take.prefix(end + Dictate.afterSound))
        } else {
            samples = take
        }
        // Short takes keep Whisper's own language pick even with a prompt: reading it first cost 0.4 to 1.4 s a take
        // (Sven, 2026-10-30, Q678); add it back if a short Spanish take comes out in English.
        let language = await language(of: samples)
        // No first-token check: a piece opening on room noise failed it however sure the rest was, and its decode again
        // at a higher temperature came back garbled or as one made-up line, one run in three on a noisy 85 s clip
        // (2026-10-19). The average log probability still sends a decode that failed as a whole round again.
        let options = DecodingOptions(language: language, detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true,
                                      promptTokens: prompt, firstTokenLogProbThreshold: nil, chunkingStrategy: .vad)
        var pieces = try await kit.transcribe(audioArray: samples + Self.padding, decodeOptions: options)
            .map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), start: Int(($0.seekTime ?? 0) * Float(WhisperKit.sampleRate))) }
            .filter { !$0.text.isEmpty && !Self.isTag($0.text) }
        // The last guard, should a piece of quiet still reach Whisper: WhisperKit 1.1.1 never computes the no-speech
        // probability (TextDecoder's noSpeechProb is 0), so noSpeechThreshold skips nothing.
        // A line no one dictates goes whatever the piece holds: typing alone is sound and came back "Продолжение следует...".
        if let last = pieces.last, Self.isNeverSaid(last.text)
            || Self.isMadeUp(last.text) && Dictate.soundEnd(Array(loudness.dropFirst(last.start / Dictate.frame)), over: level) == nil {
            pieces.removeLast()
        }
        return pieces.map(\.text).joined(separator: " ")
    }

    /// What Whisper writes on its own over quiet or a click: "Thank you.", "you", "Thanks for watching!", ".". Dropped
    /// only as the take's last piece and only over no sound, so a "Thank you" said aloud stays.
    static let madeUp: Set<String> = ["", "you", "thank you", "thanks", "thank you very much", "thank you so much", "thank you for watching",
                                      "thanks for watching", "bye", "so", "gracias", "gracias por ver", "vielen dank"]
    /// The closing lines and subtitle credits of the videos Whisper learned from, which no one dictates: dropped as the
    /// take's last piece whatever it holds. Credits by their start, whoever they credit.
    static let neverSaid: Set<String> = ["продолжение следует", "спасибо за просмотр", "ご視聴ありがとうございました", "ご視聴ありがとうございます"]
    static let credits = ["субтитры", "редактор субтитров", "untertitel", "untertitelung", "sous titres", "subtítulos realizados por",
                          "subtitles by", "amara org"]

    static func isMadeUp(_ piece: String) -> Bool { madeUp.contains(words(piece)) }

    static func isNeverSaid(_ piece: String) -> Bool {
        let words = words(piece)
        return neverSaid.contains(words) || credits.contains { words.hasPrefix($0) }
    }

    /// `piece` lowercased, its words only, one space apart: "Sous-titres réalisés…" is "sous titres réalisés".
    static func words(_ piece: String) -> String {
        String(piece.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }

    /// The take's language once `samples` hold a `solid` stretch, detected at temperature 0 on their first 30 s and kept;
    /// nil before, or when detecting fails, so the pass keeps Whisper's own pick rather than losing the take.
    private func language(of samples: [Float]) async -> String? {
        if let language = kept.withLock({ $0 }) { return language }
        guard samples.count >= Self.solid,
              let detected = try? await kit.detectLangauge(audioArray: Array(samples.prefix(WhisperKit.sampleRate * 30))).language
        else { return nil }
        if samples.count >= Self.solid { kept.withLock { $0 = detected } }
        return detected
    }

    /// A piece that is only Whisper's note about the sound, "[Foreign]", "(music)", "[BLANK_AUDIO]" or "*sounds of
    /// breath*": no words to type. Whisper small wrote "[Foreign]" for a Spanish take (2026-10-16).
    static func isTag(_ piece: String) -> Bool {
        guard piece.count > 1, let first = piece.first, let last = piece.last else { return false }
        return (first == "[" && last == "]" || first == "(" && last == ")" || first == "*" && last == "*")
            && !piece.dropFirst().dropLast().contains(where: { "[]()*".contains($0) })
    }
}

/// Parakeet Ultra or TDT v3, which read any of their 25 European languages with no hint and cut a long take themselves.
struct ParakeetTranscriber: Transcriber {
    let asr: AsrManager

    func text(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples, decoderState: &state).text
    }
}

/// The default input, recorded at 16 kHz mono from start to stop.
final class Recording: Sendable {
    nonisolated(unsafe) private let processor = AudioProcessor()
    private let keepsRecent: Bool
    /// The take from sample `start` on, a copy of its own: the processor's samples grow on the audio thread unguarded.
    private let recentSamples = OSAllocatedUnfairLock(initialState: (start: 0, samples: [Float]()))
    /// The engine's configuration-change observer while recording; set in `start`, read in `stop`, one after the other.
    nonisolated(unsafe) private var changes: (any NSObjectProtocol)?

    init(keepsRecent: Bool = false) { self.keepsRecent = keepsRecent }

    /// `buffer` hears each new buffer of samples, about 100 ms, on the audio thread; `lost` once, when the engine's
    /// input changes under it (unplugged, or the default switched), which stops the engine. Throws NoInputDevice
    /// rather than let WhisperKit tap an input with no format.
    func start(buffer: @escaping ([Float]) -> Void, lost: @escaping @Sendable () -> Void) throws {
        // The probe engine must outlive the read: inputNode does not retain it, and a freed one crashed every take.
        let probe = AVAudioEngine()
        let format = withExtendedLifetime(probe) { probe.inputNode.inputFormat(forBus: 0) }
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Dictate.NoInputDevice() }
        try processor.startRecordingLive(inputDeviceID: nil) { [keepsRecent, recentSamples] samples in
            if keepsRecent { recentSamples.withLock { $0.samples.append(contentsOf: samples) } }
            buffer(samples)
        }
        changes = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: processor.audioEngine,
                                                         queue: nil) { _ in lost() }
    }

    /// The take from sample `start` on, as far as it is recorded.
    func samples(from start: Int) -> [Float] {
        recentSamples.withLock { recent in Array(recent.samples.dropFirst(max(0, start - recent.start))) }
    }

    /// Forgets the take before sample `start`, which the partials have written down for good.
    func drop(before start: Int) {
        recentSamples.withLock { recent in
            recent.samples.removeFirst(min(recent.samples.count, max(0, start - recent.start)))
            recent.start = max(recent.start, start)
        }
    }

    /// Stops the input and hands back the whole take.
    func stop() -> [Float] {
        if let changes { NotificationCenter.default.removeObserver(changes) }
        processor.stopRecording()
        defer { processor.audioSamples = [] }
        return Array(processor.audioSamples)
    }
}
