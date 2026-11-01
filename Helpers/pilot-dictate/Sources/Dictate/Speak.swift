import AVFoundation
import FluidAudio
import Foundation
import NaturalLanguage
import os

/// Read aloud's neural voices (Sven Q264): Kokoro-82M (hexgrad, Apache 2.0) in FluidInference's Core ML build, through
/// FluidAudio's KokoroAneManager on its legacy seven-stage chain, which ships compiled models and reports its download.
/// Its folder, beside the speech models, holds everything it reads: FluidAudio keeps its English G2P and lexicon under
/// the home folder's .cache whatever the caller says, so this process takes the folder as its home before any of it runs.
public enum Speak {
    /// The model's name in the folder's ready file.
    public static let modelName = "kokoro/english"
    /// Kokoro's American and British voices, the ones Pilot lists; all fetched with the model, so ▶ never downloads.
    public static let voices = KokoroAneConstants.englishVoices.filter { ["af_", "am_", "bf_", "bm_"].contains(String($0.prefix(3))) }
    static let checkLine = "Ready."

    /// Whether the ready file in `base` names Kokoro.
    public static func isKokoro(_ base: URL) -> Bool {
        (try? String(contentsOf: base.appending(path: Dictate.readyFile), encoding: .utf8)) == modelName
    }

    /// FluidAudio's ~/.cache/fluidaudio becomes `base`/.cache/fluidaudio, and Core ML's compile of the chain lands in
    /// `base`/Library/Caches, so Remove takes all of it and no cache purge does. Before any model call, Kokoro's or a
    /// speech model's, for the life of the process.
    public static func useFolder(_ base: URL) {
        setenv("CFFIXED_USER_HOME", base.path, 1)
    }

    /// The models, the G2P, the lexicon and every listed voice, then one line spoken to a buffer, so the Neural Engine has
    /// compiled the chain before the model counts as ready.
    public static func download(to base: URL, progress: @escaping @Sendable (Double) -> Void,
                                preparing: @escaping @Sendable () -> Void) async throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The chain is most of the bytes; a repo download's own fraction ends at 0.5, where it would compile.
        let repo = try await KokoroAneResourceDownloader.ensureModels(variant: .english) { report in
            if case .downloading = report.phase { progress(min(report.fractionCompleted * 2, 1) * 0.8) }
        }
        try await KokoroAneResourceDownloader.ensureG2PAssets { report in
            if case .downloading = report.phase { progress(0.8 + min(report.fractionCompleted * 2, 1) * 0.1) }
        }
        for (index, voice) in voices.enumerated() {
            try await KokoroAneResourceDownloader.ensureVoicePack(voice, repoDirectory: repo)
            progress(0.9 + 0.1 * Double(index + 1) / Double(voices.count))
        }
        preparing()
        // The lexicon too, which the first initialize fetches.
        try await warm(base)
        try Data(modelName.utf8).write(to: base.appending(path: Dictate.readyFile))
    }

    /// Loads the chain and speaks a line to a buffer unless this helper already did, for a new helper's first read.
    public static func prepare(_ base: URL) async throws -> Bool {
        guard !Dictate.isPrepared(base) else { return false }
        try await warm(base)
        return true
    }

    private static func warm(_ base: URL) async throws {
        let manager = KokoroAneManager()
        try await manager.initialize()
        _ = try await manager.synthesizeDetailed(text: checkLine)
        Dictate.stampPrepared(base)
    }

    /// Speaks `text` in `voice` at `speed` (1 is Kokoro's own), a sentence at a time so the first is heard while the next
    /// is made; to `file` as a WAV instead of the speakers when given. `said` hears loaded once the chain is up, then
    /// speaking with the first sound.
    public static func speak(_ base: URL, text: String, voice: String, speed: Float, to file: URL?,
                             said: @escaping @Sendable (String) -> Void) async throws {
        let manager = KokoroAneManager(defaultVoice: voice)
        try await manager.initialize()
        said("loaded")
        let output: any SpeechOutput = try file.map { try FileOutput($0) } ?? SpeakerOutput()
        for (index, piece) in pieces(text).enumerated() {
            let samples = try await manager.synthesizeDetailed(text: piece, voice: voice, speed: speed).samples
            guard !samples.isEmpty else { continue }
            try await output.play(samples)
            if index == 0 { said("speaking") }
        }
        try await output.finish()
    }

    /// Each voice's ▶ line, made once into `base`/samples/<voice>.wav for the Voice page to play at once: a new child's
    /// first synthesis takes 2 to 3 s (Espresso's CPU stages warming up, measured 2026-10-19), a file plays in
    /// milliseconds. A voice whose file is there is skipped; each file lands whole or not at all.
    public static func samples(_ base: URL, _ lines: [(voice: String, text: String)]) async throws {
        let folder = base.appending(path: "samples")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manager = KokoroAneManager()
        try await manager.initialize()
        for (voice, text) in lines {
            let file = folder.appending(path: "\(voice).wav")
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            let samples = try await manager.synthesizeDetailed(text: text, voice: voice, speed: 1).samples
            let part = folder.appending(path: "\(voice).part.wav")
            try? FileManager.default.removeItem(at: part)
            let output = try FileOutput(part)
            try output.play(samples)
            try await output.finish()
            try FileManager.default.moveItem(at: part, to: file)
        }
    }

    /// The text in the pieces it is spoken in: the first sentence alone, as soon as it is made; then sentences joined up
    /// to about 300 characters, which Kokoro reads with one breath of prosody and less work a call.
    static func pieces(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        guard let first = sentences.first else { return [] }
        return sentences.dropFirst().reduce(into: [first]) { pieces, sentence in
            if pieces.count > 1, pieces[pieces.count - 1].count + sentence.count < 300 { pieces[pieces.count - 1] += " " + sentence }
            else { pieces.append(sentence) }
        }
    }
}

