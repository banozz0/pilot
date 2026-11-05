import CoreGraphics
import Foundation

// The video editor's edit (P71, after Snapzy's Studio, BSD-3: Packaging/Snapzy-LICENSE.txt): what a recording becomes on
// export, kept apart from the screen so the camera's maths is tested on its own. Every time here is the recording's own
// (source) time unless it says output; every place is a fraction of the frame from its top left.

/// Where the pointer was while a recording ran, and where it clicked (P71), on the file's timeline (pauses cut out as the
/// frames are), each place a fraction of the recorded frame from its top left (outside it below 0 or above 1). The video
/// editor's auto zoom starts from the clicks and follows the pointer. An older recording sampled it with each new frame
/// and has the pointer in its pixels; a `drawn` one (T29) kept it out, sampled each move, and keeps the pointer's shapes,
/// so the export draws it (R1–R4).
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

    /// One pointer shape the system showed (the arrow, the I-beam, a hand): a PNG drawn `scale` pixels a point, `size`
    /// points big, its hot spot `hot` points from its top left.
    public struct Shape: Equatable, Sendable, Codable {
        public var png: Data
        public var scale: Double
        public var size: CGSize
        public var hot: CGPoint

        public init(png: Data, scale: Double, size: CGSize, hot: CGPoint) {
            self.png = png
            self.scale = scale
            self.size = size
            self.hot = hot
        }
    }

    /// From `t` on the pointer had `shape`, an index into `shapes`.
    public struct ShapeChange: Equatable, Sendable {
        public var t: Double
        public var shape: Int

        public init(t: Double, shape: Int) {
            self.t = t
            self.shape = shape
        }
    }

    public var moves: [Point]
    public var clicks: [Point]
    /// T29: the recording has no pointer in its pixels; the export draws it from this track.
    public var drawn: Bool
    /// The recorded frame's size in points, for the pointer's size in the recording's pixels; nil on older tracks.
    public var frame: CGSize?
    public var shapes: [Shape]
    public var shapeChanges: [ShapeChange]
    /// The recording's own pointer settings, from Captures when it was made (Show clicks turns Click ring on): where
    /// the editor starts, and what the file Pilot hands out draws (Q821). Nil on older tracks.
    public var look: PointerLook?

    public init(moves: [Point] = [], clicks: [Point] = [], drawn: Bool = false, frame: CGSize? = nil, shapes: [Shape] = [],
                shapeChanges: [ShapeChange] = [], look: PointerLook? = nil) {
        self.moves = moves
        self.clicks = clicks
        self.drawn = drawn
        self.frame = frame
        self.shapes = shapes
        self.shapeChanges = shapeChanges
        self.look = look
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
    /// The shapes and the frame stay; the clicks are in the moves.
    public var path: CursorTrack {
        var path = self
        path.moves = merged
        path.clicks = []
        return path
    }

    // Kept as flat lists of numbers, three to a point, four decimals: a minute is a few tens of kilobytes. The shapes'
    // PNGs go in as base64, a few kilobytes each, so a track is still one file that moves with its recording.
    private enum CodingKeys: String, CodingKey { case moves, clicks, drawn, frame, shapes, shapeAt, look }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func flat(_ points: [Point]) -> [Double] { points.flatMap { [$0.t, $0.x, $0.y].map { ($0 * 10_000).rounded() / 10_000 } } }
        try c.encode(flat(moves), forKey: .moves)
        try c.encode(flat(clicks), forKey: .clicks)
        guard drawn else { return }
        try c.encode(true, forKey: .drawn)
        try c.encodeIfPresent(frame.map { [$0.width, $0.height] }, forKey: .frame)
        try c.encode(shapes, forKey: .shapes)
        try c.encode(shapeChanges.flatMap { [($0.t * 10_000).rounded() / 10_000, Double($0.shape)] }, forKey: .shapeAt)
        try c.encodeIfPresent(look, forKey: .look)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func points(_ key: CodingKeys) throws -> [Point] {
            let n = try c.decodeIfPresent([Double].self, forKey: key) ?? []
            return stride(from: 0, to: n.count - n.count % 3, by: 3).map { Point(t: n[$0], x: n[$0 + 1], y: n[$0 + 2]) }
        }
        moves = try points(.moves)
        clicks = try points(.clicks)
        // An older track has none of these: its recording has the pointer in its pixels.
        drawn = try c.decodeIfPresent(Bool.self, forKey: .drawn) ?? false
        frame = try c.decodeIfPresent([Double].self, forKey: .frame).flatMap { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
        let shapes = try c.decodeIfPresent([Shape].self, forKey: .shapes) ?? []
        self.shapes = shapes
        let n = try c.decodeIfPresent([Double].self, forKey: .shapeAt) ?? []
        shapeChanges = stride(from: 0, to: n.count - n.count % 2, by: 2).compactMap { i in
            let shape = Int(n[i + 1])
            return shapes.indices.contains(shape) ? ShapeChange(t: n[i], shape: shape) : nil
        }
        look = try c.decodeIfPresent(PointerLook.self, forKey: .look)
    }

    /// Where a recording's track is kept: `<file name>.json` in `folder` (Pilot's support folder's Recording pointers), by
    /// the file's name, which is unique when Pilot writes it. A recording moved or renamed loses its track: the editor then
    /// opens with no auto zoom.
    public static func file(for recording: URL, in folder: URL) -> URL {
        folder.appending(path: recording.lastPathComponent + ".json", directoryHint: .notDirectory)
    }

    /// Writes the track for `recording`, and keeps `folder` to `keep` tracks by deleting the oldest whose recording is
    /// gone; a track whose recording is still there is never deleted (a drawn track is a new recording's only pointer),
    /// even past `keep`. A recording is looked for by its file name beside `recording` and in each of `alsoIn`, then by
    /// the bookmark each track carries (`bookmarkName`), so one moved elsewhere keeps its track; one in a Trash does not.
    public func save(for recording: URL, in folder: URL, keep: Int = 200, alsoIn: [URL] = []) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = Self.file(for: recording, in: folder)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        if let mark = try? recording.bookmarkData(options: .minimalBookmark) {
            _ = mark.withUnsafeBytes { setxattr(file.path(percentEncoded: false), Self.bookmarkName, $0.baseAddress, mark.count, 0, 0) }
        }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        guard all.count > keep else { return }
        let folders = Set(([recording.deletingLastPathComponent()] + alsoIn).map(\.standardizedFileURL))
        func there(_ name: String) -> Bool {
            folders.contains { FileManager.default.fileExists(atPath: $0.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false)) }
        }
        let dated = all.map { ($0, (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast) }
        var over = all.count - keep
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }) where over > 0 && !there(url.deletingPathExtension().lastPathComponent) && !Self.bookmarked(url) {
            try? FileManager.default.removeItem(at: url)
            over -= 1
        }
    }

    /// The extended attribute on a track file holding its recording's bookmark.
    public static let bookmarkName = "dev.banozz.pilot.recording-bookmark"

    /// Whether the bookmark on the track file `track` finds its recording, wherever it was moved, outside any Trash.
    static func bookmarked(_ track: URL) -> Bool {
        let path = track.path(percentEncoded: false), size = getxattr(path, bookmarkName, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var mark = Data(count: size)
        guard mark.withUnsafeMutableBytes({ getxattr(path, bookmarkName, $0.baseAddress, size, 0, 0) }) == size else { return false }
        var stale = false
        guard let recording = try? URL(resolvingBookmarkData: mark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return false }
        return !recording.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
            && FileManager.default.fileExists(atPath: recording.path(percentEncoded: false))
    }

    /// The track kept for `recording`; nil when there is none.
    public static func load(for recording: URL, in folder: URL) -> CursorTrack? {
        guard let data = try? Data(contentsOf: file(for: recording, in: folder)) else { return nil }
        return try? JSONDecoder().decode(CursorTrack.self, from: data)
    }

    /// R7: the stretches worth cutting, where the pointer stood still or was off the frame for at least `least` seconds,
    /// each drawn in by `margin` at both ends so the cut never lands on a move. Recorder samples the pointer with each new
    /// frame (older tracks) or each move (drawn ones), so a gap between samples is a still pointer too. A click ends a
    /// stretch.
    public func stillParts(duration: Double, least: Double = 3, margin: Double = 0.4, epsilon: Double = 0.002) -> [ClosedRange<Double>] {
        let all = merged, clickTimes = Set(clicks.map(\.t))
        guard duration > 0, !all.isEmpty else { return [] }
        func outside(_ p: Point) -> Bool { p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1 }
        var spans: [(Double, Double)] = [(0, all[0].t)]
        var anchor = all[0]
        for p in all.dropFirst() {
            let same = abs(p.x - anchor.x) < epsilon && abs(p.y - anchor.y) < epsilon
            let away = outside(p) && outside(anchor)
            if same || away, !clickTimes.contains(p.t) { continue }
            spans.append((anchor.t, p.t))
            anchor = p
        }
        spans.append((anchor.t, duration))
        return spans.compactMap { a, b in
            guard b - a >= least else { return nil }
            let lo = max(0, a + (a > 0 ? margin : 0)), hi = min(duration, b - (b < duration ? margin : 0))
            return hi - lo >= 1 ? lo...hi : nil
        }
    }
}

