/// A scrolling capture's stitcher (spec `capture.html` CP11; Q159, and Sven's build 52: auto-scroll and upward). Frames
/// of one area arrive as the page scrolls; each new frame is matched against the last one kept by its rows, and the rows
/// that scrolled into view are added below (scrolling down) or above (scrolling up). The first move sets the direction;
/// a frame that moved the other way is skipped. Rows that stay put at the top and the bottom of both frames (a sticky
/// header, a toolbar, a status line) are kept once: the header at the top of the result, the footer at its foot.
///
/// A match needs most rows, not every row, to agree: a hover highlight under the pointer, a blinking caret or an animated
/// badge changes a few rows between frames, and an exact match failed on every real page (Sven, build 52: the capture
/// came back one frame tall). Rows are compared by a hash that leaves out the right edge, where macOS draws its overlay
/// scroll bar while scrolling. A page that scrolls over a backdrop that stays put (a see-through window over a blurred
/// wallpaper) never repeats a row, so when no hash matches the rows are compared by their edges instead, which a smooth
/// backdrop has none of (Sven, build 54: Ghostex's chat came back one frame tall, 94 of 95 frames unmatched). A row stays
/// put when only a few of its pixels changed, or changed by a shade: a glass composer redraws a level or three as the
/// page moves under it and its caret blinks, which an exact row never allowed (Sven, build 58: the composer was stitched
/// into the middle and most scrolls missed). New rows are cut where the moving part ended at the first move, never at a
/// frame's own footer, and a frame with half its moving part in place is no move: Ghostex's composer grows at the foot of
/// the chat, and its rising lines were stitched in as the page (Sven, build 59). Over a backdrop that stays put, each
/// band of new rows carries the same stretch of it, the window's foot: a sawtooth of hard seams down the result (Sven,
/// build 63: a wallpaper falling from red-brown to navy within one step, ~175, far past what easing the seam could hide).
/// So once a move was found by edges, the backdrop is worked out as what stays put across the frames, and every row of
/// the result trades the stretch it carried for one backdrop: the window's, stretched over the result's height. Only when
/// the page's rows did not repeat at that move, nor at an earlier one: an opaque page whose thumbnails load as it scrolls
/// misses the row match by a few rows and is found by edges too, and the swap smeared every row of it (Sven, build 66:
/// YouTube). The swap's backdrop is 16 column bins wide, and a wallpaper streaked finer than that still broke at every
/// seam (Sven, build 83: Pilot's own Settings, bands and a dark block at a card's edge), so over such a backdrop each new
/// frame also fades into the rows it shares with the result next to its new ones (`fade`), and no seam is a cut.
public struct ScrollStitch: Sendable {
    public enum Added: Equatable, Sendable {
        /// The first frame: the result so far.
        case first
        /// Nothing moved.
        case unchanged
        /// `rows` new rows were added below (scrolling down) or above (scrolling up).
        case appended(Int)
        /// No overlap with the last frame kept, or a move against the direction: skipped.
        case noMatch
        /// The result is as tall as it may get; nothing more is added.
        case full
    }

    public enum Direction: Equatable, Sendable { case down, up }

