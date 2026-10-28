import AppKit
import PilotCore
import SwiftUI
import SystemConfiguration

// Speed test in Line (P41, design-refs/launcher-ideas-2026-10-18.html frames 1 to 3; Sven Q292: live numbers as it
// measures): System › Connections › Test internet speed opens this in the list's place instead of an alert. Two gauges on
// a log scale for download and upload, the responsiveness beside them, the last run while it measures and a line over
// the last runs once done; the result stays until Escape. It draws only what macOS's networkQuality measures, live from
// its progress line (SpeedTest.networkQuality).

/// The view in the list's slot, at a fixed height, so the panel never resizes as numbers land.
struct SpeedTestView: View {
    @Environment(\.style) private var style
    let test: SpeedTest

    /// The list's room it takes (MenuModel's Line size).
    static func height(_ test: SpeedTest) -> CGFloat {
        switch test.phase {
        case .failed, .stopped: 192
        default: 264
        }
    }

    var body: some View {
        Group {
            switch test.phase {
            case .failed, .stopped: gone
            case .done(let result): measured(result.reading, done: true)
            case .running(let since): VStack(spacing: 10) { measured(test.live, done: false); SpeedProgress(since: since) }
            case .idle: measured(nil, done: false)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func measured(_ reading: SpeedTest.Reading?, done: Bool) -> some View {
        HStack(spacing: 0) {
            SpeedGauge(title: "Download", value: reading?.download).frame(maxWidth: .infinity)
            SpeedGauge(title: "Upload", value: reading?.upload).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    InstrumentEyebrow(text: "Responsiveness")
                    let rpm = reading.map(\.responsiveness).flatMap { $0 > 0 ? $0 : nil }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(rpm.map(Self.rpm) ?? "—").font(style.font(\.mono, size: 30 / style.scale)).tracking(-0.6)
                            .foregroundStyle(style.color(rpm == nil ? \.text3 : \.text))
                        if rpm != nil { Text("RPM").font(style.font(\.mono, size: 13 / style.scale)).foregroundStyle(style.color(\.text2)) }
                    }
                    .monospacedDigit()
                    Text("Round trips a minute while the line is busy.").styleText(\.caption).foregroundStyle(style.color(\.text3))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if done { SpeedRuns(runs: test.runs) } else { lastRun }
            }
            .padding(.leading, 18).padding(.trailing, 4).padding(.vertical, 6)
            .frame(width: 236, alignment: .topLeading)
            .overlay(alignment: .leading) { InstrumentRule(vertical: true) }
        }
        .padding(.top, 8)
    }

    /// While it measures: the run before this one, for reference.
    @ViewBuilder private var lastRun: some View {
        if let last = test.runs.last {
            VStack(alignment: .leading, spacing: 6) {
                InstrumentEyebrow(text: "Last run")
                Text("\(Self.day(last.at))\n\(Self.brief(last.reading))").font(style.font(\.mono, size: 12 / style.scale))
                    .foregroundStyle(style.color(\.text2)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Frame 3: it could not run, or Sven stopped it.
    private var gone: some View {
        let stopped = test.phase == .stopped
        return VStack(spacing: 6) {
            Image(systemName: stopped ? "stop.circle" : "wifi.exclamationmark").font(style.font(\.search)).foregroundStyle(style.color(\.text3))
                .padding(.bottom, 4).accessibilityHidden(true)
            Text(stopped ? "The speed test stopped." : "The speed test could not run.").styleText(\.strong).foregroundStyle(style.color(\.text))
            Text(stopped ? "Return runs it again." : "Check the connection, then run it again.").styleText(\.caption).foregroundStyle(style.color(\.text3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "1 240": thousands apart by a thin space, as the design writes them.
    static func rpm(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic)).replacingOccurrences(of: ",", with: "\u{202F}") }

    /// A speed as the gauges and the history write it: whole from 100 Mbit/s, one decimal under.
    static func mbits(_ value: Double) -> String { value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value) }

    /// "398 ↓ · 37.9 ↑ · 1 180 RPM".
    static func brief(_ r: SpeedTest.Reading) -> String { "\(mbits(r.download)) ↓ · \(mbits(r.upload)) ↑ · \(rpm(r.responsiveness)) RPM" }

    /// "Today 14:02", "Yesterday 21:14", else "12 Oct 21:14".
    static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today \(time(date))" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time(date))" }
        return dayAndTime(date)
    }

    /// "18 Oct 14:02".
    static func dayAndTime(_ date: Date) -> String { "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time(date))" }

    private static func time(_ date: Date) -> String { date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }

    /// The interface's name as System Settings shows it ("Wi-Fi" for en0); nil when not found. Looked up once per name,
    /// not at each redraw of the line.
    static func interfaceName(_ bsd: String) -> String? {
        if let known = interfaceNames[bsd] { return known }
        let name = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface])?.first { SCNetworkInterfaceGetBSDName($0) as String? == bsd }
            .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
        interfaceNames[bsd] = name
        return name
    }
    private static var interfaceNames: [String: String?] = [:]

    /// What the search line says beside the Speed test crumb: the measure under way, "Done in 19 s · Wi-Fi", nothing after
    /// a failure.
    static func status(_ test: SpeedTest) -> String? {
        switch test.phase {
        case .running, .idle: return "Measuring with macOS networkQuality…"
        case .done(let r):
            var line = "Done"
            if let seconds = r.seconds { line += " in \(Int(seconds.rounded())) s" }
            if let name = r.interface.flatMap(interfaceName) { line += " · \(name)" }
            return line
        case .failed, .stopped: return nil
        }
    }

    /// The foot's keys for where the run is (frames 1 to 3).
    static func hints(_ test: SpeedTest) -> [KeyHint] {
        switch test.phase {
        case .running: [("⌘.", "stop"), ("Esc", "back")]
        case .done: [("↵", "run again"), ("⌘C", "copy result"), ("Esc", "back")]
        case .failed, .stopped, .idle: [("↵", "try again"), ("Esc", "back")]
        }
    }
}

/// The search line's right side: the time since the run started while it measures ("0:08"), the result's day and time
/// once done.
struct SpeedTestTrailing: View {
    @Environment(\.style) private var style
    let test: SpeedTest

    var body: some View {
        Group {
            switch test.phase {
            // The system counts it up itself, no timer here.
            case .running(let since): Text(timerInterval: since...Date.distantFuture, countsDown: false).foregroundStyle(style.color(\.text2))
            case .done(let r): Text(SpeedTestView.dayAndTime(r.at)).foregroundStyle(style.color(\.text))
            default: EmptyView()
            }
        }
        .styleText(\.mono).monospacedDigit().lineLimit(1).fixedSize()
    }
}

/// One gauge (the design's SVG arc): a 270° track from the lower left, filled on a log scale from 1 to 1000 Mbit/s, the
/// speed in its middle, its name under it; "—" before a reading.
private struct SpeedGauge: View {
    @Environment(\.style) private var style
    let title: String
    let value: Double?

    /// How far round the arc a speed sits: log10 of 1 to 1000, as a share.
    static func share(_ mbits: Double) -> Double { min(1, max(0, log10(max(mbits, 1)) / 3)) }

    var body: some View {
        let share = value.map(Self.share) ?? 0
        VStack(spacing: -6) {
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(style.color(\.line2), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(135))
                if value != nil {
                    Circle().trim(from: 0, to: 0.75 * share).stroke(style.color(\.accent), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(135))
                    let angle = (135 + 270 * share) * .pi / 180
                    Circle().fill(style.color(\.panel)).overlay { Circle().strokeBorder(style.color(\.accent), lineWidth: 3) }
                        .frame(width: 15, height: 15)
                        .offset(x: 78 * cos(angle), y: 78 * sin(angle))
                }
                VStack(spacing: 2) {
                    Text(value.map(SpeedTestView.mbits) ?? "—").font(style.font(\.mono, size: 32 / style.scale)).tracking(-0.6)
                        .foregroundStyle(style.color(value == nil ? \.text3 : \.text)).monospacedDigit()
                    Text("Mbit/s").font(style.font(\.mono, size: 11 / style.scale)).foregroundStyle(style.color(value == nil ? \.text3 : \.text2))
                }
                .offset(y: 6)
            }
            .frame(width: 156, height: 156)
            .overlay {
                // The scale's marks at the arc's ends and its quarters, as the design places them.
                ZStack {
                    ForEach(Array([("1", -67.0, 70.0), ("10", -76.0, -62.0), ("100", 76.0, -62.0), ("1000", 66.0, 70.0)].enumerated()), id: \.offset) { _, mark in
                        Text(mark.0).font(style.font(\.mono, size: 10 / style.scale)).foregroundStyle(style.color(\.text3)).offset(x: mark.1, y: mark.2)
                    }
                }
            }
            .frame(width: 210, height: 182)
            Text(title.uppercased()).styleText(\.eyebrow).foregroundStyle(style.color(\.text3))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value.map { SpeedTestView.mbits($0) + " megabits a second" } ?? "not measured yet")")
    }
}

/// The run's bar under the gauges: the time against networkQuality's usual 20 s, never full before the result.
private struct SpeedProgress: View {
    @Environment(\.style) private var style
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let share = min(0.97, context.date.timeIntervalSince(since) / 20)
            GeometryReader { box in
                Capsule().fill(style.color(\.line2))
                    .overlay(alignment: .leading) { Capsule().fill(style.color(\.accent)).frame(width: box.size.width * share) }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
    }
}

/// "Download, last 7 runs": the download of the last runs as a line over a baseline, the newest a filled dot; under it
/// the first run's day, the slowest run's day and speed, and now.
private struct SpeedRuns: View {
    @Environment(\.style) private var style
    let runs: [SpeedTest.Result]

