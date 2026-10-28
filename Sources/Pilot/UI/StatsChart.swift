import PilotCore
import SwiftUI

// Stats' charts (card agent-bo-95422992, mockup on card agent-bo-95422987): every reading over the range History picks,
// on one axis with a recessive grid, its ceiling labelled at the top right, the range's three words under it, and the
// value under the mouse. Two lines in one chart differ by solid and dashed as well as colour.

/// The readings Stats draws over time, each a field of the minute history's points.
enum StatsTrace: Int, CaseIterable {
    case cpu, ram, gpu, down, up, read, write, heat, fan

    /// Its field of a point: StatsHistory.Point.fields lists them in this order.
    var field: KeyPath<StatsHistory.Point, Double?> { StatsHistory.Point.fields[rawValue] }
}

/// What the charts draw for one range: each reading's values across it, x from 0 (the range's start) to 1 (now), nil
/// where nothing was read, which leaves a gap in the line.
struct StatsSeries {
    var xs: [Double] = []
    var values: [StatsTrace: [Double?]] = [:]
    /// The seconds the chart's width covers, for the words under the mouse.
    var span: TimeInterval

    subscript(_ trace: StatsTrace) -> [Double?] { values[trace] ?? [] }

    /// Today is drawn in at most this many points, each the average of the minutes in it.
    static let todayPoints = 144

    /// The last 2 minutes, a reading every 2 s, newest at the right edge; a short history starts part way across, a full
    /// one (60 readings, 59 steps) reaches the left edge.
    static func twoMinutes(_ history: [SystemStats.Values]) -> StatsSeries {
        let step = SystemStats.interval, n = history.count
        var series = StatsSeries(span: 59 * step)
        series.xs = history.indices.map { 1 - Double(n - 1 - $0) * step / series.span }
        let points = history.map { StatsHistory.Point(time: .distantPast, $0) }
        for trace in StatsTrace.allCases { series.values[trace] = points.map { $0[keyPath: trace.field] } }
        return series
    }

    /// The last hour or today from the minute history: a minute is drawn at its end, a gap of more than a minute and a
    /// half (Pilot not running, the Mac asleep) breaks the line; today is averaged into at most `todayPoints`.
    static func minutes(_ points: [StatsHistory.Point], range: StatsRange, now: Date, calendar: Calendar = .current) -> StatsSeries {
        let start = range == .today ? calendar.startOfDay(for: now) : now.addingTimeInterval(-3600)
        var series = StatsSeries(span: max(60, now.timeIntervalSince(start)))
        let span = series.span, traces = StatsTrace.allCases.count
        if range == .today {
            // Each bucket's sum and count per trace, flat: bucket i, trace t at i * traces + t.
            let width = max(60, span / Double(todayPoints)), count = Int((span / width).rounded(.up))
            var sums = [Double](repeating: 0, count: count * traces), counts = [Int](repeating: 0, count: count * traces)
            for point in points {
                let i = min(count - 1, max(0, Int((point.time.timeIntervalSince(start) + 30) / width)))
                for trace in StatsTrace.allCases {
                    guard let v = point[keyPath: trace.field] else { continue }
                    sums[i * traces + trace.rawValue] += v
                    counts[i * traces + trace.rawValue] += 1
                }
            }
            series.xs = (0..<count).map { min(1, (Double($0) + 1) * width / span) }
            for trace in StatsTrace.allCases {
                series.values[trace] = (0..<count).map { i in
                    let k = i * traces + trace.rawValue
                    return counts[k] > 0 ? sums[k] / Double(counts[k]) : nil
                }
            }
            return series
        }
        // An hour: each minute as it is, a nil between two minutes read far apart.
        let x = { (time: Date) in min(1, max(0, (time.timeIntervalSince(start) + 60) / span)) }
        var rows: [(x: Double, point: StatsHistory.Point?)] = []
        for (i, point) in points.enumerated() {
            if i > 0, point.time.timeIntervalSince(points[i - 1].time) > 90 {
                rows.append(((x(points[i - 1].time) + x(point.time)) / 2, nil))
            }
            rows.append((x(point.time), point))
        }
        series.xs = rows.map(\.x)
        for trace in StatsTrace.allCases { series.values[trace] = rows.map { $0.point?[keyPath: trace.field] } }
        return series
    }
}