    /// Pixels a side, four bytes each (any order), rows top first.
    public let width: Int, frameHeight: Int
    /// How tall the result may get.
    public let limit: Int
    /// Columns at the right left out of the row hash: the overlay scroll bar's room.
    public let ignoredRight: Int
    /// The share of overlapping rows that must agree for a match.
    public static let agreement = 0.8
    /// The share of a frame's rows in place, with no move found, that makes it a page that did not move.
    static let inPlace = 0.75
    /// The most a pixel's blue, green and red may change together and still be the same pixel: glass redrawing a shade
    /// (Ghostex's composer changes by 3 at most).
    static let shade = 8
    /// The share of rows repeating at a move found by edges under which the page is over a backdrop that stays put: none
    /// repeat there, while an opaque page with thumbnails loading repeats most (YouTube's 0.66 to 0.8).
    static let backdropRepeats = 0.5
    /// How strongly the backdrop worked out is kept smooth from row to row, against the steps measured between frames.
    static let backdropSmooth: Float = 0.05
    /// The rows either side the swapped backdrop is averaged over (`swapBackdrop`).
    static let backdropBlur = 48
    /// A pixel this far from the backdrop (blue, green and red together) is the page's own, text say, and keeps its colour;
    /// nearer, it takes that share less of the swap: a see-through card all of it, an anti-aliased edge part.
    static let opaque: Float = 384
    /// In the scroll bar's room, a pixel that changed more than this (blue, green and red together) is the bar, not
    /// the backdrop, and is not faded (`fade`).
    static let scrollBar = 96
    /// The direction, once the page first moved.
    public private(set) var direction: Direction?
    private var header: [UInt8] = []
    private var body: [UInt8] = []
    /// Rows added above while scrolling up, bottom first: the top row of the result's moving part is the last one.
    private var above: [UInt8] = []
    private var footer: [UInt8] = []
    private var last: [UInt64] = []
    /// The last frame kept, and its edges once worked out, for the edge match.
    private var lastFrame: [UInt8] = []
    private var lastEdges: [Float]?
    /// Each column's bin in a row's edges, worked out once.
    private let binOf: [Int]
    private var top = 0, bottom = 0
    /// The frame rows each row of the body, and of `above` (in its order), came from, and how much of each: one row, or
    /// several where frames were faded together (`fade`).
    private typealias Source = (row: Int, share: Float)
    /// Rows that each came whole from one frame row.
    private static func whole(_ rows: Range<Int>) -> [[Source]] { rows.map { [($0, 1) as Source] } }
    private var bodySource: [[Source]] = []
    private var aboveSource: [[Source]] = []
    /// A move was found by edges: the page scrolls over a backdrop that stays put.
    private var seeThrough = false
    /// A move was found by rows: the page's rows repeat, so it is opaque and never over a backdrop that stays put.
    private var matchedByRows = false
    /// The backdrop's level in the frame before the first move over it, per frame row, column bin and channel: its text
    /// and cards count, but only a few rows of it.
    private var backdropLevel: [Float] = []
    /// The moves over the backdrop: how many of each length.
    private var backdropMoves: [Int: Int] = [:]
    /// Per moving-part row, column bin and channel, the steps measured from it less those measured to it (`measure`).
    private var backdropPull: [Float] = []

    public init(width: Int, height: Int, limit: Int = 20_000, ignoredRight: Int = 0) {
        self.width = width
        frameHeight = height
        self.limit = limit
        self.ignoredRight = min(max(0, ignoredRight), max(0, width - 1))
        let columns = width - self.ignoredRight, bins = max(1, min(columns - 1, 192))
        binOf = (0..<max(columns, 1)).map { x in x == 0 ? 0 : (x - 1) * bins / max(columns - 1, 1) }
    }

    public var rowBytes: Int { width * 4 }

    /// The result's height so far in pixel rows.
    public var height: Int { (header.count + above.count + body.count + footer.count) / max(rowBytes, 1) }

    public var isEmpty: Bool { last.isEmpty }