    var body: some View {
        let shown = Array(runs.suffix(7)), values = shown.map(\.reading.download)
        let (lo, hi) = (values.min() ?? 0, values.max() ?? 0)
        let (w, h): (CGFloat, CGFloat) = (206, 52)
        let points = values.enumerated().map { i, v in
            CGPoint(x: 3 + (values.count > 1 ? CGFloat(i) * (w - 6) / CGFloat(values.count - 1) : w - 6),
                    y: 7 + (hi > lo ? (1 - (v - lo) / (hi - lo)) * 30 : 15))
        }
        VStack(alignment: .leading, spacing: 8) {
            InstrumentEyebrow(text: "Download, last \(shown.count) run\(shown.count == 1 ? "" : "s")")
            ZStack(alignment: .topLeading) {
                Path { $0.move(to: CGPoint(x: 3, y: 44)); $0.addLine(to: CGPoint(x: w - 3, y: 44)) }.stroke(style.color(\.line))
                Path { $0.addLines(points) }.stroke(style.color(\.accent), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                ForEach(Array(points.dropLast().enumerated()), id: \.offset) { _, p in
                    Circle().fill(style.color(\.panel)).overlay { Circle().strokeBorder(style.color(\.text3), lineWidth: 1.2) }
                        .frame(width: 5, height: 5).position(p)
                }
                if let last = points.last { Circle().fill(style.color(\.accent)).frame(width: 6, height: 6).position(last) }
            }
            .frame(width: w, height: h)
            if let first = shown.first, let slowest = shown.min(by: { $0.reading.download < $1.reading.download }) {
                HStack {
                    Text(first.at.formatted(.dateTime.day().month(.abbreviated)))
                    Spacer()
                    if shown.count > 2 { Text("\(slowest.at.formatted(.dateTime.day().month(.abbreviated))) · \(SpeedTestView.mbits(slowest.reading.download))") }
                    Spacer()
                    Text("now")
                }
                .font(style.font(\.mono, size: 10.5 / style.scale)).foregroundStyle(style.color(\.text3)).lineLimit(1)
                .frame(width: w)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download over the last \(shown.count) runs: \(values.map(SpeedTestView.mbits).joined(separator: ", ")) megabits a second")
    }
}
