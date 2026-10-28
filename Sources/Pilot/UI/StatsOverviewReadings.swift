import AppKit
import PilotCore
import SwiftUI

// Stats' Overview (Sven's card layout, 2026-10-12, in place of Comfortable): six cards (seven on a Mac with a battery),
// each its value now, a few figures and the range's sparkline along its foot, or the view picked for it (Line, Bars,
// Ring; Sven, 2026-10-12); Worth a look, what stands out among the busiest apps and the Mac's own
// readings; Right now, what holds the memory and the CPU as rings; and a footer counting the apps and processes. Reads
// only what the page already samples (SystemSampler: the readings every 2 s, the process list every 10 s).

/// The Overview: drawn from StatsReadings' tick, so the range's points are worked out once.
struct StatsOverviewReadings: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    let now: StatsReadings.Now
    let range: StatsRange
    let today: [StatsHistory.Point]
    let store: BarItemsStore
    let go: (AppPlace) -> Void

    /// Each card's colour, as the menu bar's dropdown colours its readings (ToyDropdown.module).
    private enum Module: Int { case cpu = 0, memory = 1, disk = 2, graphics = 3, heat = 4, network = 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Six in two rows of three; with a battery seven, four over three where four fit (Sven, 2026-10-12: both
            // Battery and Temperature), each row filling the width.
            CardGrid(minimum: 230, spacing: 12, most: 4, stretch: true, balance: true) {
                cpu
                memory
                graphics
                storage
                network
                temperature
                if now.raw?.battery != nil { battery }
            }
            WorthALook(findings: SystemSampler.shared.findings, reading: SystemSampler.shared.processCount == nil, go: go)
            RightNow(now: now)
            footer
        }
    }

    private func colour(_ module: Module) -> Color { ink.module(module.rawValue) }

    private func line(_ name: String, _ values: [Double?], _ module: Module, dashed: Bool = false) -> ChartLine {
        ChartLine(name: name, values: values, colour: colour(module), dashed: dashed)
    }

    /// A card's readings over the range, for whichever view it shows: `lines` on its chart, `spark` (else the first line)
    /// under its number and round its ring.
    private func trace(_ title: String, _ lines: [ChartLine], spark: (line: ChartLine, top: Double)? = nil, top: Double, label: String,
                       share: Double?, of: String? = nil, format: @escaping (Double) -> String) -> OverviewCard.Trace {
        OverviewCard.Trace(xs: now.series.xs, lines: lines, spark: spark?.line ?? lines[0], sparkTop: spark?.top ?? top, top: top,
                           topLabel: label, axis: now.axis, span: now.series.span, bars: StatsViews.barCount(range),
                           label: "\(title) \(now.words)", share: share, of: of, format: format)
    }

    private static let share = { (value: Double) in StatsFormat.percent(value) + "%" }

    // MARK: The cards

    private var cpu: some View {
        let v = now.values, split = v?.split
        let values = now.series[.cpu]
        let figures = [
            split.map { StatsFact("User", Self.percent($0[0])) }, split.map { StatsFact("System", Self.percent($0[1])) },
            StatsOverview.average(today.map(\.cpu)).map { StatsFact("Today", Self.percent($0), help: "The average since midnight, while Pilot read") },
            now.raw.map { StatsFact("Uptime", StatsFormat.duration($0.uptime)) },
        ]
        let top = StatsFormat.ceiling(values, steps: StatsFormat.shareSteps)
        return OverviewCard(kind: .cpu, card: .cpu, colour: .accent, store: store, open: ("Open Activity", { go(AppPlace(.activity)) }),
                            caption: now.row("Load").map { "Now · load \($0.components(separatedBy: " · ")[0])" } ?? "Now",
                            value: v?.cpu.map(StatsFormat.percent) ?? "–", unit: "%", figures: figures,
                            trace: trace("CPU", [line("CPU", values, .cpu)], top: top, label: Self.share(top), share: v?.cpu, format: Self.share))
    }

    private var memory: some View {
        let m = now.raw?.memory
        let used = m.map { SystemStats.memorySize($0.used).split(separator: " ") }
        let page = m?.pageSize ?? 0
        var figures: [StatsFact?] = m.map {
            [StatsFact("App", StatsFormat.memory($0.app)), StatsFact("Wired", StatsFormat.memory($0.wired * page)),
             StatsFact("Compressed", StatsFormat.memory($0.compressed * page))]
        } ?? []
        if let m, m.swapUsed > 0 { figures.append(StatsFact("Swap", StatsFormat.memory(m.swapUsed))) }
        let pressure = m?.pressure ?? .normal
        let badge = m.map { _ in
            OverviewCard.Badge(text: pressure.rawValue.capitalized + (now.values.map { " · \(StatsFormat.percent($0.ram)) %" } ?? ""),
                               tone: pressure == .normal ? .good : pressure == .warning ? .warn : .problem)
        }
        return OverviewCard(kind: .memory, card: .memory, colour: .second, store: store, open: ("Open Activity", { go(AppPlace(.activity)) }),
                            caption: m.map { "In use of \(SystemStats.memorySize($0.total))" } ?? "In use",
                            value: used.map { String($0[0]) } ?? "–", unit: used.map { String($0.last ?? "") } ?? "", badge: badge,
                            figures: figures, trace: trace("Memory", [line("Memory", now.series[.ram], .memory)], top: 1, label: "100%",
                                                           share: now.values?.ram, format: Self.share))
    }

    private var graphics: some View {
        let detail = now.raw?.gpuDetail
        let values = now.series[.gpu]
        let figures = [
            detail?.renderer.map { StatsFact("Renderer", Self.percent($0)) }, detail?.tiler.map { StatsFact("Tiler", Self.percent($0)) },
            StatsOverview.average(today.map(\.gpu)).map { StatsFact("Today", Self.percent($0), help: "The average since midnight, while Pilot read") },
            today.compactMap(\.gpu).max().map { StatsFact("Peak", Self.percent($0), help: "The busiest minute since midnight") },
        ]
        let top = StatsFormat.ceiling(values, steps: StatsFormat.shareSteps)
        return OverviewCard(kind: .graphics, card: .graphics, colour: .good, store: store, caption: now.row("Graphics") ?? "Now",
                            value: now.values?.gpu.map(StatsFormat.percent) ?? "–", unit: "%", figures: figures,
                            trace: trace("Graphics", [line("Graphics", values, .graphics)], top: top, label: Self.share(top),
                                         share: now.values?.gpu, format: Self.share))
    }

    private var storage: some View {
        let disk = now.raw?.slow.disk
        let free = disk.map { SystemStats.decimal(Double($0.available)).split(separator: " ") }
        // A macOS update wants about 20 GB free.
        let low = disk.map { $0.available < 20_000_000_000 } ?? false
        // Read and written together: what the disk did.
        let both = zip(now.series[.read], now.series[.write]).map { r, w in r == nil && w == nil ? nil : (r ?? 0) + (w ?? 0) }
        let figures = [
            now.values?.diskRead.map { StatsFact("Reading", StatsFormat.rateText($0)) }, now.values?.diskWrite.map { StatsFact("Writing", StatsFormat.rateText($0)) },
            today.isEmpty ? nil : StatsFact("Written today", StatsFormat.bytes(StatsOverview.total(perMinute: today.map(\.diskWrite))),
                                            help: "Written since midnight while Pilot read"),
        ]
        let reads = [line("Read", now.series[.read], .disk), line("Write", now.series[.write], .disk, dashed: true)]
        let top = StatsFormat.ceiling(now.series[.read] + now.series[.write], steps: StatsFormat.rateSteps)
        return OverviewCard(kind: .storage, card: .storage, title: "Disk", colour: .amber, store: store,
                            open: ("Clean this Mac", { PilotMenu.shared.toggle(branch: .clean) }),
                            caption: disk.map { "Free of \(SystemStats.decimal(Double($0.total)))" } ?? "Free",
                            value: free.map { String($0[0]) } ?? "–", unit: free.map { String($0.last ?? "") } ?? "",
                            aside: now.raw?.diskUsed.map { "\(StatsFormat.percent($0)) % used" }, warn: low, figures: figures,
                            trace: trace("Disk read and write", reads, spark: (line("Disk", both, .disk), StatsFormat.ceiling(both, steps: StatsFormat.rateSteps)), top: top, label: StatsFormat.rateLabel(top),
                                         share: now.raw?.diskUsed, of: "Disk", format: StatsFormat.rateText))
    }

    private var network: some View {
        @Bindable var settings = engine.settings
        let slow = now.raw?.slow
        let down = now.values?.down.map(StatsFormat.rate)
        let minus = { (n: Int) in "\(n)".replacingOccurrences(of: "-", with: "−") }
        let asks = "Asks api.ipify.org every 10 minutes while Stats shows"
        let publicIP = settings.showPublicIP
            ? StatsFact("Public IP", SystemSampler.shared.publicIP ?? "…", help: asks + "; click to stop") { settings.showPublicIP = false }
            : StatsFact("Public IP", "Show", link: true, help: asks + "; off, nothing leaves the Mac") { settings.showPublicIP = true }
        let figures = [
            today.isEmpty ? nil : StatsFact("Today", StatsFormat.bytes(StatsOverview.total(perMinute: today.map { p in (p.down ?? 0) + (p.up ?? 0) })),
                                            help: "Downloaded and uploaded since midnight while Pilot read"),
            slow?.wifi.map { StatsFact("Signal", "\(minus($0.signal)) dBm") }, slow?.localIP.map { StatsFact("Address", $0) }, publicIP,
        ]
        let values = now.series[.down]
        let top = StatsFormat.ceiling(values + now.series[.up], steps: StatsFormat.rateSteps)
        return OverviewCard(kind: .network, card: .network, colour: .third, store: store, caption: "Downloading" + (slow?.wifi == nil ? "" : " · Wi-Fi"),
                            value: down?.value ?? "–", unit: down?.unit ?? "", aside: now.values?.up.map { "↑ " + StatsFormat.rateText($0) },
                            figures: figures,
                            trace: trace("Download and upload", [line("↓ Down", values, .network), line("↑ Up", now.series[.up], .network, dashed: true)],
                                         top: top, label: StatsFormat.rateLabel(top), share: now.values?.down.map { $0 / top }, of: "Down",
                                         format: StatsFormat.rateText))
    }

    /// A Mac with a battery: its charge, what is left, the draw and its health. No history is kept, so no sparkline.
    private var battery: some View {
        let battery = now.raw?.battery, health = now.raw?.slow.batteryHealth
        let state = battery.map { $0.charging ? "Charging" : $0.pluggedIn ? "Plugged in" : "On battery" } ?? "Battery"
        let left = battery?.minutesLeft.map { StatsFact(battery?.charging == true ? "To full" : "Remaining", StatsFormat.duration(Double($0) * 60)) }
        let figures = [left, now.power.map { StatsFact("Power draw", String(format: "%.1f W", $0)) }, health.map { StatsFact("Health", "\($0.percent) %") },
                       health.map { StatsFact("Cycles", "\($0.cycles)") }]
        return OverviewCard(kind: .battery, colour: .good, store: store, caption: state, value: battery.map { "\($0.percent)" } ?? "–", unit: "%",
                            warn: (battery?.percent ?? 100) < 20 && battery?.pluggedIn == false, figures: figures, trace: nil)
    }

    /// The CPU's temperature, the hottest sensor, the fan and what the Mac draws.
    private var temperature: some View {
        let sensors = now.raw?.sensors
        let temperature = { (prefixes: [String]) in sensors.flatMap { SystemStats.temperature($0.temperatures, prefixes: prefixes) } }
        let degrees = { (t: Double) in "\(StatsFormat.whole(t)) °C" }
        let fan = sensors?.fans.first { $0.actual.isFinite && $0.actual >= 0 && $0.actual < 20_000 }
        let figures = [temperature(SystemStats.cpuSensors).map { StatsFact("Hottest", degrees($0.hottest)) },
                       temperature(SystemStats.gpuSensors).map { StatsFact("Graphics", degrees($0.average)) },
                       fan.map { StatsFact("Fan", "\(StatsFormat.whole($0.actual)) rpm") },
                       now.power.map { StatsFact("Power draw", String(format: "%.1f W", $0)) }]
        let values = now.series[.heat]
        let top = StatsFormat.ceiling(values, steps: StatsFormat.heatSteps, headroom: 1.25)
        // The ring against the charts' highest ceiling, so it never jumps as the chart's does.
        let most = StatsFormat.heatSteps[StatsFormat.heatSteps.count - 1]
        return OverviewCard(kind: .heat, card: .temperature, colour: .problem, store: store,
                            caption: sensors == nil ? "No temperature reads on this Mac" : "CPU average",
                            value: now.values?.heat.map(StatsFormat.whole) ?? "–", unit: "°C", figures: figures,
                            trace: trace("CPU temperature", [line("CPU", values, .heat)], top: top, label: "\(Int(top))°",
                                         share: now.values?.heat.map { $0 / most }, format: degrees))
    }

    // MARK: The foot

    /// "24 apps · 612 processes", and how the rings count.
    private var footer: some View {
        let apps = NSWorkspace.shared.runningApplications.lazy.filter { $0.activationPolicy == .regular }.count
        let processes = SystemSampler.shared.processCount.map { " · \($0) processes" } ?? ""
        return Text("\(apps) apps\(processes) · By app groups as Activity does: each app with what it started, memory as its footprint.")
            .font(ink.ui(11.5)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
    }

    static func percent(_ share: Double) -> String { StatsFormat.percent(share) + " %" }
}