/// T29: how the export draws the pointer. R1 to R3 need a recording that kept the pointer out of its pixels (a drawn
/// track); R4 rings every click of any recording with a track. All off draws the pointer as it was recorded.
public struct PointerLook: Equatable, Sendable, Codable {
    /// R1: shaky movement comes out steady.
    public var smooth: Bool
    /// R2: the pointer this many times its recorded size.
    public var size: Double
    /// R3: the pointer fades once it has stood still a moment, and is back just before it moves.
    public var hideStill: Bool
    /// R4: Pilot's halo ripple (T4) on every click.
    public var clickRing: Bool

    public static let sizes: [Double] = [1, 1.5, 2, 3]

    public init(smooth: Bool = false, size: Double = 1, hideStill: Bool = false, clickRing: Bool = false) {
        self.smooth = smooth
        self.size = size
        self.hideStill = hideStill
        self.clickRing = clickRing
    }
}

/// A track made ready for drawing a frame at a time (T29): its places in time order, when it moved, its clicks and its
/// shapes, each read by a binary search. Every answer depends only on `t`, so a seek in the preview shows what the export
/// draws.
public struct DrawnPointer: Sendable {
    public let track: CursorTrack
    /// The samples, clicks folded in, in time order.
    private let path: CursorTrack
    private let clicks: [Double]
    /// When the pointer arrived somewhere new: the first sample, each one away from the one before, each click.
    private let moved: [Double]

