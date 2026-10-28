@testable import Dictate
import Foundation
import Testing

/// Each downloaded speech model on a recorded take, never the microphone. Opt-in: PILOT_LIVE=1 with models downloaded,
/// in Pilot's Speech folder or the one PILOT_DICTATE_MODELS names (`pilot-dictate download <folder>/<id> <model>` fetches
/// one there); every subfolder holding a ready file is tried.
@Suite("Live transcribe")
struct LiveTranscribeTests {
    static let base = ProcessInfo.processInfo.environment["PILOT_DICTATE_MODELS"].map { URL(filePath: $0) }
        ?? URL.applicationSupportDirectory.appending(path: "Pilot/Speech")
    static let models = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
        .filter { FileManager.default.fileExists(atPath: $0.appending(path: Dictate.readyFile).path) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    static let enabled = ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1" && !models.isEmpty

    @Test("fox.wav reads back as it was said, and silence is no text, in each model", .enabled(if: enabled), arguments: models)
    func fox(_ folder: URL) async throws {
        let wav = try #require(Bundle.module.url(forResource: "fox", withExtension: "wav"))
        let clock = ContinuousClock()
        let transcriber = try await Dictate.load(folder)
        let start = clock.now
        let text = try await Dictate.transcribe(transcriber, try Dictate.samples(of: wav))
        print("\(folder.lastPathComponent) transcribed in \(clock.now - start): \(text)")
        #expect(text.lowercased().contains("quick brown fox jumps over the lazy dog"))
        #expect(try await Dictate.transcribe(transcriber, [Float](repeating: 0, count: 48_000)).isEmpty)
    }

    /// The live words' cost: one pass over 2 to 30 s of the take, as `Dictate.partials` makes them, timed after a first pass
    /// warms the model.
    @Test("Partial passes, timed by take length", .enabled(if: enabled), arguments: models)
    func partialPasses(_ folder: URL) async throws {
        let wav = try Dictate.samples(of: try #require(Bundle.module.url(forResource: "fox", withExtension: "wav")))
        let take = Array(repeatElement(wav, count: 30 * 16_000 / wav.count + 1).joined())
        let transcriber = try await Dictate.load(folder)
        _ = try await Dictate.transcribe(transcriber, Array(take.prefix(32_000)))
        let clock = ContinuousClock()
        for seconds in [2, 5, 10, 20, 30] {
            let start = clock.now
            _ = try await Dictate.transcribe(transcriber, Array(take.prefix(seconds * 16_000)))
            let pass = clock.now - start
            print("\(folder.lastPathComponent) partial over \(seconds) s: \(pass), then rests \(Dictate.partialGap(after: pass))")
        }
        #expect(Dictate.partialGap(after: .milliseconds(50)) == .milliseconds(200) && Dictate.partialGap(after: .seconds(2)) == .milliseconds(600))
    }

    @Test("A piece that is only Whisper's note about the sound is no text")
    func tags() {
        #expect(["[Foreign]", "(music)", "[BLANK_AUDIO]"].allSatisfy(WhisperTranscriber.isTag))
        #expect(!["Hola", "[a] and [b]", "(see) this", ""].contains(where: WhisperTranscriber.isTag))
    }
}