// MARK: - A card

/// One of the cards: its title with its view, In menu bar and a chevron where it leads somewhere, a caption, then its
/// view: Number (the default) the value now, up to four figures in a row and the range's sparkline along its foot; Line
/// and Bars the value, the figures and the range's chart; Ring the value round its share, the range's lowest, average
/// and highest, and the figures.
struct OverviewCard: View {
    @Environment(\.ink) private var ink
    @Environment(\.statsViews) private var views

    /// A card's readings over the range, as each view draws them.
    struct Trace {
        let xs: [Double]
        /// The chart's lines (two rates on Disk and Network, the second dashed).
        let lines: [ChartLine]
        /// The sparkline's and the ring's line, and the sparkline's top.
        let spark: ChartLine
        let sparkTop: Double
        let top: Double
        let topLabel: String
        let axis: [String]
        let span: TimeInterval
        let bars: Int
        /// What VoiceOver calls the chart.
        let label: String
        /// The ring's share of its top now; nil before a reading.
        let share: Double?
        /// What the ring's lowest, average and highest are of, when not the card's own value.
        var of: String?
        let format: (Double) -> String
    }

    struct Badge {
        enum Tone { case good, warn, problem }
        let text: String
        let tone: Tone
    }

    let kind: BarKind
    /// The card whose view is picked; nil for one without a history (Battery), always a Number.
    var card: StatsCard?
    var title: String?
    let colour: TileColour
    let store: BarItemsStore
    var open: (label: String, action: () -> Void)?
    let caption: String
    let value: String
    let unit: String
    var aside: String?
    var badge: Badge?
    var warn = false
    let figures: [StatsFact]
    let trace: Trace?