    /// R1's window, seconds, and how near a click the pointer goes back to its own place, so the click lands on it.
    public static let smoothWindow = 0.3, clickHold = 0.15
    /// R3: still this long, the pointer fades out over `fadeOut`; it fades back in over the `fadeIn` before it moves.
    public static let stillAfter = 1.5, fadeOut = 0.4, fadeIn = 0.15
    /// R4: how long a click's ring plays (T4's ripple).
    public static let ringSeconds = 0.46

    public init(_ track: CursorTrack) {
        self.track = track
        path = track.path
        let clicks = track.clicks.map(\.t).sorted()
        self.clicks = clicks
        var moved: [Double] = []
        var last: CursorTrack.Point?
        for p in path.moves {
            if let l = last, abs(p.x - l.x) < 0.000_5, abs(p.y - l.y) < 0.000_5 { continue }
            moved.append(p.t)
            last = p
        }
        self.moved = Array(Set(moved + clicks)).sorted()
    }

    /// Where the pointer is at `t`; R1 averages it over `smoothWindow` round `t`, back to its own place at a click.
    public func place(at t: Double, smooth: Bool) -> CGPoint? {
        guard let raw = path.place(at: t) else { return nil }
        guard smooth else { return raw }
        // Weighted to the middle, so the pointer follows a turn without lagging behind it.
        let taps = 11
        var x = 0.0, y = 0.0, total = 0.0
        for i in 0..<taps {
            let k = Double(i) / Double(taps - 1)
            let w = 1 - abs(k * 2 - 1) + 0.1
            guard let p = path.place(at: t - Self.smoothWindow / 2 + Self.smoothWindow * k) else { continue }
            x += p.x * w
            y += p.y * w
            total += w
        }
        guard total > 0 else { return raw }
        let near = Self.nearest(clicks, to: t).map { abs($0 - t) } ?? .infinity
        let f = min(1, near / Self.clickHold)
        return CGPoint(x: raw.x + (x / total - raw.x) * f, y: raw.y + (y / total - raw.y) * f)
    }