/// How Stats writes its numbers, on PilotCore's own (SystemStats' decimal, memorySize, duration) where they exist.
enum StatsFormat {
    /// "9": a share as whole percent.
    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))" }

    /// "1.2" "MB/s", "340" "KB/s": bytes a second.
    static func rate(_ bytes: Double) -> (value: String, unit: String) {
        bytes >= 1_000_000 ? (String(format: "%.1f", bytes / 1_000_000), "MB/s") : ("\(Int((bytes / 1_000).rounded()))", "KB/s")
    }

    static func rateText(_ bytes: Double?) -> String { bytes.map { let r = rate($0); return "\(r.value) \(r.unit)" } ?? "–" }

    /// "7.4 GB", "245 GB", "618 MB": decimal, as Finder counts disks and transfers.
    static func bytes(_ bytes: Double) -> String { SystemStats.decimal(bytes) }

    /// "6.1 GB", "618 MB", "0 B": memory in units of 1024, as Activity Monitor counts it.
    static func memory(_ bytes: UInt64) -> String { bytes == 0 ? "0 B" : SystemStats.memorySize(bytes) }

    /// "1,020": a whole number with its thousands marked.
    static func whole(_ value: Double) -> String { Int(value.rounded()).formatted(.number.grouping(.automatic)) }

    /// "3 d 4 h", "1 h 20 min", "12 min".
    static func duration(_ seconds: TimeInterval) -> String { SystemStats.duration(minutes: Int(seconds / 60)) }

    /// The words for a moment `seconds` before now: "now", "35 s ago", "17 min ago", "3 h ago".
    static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3: "now"
        case ..<120: "\(Int(seconds.rounded())) s ago"
        case ..<7200: "\(Int((seconds / 60).rounded())) min ago"
        default: "\(Int((seconds / 3600).rounded())) h ago"
        }
    }

    /// Shares' chart ceilings, then rates' from 100 KB/s, then temperatures'.
    static let shareSteps = [0.1, 0.2, 0.4, 0.6, 0.8, 1]
    static let rateSteps = [0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048].map { $0 * 1_000_000 }
    static let heatSteps: [Double] = [60, 80, 100, 120]

    /// A chart's ceiling: the first of `steps` at or over its highest point with `headroom` above it, else the last.
    static func ceiling(_ values: [Double?], steps: [Double], headroom: Double = 1.1) -> Double {
        let top = values.compactMap(\.self).max() ?? 0
        return steps.first { $0 >= top * headroom } ?? steps[steps.count - 1]
    }

    /// "4 MB/s", "250 KB/s": a rate ceiling's label.
    static func rateLabel(_ bytes: Double) -> String {
        bytes >= 1_000_000 ? "\(whole(bytes / 1_000_000)) MB/s" : "\(whole(bytes / 1_000)) KB/s"
    }
}

/// One line of a chart.
struct ChartLine {
    let name: String
    let values: [Double?]
    let colour: Color
    var dashed = false
}

/// A reading over the range: one or two lines on one axis from 0 to `top`, the first filled under, the grid at 0, half
/// and the top, `topLabel` at the top right, `axis` under it; the mouse shows a crosshair and the values at that moment.
struct StatsChart: View {
    @Environment(\.ink) private var ink
    let xs: [Double]
    let lines: [ChartLine]
    let top: Double
    let topLabel: String
    let axis: [String]
    /// The seconds the width covers.
    let span: TimeInterval
    /// A value as the tip writes it: "7%", "1.4 MB/s".
    let format: (Double) -> String
    /// Where the crosshair starts, 0 to 1; nil until the mouse comes (a render shows one).
    var hover: Double?
    /// What VoiceOver calls the chart: "CPU over the last 2 minutes".
    var label = ""
    /// Bars in place of the line: the same samples averaged into this many bars across the range.
    var bars: Int?
    /// A fixed plot height (Compact's cards); nil grows with the card.
    var height: CGFloat?