    init(kind: BarKind, card: StatsCard? = nil, title: String? = nil, colour: TileColour, store: BarItemsStore,
         open: (label: String, action: () -> Void)? = nil, caption: String, value: String, unit: String, aside: String? = nil,
         badge: Badge? = nil, warn: Bool = false, figures: [StatsFact?], trace: Trace?) {
        self.kind = kind; self.card = card; self.title = title; self.colour = colour; self.store = store; self.open = open
        self.caption = caption; self.value = value; self.unit = unit; self.aside = aside; self.badge = badge; self.warn = warn
        self.figures = Array(figures.compactMap(\.self).prefix(4)); self.trace = trace
    }

    var body: some View {
        let view = trace == nil ? .number : card.flatMap { views?.views.view($0) } ?? .number
        VStack(alignment: .leading, spacing: 0) {
            header
            if view == .ring, let trace {
                // The ring carries the value; what it means stays beside the caption.
                // Side by side, or the note under the caption when both would not fit whole.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { captionText.fixedSize(); Spacer(minLength: 0); note }
                    VStack(alignment: .leading, spacing: 6) { captionText; note }
                }
                .padding(.top, 8)
                let spread = StatsViews.spread(trace.spark.values).map { (trace.format($0.low), trace.format($0.average), trace.format($0.high)) }
                StatsRing(share: trace.share, value: value, unit: unit, colour: trace.spark.colour, of: trace.of, spread: spread, size: 112)
                if !figures.isEmpty { row.padding(.top, 12) }
                Spacer(minLength: 0)
            } else {
                captionText.padding(.top, 8)
                big
                if !figures.isEmpty { row.padding(.top, 10) }
                Spacer(minLength: 0)
                if let trace {
                    if view == .number {
                        StatsSparkline(xs: trace.xs, line: trace.spark, top: trace.sparkTop).padding(.top, 4)
                    } else {
                        StatsChart(xs: trace.xs, lines: trace.lines, top: trace.top, topLabel: trace.topLabel, axis: trace.axis, span: trace.span,
                                   format: trace.format, label: trace.label, bars: view == .bars ? trace.bars : nil, height: 72)
                            .padding(.top, 12)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .statsBlock()
    }

    private var captionText: some View {
        Text(caption).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.tail)
    }

    private var header: some View {
        HStack(spacing: 4) {
            StatsTitle(title: title ?? kind.statsTitle, symbol: kind.symbol, colour: colour)
            Spacer(minLength: 0)
            if let card, trace != nil { ViewSwitch(card: card) }
            PinButton(kind: kind, store: store, short: true)
            if let open {
                Button(action: open.action) {
                    Image(systemName: "chevron.right").font(ink.ui(10.5, .semibold)).foregroundStyle(ink.muted)
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .buttonStyle(.kitPress)
                .help(open.label)
                .accessibilityLabel(open.label)
            }
        }
    }

    /// The value in the display face, its unit small, and at the right what it means or its badge; the note under the
    /// value when both would not fit the column.
    private var big: some View {
        let number = Text(value).font(ink.display(32)).tracking(ink.displayTracking(32)).foregroundStyle(warn ? ink.warnText : ink.text)
        let small = Text(" " + unit).font(ink.display(14)).foregroundStyle(ink.muted)
        let reading = Text("\(number)\(small)").lineLimit(1).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) { reading; Spacer(minLength: 0); note.fixedSize() }
            VStack(alignment: .leading, spacing: 4) { reading; note }
        }
        .monospacedDigit()
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    /// What the value means at its right: its badge (Memory's pressure) or a word (Disk's used share, Network's upload).
    @ViewBuilder private var note: some View {
        if let badge { BadgeView(badge: badge) }
        if let aside {
            HStack(spacing: 3) {
                if warn { Image(systemName: "exclamationmark.triangle").font(ink.ui(11)) }
                Text(aside)
            }
            .font(ink.ui(12)).foregroundStyle(warn ? ink.warnText : ink.text2).lineLimit(1)
        }
    }

    /// The figures side by side, each its name over its value; fewer when four would cut their words, down to the first
    /// two cut short at the narrowest column, so the row never pushes the card past its column (Sven, build 42: Network's
    /// three whole figures ran under Temperature).
    private var row: some View {
        ViewThatFits(in: .horizontal) {
            row(figures)
            row(Array(figures.prefix(3)))
            row(Array(figures.prefix(2)))
            row(Array(figures.prefix(2)), whole: false)
        }
    }

    private func row(_ shown: [StatsFact], whole: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(shown.indices, id: \.self) { i in figure(shown[i], whole: whole) }
        }
    }

    @ViewBuilder private func figure(_ fact: StatsFact, whole: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fact.label).font(ink.ui(11)).foregroundStyle(ink.muted)
            Group {
                if let action = fact.action {
                    Button(action: action) {
                        Text(fact.value).foregroundStyle(fact.link ? ink.link : ink.text).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(fact.value).foregroundStyle(ink.text)
                }
            }
            .font(ink.ui(12.5, .medium)).monospacedDigit()
        }
        .lineLimit(1).truncationMode(.tail)
        // Its whole words, so the row's ViewThatFits drops a figure rather than cut one, until the last resort.
        .fixedSize(horizontal: whole, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(fact.help ?? "")
        .accessibilityElement(children: .combine)
    }

    private struct BadgeView: View {
        @Environment(\.ink) private var ink
        let badge: Badge

        var body: some View {
            let tint = switch badge.tone {
            case .good: ink.green
            case .warn: ink.yellow
            case .problem: ink.red
            }
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(badge.text).foregroundStyle(ink.text2)
            }
            .font(ink.ui(11, .medium)).lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: .capsule)
        }
    }
}