    /// R3: how much of the pointer shows at `t`, 0 to 1.
    public func shown(at t: Double) -> Double {
        let i = Self.firstAfter(moved, t)
        let last = i > 0 ? moved[i - 1] : (moved.first ?? t)
        let still = t - last
        let out = still <= Self.stillAfter ? 1 : max(0, 1 - (still - Self.stillAfter) / Self.fadeOut)
        let back = i < moved.count ? max(0, 1 - (moved[i] - t) / Self.fadeIn) : 0
        return max(out, back)
    }

    /// The pointer's shape at `t`: the last change at or before it, else the first one; nil with no shapes.
    public func shape(at t: Double) -> Int? {
        let changes = track.shapeChanges
        guard let first = changes.first else { return track.shapes.isEmpty ? nil : 0 }
        var lo = 0, hi = changes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if changes[mid].t <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? changes[lo - 1].shape : first.shape
    }

    /// R4: the clicks whose ring plays at `t`: where each was, and how long ago.
    public func rings(at t: Double) -> [(place: CGPoint, age: Double)] {
        track.clicks.filter { $0.t <= t && $0.t > t - Self.ringSeconds }.map { ($0.place, t - $0.t) }
    }

    /// The index of the first time in `sorted` after `t`.
    private static func firstAfter(_ sorted: [Double], _ t: Double) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func nearest(_ sorted: [Double], to t: Double) -> Double? {
        let i = firstAfter(sorted, t)
        return [i - 1, i].filter(sorted.indices.contains).map { sorted[$0] }.min { abs($0 - t) < abs($1 - t) }
    }
}

/// R5, R6: one part of the recording between two splits, from `start` to `end` (the recording's seconds): cut out of the
/// export, or kept at its own speed (nil follows the clip's). An edit's parts cover the recording end to end.
public struct ClipPart: Equatable, Sendable, Codable {
    public var start: Double
    public var end: Double
    public var speed: Double?
    public var cut: Bool

    /// A part's own speeds, for the waiting worth speeding past.
    public static let speeds: [Double] = [0.5, 1, 2, 4, 8]

    public init(start: Double, end: Double, speed: Double? = nil, cut: Bool = false) {
        self.start = start
        self.end = end
        self.speed = speed
        self.cut = cut
    }

    public var length: Double { end - start }
    public func contains(_ t: Double) -> Bool { t >= start && t < end }
}

