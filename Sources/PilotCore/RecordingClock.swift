/// A recording's timeline with pauses cut out (spec `capture.html` CP13). ScreenCaptureKit stamps every sample with the
/// host clock; the file's timeline starts at the first video frame and leaves out every paused stretch, so a file
/// recorded with a two-second pause plays without a two-second hole. Samples stamped inside a pause are dropped, and so
/// is any sample that would land at or before the last one on its track, as one queued from before a resume would.
public struct RecordingClock: Equatable, Sendable {
    /// The host time of the first video frame: the file's zero.
    public private(set) var first: Double?
    /// Every finished pause, added up.
    public private(set) var pausedTotal: Double = 0
    private var pausedAt: Double?
    private var last: [Int: Double] = [:]

    public init() {}

    public var isPaused: Bool { pausedAt != nil }

    public mutating func pause(at time: Double) {
        guard pausedAt == nil else { return }
        pausedAt = time
    }

    public mutating func resume(at time: Double) {
        guard let start = pausedAt else { return }
        pausedTotal += max(0, time - start)
        pausedAt = nil
    }

    /// Where a sample stamped `time` on `track` lands in the file, in seconds; nil when it is dropped. Only a video frame
    /// (`starts`) can start the timeline: sound before the first frame has no picture to go with.
    public mutating func place(_ time: Double, track: Int, starts: Bool) -> Double? {
        if let pausedAt, time >= pausedAt { return nil }
        if first == nil {
            guard starts else { return nil }
            first = time
        }
        let out = time - (first ?? time) - pausedTotal
        guard out >= 0, last[track].map({ out > $0 }) ?? true else { return nil }
        last[track] = out
        return out
    }

    /// How long the recording has run at `now`, pauses left out: the timer the top bar shows.
    public func elapsed(at now: Double) -> Double {
        guard let first else { return 0 }
        return max(0, (pausedAt ?? now) - first - pausedTotal)
    }

    /// "0:42", "12:05", "1:02:09".
    public static func label(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