// MARK: - Worth a look

/// What stands out, from the busiest apps across the listings and the Mac's own readings (StatsOverview.Watch): three
/// rows, then Show all. A row about an app opens Activity, the disk's opens Clean.
private struct WorthALook: View {
    @Environment(\.ink) private var ink
    let findings: [StatsOverview.Finding]
    /// No process listing yet.
    let reading: Bool
    let go: (AppPlace) -> Void
    @State private var all = false
    static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                OverviewHeading(text: "Worth a look")
                Spacer(minLength: 0)
                if findings.count > Self.shown {
                    AccentLink(title: all ? "Show fewer" : "Show all \(findings.count)") { all.toggle() }
                }
            }
            VStack(spacing: 0) {
                if findings.isEmpty {
                    quiet
                } else {
                    let rows = all ? findings : Array(findings.prefix(Self.shown))
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, finding in
                        FindingRow(finding: finding, first: i == 0, open: open(finding))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 2)
            .blockSurface()
        }
    }

    private var quiet: some View {
        HStack(spacing: 12) {
            Image(systemName: reading ? "hourglass" : "checkmark.circle").font(ink.ui(15)).foregroundStyle(reading ? ink.muted : ink.green)
                .frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(reading ? "Looking…" : "Nothing stands out").font(ink.ui(13, .medium)).foregroundStyle(ink.text)
                Text(reading ? "Pilot looks at the busiest apps every 10 seconds while Stats shows."
                     : "No app is hogging the CPU or its memory, and the Mac has room to spare.")
                    .font(ink.ui(12)).foregroundStyle(ink.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func open(_ finding: StatsOverview.Finding) -> (label: String, action: () -> Void)? {
        if finding.app != nil { return ("Open Activity", { go(AppPlace(.activity)) }) }
        if finding.tag == .disk { return ("Clean this Mac", { PilotMenu.shared.toggle(branch: .clean) }) }
        return nil
    }
}

/// A section's name over its cards.
private struct OverviewHeading: View {
    @Environment(\.ink) private var ink
    let text: String
    var body: some View {
        Text(text).font(ink.ui(15, .semibold)).foregroundStyle(ink.text).accessibilityAddTraits(.isHeader)
    }
}

/// One finding: the app's icon or the tag's glyph, what it is and why, its value now, its tag and when it was first seen.
private struct FindingRow: View {
    @Environment(\.ink) private var ink
    let finding: StatsOverview.Finding
    let first: Bool
    let open: (label: String, action: () -> Void)?

    var body: some View {
        if let open {
            Button(action: open.action) { content(chevron: true) }.buttonStyle(.plain).help(open.label)
        } else {
            content(chevron: false)
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack(spacing: 12) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(ink.ui(13, .medium)).foregroundStyle(ink.text)
                Text(finding.line).font(ink.ui(12)).foregroundStyle(ink.muted)
            }
            .lineLimit(1).truncationMode(.tail)
            .layoutPriority(-1)
            Spacer(minLength: 12)
            Text(finding.value).font(ink.ui(12, .medium)).foregroundStyle(ink.text2).monospacedDigit().lineLimit(1).fixedSize()
            TagChip(tag: finding.tag)
            // Redrawn with the readings every 2 s; no timer of its own.
            Text(StatsOverview.ago(finding.since, now: Date())).font(ink.ui(11.5)).foregroundStyle(ink.muted).monospacedDigit()
                .lineLimit(1).frame(minWidth: 70, alignment: .trailing)
            Image(systemName: "chevron.right").font(ink.ui(10, .semibold)).foregroundStyle(ink.muted).opacity(chevron ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .overlay(alignment: .top) { if !first { ink.line.frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        if let app = finding.app {
            AppIcon(name: app, size: 24, glyph: "macwindow")
        } else {
            KitTile(symbol: TagChip.symbol(finding.tag), colour: TagChip.colour(finding.tag), size: 24)
        }
    }
}

/// A finding's tag: its word in its colour on a soft fill.
private struct TagChip: View {
    @Environment(\.ink) private var ink
    let tag: StatsOverview.Finding.Tag

    static func symbol(_ tag: StatsOverview.Finding.Tag) -> String {
        switch tag {
        case .cpu: BarKind.cpu.symbol
        case .memory: BarKind.memory.symbol
        case .disk: BarKind.storage.symbol
        case .heat: BarKind.heat.symbol
        case .battery: BarKind.battery.symbol
        }
    }

    static func colour(_ tag: StatsOverview.Finding.Tag) -> TileColour {
        switch tag {
        case .cpu: .accent
        case .memory: .second
        case .disk: .amber
        case .heat: .problem
        case .battery: .good
        }
    }

    var body: some View {
        let tint = ink.module([StatsOverview.Finding.Tag.cpu: 0, .memory: 1, .disk: 2, .heat: 4, .battery: 2][tag] ?? 0)
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(tag)).font(ink.ui(9.5, .semibold))
            Text(tag.rawValue)
        }
        .font(ink.ui(11, .semibold)).foregroundStyle(ink.isInstrument ? ink.text2 : ink.text)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(ink.isInstrument ? 0.18 : 0.35), in: .capsule)
        .fixedSize()
    }
}

// MARK: - Right now

/// What holds the memory and the CPU now, as rings: memory by type from the reading, memory and CPU by app from the
/// last process listing.
private struct RightNow: View {
    @Environment(\.ink) private var ink
    let now: StatsReadings.Now

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverviewHeading(text: "Right now")
            CardGrid(minimum: 230, spacing: 12, most: 3, stretch: true) {
                memoryByType
                memoryByApp
                cpuByApp
            }
        }
    }

    private var others: Color { ink.text.opacity(0.3) }

    private func colours(_ slices: [StatsOverview.Slice]) -> [Color] {
        slices.enumerated().map { i, slice in slice.name == "Other" ? others : ink.graph(i) }
    }

    private var memoryByType: some View {
        let m = now.raw?.memory
        let page = m?.pageSize ?? 0, total = Double(m?.total ?? 0)
        let cached = Double(((m?.purgeable ?? 0) + (m?.external ?? 0)) * page)
        let parts: [(String, Double)] = m.map { m in
            [("App", Double(m.app)), ("Wired", Double(m.wired * page)), ("Compressed", Double(m.compressed * page)), ("Cached", cached)]
        } ?? []
        let free = max(0, total - parts.reduce(0) { $0 + $1.1 })
        let tints = [ink.graph(1), ink.graph(0), ink.graph(2), ink.graph(3)]
        // A part macOS reports none of (no cached files) stays out of the key.
        let rows = parts.enumerated().filter { $0.element.1 > 0 }
            .map { i, part in RingRow(name: part.0, value: StatsFormat.memory(UInt64(part.1)), colour: tints[i], amount: part.1) }
            + (m == nil ? [] : [RingRow(name: "Free", value: StatsFormat.memory(UInt64(free)), colour: ink.text.opacity(0.12), amount: free, ring: false)])
        return RingCard(title: "Memory by type", symbol: BarKind.memory.symbol, colour: .second, whole: total, rows: rows,
                        centre: now.values.map { StatsFormat.percent($0.ram) + " %" } ?? "–", caption: "in use")
    }

    private var memoryByApp: some View {
        let m = now.raw?.memory
        let apps = SystemSampler.shared.appsByMemory
        let slices = StatsOverview.slices(apps.map { .init(name: $0.name, amount: Double($0.memory)) }, total: Double(m?.used ?? 0))
        let tints = colours(slices)
        let rows = slices.enumerated().map { i, s in
            RingRow(name: s.name, value: StatsFormat.memory(UInt64(s.amount)), colour: tints[i], amount: s.amount, app: s.name != "Other")
        }
        return RingCard(title: "Memory by app", symbol: "square.stack.3d.up", colour: .second, whole: Double(m?.total ?? 0),
                        rows: apps.isEmpty ? [] : rows, centre: m.map { SystemStats.memorySize($0.used) } ?? "–", caption: "in use")
    }

    private var cpuByApp: some View {
        // ps counts a share of one core; the ring's whole is every core.
        let read = now.raw?.cores.count ?? 0
        let cores = read > 0 ? read : max(1, ProcessInfo.processInfo.activeProcessorCount)
        let whole = Double(cores) * 100
        let apps = SystemSampler.shared.appsByCPU
        let slices = StatsOverview.slices(apps.map { .init(name: $0.name, amount: $0.cpu) }, total: (now.values?.cpu ?? 0) * whole)
        let tints = colours(slices)
        let rows = slices.enumerated().map { i, s in
            RingRow(name: s.name, value: String(format: "%.1f %%", s.amount), colour: tints[i], amount: s.amount, app: s.name != "Other")
        }
        return RingCard(title: "CPU by app", symbol: BarKind.cpu.symbol, colour: .accent, whole: whole, rows: apps.isEmpty ? [] : rows,
                        centre: now.values?.cpu.map { StatsFormat.percent($0) + " %" } ?? "–", caption: "in use",
                        note: "A share of one core, as Activity Monitor counts it")
    }
}