    var body: some View {
        let (xs, lines) = shaped
        VStack(spacing: 4) {
            ChartPlot(xs: xs, lines: lines, top: top, bars: bars != nil)
                .overlay(alignment: .topTrailing) { yLabel(topLabel).offset(y: -4) }
                .overlay(alignment: .bottomTrailing) { yLabel("0").offset(y: 6) }
                .overlay { ChartHover(xs: xs, lines: lines, span: span, format: format, hover: hover) }
                .frame(minHeight: height ?? 54, maxHeight: height ?? .infinity)
            HStack {
                ForEach(Array(axis.enumerated()), id: \.offset) { i, word in
                    Text(word)
                    if i < axis.count - 1 { Spacer(minLength: 4) }
                }
            }
            .font(ink.mono(9.5)).foregroundStyle(ink.muted).lineLimit(1)
            .padding(.trailing, 30)
            .accessibilityHidden(true)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(summary)
    }

    /// The samples as drawn: as read for a line, averaged into bars for Bars.
    private var shaped: (xs: [Double], lines: [ChartLine]) {
        guard let bars else { return (xs, lines) }
        let bucketed = lines.map { StatsViews.bars(xs: xs, values: $0.values, count: bars) }
        return (bucketed.first?.xs ?? [], zip(lines, bucketed).map { ChartLine(name: $0.name, values: $1.values, colour: $0.colour, dashed: $0.dashed) })
    }

    /// The ceiling or the floor, on the tile's own colour so the grid and the line pass behind it.
    private func yLabel(_ text: String) -> some View {
        Text(text).font(ink.mono(9.5)).foregroundStyle(ink.muted).lineLimit(1)
            .padding(.leading, 3)
            .background(ink.raised.opacity(0.85))
    }

    /// "now 9%, highest 22%" for each line.
    private var summary: String {
        lines.map { line in
            let now = line.values.last(where: { $0 != nil }).flatMap(\.self).map(format) ?? "not read"
            let high = line.values.compactMap(\.self).max().map(format) ?? "not read"
            return "\(lines.count > 1 ? line.name + " " : "")now \(now), highest \(high)"
        }
        .joined(separator: "; ")
    }
}

/// The grid and the lines, or the bars; redrawn only when the readings change, never as the mouse moves.
private struct ChartPlot: View {
    @Environment(\.ink) private var ink
    let xs: [Double]
    let lines: [ChartLine]
    let top: Double
    var bars = false
    var grid = true

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let y = { (v: Double) in h - 1 - CGFloat(min(max(v / max(top, .leastNonzeroMagnitude), 0), 1)) * (h - 4) }
            for f in grid ? [0.0, 0.5, 1] : [] {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y(f * top)))
                grid.addLine(to: CGPoint(x: w, y: y(f * top)))
                context.stroke(grid, with: .color(ink.line), lineWidth: 1)
            }
            if bars {
                // Each bar's slot split between the lines, the second a step lighter; a gap of a fifth between slots.
                let slot = w / CGFloat(max(xs.count, 1)), width = slot * 0.8 / CGFloat(max(lines.count, 1))
                for (i, line) in lines.enumerated() {
                    var path = Path()
                    for (x, value) in zip(xs, line.values) {
                        guard let value else { continue }
                        let left = x * w - slot * 0.4 + CGFloat(i) * width, top = min(y(value), h - 2)
                        path.addRoundedRect(in: CGRect(x: left, y: top, width: max(1, width - 1), height: h - top),
                                            cornerSize: CGSize(width: min(2, width / 3), height: min(2, width / 3)))
                    }
                    context.fill(path, with: .color(line.colour.opacity(i == 0 ? 0.85 : 0.5)))
                }
                return
            }
            for (i, line) in lines.enumerated() {
                // Each unbroken run of readings is its own stretch of line.
                var runs: [[CGPoint]] = [[]]
                for (x, value) in zip(xs, line.values) {
                    if let value { runs[runs.count - 1].append(CGPoint(x: x * w, y: y(value))) } else if !runs[runs.count - 1].isEmpty { runs.append([]) }
                }
                for run in runs where !run.isEmpty {
                    if run.count == 1 {
                        context.fill(Path(ellipseIn: CGRect(x: run[0].x - 1.5, y: run[0].y - 1.5, width: 3, height: 3)), with: .color(line.colour))
                        continue
                    }
                    var path = Path()
                    path.addLines(run)
                    if i == 0 {
                        var area = path
                        area.addLine(to: CGPoint(x: run[run.count - 1].x, y: h))
                        area.addLine(to: CGPoint(x: run[0].x, y: h))
                        area.closeSubpath()
                        context.fill(area, with: .color(line.colour.opacity(0.13)))
                    }
                    context.stroke(path, with: .color(line.colour),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: line.dashed ? [4, 3] : []))
                }
            }
        }
    }
}

/// The crosshair and the values at the moment under the mouse; its own view, so moving the mouse redraws only this.
private struct ChartHover: View {
    @Environment(\.ink) private var ink
    let xs: [Double]
    let lines: [ChartLine]
    let span: TimeInterval
    let format: (Double) -> String
    @State private var at: Double?

