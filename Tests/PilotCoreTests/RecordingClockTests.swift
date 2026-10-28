import Testing
@testable import PilotCore

/// A recording's timeline (spec `capture.html` CP13): it starts at the first frame, a pause leaves no hole, and nothing
/// lands out of order on a track.
@Suite("Recording clock")
struct RecordingClockTests {
    @Test("The first frame is zero; sound before it is dropped")
    func start() {
        var clock = RecordingClock()
        #expect(clock.place(99.9, track: 1, starts: false) == nil)
        #expect(clock.place(100, track: 0, starts: true) == 0)
        #expect(clock.place(100.5, track: 1, starts: false) == 0.5)
        #expect(clock.place(101, track: 0, starts: true) == 1)
    }

    @Test("A two-second pause is cut out: samples inside it are dropped, those after it move back")
    func pause() {
        var clock = RecordingClock()
        _ = clock.place(100, track: 0, starts: true)
        clock.pause(at: 101)
        #expect(clock.isPaused)
        #expect(clock.place(101.5, track: 0, starts: true) == nil)
        #expect(abs((clock.place(100.9, track: 0, starts: true) ?? -1) - 0.9) < 1e-9, "stamped before the pause, it still lands")
        clock.resume(at: 103)
        #expect(clock.pausedTotal == 2)
        #expect(clock.place(103.5, track: 0, starts: true) == 1.5)
        #expect(clock.place(102.8, track: 0, starts: true) == nil, "queued from before the resume: out of order, dropped")
    }

    @Test("Pausing twice or resuming unpaused changes nothing")
    func idempotent() {
        var clock = RecordingClock()
        _ = clock.place(10, track: 0, starts: true)
        clock.resume(at: 11)
        clock.pause(at: 12)
        clock.pause(at: 13)
        clock.resume(at: 14)
        #expect(clock.pausedTotal == 2)
    }

    @Test("The timer leaves pauses out and stops while paused")
    func elapsed() {
        var clock = RecordingClock()
        #expect(clock.elapsed(at: 5) == 0)
        _ = clock.place(100, track: 0, starts: true)
        #expect(clock.elapsed(at: 142) == 42)
        clock.pause(at: 142)
        #expect(clock.elapsed(at: 150) == 42)
        clock.resume(at: 150)
        #expect(clock.elapsed(at: 160) == 52)
        #expect(RecordingClock.label(42.9) == "0:42")
        #expect(RecordingClock.label(725) == "12:05")
        #expect(RecordingClock.label(3729) == "1:02:09")
    }
}
