import CoreGraphics
import Foundation

// The video editor's edit (P71, after Snapzy's Studio, BSD-3: Packaging/Snapzy-LICENSE.txt): what a recording becomes on
// export, kept apart from the screen so the camera's maths is tested on its own. Every time here is the recording's own
// (source) time unless it says output; every place is a fraction of the frame from its top left.

/// Where the pointer was while a recording ran, and where it clicked (P71): sampled at most 30 times a second with the
/// frames, on the file's timeline (pauses cut out as the frames are), each place a fraction of the recorded frame from its
/// top left (outside it below 0 or above 1). The video editor's auto zoom starts from the clicks and follows the pointer.
public struct CursorTrack: Equatable, Sendable, Codable {
    public struct Point: Equatable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double

        public init(t: Double, x: Double, y: Double) {
            self.t = t
            self.x = x
            self.y = y
        }

        public var place: CGPoint { CGPoint(x: x, y: y) }
    }

    public var moves: [Point]
    public var clicks: [Point]

    public init(moves: [Point] = [], clicks: [Point] = []) {
        self.moves = moves
        self.clicks = clicks
    }

    public var isEmpty: Bool { moves.isEmpty && clicks.isEmpty }

    /// Where the pointer was at `t`, straight between the samples round it (a click is a sample too); nil with none.
    public func place(at t: Double) -> CGPoint? {
        let all = merged
        guard let first = all.first, let last = all.last else { return nil }
        if t <= first.t { return first.place }
        if t >= last.t { return last.place }
        // The first sample after t: the one before it is at or before t.
        var lo = 0, hi = all.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if all[mid].t <= t { lo = mid + 1 } else { hi = mid }
        }
        let a = all[lo - 1], b = all[lo]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// The pointer's place averaged over `window` seconds round `t`: what the zoom's camera follows, so a flick of the
    /// mouse never jerks it. The same answer for the same `t`, so a seek shows what the export draws.
    public func smoothed(at t: Double, window: Double = 0.8) -> CGPoint? {
        guard !isEmpty else { return nil }
        let steps = 9
        var x = 0.0, y = 0.0
        for i in 0..<steps {
            guard let p = place(at: t - window / 2 + window * Double(i) / Double(steps - 1)) else { return nil }
            x += p.x
            y += p.y
        }
        return CGPoint(x: x / Double(steps), y: y / Double(steps))
    }

    /// Moves and clicks in time order.
    private var merged: [Point] {
        clicks.isEmpty ? moves : (moves + clicks).sorted { $0.t < $1.t }
    }

    /// The clicks folded into the moves once, in time order: what a frame's many `place` calls read without sorting again.
    public var path: CursorTrack { CursorTrack(moves: merged) }

    // Kept as flat lists of numbers, three to a point, four decimals: a minute is a few tens of kilobytes.
    private enum CodingKeys: String, CodingKey { case moves, clicks }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func flat(_ points: [Point]) -> [Double] { points.flatMap { [$0.t, $0.x, $0.y].map { ($0 * 10_000).rounded() / 10_000 } } }
        try c.encode(flat(moves), forKey: .moves)
        try c.encode(flat(clicks), forKey: .clicks)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func points(_ key: CodingKeys) throws -> [Point] {
            let n = try c.decodeIfPresent([Double].self, forKey: key) ?? []
            return stride(from: 0, to: n.count - n.count % 3, by: 3).map { Point(t: n[$0], x: n[$0 + 1], y: n[$0 + 2]) }
        }
        moves = try points(.moves)
        clicks = try points(.clicks)
    }

    /// Where a recording's track is kept: `<file name>.json` in `folder` (Pilot's support folder's Recording pointers), by
    /// the file's name, which is unique when Pilot writes it. A recording moved or renamed loses its track: the editor then
    /// opens with no auto zoom.
    public static func file(for recording: URL, in folder: URL) -> URL {
        folder.appending(path: recording.lastPathComponent + ".json", directoryHint: .notDirectory)
    }

    /// Writes the track for `recording`, and keeps only the newest `keep` tracks in `folder`.
    public func save(for recording: URL, in folder: URL, keep: Int = 200) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.file(for: recording, in: folder), options: .atomic)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        guard all.count > keep else { return }
        let dated = all.map { ($0, (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }

    /// The track kept for `recording`; nil when there is none.
    public static func load(for recording: URL, in folder: URL) -> CursorTrack? {
        guard let data = try? Data(contentsOf: file(for: recording, in: folder)) else { return nil }
        return try? JSONDecoder().decode(CursorTrack.self, from: data)
    }
}

/// One stretch the camera zooms in (Snapzy's zoom segments): from `start` to `end` of the recording, `level` times, at
/// `focus` (a fraction of the cropped frame) or following the pointer when it is nil. Made from the clicks, or added on
/// the timeline; each is moved, stretched and set on its own.
public struct ZoomSegment: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var level: Double
    public var focus: CGPoint?

    public static let levels: ClosedRange<Double> = 1.25...4
    public static let standardLevel = 2.0
    /// The shortest a segment is, in seconds.
    public static let shortest = 0.5

    public init(id: UUID = UUID(), start: Double, end: Double, level: Double = ZoomSegment.standardLevel, focus: CGPoint? = nil) {
        self.id = id
        self.start = start
        self.end = max(end, start + Self.shortest)
        self.level = min(Self.levels.upperBound, max(Self.levels.lowerBound, level))
        self.focus = focus
    }

    public var length: Double { end - start }

    /// How far in the zoom is at `t`, 0 to 1: it eases in over its first `ramp` seconds and out over its last.
    public func amount(at t: Double) -> Double {
        guard t > start, t < end else { return 0 }
        let ramp = min(0.5, length / 3)
        let f = min(1, (t - start) / ramp, (end - t) / ramp)
        return f * f * (3 - 2 * f)
    }

    /// The zooms a recording's clicks suggest: clicks less than `gap` seconds apart share one, which starts a little before
    /// the first and holds a little after the last; at least `minimum` long, inside `duration`, never overlapping.
    public static func auto(from clicks: [CursorTrack.Point], duration: Double, gap: Double = 2.5, lead: Double = 0.6,
                            hold: Double = 1.6, minimum: Double = 1.5) -> [ZoomSegment] {
        guard duration > 0 else { return [] }
        var spans: [(Double, Double)] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) where click.t >= 0 && click.t <= duration {
            if let last = spans.last, click.t - last.1 < gap { spans[spans.count - 1].1 = click.t } else { spans.append((click.t, click.t)) }
        }
        var segments: [ZoomSegment] = []
        for (first, last) in spans {
            var a = max(0, first - lead), b = min(duration, last + hold)
            if b - a < minimum {
                b = min(duration, a + minimum)
                a = max(0, b - minimum)
            }
            if let prev = segments.last, a < prev.end {
                segments[segments.count - 1].end = max(prev.end, b)
            } else if b - a >= shortest {
                segments.append(ZoomSegment(start: a, end: b))
            }
        }
        return segments
    }
}