/// R8: a part of the frame blurred for a time, to hide a key or an email: from `start` to `end` of the recording, over
/// `area` (a fraction of the whole frame from its top left).
public struct BlurSpan: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var area: CGRect

    /// Where a new blur sits: a band across the middle, moved and sized on the stage.
    public static let standardArea = CGRect(x: 0.3, y: 0.44, width: 0.4, height: 0.12)
    public static let shortest = 0.25
    /// The smallest area, a fraction of the frame each way.
    public static let smallest = 0.02

    public init(id: UUID = UUID(), start: Double, end: Double, area: CGRect = BlurSpan.standardArea) {
        self.id = id
        self.start = start
        self.end = max(end, start + Self.shortest)
        self.area = Self.fitted(area)
    }

    public var length: Double { end - start }
    public func contains(_ t: Double) -> Bool { t >= start && t < end }

    /// `r` inside the frame and at least `smallest` each way.
    public static func fitted(_ r: CGRect) -> CGRect {
        let s = smallest
        let w = min(1, max(s, r.width)), h = min(1, max(s, r.height))
        return CGRect(x: min(max(0, r.minX), 1 - w), y: min(max(0, r.minY), 1 - h), width: w, height: h)
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

/// R9: the export's shape. Any but `recorded` makes the frame that shape and aims the camera inside the recording: it
/// follows the pointer (smoothed), and each zoom goes in from there (Screen Studio's vertical and square).
public enum VideoShape: String, CaseIterable, Sendable, Codable {
    case recorded, vertical, square

    public var title: String {
        switch self {
        case .recorded: "Auto"
        case .vertical: "9:16"
        case .square: "1:1"
        }
    }

    /// Width over height; nil keeps the recording's (cropped) shape.
    public var aspect: CGFloat? {
        switch self {
        case .recorded: nil
        case .vertical: 9.0 / 16
        case .square: 1
        }
    }
}

/// R12: the whole look of an edit saved under a name, for the next recording: the backdrop, the shape, motion blur and
/// how the pointer is drawn. Never a clip's own trim, parts, zooms or blurs.
public struct VideoPreset: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var backdrop: Backdrop?
    public var shape: VideoShape
    public var motionBlur: Bool
    public var pointer: PointerLook

    public init(id: UUID = UUID(), name: String, backdrop: Backdrop?, shape: VideoShape = .recorded, motionBlur: Bool = false,
                pointer: PointerLook = PointerLook()) {
        self.id = id
        self.name = name
        self.backdrop = backdrop
        self.shape = shape
        self.motionBlur = motionBlur
        self.pointer = pointer
    }

    /// The same look as `other`, whatever each is called.
    public func sameLook(_ other: VideoPreset) -> Bool {
        backdrop == other.backdrop && shape == other.shape && motionBlur == other.motionBlur && pointer == other.pointer
    }

    /// "Look 1", "Look 2": the first number no preset has.
    public static func nextName(_ presets: [VideoPreset]) -> String {
        let taken = Set(presets.map(\.name))
        return (1...).lazy.map { "Look \($0)" }.first { !taken.contains($0) }!
    }
}

/// Everything the editor changes about a recording: the part kept (trim), its parts cut or at their own speed, the part
/// of the frame kept (crop), the clip's speed, the backdrop round it, the export's shape, the zooms, motion blur, the
/// blurs and how the pointer is drawn. A value: undo keeps the ones before.
public struct VideoEdit: Equatable, Sendable {
    /// The recording's length, seconds.
    public let duration: Double
    public var trimIn: Double
    public var trimOut: Double
    /// The recording split into parts (R5, R6), end to end; one part until it is split.
    public private(set) var parts: [ClipPart]
    /// The part of the frame kept, a fraction of it from its top left; nil keeps all of it.
    public var crop: CGRect?
    /// The clip's speed: every part's that has none of its own.
    public var speed: Double
    public var backdrop: Backdrop?
    public var zooms: [ZoomSegment]
    public var blurs: [BlurSpan]
    /// R1–R4: how the export draws the pointer (T29).
    public var pointer = PointerLook()
    /// R9: the export's shape.
    public var shape = VideoShape.recorded
    /// R10: a moving camera (a zoom easing in or out, the shape following the pointer) is blurred along its move.
    public var motionBlur = false

    public static let speeds: [Double] = [0.5, 1, 1.5, 2, 3, 4]
    /// All of the frame, as a crop.
    public static let wholeFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The shortest part trim keeps, seconds.
    public static let shortest = 0.25
    /// The smallest crop, a fraction of the frame each way.
    public static let smallestCrop = 0.05

    public init(duration: Double, trimIn: Double = 0, trimOut: Double? = nil, crop: CGRect? = nil, speed: Double = 1,
                backdrop: Backdrop? = nil, zooms: [ZoomSegment] = [], blurs: [BlurSpan] = []) {
        self.duration = max(0, duration)
        self.trimIn = trimIn
        self.trimOut = trimOut ?? duration
        parts = [ClipPart(start: 0, end: max(0, duration))]
        self.crop = crop
        self.speed = speed
        self.backdrop = backdrop
        self.zooms = zooms
        self.blurs = blurs
    }

