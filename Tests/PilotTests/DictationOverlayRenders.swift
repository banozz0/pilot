#if DEBUG
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Pilot

/// The dictation pill and its toasts (Q239) over a light and a dark ground, as they sit at the foot of the screen; no
/// panel opens. `PILOT_RENDER_DIR=<fresh dir> swift test --filter DictationOverlayRenders`
@MainActor
@Suite("Dictation overlay renders")
struct DictationOverlayRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Listening with the microphone toast, listening, writing, and the recover toast", .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func render() throws {
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("dictation-overlay")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        func overlay(_ drive: (DictationOverlay) -> Void) -> DictationOverlay {
            let o = DictationOverlay(after: { _, _ in Watch {} }, shows: false)
            drive(o)
            return o
        }
        /// Every word revealed, as the pill shows a pass once its words have come in.
        func revealed(_ drive: (DictationOverlay) -> Void) -> DictationOverlay {
            let (o, steps) = DictationOverlayTests.stepped()
            drive(o)
            steps.drain()
            return o
        }
        let speech: [Double] = [0, 0.05, 0.3, 0.7, 0.9, 0.6, 0.4, 0.8, 1, 0.5, 0.2, 0.35, 0.6, 0.3, 0.1, 0, 0.05, 0.2]
        let states: [(String, DictationOverlay)] = [
            ("1-started-mic-toast", overlay { $0.started(microphone: "AB13X USB Audio (USB)", words: false) }),
            ("2-listening", overlay { $0.started(microphone: nil, words: false); $0.levels(speech) }),
            ("3-quiet", overlay { $0.started(microphone: nil, words: false) }),
            ("4-writing", overlay { $0.started(microphone: nil, words: false); $0.levels(speech); $0.writing() }),
            ("5-recover", overlay { $0.recoverable("Lo que dije") }),
            ("6-words-waiting", overlay { $0.started(microphone: nil, words: true) }),
            ("7-words-short", revealed { $0.started(microphone: nil, words: true); $0.levels(speech); $0.words("Hola, can you send me") }),
            ("8-words-long", revealed { $0.started(microphone: nil, words: true); $0.levels(speech); $0.words(DictationOverlayTests.long) }),
            ("9-words-writing", overlay { $0.started(microphone: nil, words: true); $0.levels(speech); $0.words(DictationOverlayTests.long); $0.writing() }),
        ]
        for (name, o) in states {
            for (ground, colour) in [("light", Color(white: 0.93)), ("dark", Color(white: 0.16))] {
                let view = DictationOverlayView(overlay: o).padding(20).background(colour).pilotTheme()
                try #require(rendered(view).representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("\(name)-\(ground).png"))
            }
        }
    }
}

/// The overlay's model alone: no panel opens.
@MainActor
@Suite("Dictation overlay")
struct DictationOverlayTests {
    static let long = "Hola Alex, can you send me the notes from this morning's meeting about the launch plan, and then "
        + "book a table for four at the place near the harbour for Friday night"

    /// The overlay's timers, held until the test runs them.
    @MainActor
    final class Steps {
        var waiting: [@MainActor () -> Void] = []
        var delays: [TimeInterval] = []
        /// Seconds since the test began, the overlay's clock.
        var clock: TimeInterval = 0
        /// Runs the next one; false when none waits.
        @discardableResult
        func next() -> Bool {
            guard !waiting.isEmpty else { return false }
            waiting.removeFirst()()
            return true
        }
        func drain() { while next() {} }
    }

    static func stepped() -> (DictationOverlay, Steps) {
        let steps = Steps()
        let start = Date()
        return (DictationOverlay(after: { delay, step in steps.delays.append(delay); steps.waiting.append(step); return Watch {} },
                                 now: { start.addingTimeInterval(steps.clock) }, shows: false), steps)
    }