    /// One frame, `width` × `height` pixels, rows top first.
    public mutating func add(_ pixels: [UInt8]) -> Added {
        guard pixels.count == rowBytes * frameHeight else { return .noMatch }
        let rows = hashes(pixels)
        guard !last.isEmpty else {
            body = pixels
            bodySource = Self.whole(0..<frameHeight)
            keep(pixels, rows, edges: nil)
            return .first
        }
        guard height < limit else { return .full }
        if rows == last { return .unchanged }
        // Rows fixed in place at the top and the foot of both frames: a header and a footer.
        var t = 0
        while t < frameHeight, stays(t, pixels, rows) { t += 1 }
        var b = 0
        while b < frameHeight - t, stays(frameHeight - 1 - b, pixels, rows) { b += 1 }
        let span = frameHeight - t - b
        guard span > 0 else { return .unchanged }
        // Half the moving part in place at its top or its foot: the page did not move; something over it did.
        let moving = frameHeight - top - bottom
        if 2 * (t - top) >= moving || 2 * (b - bottom) >= moving { return .unchanged }
        let new = Array(rows[t..<(t + span)]), old = Array(last[t..<(t + span)])
        if Self.agree(new, old, shift: 0) >= 0.98 { return .unchanged }
        var edges: [Float]?
        let found = Self.offset(of: new, in: old, direction: direction) ?? {
            let now = self.edges(pixels), before = previousEdges()
            edges = now
            let part = (t * bins)..<((t + span) * bins)
            return Self.edgeOffset(of: Array(now[part]), in: Array(before[part]), bins: bins, direction: direction)
        }()
        // No move, but most rows exactly where they were: only a band changed (a status line or a spinner animating;
        // Sven, build 55), and the page did not move. A miss here made Pilot's scrolling back off until it gave up.
        guard let dy = found else {
            let staying = (0..<frameHeight).count { stays($0, pixels, rows) }
            return Double(staying) >= Self.inPlace * Double(frameHeight) ? .unchanged : .noMatch
        }
        if dy == 0 { return .unchanged }
        if direction == nil {
            direction = dy > 0 ? .down : .up
            // Rows over the footer that did not move with the page either are the footer's too: the window's rim and
            // its rounded corner where the area reaches past the window's foot, which were stitched in as a line and a
            // tick at every seam (Sven, build 66). Over a backdrop that stays put no row follows exactly, so not there.
            if edges == nil { while b < frameHeight / 16, !follows(frameHeight - 1 - b, pixels, dy: dy) { b += 1 } }
            if t + b > 0 {
                // The first move shows what stays put: split it out of what the first frame put in the body.
                header = Array(body[0..<(t * rowBytes)])
                footer = Array(body[(body.count - b * rowBytes)...])
                body = Array(body[(t * rowBytes)..<(body.count - b * rowBytes)])
                bodySource = Self.whole(t..<(frameHeight - b))
                top = t
                bottom = b
            }
        }
        if edges == nil { matchedByRows = true }
        if edges != nil, !seeThrough, !matchedByRows, Self.agree(new, old, shift: dy) < Self.backdropRepeats {
            seeThrough = true
            backdropLevel = levels(lastFrame)
        }
        // The moving part is where it was at the first move; this frame's own header or footer may have grown into it.
        let end = frameHeight - bottom, moved = min(abs(dy), end - top), added = min(moved, limit - height)
        if dy > 0 {
            // Scrolled down: the last rows of the moving part are new; they go below.
            let seam = end - moved
            if seeThrough { fade(pixels, seam: seam, down: true) }
            body.append(contentsOf: pixels[(seam * rowBytes)..<((seam + added) * rowBytes)])
            bodySource.append(contentsOf: Self.whole(seam..<(seam + added)))
        } else {
            // Scrolled up: the first rows of the moving part are new; they go above, nearest the body first.
            let seam = top + moved
            if seeThrough { fade(pixels, seam: seam, down: false) }
            for row in ((seam - added)..<seam).reversed() {
                above.append(contentsOf: pixels[(row * rowBytes)..<((row + 1) * rowBytes)])
                aboveSource.append([(row, 1)])
            }
        }
        if bottom > 0 { footer = Array(pixels[((frameHeight - bottom) * rowBytes)...]) }
        if top > 0 { header = Array(pixels[0..<(top * rowBytes)]) }
        if seeThrough { measure(from: lastFrame, to: pixels, dy: dy) }
        keep(pixels, rows, edges: edges)
        return added < moved ? .full : .appended(added)
    }

    /// The result: header, what scrolled in above, the body, footer; its height is `height`.
    public func pixels() -> [UInt8] {
        var out = header
        out.reserveCapacity(height * rowBytes)
        for row in (0..<(above.count / max(rowBytes, 1))).reversed() { out.append(contentsOf: above[(row * rowBytes)..<((row + 1) * rowBytes)]) }
        out.append(contentsOf: body)
        out.append(contentsOf: footer)
        if seeThrough { swapBackdrop(&out, from: header.count / rowBytes, sources: aboveSource.reversed() + bodySource) }
        return out
    }

    /// The most rows a new frame is faded into the result over, above its new rows (below, scrolling up). As few as hide a
    /// seam (Sven's frames: 48 and 400 alike), so the fade stays clear of the area's middle, where Pilot's scrolling
    /// holds the pointer and a row under it may light up.
    static let fadeRows = 48