    // MARK: The time map

    /// One stretch the export plays: the recording's `start` to `end` at `rate`, from the export's second `at`.
    public struct Piece: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let rate: Double
        public let at: Double

        public var length: Double { (end - start) / rate }
    }

    /// What the export plays, in order: each part not cut, inside the trim, at its speed (the clip's when it has none).
    public var pieces: [Piece] {
        var all: [Piece] = [], at = 0.0
        for p in parts where !p.cut {
            let a = max(p.start, trimIn), b = min(p.end, trimOut)
            guard b - a > 0.000_1 else { continue }
            let piece = Piece(start: a, end: b, rate: p.speed ?? speed, at: at)
            all.append(piece)
            at += piece.length
        }
        return all
    }

    /// The export's length in seconds: the parts kept, each at its speed.
    public var length: Double { pieces.last.map { $0.at + $0.length } ?? 0 }

    /// The recording's time `output` seconds into the export: the one mapping the export and the preview share.
    public func source(at output: Double) -> Double {
        let all = pieces
        guard let piece = all.last(where: { $0.at <= output }) ?? all.first else { return trimIn }
        return min(piece.end, piece.start + max(0, output - piece.at) * piece.rate)
    }

    /// The export's time for the recording's `source` seconds; a time in a cut or before the trim is where the export goes
    /// on from it.
    public func output(at source: Double) -> Double {
        let all = pieces
        guard let piece = all.first(where: { source < $0.end }) else { return length }
        return piece.at + max(0, source - piece.start) / piece.rate
    }

    /// Where playing from the recording's `t` goes on and at what rate: `t` itself inside a kept piece, the next piece's
    /// start from a cut, nil past the last.
    public func playing(from t: Double) -> (time: Double, rate: Double)? {
        guard let piece = pieces.first(where: { t < $0.end - 0.01 }) else { return nil }
        return (max(t, piece.start), piece.rate)
    }

    // MARK: Parts

    /// The index of the part at the recording's `t`.
    public func part(at t: Double) -> Int {
        parts.firstIndex { $0.contains(t) } ?? max(0, parts.count - 1)
    }

    /// R5: the part at `t` split in two there; false when `t` is within `shortest` of its edges.
    @discardableResult
    public mutating func split(at t: Double) -> Bool {
        let i = part(at: t), p = parts[i]
        guard t - p.start >= Self.shortest, p.end - t >= Self.shortest else { return false }
        parts[i].end = t
        parts.insert(ClipPart(start: t, end: p.end, speed: p.speed, cut: p.cut), at: i + 1)
        return true
    }

    /// R5: the part at `i` cut out of the export, or kept again.
    public mutating func setCut(_ i: Int, _ cut: Bool) {
        guard parts.indices.contains(i) else { return }
        parts[i].cut = cut
    }

    /// R6: the part at `i` at its own speed, or the clip's (nil).
    public mutating func setSpeed(ofPart i: Int, _ speed: Double?) {
        guard parts.indices.contains(i) else { return }
        parts[i].speed = speed
    }

    /// R7: each of `spans` split off and cut.
    public mutating func cut(_ spans: [ClosedRange<Double>]) {
        for span in spans {
            split(at: span.lowerBound)
            split(at: span.upperBound)
            for i in parts.indices where parts[i].start >= span.lowerBound - 0.000_1 && parts[i].end <= span.upperBound + 0.000_1 { parts[i].cut = true }
        }
    }

    /// Whether the recording's `t` is in a part cut out.
    public func isCut(_ t: Double) -> Bool { parts[part(at: t)].cut }

    /// R8: the areas blurred at the recording's `t`.
    public func blurred(at t: Double) -> [CGRect] { blurs.filter { $0.contains(t) }.map(\.area) }

    // MARK: The look (R12)

    /// This edit's look, as an unsaved preset.
    public var look: VideoPreset { VideoPreset(name: "", backdrop: backdrop, shape: shape, motionBlur: motionBlur, pointer: pointer) }

    /// `preset`'s look on this edit; its trim, parts, zooms and blurs stay.
    public mutating func apply(_ preset: VideoPreset) {
        backdrop = preset.backdrop
        shape = preset.shape
        motionBlur = preset.motionBlur
        pointer = preset.pointer
    }

    // MARK: Motion blur (R10)

    /// R10's shutter: half a frame at 30 a second, in the export's seconds.
    public static let shutter = 1.0 / 60
    /// The fewest and most shots one frame averages: a long move takes more, so it smears rather than doubles.
    public static let shutterTaps = 5, mostShutterTaps = 16

    /// The recording's times one export frame at its `t` blurs over: `taps` across the shutter at its piece's rate, kept
    /// inside that piece so a cut never blends two places. Just `t` with motion blur off.
    public func shutterTimes(at t: Double, taps: Int = VideoEdit.shutterTaps) -> [Double] {
        guard motionBlur, let piece = pieces.first(where: { t >= $0.start - 0.000_1 && t <= $0.end + 0.000_1 }) else { return [t] }
        let n = max(2, taps), span = Self.shutter * piece.rate
        return (0..<n).map { min(piece.end, max(piece.start, t + span * (Double($0) / Double(n - 1) - 0.5))) }
    }

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

    /// R9: how long the shape's camera averages the pointer over, seconds: calmer than a zoom's, so it drifts after it.
    public static let followWindow = 1.6

    /// The camera at the recording's time `t`: the part of the cropped frame on screen, a fraction of it from its top
    /// left, `window` (the layout's, a shape's part of the frame) over the zoom each way. It eases into each zoom,
    /// centred on the zoom's focus or the pointer (smoothed), and never shows anything outside the frame; with no zoom
    /// it is all of the window, which follows the pointer when it is smaller than the frame (R9).
    public func camera(at t: Double, cursor: CursorTrack?, window: CGSize) -> CGRect {
        var best: (amount: Double, segment: ZoomSegment)?
        for z in zooms {
            let a = z.amount(at: t) * (z.level - 1)
            if a > 0, a > best?.amount ?? 0 { best = (a, z) }
        }
        let shaped = window.width < 1 || window.height < 1
        guard best != nil || shaped else { return Self.wholeFrame }
        let middle = CGPoint(x: 0.5, y: 0.5)
        let base = shaped ? cursor?.smoothed(at: t, window: Self.followWindow).map(inCrop) ?? middle : middle
        var scale = 1.0, f = 0.0, target = base
        if let best {
            scale = 1 + best.amount
            f = best.amount / (best.segment.level - 1)
            target = best.segment.focus ?? cursor?.smoothed(at: t).map(inCrop) ?? middle
        }
        // From the middle (or the shape's place) to the target as it eases in, so the camera never swings sideways at the start.
        let centre = CGPoint(x: base.x + (target.x - base.x) * f, y: base.y + (target.y - base.y) * f)
        let w = window.width / scale, h = window.height / scale
        return CGRect(x: min(max(0, centre.x - w / 2), 1 - w), y: min(max(0, centre.y - h / 2), 1 - h), width: w, height: h)
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

    /// `canvas` (pixels) at this size for `format`: never bigger than it, both sides even. A shape's (R9) 1080p and 720p
    /// are that shape's standard pixels, 1080 × 1920 or 720 × 720, grown when the recording is smaller: a vertical
    /// export is for a phone's whole screen.
    public func pixels(_ canvas: CGSize, format: VideoFormat, shape: VideoShape = .recorded) -> CGSize {
        if let aspect = shape.aspect, self != .full {
            let short: CGFloat = self == .p1080 ? 1080 : 720
            let long = (short * max(aspect, 1 / aspect)).rounded()
            var size = aspect >= 1 ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
            if format == .gif, max(size.width, size.height) > VideoFormat.gifLongest {
                let k = VideoFormat.gifLongest / max(size.width, size.height)
                size = CGSize(width: (size.width * k / 2).rounded() * 2, height: (size.height * k / 2).rounded() * 2)
            }
            return size
        }
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
/// backdrop's padding, corners and shadow in points look the same round a video as round a capture of its size. A shape
/// (R9) makes the canvas that shape: the video's spot takes the cropped frame's whole height (or width) inside the
/// padding, and the camera shows that `window` of the frame.
public struct VideoLayout: Equatable, Sendable {
    /// The canvas, pixels.
    public let canvas: CGSize
    /// The video's place on the canvas, pixels from its top left.
    public let spot: CGRect
    /// The kept part of the frame, pixels from its top left.
    public let crop: CGRect
    /// Pixels a backdrop point, at this layout's size.
    public let scale: CGFloat
    /// The part of the cropped frame the spot shows with no zoom, a fraction of it each way: all of it but for a shape.
    public let window: CGSize

    /// `edit`'s layout over a recording `source` pixels big, at full size.
    public init(source: CGSize, edit: VideoEdit) { self.init(source: source, crop: edit.crop, backdrop: edit.backdrop, shape: edit.shape) }

    /// `source` is the recording's size in pixels; `out` scales the whole layout (the preview's and a smaller export's).
    public init(source: CGSize, crop: CGRect?, backdrop: Backdrop?, shape: VideoShape = .recorded, out: CGFloat = 1) {
        let c = crop ?? VideoEdit.wholeFrame
        self.crop = CGRect(x: c.minX * source.width, y: c.minY * source.height, width: c.width * source.width, height: c.height * source.height)
        let k = Self.pointScale(source)
        let area = CGSize(width: self.crop.width / k, height: self.crop.height / k)
        let s = k * out
        scale = s
        if let aspect = shape.aspect {
            // The spot as tall as the frame and the canvas round it the shape; too wide for the frame, as wide instead.
            // The padding is at most a quarter of the frame's shorter side, so the spot never vanishes.
            let a = max(area.width, 1), b = max(area.height, 1)
            let pad = min(backdrop?.pad ?? 0, min(a, b) / 4)
            var spotW = (b + 2 * pad) * aspect - 2 * pad, spotH = b
            if spotW > a { (spotW, spotH) = (a, (a + 2 * pad) / aspect - 2 * pad) }
            let w = spotW + 2 * pad, h = spotH + 2 * pad
            canvas = CGSize(width: (w * s).rounded(), height: (h * s).rounded())
            spot = CGRect(x: (pad * s).rounded(), y: (pad * s).rounded(), width: canvas.width - 2 * (pad * s).rounded(), height: canvas.height - 2 * (pad * s).rounded())
            window = CGSize(width: min(1, spotW / a), height: min(1, spotH / b))
            return
        }
        window = CGSize(width: 1, height: 1)
        guard let backdrop else {
            canvas = CGSize(width: (area.width * s).rounded(), height: (area.height * s).rounded())
            spot = CGRect(origin: .zero, size: canvas)
            return
        }
        let points = backdrop.canvas(for: area), place = backdrop.spot(for: area)
        canvas = CGSize(width: (points.width * s).rounded(), height: (points.height * s).rounded())
        spot = CGRect(x: (place.minX * s).rounded(), y: (place.minY * s).rounded(), width: (area.width * s).rounded(), height: (area.height * s).rounded())
    }

    private init(canvas: CGSize, spot: CGRect, crop: CGRect, scale: CGFloat, window: CGSize) {
        self.canvas = canvas
        self.spot = spot
        self.crop = crop
        self.scale = scale
        self.window = window
    }

    /// This layout drawn exactly `size` big (an export's even size): the spot and the scale follow.
    public func fitted(to size: CGSize) -> VideoLayout {
        let kx = size.width / max(canvas.width, 1), ky = size.height / max(canvas.height, 1)
        let spot = CGRect(x: (self.spot.minX * kx).rounded(), y: (self.spot.minY * ky).rounded(),
                          width: (self.spot.width * kx).rounded(), height: (self.spot.height * ky).rounded())
        return VideoLayout(canvas: size, spot: spot, crop: crop, scale: scale * kx, window: window)
    }

    /// A recording's pixels a point: 1 up to 1440 pixels on its longer side, more above it (a Retina recording's 2).
    public static func pointScale(_ source: CGSize) -> CGFloat { max(1, max(source.width, source.height) / 1440) }
}