    init(xs: [Double], lines: [ChartLine], span: TimeInterval, format: @escaping (Double) -> String, hover: Double?) {
        self.xs = xs
        self.lines = lines
        self.span = span
        self.format = format
        _at = State(initialValue: hover)
    }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(.rect)
                if let at, let i = nearest(at) {
                    ink.muted.frame(width: 1).frame(maxHeight: .infinity).offset(x: xs[i] * w)
                    tip(i).fixedSize()
                        .alignmentGuide(.leading) { $0.width / 2 - min(max(xs[i], 0.12), 0.88) * w }
                        .offset(y: -4)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): at = w > 0 ? min(max(point.x / w, 0), 1) : nil
                case .ended: at = nil
                }
            }
        }
    }

    /// The reading nearest the mouse that has a value.
    private func nearest(_ x: Double) -> Int? {
        xs.indices.filter { i in lines.contains { $0.values.indices.contains(i) && $0.values[i] != nil } }
            .min { abs(xs[$0] - x) < abs(xs[$1] - x) }
    }

    private func tip(_ i: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(5), style: .continuous)
        return HStack(spacing: 4) {
            ForEach(lines.indices, id: \.self) { l in
                if l > 0 { Text("·").foregroundStyle(ink.muted) }
                if lines.count > 1 { Text(lines[l].name).foregroundStyle(ink.text2) }
                Text(lines[l].values[i].map(format) ?? "–").fontWeight(.semibold).foregroundStyle(ink.text)
            }
            Text(StatsFormat.ago((1 - xs[i]) * span)).foregroundStyle(ink.muted)
        }
        .font(ink.ui(11)).monospacedDigit().lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(ink.background, in: shape)
        .overlay { shape.strokeBorder(ink.line2) }
        .shadow(color: .black.opacity(0.35), radius: 9, y: 6)
    }
}

/// The key over a two-line chart: each line's stroke, solid or dashed, its name and its value now.
struct ChartKey: View {
    @Environment(\.ink) private var ink
    let items: [(line: ChartLine, now: String)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 5) {
                    Canvas { context, size in
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        context.stroke(path, with: .color(items[i].line.colour), style: StrokeStyle(lineWidth: 2, dash: items[i].line.dashed ? [3, 2] : []))
                    }
                    .frame(width: 14, height: 2)
                    Text(items[i].line.name).foregroundStyle(ink.text2)
                    Text(items[i].now).fontWeight(.semibold).foregroundStyle(ink.text).monospacedDigit()
                }
            }
        }
        .font(ink.ui(11)).lineLimit(1)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Number's sparkline: the first line over the range, no grid or labels, filled under.
struct StatsSparkline: View {
    let xs: [Double]
    let line: ChartLine
    let top: Double

    var body: some View {
        ChartPlot(xs: xs, lines: [line], top: top, grid: false).frame(height: 34).padding(.top, 6).accessibilityHidden(true)
    }
}

/// Ring: the value now against its top as an arc, the number in the middle, what it means under it, then the lowest,
/// the average and the highest across the range.
struct StatsRing: View {
    @Environment(\.ink) private var ink
    /// 0 to 1 of the ring; nil before the first reading.
    let share: Double?
    let value: String
    let unit: String
    let colour: Color
    var detail: String?
    /// What the spread is of, when it differs from the card's title ("Read" on Storage).
    var of: String?
    var spread: (low: String, average: String, high: String)?
    let size: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Redrawn each tick without an animation, as the line is.
                TimerRing(left: share ?? 0, lineWidth: size * 0.09, track: ink.text.opacity(0.1), tint: colour)
                VStack(spacing: 0) {
                    Text(value).font(ink.display(size * 0.28)).foregroundStyle(ink.text)
                    Text(unit).font(ink.ui(11)).foregroundStyle(ink.muted)
                }
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).padding(size * 0.14)
            }
            .frame(width: size, height: size)
            if let detail { Text(detail).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.tail) }
            if let spread {
                HStack(spacing: 0) {
                    part(of.map { "\($0) low" } ?? "Lowest", spread.low)
                    part(of.map { "\($0) average" } ?? "Average", spread.average)
                    part(of.map { "\($0) high" } ?? "Highest", spread.high)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }

    private func part(_ name: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(name).font(ink.ui(11)).foregroundStyle(ink.muted)
            Text(value).font(ink.ui(12, .medium)).foregroundStyle(ink.text).monospacedDigit()
        }
        .lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity)
    }
}