/// Everything the editor changes about a recording: the part kept (trim), the part of the frame kept (crop), the speed,
/// the backdrop round it and the zooms. A value: undo keeps the ones before.
public struct VideoEdit: Equatable, Sendable {
    /// The recording's length, seconds.
    public let duration: Double
    public var trimIn: Double
    public var trimOut: Double
    /// The part of the frame kept, a fraction of it from its top left; nil keeps all of it.
    public var crop: CGRect?
    public var speed: Double
    public var backdrop: Backdrop?
    public var zooms: [ZoomSegment]

    public static let speeds: [Double] = [0.5, 1, 1.5, 2, 3, 4]
    /// All of the frame, as a crop.
    public static let wholeFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The shortest part trim keeps, seconds.
    public static let shortest = 0.25
    /// The smallest crop, a fraction of the frame each way.
    public static let smallestCrop = 0.05

    public init(duration: Double, trimIn: Double = 0, trimOut: Double? = nil, crop: CGRect? = nil, speed: Double = 1,
                backdrop: Backdrop? = nil, zooms: [ZoomSegment] = []) {
        self.duration = max(0, duration)
        self.trimIn = trimIn
        self.trimOut = trimOut ?? duration
        self.crop = crop
        self.speed = speed
        self.backdrop = backdrop
        self.zooms = zooms
    }