    /// Over a backdrop that stays put, the rows a new frame shares with the result next to its new ones fade from the
    /// result's to the frame's, so no seam cuts from one stretch of backdrop to another. The move is exact to the row
    /// (Sven's frames: text pixels agree there, three quarters disagree a row off), so the page is the same in both and
    /// only the backdrop changes. No row is left out by its edges: the backdrop's own differ from frame to frame, and a
    /// row left out drew a line. In the scroll bar's room a pixel that differs much (the bar itself) keeps the result's.
    private mutating func fade(_ pixels: [UInt8], seam: Int, down: Bool) {
        let aboveRows = above.count / rowBytes, content = aboveRows + body.count / rowBytes, end = frameHeight - bottom
        // The frame rows shared, nearest the seam last when down, first when up.
        let shared = down ? max(top, seam - min(Self.fadeRows, content))..<seam : seam..<min(end, seam + min(Self.fadeRows, content))
        guard shared.count > 0 else { return }
        let width = self.width, rowBytes = self.rowBytes, columns = width - ignoredRight
        for y in shared {
            // The frame's share: rising to the seam's side, where the rows after are all the frame's.
            let w = Float(down ? y - shared.lowerBound + 1 : shared.upperBound - y) / Float(shared.count + 1)
            let i = down ? content - (seam - y) : y - seam, inAbove = i < aboveRows, row = inAbove ? aboveRows - 1 - i : i - aboveRows
            // The row takes `w` of the frame's row (in 256ths), and its sources their shares less `w`, plus the frame's row.
            let w256 = Int((w * 256).rounded())
            func blend(_ store: inout [UInt8], _ sources: inout [Source]) {
                store.withUnsafeMutableBufferPointer { o in pixels.withUnsafeBufferPointer { p in
                    let a = row * rowBytes, b = y * rowBytes
                    for x in 0..<width {
                        let j = a + x * 4, k = b + x * 4
                        if x >= columns, abs(Int(o[j]) - Int(p[k])) + abs(Int(o[j + 1]) - Int(p[k + 1])) + abs(Int(o[j + 2]) - Int(p[k + 2])) > Self.scrollBar { continue }
                        for c in 0..<3 {
                            let was = Int(o[j + c])
                            o[j + c] = UInt8(was + ((Int(p[k + c]) - was) * w256 + 128) >> 8)
                        }
                    }
                } }
                for s in sources.indices { sources[s].share *= 1 - w }
                sources.removeAll { $0.share < 0.01 }
                sources.append((y, w))
            }
            if inAbove { blend(&above, &aboveSource[row]) } else { blend(&body, &bodySource[row]) }
        }
    }

    /// Column bins of the backdrop, 16 at most (a blurred wallpaper changes slowly across), and the columns of each.
    private var backdropBins: Int { min(16, max(1, (width - ignoredRight) / 16)) }
    private func backdropColumns(_ bin: Int) -> StrideTo<Int> {
        let columns = width - ignoredRight, bins = backdropBins, from = bin * columns / bins, to = (bin + 1) * columns / bins
        return Swift.stride(from: from, to: to, by: max(1, (to - from) / 32))
    }

    /// A frame's backdrop per row, column bin and channel: the bin's middle pixel by brightness, of about 32, so the text
    /// over it counts for little.
    private func levels(_ pixels: [UInt8]) -> [Float] {
        let bins = backdropBins
        var level = [Float](repeating: 0, count: frameHeight * bins * 3), sample: [(Int, Int)] = []
        for row in 0..<frameHeight {
            for bin in 0..<bins {
                sample.removeAll(keepingCapacity: true)
                for x in backdropColumns(bin) {
                    let i = (row * width + x) * 4
                    sample.append((Int(pixels[i]) + 2 * Int(pixels[i + 1]) + Int(pixels[i + 2]), i))
                }
                sample.sort { $0.0 < $1.0 }
                let i = sample[sample.count / 2].1
                for c in 0..<3 { level[(row * bins + bin) * 3 + c] = Float(pixels[i + c]) }
            }
        }
        return level
    }