/// One line of a ring's key, and its part of the ring.
private struct RingRow {
    let name: String
    let value: String
    let colour: Color
    let amount: Double
    /// Drawn in the ring (Free is the track).
    var ring = true
    /// An app, shown with its icon.
    var app = false
}

/// A ring card: its title, the ring with its figure in the middle, and its key with each part's value.
private struct RingCard: View {
    @Environment(\.ink) private var ink
    let title: String
    let symbol: String
    let colour: TileColour
    let whole: Double
    let rows: [RingRow]
    let centre: String
    let caption: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatsTitle(title: title, symbol: symbol, colour: colour)
            HStack(alignment: .center, spacing: 16) {
                ring
                if rows.isEmpty {
                    FinePrint(text: "Reading…").frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 5) { ForEach(rows.indices, id: \.self) { key(rows[$0]) } }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .statsBlock()
        .help(note ?? "")
    }

    private var ring: some View {
        let parts = rows.filter(\.ring)
        return ZStack {
            Canvas { context, size in
                let width: CGFloat = 11, rect = CGRect(origin: .zero, size: size).insetBy(dx: width / 2, dy: width / 2)
                let centre = CGPoint(x: rect.midX, y: rect.midY), radius = rect.width / 2
                context.stroke(Path(ellipseIn: rect), with: .color(ink.text.opacity(0.08)), lineWidth: width)
                guard whole > 0 else { return }
                // Each part from the top, clockwise, a hair apart.
                let gap = parts.count > 1 ? 1.2 : 0
                var start = -90.0
                for part in parts {
                    let sweep = 360 * min(1, part.amount / whole)
                    if sweep > gap {
                        var path = Path()
                        path.addArc(center: centre, radius: radius, startAngle: .degrees(start), endAngle: .degrees(start + sweep - gap), clockwise: false)
                        context.stroke(path, with: .color(part.colour), lineWidth: width)
                    }
                    start += sweep
                }
            }
            VStack(spacing: 0) {
                Text(centre).font(ink.display(17)).foregroundStyle(ink.text)
                Text(caption).font(ink.ui(10.5)).foregroundStyle(ink.muted)
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).padding(16)
        }
        .frame(width: 96, height: 96)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(centre) \(caption); " + rows.map { "\($0.name) \($0.value)" }.joined(separator: ", "))
    }

    private func key(_ row: RingRow) -> some View {
        HStack(spacing: 6) {
            Circle().fill(row.colour).frame(width: 7, height: 7)
            if row.app { AppIcon(name: row.name, size: 14, glyph: "macwindow") }
            Text(row.name).font(ink.ui(12)).foregroundStyle(ink.text).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(row.value).font(ink.ui(11.5)).foregroundStyle(ink.text2).monospacedDigit().fixedSize()
        }
        .lineLimit(1)
        .accessibilityHidden(true)
    }
}