    /// The export's length in seconds: the part kept, at its speed.
    public var length: Double { max(0, trimOut - trimIn) / speed }

    /// The recording's time `output` seconds into the export: the one mapping the export and the preview share.
    public func source(at output: Double) -> Double { trimIn + output * speed }

    /// The export's time for the recording's `source` seconds.
    public func output(at source: Double) -> Double { (source - trimIn) / speed }

    /// The trim moved: `in` and `out` inside the recording, at least `shortest` apart.
    public mutating func trim(in a: Double? = nil, out b: Double? = nil) {
        if let a { trimIn = min(max(0, a), trimOut - Self.shortest) }
        if let b { trimOut = max(min(duration, b), trimIn + Self.shortest) }
    }

    /// The crop made whole: inside the frame, never smaller than `smallestCrop`; all of the frame is no crop.
    public static func fitted(_ r: CGRect) -> CGRect? {
        let s = smallestCrop
        let x = min(max(0, r.minX), 1 - s), y = min(max(0, r.minY), 1 - s)
        let w = min(max(s, r.width), 1 - x), h = min(max(s, r.height), 1 - y)
        let fit = CGRect(x: x, y: y, width: w, height: h)
        return fit.width > 0.999 && fit.height > 0.999 ? nil : fit
    }

    /// The camera at the recording's time `t`: the part of the cropped frame on screen, a fraction of it from its top
    /// left, 1/zoom each way. It eases into each zoom, centred on the zoom's focus or the pointer (smoothed), and never
    /// shows anything outside the frame; with no zoom it is all of it.
    public func camera(at t: Double, cursor: CursorTrack?) -> CGRect {
        var best: (amount: Double, segment: ZoomSegment)?
        for z in zooms {
            let a = z.amount(at: t) * (z.level - 1)
            if a > 0, a > best?.amount ?? 0 { best = (a, z) }
        }
        guard let best else { return Self.wholeFrame }
        let scale = 1 + best.amount, f = best.amount / (best.segment.level - 1)
        let target = best.segment.focus ?? cursor?.smoothed(at: t).map(inCrop) ?? CGPoint(x: 0.5, y: 0.5)
        // From the middle to the target as it eases in, so the camera never swings sideways at the start.
        let centre = CGPoint(x: 0.5 + (target.x - 0.5) * f, y: 0.5 + (target.y - 0.5) * f)
        let side = 1 / scale
        return CGRect(x: min(max(0, centre.x - side / 2), 1 - side), y: min(max(0, centre.y - side / 2), 1 - side), width: side, height: side)
    }

    /// A place on the whole frame as a place on the cropped one.
    public func inCrop(_ p: CGPoint) -> CGPoint {
        guard let crop else { return p }
        return CGPoint(x: (p.x - crop.minX) / max(crop.width, 0.0001), y: (p.y - crop.minY) / max(crop.height, 0.0001))
    }
}

/// The export's file: MP4 in H.264 or HEVC, or an animated GIF.
public enum VideoFormat: String, CaseIterable, Sendable, Codable {
    case h264, hevc, gif

    public var title: String {
        switch self {
        case .h264: "MP4"
        case .hevc: "HEVC"
        case .gif: "GIF"
        }
    }

    public var fileExtension: String { self == .gif ? "gif" : "mp4" }
    /// A GIF's frames a second; an MP4 keeps the recording's.
    public static let gifFPS = 15
    /// A GIF's longest side at most, pixels: a bigger one is megabytes a second.
    public static let gifLongest: CGFloat = 1280
}