    /// Measures how much brighter the backdrop is at each moving-part row than `dy` rows on: the new frame's row less the
    /// old frame's row that showed the same page, over about 32 columns a bin. Text over it changes nothing and a
    /// see-through card passes most of the change, so the bin's change is three quarters of the way to its end (a hover,
    /// a few columns, counts for little).
    private mutating func measure(from old: [UInt8], to new: [UInt8], dy: Int) {
        let bins = backdropBins, span = frameHeight - top - bottom, stride = bins * 3
        if backdropPull.isEmpty { backdropPull = [Float](repeating: 0, count: span * stride) }
        backdropMoves[dy, default: 0] += 1
        var sample: [[Int]] = [[], [], []]
        for r in max(0, -dy)..<min(span, span - dy) {
            let n = (top + r) * width * 4, o = (top + r + dy) * width * 4
            for bin in 0..<bins {
                for c in 0..<3 { sample[c].removeAll(keepingCapacity: true) }
                for x in backdropColumns(bin) {
                    for c in 0..<3 { sample[c].append(Int(new[n + x * 4 + c]) - Int(old[o + x * 4 + c])) }
                }
                for c in 0..<3 {
                    sample[c].sort()
                    let count = sample[c].count, rising = sample[c][count / 2] > 0
                    let step = Float(sample[c][rising ? count * 3 / 4 : (count - 1) / 4]), k = bin * 3 + c
                    backdropPull[r * stride + k] += step
                    backdropPull[(r + dy) * stride + k] -= step
                }
            }
        }
    }

    /// The moving part's backdrop for value `k` (bin and channel), row by row: the rows that best fit every step measured,
    /// kept smooth (`backdropSmooth`), by conjugate gradients; then lifted to the first frame's level, its middle offset.
    /// What is solved: each row less the row `dy` on, every move counted, against the steps measured (`backdropPull`).
    private func backdropRows(_ k: Int, span: Int, stride: Int) -> [Float] {
        func apply(_ x: [Float]) -> [Float] {
            var out = x.map { $0 * 1e-4 }
            for r in 0..<(span - 1) {
                let d = Self.backdropSmooth * (x[r + 1] - x[r])
                out[r + 1] += d
                out[r] -= d
            }
            for (dy, count) in backdropMoves {
                for r in max(0, -dy)..<min(span, span - dy) {
                    let d = Float(count) * (x[r] - x[r + dy])
                    out[r] += d
                    out[r + dy] -= d
                }
            }
            return out
        }
        let b = (0..<span).map { backdropPull[$0 * stride + k] }
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        var x = [Float](repeating: 0, count: span), residual = b, direction = b, size = dot(residual, residual)
        let enough = 1e-8 * max(size, 1)
        for _ in 0..<400 where size > enough {
            let pushed = apply(direction), along = size / dot(direction, pushed)
            for r in 0..<span {
                x[r] += along * direction[r]
                residual[r] -= along * pushed[r]
            }
            let next = dot(residual, residual)
            for r in 0..<span { direction[r] = residual[r] + next / size * direction[r] }
            size = next
        }
        let lift = (0..<span).map { backdropLevel[(top + $0) * stride + k] - x[$0] }.sorted()[span / 2]
        return x.map { $0 + lift }
    }