    @Test("Words come in one by one; the words a pass kept keep their ids; a changed word swaps in place, never hidden again; ✓ shows them all")
    func wordsStream() {
        let (o, steps) = Self.stepped()
        o.started(microphone: nil, words: true)
        o.words("Hola can")
        #expect(o.revealed == 1 && o.spoken.map(\.text) == ["Hola", "can"])
        steps.next()
        #expect(o.revealed == 2 && !steps.next())
        let first = o.spoken.map(\.id)

        o.words("Hola can you send")
        #expect(Array(o.spoken.map(\.id).prefix(2)) == first && o.revealed == 3, "kept words stay, the first new one shows at once")
        steps.drain()
        #expect(o.revealed == 4)

        // The model heard "can" again as "Ken": it swaps in place, the rest stay, the new word shows at once.
        let before = o.spoken.map(\.id)
        o.words("Hola Ken you send me")
        #expect(o.spoken[0].id == first[0] && o.spoken[1].id != first[1] && Array(o.spoken.map(\.id)[2..<4]) == Array(before[2..<4])
                && o.revealed == 5)
        o.writing()
        #expect(o.revealed == 5 && o.words == "Hola Ken you send me", "the take is over: all of it shows")
        o.ended()
        #expect(o.spoken.isEmpty && o.revealed == 0)
        #expect(DictationOverlay.revealStep(waiting: 30, passGap: nil) == 0.03 && DictationOverlay.revealStep(waiting: 6, passGap: 2.6) == 0.25)

        // Whisper turbo's passes, 2.6 s apart: the next pass's ten new words spread over 1.8 s, not one lump.
        let (paced, pacedSteps) = Self.stepped()
        paced.started(microphone: nil, words: true)
        paced.words("one")
        pacedSteps.clock += 2.6
        paced.words("one two three four five six seven eight nine ten eleven")
        #expect(pacedSteps.delays.last.map { abs($0 - 0.7 * 2.6 / 9) < 0.0001 } == true, "\(pacedSteps.delays)")
    }

    @Test("Words: the pill keeps one size however many words come, the newest in view, the oldest cut at the front")
    func wordsPillLayout() throws {
        testApp()
        func pill(_ words: String) -> DictationOverlay {
            let (o, steps) = Self.stepped()
            o.started(microphone: nil, words: true)
            o.words(words)
            steps.drain()
            return o
        }
        let short = try rendered(DictationWordsPill(overlay: pill("Hola")).pilotTheme())
        let long = try rendered(DictationWordsPill(overlay: pill(Self.long)).pilotTheme())
        let size = { (rep: NSBitmapImageRep) in CGSize(width: rep.pixelsWide / 2, height: rep.pixelsHigh / 2) }
        #expect(size(short) == CGSize(width: DictationWordsPill.width, height: DictationWordsPill.height) && size(long) == size(short),
                "\(size(short)) \(size(long))")
        let read = try recognisedText(in: long).map(\.text).joined(separator: " ")
        #expect(read.contains("Friday night") && !read.contains("Hola Alex"), "read: \(read)")
        // Waveform's pill stays the small one; words never reach it.
        let waveform = DictationOverlay(after: { _, _ in Watch {} }, shows: false)
        waveform.started(microphone: nil, words: false)
        waveform.words("Hola")
        #expect(!waveform.showsWords && waveform.words.isEmpty)
    }

    @Test("A new take keeps a cancelled take's Undo on offer; Undo hands back its words once and closes the toast")
    func recoverSurvivesNextTake() {
        let o = DictationOverlay(after: { _, _ in Watch {} }, shows: false)
        var recovered: [String] = []
        o.bind(cancel: {}, finish: {}, recover: { recovered.append($0) })
        o.recoverable("Lo que dije")
        o.started(microphone: "AB13X USB Audio (USB)", words: false)
        #expect(o.toast == .recover("Lo que dije") && o.phase == .listening)
        o.undo()
        o.undo()
        #expect(recovered == ["Lo que dije"] && o.toast == nil)
        o.started(microphone: "AB13X USB Audio (USB)", words: false)
        #expect(o.toast == .microphone("AB13X USB Audio (USB)"))
    }
}
#endif