/// The export's size: the canvas as it is (at most 4096 a side), or its shorter side at 1080 or 720.
public enum VideoSize: String, CaseIterable, Sendable, Codable {
    case full, p1080, p720

    public var title: String {
        switch self {
        case .full: "Full"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }

    /// `canvas` (pixels) at this size for `format`: never bigger than it, both sides even.
    public func pixels(_ canvas: CGSize, format: VideoFormat) -> CGSize {
        let short = min(canvas.width, canvas.height), long = max(canvas.width, canvas.height)
        var k: CGFloat = switch self {
        case .full: 1
        case .p1080: min(1, 1080 / max(short, 1))
        case .p720: min(1, 720 / max(short, 1))
        }
        k = min(k, 4096 / max(long, 1))
        if format == .gif { k = min(k, VideoFormat.gifLongest / max(long, 1)) }
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * k / 2).rounded() * 2) }
        return CGSize(width: even(canvas.width), height: even(canvas.height))
    }
}

/// Where the recording sits in the export (P71): the cropped frame as a capture of `pointScale` pixels a point, so the
/// backdrop's padding, corners and shadow in points look the same round a video as round a capture of its size.
public struct VideoLayout: Equatable, Sendable {
    /// The canvas, pixels.
    public let canvas: CGSize
    /// The video's place on the canvas, pixels from its top left.
    public let spot: CGRect
    /// The kept part of the frame, pixels from its top left.
    public let crop: CGRect
    /// Pixels a backdrop point, at this layout's size.
    public let scale: CGFloat

    /// `edit`'s layout over a recording `source` pixels big, at full size.
    public init(source: CGSize, edit: VideoEdit) { self.init(source: source, crop: edit.crop, backdrop: edit.backdrop) }

    /// `source` is the recording's size in pixels; `out` scales the whole layout (the preview's and a smaller export's).
    public init(source: CGSize, crop: CGRect?, backdrop: Backdrop?, out: CGFloat = 1) {
        let c = crop ?? VideoEdit.wholeFrame
        self.crop = CGRect(x: c.minX * source.width, y: c.minY * source.height, width: c.width * source.width, height: c.height * source.height)
        let k = Self.pointScale(source)
        let area = CGSize(width: self.crop.width / k, height: self.crop.height / k)
        let s = k * out
        scale = s
        guard let backdrop else {
            canvas = CGSize(width: (area.width * s).rounded(), height: (area.height * s).rounded())
            spot = CGRect(origin: .zero, size: canvas)
            return
        }
        let points = backdrop.canvas(for: area), place = backdrop.spot(for: area)
        canvas = CGSize(width: (points.width * s).rounded(), height: (points.height * s).rounded())
        spot = CGRect(x: (place.minX * s).rounded(), y: (place.minY * s).rounded(), width: (area.width * s).rounded(), height: (area.height * s).rounded())
    }

    private init(canvas: CGSize, spot: CGRect, crop: CGRect, scale: CGFloat) {
        self.canvas = canvas
        self.spot = spot
        self.crop = crop
        self.scale = scale
    }

    /// This layout drawn exactly `size` big (an export's even size): the spot and the scale follow.
    public func fitted(to size: CGSize) -> VideoLayout {
        let kx = size.width / max(canvas.width, 1), ky = size.height / max(canvas.height, 1)
        let spot = CGRect(x: (self.spot.minX * kx).rounded(), y: (self.spot.minY * ky).rounded(),
                          width: (self.spot.width * kx).rounded(), height: (self.spot.height * ky).rounded())
        return VideoLayout(canvas: size, spot: spot, crop: crop, scale: scale * kx)
    }

    /// A recording's pixels a point: 1 up to 1440 pixels on its longer side, more above it (a Retina recording's 2).
    public static func pointScale(_ source: CGSize) -> CGFloat { max(1, max(source.width, source.height) / 1440) }
}