    /// Swaps the backdrop of the `sources.count` rows from `start` in `out` (the frame rows each came from) for the moving
    /// part's backdrop stretched over them, so the result reads as one window: each pixel trades the backdrop of its frame
    /// rows (their shares of it, where frames were faded together) for the stretched one's, less as it stands out from it
    /// (`opaque`). A backdrop flat to within `shade` is left. Only the backdrop's broad change is swapped (`backdropBlur`):
    /// over a streaked wallpaper a bin's level jumps from streak to gap row by row, and swapping that smeared the streaks
    /// into horizontal bands (Sven, build 83); the fade hides what the broad swap leaves at the seams.
    private func swapBackdrop(_ out: inout [UInt8], from start: Int, sources: [[Source]]) {
        let n = sources.count, span = frameHeight - top - bottom, bins = backdropBins, stride = bins * 3
        guard n > 0, span > 1, !backdropPull.isEmpty else { return }
        var solved = [Float](repeating: 0, count: span * stride)
        for k in 0..<stride {
            for (r, level) in backdropRows(k, span: span, stride: stride).enumerated() { solved[r * stride + k] = level }
        }
        // Each level the mean of `backdropBlur` rows either side, its own bin counted twice and its neighbours once.
        var tint = [Float](repeating: 0, count: span * stride)
        for k in 0..<stride {
            let b = k / 3, c = k % 3
            var sums = [Float](repeating: 0, count: span + 1)
            for r in 0..<span {
                sums[r + 1] = sums[r] + 2 * solved[r * stride + k] + solved[r * stride + max(0, b - 1) * 3 + c] + solved[r * stride + min(bins - 1, b + 1) * 3 + c]
            }
            for r in 0..<span {
                let lo = max(0, r - Self.backdropBlur), hi = min(span, r + Self.backdropBlur + 1)
                tint[r * stride + k] = (sums[hi] - sums[lo]) / Float(4 * (hi - lo))
            }
        }
        let range = (0..<bins).map { b -> Float in
            let level = (0..<span).map { r in (0..<3).reduce(Float(0)) { $0 + tint[r * stride + b * 3 + $1] } }
            return level.max()! - level.min()!
        }.max() ?? 0
        guard range > Float(Self.shade) else { return }
        // Each column between its two nearest bins' middles.
        let columns = width - ignoredRight
        let place = (0..<width).map { x -> (Int, Int, Float) in
            let at = max(0, Float(min(x, columns - 1)) + 0.5) * Float(bins) / Float(columns) - 0.5
            let lo = min(bins - 1, max(0, Int(at.rounded(.down))))
            return (lo, min(bins - 1, lo + 1), min(1, max(0, at - Float(lo))))
        }
        var had = [Float](repeating: 0, count: stride)
        out.withUnsafeMutableBufferPointer { o in
            for (r, source) in sources.enumerated() {
                // The backdrop the row carries: its frame rows' levels, by their shares.
                for k in 0..<stride { had[k] = 0 }
                var total: Float = 0
                for (row, share) in source {
                    total += share
                    for k in 0..<stride { had[k] += share * tint[(row - top) * stride + k] }
                }
                for k in 0..<stride { had[k] /= total }
                let wants = ((2 * r + 1) * span / (2 * n)) * stride, base = (start + r) * rowBytes
                for x in 0..<width {
                    let (lo, hi, f) = place[x], i = base + x * 4
                    func level(_ t: [Float], _ row: Int) -> SIMD3<Float> {
                        let a = row + lo * 3, b = row + hi * 3
                        return SIMD3(t[a], t[a + 1], t[a + 2]) * (1 - f) + SIMD3(t[b], t[b + 1], t[b + 2]) * f
                    }
                    let pixel = SIMD3(Float(o[i]), Float(o[i + 1]), Float(o[i + 2])), was = level(had, 0), off = pixel - was
                    let share = 1 - (abs(off.x) + abs(off.y) + abs(off.z)) / Self.opaque
                    guard share > 0 else { continue }
                    let now = (pixel + share * (level(tint, wants) - was)).rounded(.toNearestOrAwayFromZero)
                        .clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 255))
                    (o[i], o[i + 1], o[i + 2]) = (UInt8(now.x), UInt8(now.y), UInt8(now.z))
                }
            }
        }
    }

    /// The share of rows that agree when `new` sits `shift` rows up from `old` (down when negative), over their overlap.
    static func agree(_ new: [UInt64], _ old: [UInt64], shift: Int) -> Double {
        let n = new.count, overlap = n - abs(shift)
        guard overlap > 0 else { return 0 }
        var same = 0
        for i in 0..<overlap where (shift >= 0 ? old[i + shift] == new[i] : old[i] == new[i - shift]) { same += 1 }
        return Double(same) / Double(overlap)
    }

    /// How far the moving part moved: positive up (the page scrolled down), negative down. Candidates come from rows that
    /// differ from their neighbours, found in the old frame; the one where most rows agree wins, the smallest move on a tie,
    /// with at least a quarter of the part (and 8 rows) in common. Against `direction` nothing is taken.
    static func offset(of new: [UInt64], in old: [UInt64], direction: Direction?) -> Int? {
        let n = new.count, least = max(8, n / 4)
        guard n > least else { return nil }
        var positions: [UInt64: [Int]] = [:]
        for (i, h) in old.enumerated() { positions[h, default: []].append(i) }
        // Up to 24 probes spread over the part, each a row unlike the next.
        let stride = max(1, n / 24)
        var votes: [Int: Int] = [:]
        for i in Swift.stride(from: 0, to: n - 1, by: stride) where new[i] != new[i + 1] {
            for j in positions[new[i]] ?? [] where j != i && abs(j - i) <= n - least { votes[j - i, default: 0] += 1 }
        }
        let allowed = votes.keys.filter { dy in
            switch direction {
            case .down?: dy > 0
            case .up?: dy < 0
            case nil: true
            }
        }
        let tried = allowed.sorted { (votes[$0]!, -abs($0)) > (votes[$1]!, -abs($1)) }.prefix(6)
        var best: (dy: Int, score: Double)?
        for dy in tried {
            let score = agree(new, old, shift: dy)
            if score >= agreement, score > (best?.score ?? 0) || (score == best?.score && abs(dy) < abs(best!.dy)) { best = (dy, score) }
        }
        return best?.dy
    }

    private mutating func keep(_ pixels: [UInt8], _ rows: [UInt64], edges: [Float]?) {
        last = rows
        lastFrame = pixels
        lastEdges = edges
    }

    /// Whether `row` is where it was in the last frame kept: the same hash, or at most one column in 32 (and 2) changed by
    /// more than `shade`, which a blinking caret or a spinner is and a line of moved text is not.
    private func stays(_ row: Int, _ pixels: [UInt8], _ rows: [UInt64]) -> Bool {
        let columns = width - ignoredRight
        return rows[row] == last[row] || !differ(pixels, row, from: row, columns: columns, most: max(2, columns / 32))
    }

    /// Whether frame row `row` moved with the page by `dy`, the same pixels where the move puts them in both frames: no
    /// column changed by more than `shade`, the scroll bar's included, where a window's rounded corner shows.
    private func follows(_ row: Int, _ pixels: [UInt8], dy: Int) -> Bool {
        let (new, old) = dy > 0 ? (row - dy, row) : (row, row + dy)
        return !differ(pixels, new, from: old, columns: width, most: 0)
    }

    /// Whether more than `most` of the first `columns` pixels of `pixels`' row `row` differ by more than `shade` from
    /// those of the last frame kept's row `from`.
    private func differ(_ pixels: [UInt8], _ row: Int, from: Int, columns: Int, most: Int) -> Bool {
        let base = row * rowBytes, was = from * rowBytes
        return pixels.withUnsafeBufferPointer { p in lastFrame.withUnsafeBufferPointer { o in
            var changed = 0
            for x in 0..<columns {
                let i = base + x * 4, j = was + x * 4
                let d = abs(Int(p[i]) - Int(o[j])) + abs(Int(p[i + 1]) - Int(o[j + 1])) + abs(Int(p[i + 2]) - Int(o[j + 2]))
                if d > Self.shade { changed += 1; if changed > most { return true } }
            }
            return false
        } }
    }

    /// The last frame's edges, worked out once.
    private mutating func previousEdges() -> [Float] {
        if let lastEdges { return lastEdges }
        let e = edges(lastFrame)
        lastEdges = e
        return e
    }

    /// Columns of a row's edges: about five pixels each on a wide area.
    private var bins: Int { max(1, min(width - ignoredRight - 1, 192)) }
    /// A brightness step (blue + 2 green + red, 0 to 1020) under this is a backdrop's slow change, not an edge.
    static let edgeFloor = 40
    /// The most two rows' edges may differ, as a share of them, for the edge match to take a move.
    static let edgeMismatch: Float = 0.2
    /// How much closer than any other move the edge match's move must be (a real move is about 0.02, a wrong one 0.4).
    static let edgeMargin: Float = 0.15

    /// Each row's edges: how much the brightness steps between neighbouring pixels, summed over `bins` columns, steps
    /// under `edgeFloor` left out. Rows top first, `bins` values a row; the ignored right edge is left out.
    func edges(_ pixels: [UInt8]) -> [Float] {
        let columns = width - ignoredRight, bins = self.bins
        guard columns > 1 else { return [Float](repeating: 0, count: frameHeight * bins) }
        var edges = [Float](repeating: 0, count: frameHeight * bins)
        edges.withUnsafeMutableBufferPointer { out in pixels.withUnsafeBufferPointer { p in
            for row in 0..<frameHeight {
                let base = row * rowBytes
                var before = Int(p[base]) + 2 * Int(p[base + 1]) + Int(p[base + 2])
                for x in 1..<columns {
                    let i = base + x * 4
                    let now = Int(p[i]) + 2 * Int(p[i + 1]) + Int(p[i + 2])
                    let step = abs(now - before)
                    if step >= Self.edgeFloor { out[row * bins + binOf[x]] += Float(step) }
                    before = now
                }
            }
        } }
        return edges
    }

    /// The move by edges, as `offset`'s sign: each shift's per-row edge totals are compared first, and the six closest
    /// are checked column by column; the closest wins when its rows differ by at most `edgeMismatch`, at least 8 of them
    /// have edges, and every other move is `edgeMargin` further off. 0 is a page that did not move.
    static func edgeOffset(of new: [Float], in old: [Float], bins: Int, direction: Direction?) -> Int? {
        let n = new.count / max(bins, 1), least = max(8, n / 4)
        guard n > least else { return nil }
        func total(_ e: [Float]) -> [Float] { (0..<n).map { r in e[(r * bins)..<((r + 1) * bins)].reduce(0, +) } }
        let a = total(new), b = total(old)
        // How far apart a shift's rows are, `w` values a row: 0 the same, 1 nothing in common; nil with under 8 rows
        // that have edges. The rows' totals (w 1) over about 400 rows rank the shifts; the columns decide.
        func apart(_ x: [Float], _ y: [Float], _ w: Int, _ dy: Int, every: Int) -> Float? {
            var diff: Float = 0, sum: Float = 0, rows = 0
            for i in Swift.stride(from: 0, to: n - abs(dy), by: every) {
                let r = (dy >= 0 ? i : i - dy) * w, o = (dy >= 0 ? i + dy : i) * w
                var d: Float = 0, s: Float = 0
                for c in 0..<w { d += abs(x[r + c] - y[o + c]); s += x[r + c] + y[o + c] }
                guard s > 0 else { continue }
                rows += 1
                diff += d
                sum += s
            }
            return rows >= 8 && sum > 0 ? diff / sum : nil
        }
        let shifts = (-(n - least)...(n - least)).filter { dy in
            switch direction {
            case .down?: dy >= 0
            case .up?: dy <= 0
            case nil: true
            }
        }
        let tried = shifts.compactMap { dy in apart(a, b, 1, dy, every: max(1, n / 400)).map { (dy, $0) } }.sorted { $0.1 < $1.1 }.prefix(6)
        let scored = tried.compactMap { dy, _ in apart(new, old, bins, dy, every: 1).map { (dy: dy, score: $0) } }.sorted { $0.score < $1.score }
        guard let best = scored.first, best.score <= edgeMismatch else { return nil }
        // Rows that repeat (lines alike, a list of the same cards) fit more than one move: then nothing is taken.
        if let rival = scored.first(where: { abs($0.dy - best.dy) > 2 }), rival.score - best.score < edgeMargin { return nil }
        return best.dy
    }

    /// Each row's FNV-1a hash over its pixels left of the ignored edge.
    private func hashes(_ pixels: [UInt8]) -> [UInt64] {
        let bytes = (width - ignoredRight) * 4
        return pixels.withUnsafeBytes { raw in
            (0..<frameHeight).map { row in
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                let base = raw.baseAddress!.advanced(by: row * rowBytes)
                var i = 0
                while i + 8 <= bytes {
                    h = (h ^ base.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0x100_0000_01b3
                    i += 8
                }
                while i < bytes {
                    h = (h ^ UInt64(base.load(fromByteOffset: i, as: UInt8.self))) &* 0x100_0000_01b3
                    i += 1
                }
                return h
            }
        }
    }
}
