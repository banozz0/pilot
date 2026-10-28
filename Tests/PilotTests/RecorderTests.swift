import AppKit
import AVFoundation
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The recorder's picks and settings (story 192), with no stream: what the overlay's pick records, settings saved before
/// recording existed, the recording settings as `pilot get` reads them, and the stop and pause keys with nothing running.
@MainActor
@Suite("Recorder")
struct RecorderTests {
    static let grab = CaptureGrabTests.grab

    @Test("The overlay's pick: a dragged area records that area, Return the display, a window its app, a flat drag nothing")
    func picked() {
        #expect(RecordingSource.picked(.area(Self.grab, CGRect(x: 10, y: 20, width: 100, height: 50))) == .area(CGRect(x: 10, y: 20, width: 100, height: 50), on: 1))
        #expect(RecordingSource.picked(.area(Self.grab, CGRect(origin: .zero, size: Self.grab.frame.size))) == .display(1))
        #expect(RecordingSource.picked(.window(7, owner: 4242, Self.grab)) == .app(4242, on: 1))
        #expect(RecordingSource.picked(.window(7, owner: 0, Self.grab)) == .display(1))
        #expect(RecordingSource.picked(.area(Self.grab, CGRect(x: 10, y: 20, width: 100, height: 0))) == nil)
        #expect(RecordingSource.picked(.cancelled) == nil)
    }

    @Test("Settings saved before recording existed keep their folder, and take the recording defaults; the parked engine key is skipped")
    func oldSettings() throws {
        let old = Data(#"{"engine":"shottr","capturesFolder":"/Volumes/Shots"}"#.utf8)
        let settings = try JSONDecoder().decode(CaptureSettings.self, from: old)
        #expect(settings.capturesFolder == "/Volumes/Shots")
        #expect(settings.audio == .none && settings.countdown == 3 && !settings.showClicks)
    }

    @Test("Sound, countdown and clicks read and write as pilot get and set do")
    func settings() async throws {
        let store = CaptureSettingsStore(defaults: UserDefaults(suiteName: testSuite())!)
        let schema = SettingsSchema()
        schema.registerCaptures(store)
        #expect(try schema.get("capture.audio") == .string("none"))
        #expect(try schema.get("capture.countdown") == .string("3"))
        #expect(try schema.get("capture.showClicks") == .bool(false))
        _ = try await schema.setting("capture.audio").apply(.string("both"))
        _ = try await schema.setting("capture.countdown").apply(.string("0"))
        #expect(store.settings.audio == .both && store.settings.audio.mic && store.settings.audio.system)
        #expect(store.settings.countdown == 0)
        #expect(try schema.get("capture.recordQuality") == .string("high"))
        #expect(try schema.get("capture.recordResolution") == .string("native"))
        #expect(try schema.get("capture.recordFPS") == .string("60"))
        _ = try await schema.setting("capture.recordQuality").apply(.string("best"))
        _ = try await schema.setting("capture.recordFPS").apply(.string("30"))
        #expect(store.settings.recordQuality == .best && store.settings.recordFPS == 30)
    }

    @Test("With nothing recording, stop and pause do nothing and say nothing")
    func idleKeys() {
        let recorder = Recorder()
        var told: [String] = []
        recorder.tell = { text, _ in told.append(text) }
        recorder.stop()
        recorder.pauseOrResume()
        #expect(recorder.phase == .idle && told.isEmpty)
    }

    /// A recorder whose Microphone answers are a test's: counts the reads and the questions.
    final class Mic {
        var reads = 0, asks = 0
        var status: AVAuthorizationStatus = .notDetermined
        var answer: CheckedContinuation<Bool, Never>?
        var holds = false
    }

    static func recorder(_ mic: Mic, told: @escaping (String) -> Void = { _ in }) -> Recorder {
        let recorder = Recorder()
        recorder.barShows = { true }
        recorder.tell = { text, _ in told(text) }
        recorder.micStatus = { mic.reads += 1; return mic.status }
        recorder.askMic = {
            mic.asks += 1
            guard mic.holds else { return true }
            return await withCheckedContinuation { mic.answer = $0 }
        }
        return recorder
    }

    @Test("No sound picked: Microphone is never read or asked; Mic picked: asked once, the first time")
    func micAskedOnlyForMic() async {
        let mic = Mic()
        let none = Self.recorder(mic)
        none.start(.display(1), settings: CaptureSettings(audio: .system, countdown: 3), folder: FileManager.default.temporaryDirectory)
        await CaptureGrabTests.settle { none.phase == .counting(3) }
        none.stop()
        #expect(mic.reads == 0 && mic.asks == 0)
        let withMic = Self.recorder(mic)
        withMic.start(.display(1), settings: CaptureSettings(audio: .mic, countdown: 3), folder: FileManager.default.temporaryDirectory)
        await CaptureGrabTests.settle { withMic.phase == .counting(3) }
        withMic.stop()
        #expect(mic.asks == 1)
        mic.status = .authorized
        withMic.start(.display(1), settings: CaptureSettings(audio: .both, countdown: 3), folder: FileManager.default.temporaryDirectory)
        await CaptureGrabTests.settle { withMic.phase == .counting(3) }
        withMic.stop()
        #expect(mic.asks == 1, "granted: never asked again")
    }

    @Test("The phase leaves idle at once: a second start is ignored, and a stop during the Microphone question wins")
    func startingHole() async {
        let mic = Mic()
        mic.holds = true
        var told: [String] = []
        let recorder = Self.recorder(mic) { told.append($0) }
        recorder.start(.display(1), settings: CaptureSettings(audio: .mic, countdown: 3), folder: FileManager.default.temporaryDirectory)
        #expect(recorder.phase == .starting && recorder.isActive)
        recorder.start(.display(2), settings: CaptureSettings(audio: .mic, countdown: 3), folder: FileManager.default.temporaryDirectory)
        await CaptureGrabTests.settle { mic.answer != nil }
        #expect(mic.asks == 1, "the second start never got going")
        recorder.stop()
        #expect(recorder.phase == .idle && told == ["Recording cancelled."])
        mic.answer?.resume(returning: true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.phase == .idle, "the late answer does not start the count")
    }

    @Test("Stop with nothing recording still runs what waits on it, once")
    func stopThen() {
        let recorder = Recorder()
        var done = 0
        recorder.stop { done += 1 }
        #expect(done == 1)
    }

    @Test("The record key while a recording counts down stops it")
    func recordKeyStops() async {
        let recorder = Recorder()
        recorder.barShows = { true }
        var told: [String] = []
        recorder.tell = { text, _ in told.append(text) }
        let defaults = UserDefaults(suiteName: testSuite())!
        let capture = PilotCapture(grabber: CaptureGrabTests.FakeGrabber(grabs: [Self.grab]), store: CaptureSettingsStore(defaults: defaults),
                                   defaults: defaults, recorder: recorder, tell: { _, _ in })
        capture.overlaysVisible = false
        recorder.start(.display(1), settings: CaptureSettings(countdown: 3), folder: FileManager.default.temporaryDirectory)
        await CaptureGrabTests.settle { recorder.phase == .counting(3) }
        #expect(recorder.phase == .counting(3))
        capture.run(.record)
        #expect(recorder.phase == .idle)
        #expect(told == ["Recording cancelled."])
    }
}