/// Kokoro's samples: 24 kHz mono floats.
nonisolated(unsafe) let speechFormat = AVAudioFormat(standardFormatWithSampleRate: Double(KokoroAneConstants.sampleRate), channels: 1)!

/// Where spoken samples go.
protocol SpeechOutput: Sendable {
    /// Returns once the piece may be followed by the next.
    func play(_ samples: [Float]) async throws
    /// Returns once everything played or was written.
    func finish() async throws
}

extension SpeechOutput {
    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}

/// The default output, each piece queued behind the one playing, so there is no gap between them, and never more than
/// two ahead, so a long read holds a few seconds of sound rather than all of it.
final class SpeakerOutput: SpeechOutput, @unchecked Sendable {
    static let ahead = 2

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Pieces queued and not played yet, and who waits for fewer: `play` for room, `finish` for none.
    private let state = OSAllocatedUnfairLock(initialState: (queued: 0, waiting: CheckedContinuation<Void, Never>?.none, until: 0))

    init() throws {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: speechFormat)
        try engine.start()
        player.play()
    }

    func play(_ samples: [Float]) async throws {
        state.withLock { $0.queued += 1 }
        player.scheduleBuffer(Self.buffer(samples), completionCallbackType: .dataPlayedBack) { [state] _ in
            let done = state.withLock { s -> CheckedContinuation<Void, Never>? in
                s.queued -= 1
                guard s.queued <= s.until, let waiting = s.waiting else { return nil }
                s.waiting = nil
                return waiting
            }
            done?.resume()
        }
        await queued(atMost: Self.ahead)
    }

    func finish() async throws {
        await queued(atMost: 0)
        engine.stop()
    }

    private func queued(atMost limit: Int) async {
        await withCheckedContinuation { done in
            let now = state.withLock { s -> Bool in
                if s.queued <= limit { return true }
                (s.waiting, s.until) = (done, limit)
                return false
            }
            if now { done.resume() }
        }
    }
}

/// A WAV file: the proof runs, never the speakers.
final class FileOutput: SpeechOutput, @unchecked Sendable {
    private let file: AVAudioFile

    init(_ url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: speechFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func play(_ samples: [Float]) throws { try file.write(from: Self.buffer(samples)) }

    func finish() async throws { file.close() }
}
