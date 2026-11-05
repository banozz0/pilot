import AVFoundation
import CoreMedia
import PilotCore

/// One recording's file (spec `capture.html` CP13): ScreenCaptureKit's samples written into an .mp4, H.264 video and AAC
/// sound, through AVAssetWriter, since SCRecordingOutput has no pause. RecordingClock retimes every sample so a pause
/// leaves no hole. Used on one serial queue only: the stream's.
final class RecordingWriter: @unchecked Sendable {
    enum Track: Int { case video, system, mic }

    enum Problem: Error, LocalizedError {
        case nothingRecorded
        case notWritten(String)

        var errorDescription: String? {
            switch self {
            case .nothingRecorded: "Nothing was recorded."
            case .notWritten(let why): "The recording was not written: \(why)"
            }
        }
    }

    let url: URL
    let fps: Int
    private let writer: AVAssetWriter
    private let inputs: [Track: AVAssetWriterInput]
    private var clock = RecordingClock()
    private var started = false
    /// Where the last frame landed, and where the last sound ends: the file ends at the later of one frame after the
    /// first and the second, so a narrated still screen keeps its last words.
    private(set) var lastFrame: Double = 0
    private(set) var soundEnd: Double = 0
    /// The pointer's places and clicks on the file's timeline (P71), for the video editor's zoom; and, on a recording
    /// that keeps the pointer out (T29), its shapes, for the export to draw it.
    private(set) var pointer = CursorTrack()
    /// The shape the pointer has now, an index into the track's shapes; noted at the next place kept.
    private var shapeNow: Int?

    /// `size` in pixels, even both ways (H.264's need); `system` and `mic` add a sound track each.
    /// `quality` is VideoToolbox's 0 to 1 (CaptureSettings.RecordQuality.level).
    init(url: URL, size: CGSize, fps: Int = 60, quality: Double = CaptureSettings.RecordQuality.high.level, system: Bool = false, mic: Bool = false) throws {
        self.url = url
        self.fps = fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(size: size, fps: fps, quality: quality))
        video.expectsMediaDataInRealTime = true
        var inputs: [Track: AVAssetWriterInput] = [.video: video]
        for (track, on) in [(Track.system, system), (.mic, mic)] where on {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
            ])
            audio.expectsMediaDataInRealTime = true
            inputs[track] = audio
        }
        for track in [Track.video, .system, .mic] {
            if let input = inputs[track], writer.canAdd(input) { writer.add(input) }
        }
        self.inputs = inputs
        // A fragment every 2 s: a crash or a power cut leaves a file that plays up to its last fragment.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        guard writer.startWriting() else { throw Problem.notWritten(writer.error?.localizedDescription ?? "the writer did not start") }
    }

    /// H.264 at a quality the encoder holds frame by frame, CABAC, tagged BT.709 as ScreenCaptureKit's frames are. An
    /// average bitrate (build 52) let the encoder spend a fifth of it on screen content: soft text, banded gradients.
    static func videoSettings(size: CGSize, fps: Int, quality: Double) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: quality,
                AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            ] as [String: Any],
        ]
    }

    func pause(at time: Double) { clock.pause(at: time) }
    func resume(at time: Double) { clock.resume(at: time) }

    /// One sample from the stream, kept on its track at its place on the file's timeline, or dropped (paused, before the
    /// first frame, out of order, or the encoder not keeping up).
    func append(_ sample: CMSampleBuffer, _ track: Track) {
        guard writer.status == .writing, let input = inputs[track], sample.isValid else { return }
        let stamp = sample.presentationTimeStamp
        guard stamp.isNumeric, let at = clock.place(stamp.seconds, track: track.rawValue, starts: track == .video) else { return }
        if !started {
            writer.startSession(atSourceTime: .zero)
            started = true
        }
        guard input.isReadyForMoreMediaData, let moved = Self.retimed(sample, by: stamp.seconds - at) else { return }
        guard input.append(moved) else { return }
        if track == .video { lastFrame = at } else { soundEnd = max(soundEnd, at + max(0, sample.duration.seconds.isFinite ? sample.duration.seconds : 0)) }
    }

    /// The pointer at `place` (a fraction of the recorded frame) at host time `time`, or a click there: kept at its place
    /// on the file's timeline, dropped while paused or before the first frame, as sound is.
    func point(_ place: CGPoint, at time: Double, click: Bool) {
        guard started, let at = clock.place(time, track: click ? Self.clickTrack : Self.moveTrack, starts: false) else { return }
        let p = CursorTrack.Point(t: at, x: place.x, y: place.y)
        if click { pointer.clicks.append(p) } else { pointer.moves.append(p) }
        if let shapeNow, shapeNow != pointer.shapeChanges.last?.shape, at > pointer.shapeChanges.last?.t ?? -1 {
            pointer.shapeChanges.append(CursorTrack.ShapeChange(t: at, shape: shapeNow))
        }
    }

    /// T29: the file has no pointer in its pixels; the track says so, with the recorded frame's size in points and the
    /// recording's own pointer settings.
    func drawsPointer(frame: CGSize, look: PointerLook) {
        pointer.drawn = true
        pointer.frame = frame
        pointer.look = look
    }

    /// The pointer's shape from now on: kept once, and noted on the track with the next place kept.
    func shape(_ shape: CursorTrack.Shape) {
        if let i = pointer.shapes.firstIndex(of: shape) {
            shapeNow = i
        } else {
            pointer.shapes.append(shape)
            shapeNow = pointer.shapes.count - 1
        }
    }

    /// The clock's own tracks for the pointer, after the media's.
    private static let moveTrack = 3, clickTrack = 4

    /// Ends the file one frame after its last and closes it; the file's length in seconds. A recording that never got a
    /// frame leaves no file.
    func finish() async throws -> Double {
        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw Problem.nothingRecorded
        }
        let end = max(lastFrame + 1 / Double(fps), soundEnd)
        inputs.values.forEach { $0.markAsFinished() }
        writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600))
        let writer = self.writer
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in writer.finishWriting { done.resume() } }
        guard writer.status == .completed else { throw Problem.notWritten(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)") }
        return end
    }

    /// Drops the file: nothing of it is kept.
    func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    /// `sample` with every timestamp moved `offset` seconds earlier.
    static func retimed(_ sample: CMSampleBuffer, by offset: Double) -> CMSampleBuffer? {
        guard var timings = try? sample.sampleTimingInfos() else { return nil }
        for i in timings.indices {
            let scale = max(timings[i].presentationTimeStamp.timescale, 600)
            let shift = CMTime(seconds: offset, preferredTimescale: scale)
            timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, shift)
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, shift) }
        }
        return try? CMSampleBuffer(copying: sample, withNewTiming: timings)
    }

    /// `size` in pixels made fit for H.264: at most 4096 wide or high, keeping its shape, both sides even.
    static func encodable(_ size: CGSize) -> CGSize {
        let fit = min(1, 4096 / max(size.width, size.height, 1))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * fit / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}
