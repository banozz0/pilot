import AppKit
import PilotCore
import SwiftUI

// Stats' blocks (card agent-bo-95422992): one per reading, each its value now with what it means and its chart over the
// range History picks; the readings the menu bar can show carry In menu bar. Busiest apps ranks right now.

/// Compact's nine blocks in rows: CPU, Memory, Storage; Network, Temperature, Fan; Graphics, Batteries, Busiest apps; or
/// the Overview (StatsOverviewReadings). Reads the sampler once a tick, so the range's points are worked out once;
/// Busiest apps reads its own.
struct StatsReadings: View {
    @Environment(\.ink) private var ink
    let range: StatsRange
    /// The CPU chart's crosshair, for a render.
    let hover: Double?
    let store: BarItemsStore
    /// Each card's view and the page's layout.
    let views: StatsViewsStore
    /// Opens another page (the Overview's chevrons and Worth a look's rows).
    var go: (AppPlace) -> Void = { _ in }

    /// What every block reads this tick.
    struct Now {
        let series: StatsSeries
        let axis: [String]
        let values: SystemStats.Values?
        let raw: SystemStats.Raw?
        let rows: [SystemStats.Row]
        /// The whole Mac's draw in watts, where the SMC gives a sane one.
        let power: Double?
        /// "over the last 2 minutes", for VoiceOver.
        let words: String

        /// This Mac's row of that name, as Home's full list words it; nil until it reads.
        func row(_ name: String) -> String? { rows.first { $0.name == name }.flatMap { $0.value == "—" ? nil : $0.value } }
    }

    var body: some View {
        let system = SystemSampler.shared, date = Date()
        // Today's minutes once: Network's total reads them on every range.
        let today = system.minutes.points(.today, now: date)
        let series: StatsSeries = switch range {
        case .twoMinutes: .twoMinutes(system.history)
        case .hour: .minutes(system.minutes.points(.hour, now: date), range: .hour, now: date)
        case .today: .minutes(today, range: .today, now: date)
        }
        let raw = system.latest
        let now = Now(series: series, axis: range.axis(now: date), values: system.latestValues, raw: raw, rows: system.rows,
                      power: raw?.sensors?.power.flatMap { $0.isFinite && $0 > 0 && $0 < 2000 ? $0 : nil }, words: Self.words(range))
        Group { readings(now, today: today) }.environment(\.statsViews, views)
    }

    /// Compact's nine blocks, or the Overview.
    @ViewBuilder private func readings(_ now: Now, today: [StatsHistory.Point]) -> some View {
        if compact {
            // Five across at their own height (Toybox's wider sidebar included), every card on one 1440 by 900 screen.
            CardGrid(minimum: 196, spacing: 10, most: 5, stretch: true) {
                cpu(now)
                memory(now)
                storage(now)
                network(now, today: today)
                temperature(now)
                fan(now)
                graphics(now)
                batteries(now)
                BusiestBlock(store: store)
            }
        } else {
            StatsOverviewReadings(now: now, range: range, today: today, store: store, go: go)
        }
    }

    static func words(_ range: StatsRange) -> String {
        switch range {
        case .twoMinutes: "over the last 2 minutes"
        case .hour: "over the last hour"
        case .today: "today"
        }
    }

    private var compact: Bool { views.views.layout == .compact }

    private func chart(_ now: Now, _ lines: [ChartLine], top: Double, label: String, title: String, hover: Double? = nil, bars: Bool,
                       format: @escaping (Double) -> String) -> some View {
        StatsChart(xs: now.series.xs, lines: lines, top: top, topLabel: label, axis: now.axis, span: now.series.span, format: format,
                   hover: hover, label: "\(title) \(now.words)", bars: bars ? StatsViews.barCount(range) : nil, height: 64)
    }

    /// Two rates on one chart under their key: read and write, down and up.
    @ViewBuilder private func rates(_ now: Now, _ first: ChartLine, _ second: ChartLine, current: (Double?, Double?), title: String,
                                    bars: Bool) -> some View {
        let top = StatsFormat.ceiling(first.values + second.values, steps: StatsFormat.rateSteps)
        ChartKey(items: [(first, StatsFormat.rateText(current.0)), (second, StatsFormat.rateText(current.1))])
        chart(now, [first, second], top: top, label: StatsFormat.rateLabel(top), title: title, bars: bars, format: StatsFormat.rateText)
    }

    /// What a Ring and a Number read off a card: its value now (the big number) and its share of the top, and the line
    /// the sparkline draws and the ring's lowest, average and highest come from.
    struct Gauge {
        let value: String
        var unit = ""
        var detail: String?
        var warn = false
        let share: Double?
        let line: ChartLine
        let top: Double
        /// The line's name under the ring, when the big number is not that line (Storage's used share over its reads).
        var of: String?
        let format: (Double) -> String
    }

    /// A card in its view: Line and Bars the big number and the chart; Ring the gauge; Number the big number, larger,
    /// over a sparkline.
    @ViewBuilder private func shown(_ card: StatsCard, _ now: Now, _ g: Gauge, @ViewBuilder chart: (_ bars: Bool) -> some View) -> some View {
        let view = views.views.view(card)
        switch view {
        case .line, .bars:
            BigValue(value: g.value, unit: g.unit, detail: g.detail, warn: g.warn)
            chart(view == .bars)
        case .ring:
            let spread = StatsViews.spread(g.line.values).map { (g.format($0.low), g.format($0.average), g.format($0.high)) }
            StatsRing(share: g.share, value: g.value, unit: g.unit, colour: g.line.colour, detail: g.detail, of: g.of, spread: spread, size: 92)
        case .number:
            // The number takes the card's width; what it means goes under it.
            BigValue(value: g.value, unit: g.unit, size: 1.6)
            if let detail = g.detail {
                Text(detail).font(ink.ui(12)).foregroundStyle(g.warn ? ink.warnText : ink.muted).lineLimit(1).truncationMode(.tail)
            }
            StatsSparkline(xs: now.series.xs, line: g.line, top: g.top)
        }
    }

    /// A card with one line: its chart drawn from the gauge's line, top and format.
    private func shown(_ card: StatsCard, _ now: Now, _ g: Gauge, label: String, title: String, hover: Double? = nil) -> some View {
        shown(card, now, g) { bars in
            chart(now, [g.line], top: g.top, label: label, title: title, hover: hover, bars: bars, format: g.format)
        }
    }

    private static let percent = { (share: Double) in StatsFormat.percent(share) + "%" }

    // MARK: CPU, Memory, Storage

    private func cpu(_ now: Now) -> some View {
        let v = now.values
        let split = v?.split.map { "\(StatsFormat.percent($0[0]))% apps · \(StatsFormat.percent($0[1]))% macOS" }
        let line = ChartLine(name: "CPU", values: now.series[.cpu], colour: ink.graph(0))
        let top = StatsFormat.ceiling(line.values, steps: StatsFormat.shareSteps)
        return StatsBlock(kind: .cpu, colour: .accent, store: store, card: .cpu) {
            shown(.cpu, now, Gauge(value: v?.cpu.map(StatsFormat.percent) ?? "–", unit: "%", detail: split, share: v?.cpu, line: line, top: top,
                                   format: Self.percent), label: Self.percent(top), title: "CPU", hover: hover)
        }
    }

    private func memory(_ now: Now) -> some View {
        let m = now.raw?.memory
        let line = ChartLine(name: "Memory", values: now.series[.ram], colour: ink.graph(1))
        return StatsBlock(kind: .memory, colour: .second, store: store, card: .memory) {
            shown(.memory, now, Gauge(value: now.values.map { StatsFormat.percent($0.ram) } ?? "–", unit: "%", detail: now.row("RAM"),
                                      warn: (m?.pressure ?? .normal) != .normal, share: now.values?.ram, line: line, top: 1, format: Self.percent),
                  label: "100%", title: "Memory")
        }
    }

    private func storage(_ now: Now) -> some View {
        // A macOS update wants about 20 GB free.
        let low = (now.raw?.slow.disk).map { $0.available < 20_000_000_000 } ?? false
        let read = ChartLine(name: "Read", values: now.series[.read], colour: ink.graph(0))
        let used = now.raw?.diskUsed
        return StatsBlock(kind: .storage, colour: .amber, store: store, card: .storage) {
            shown(.storage, now, Gauge(value: used.map(StatsFormat.percent) ?? "–", unit: "%", detail: now.row("Disk"), warn: low, share: used,
                                       line: read, top: StatsFormat.ceiling(read.values, steps: StatsFormat.rateSteps), of: "Read",
                                       format: StatsFormat.rateText)) { bars in
                rates(now, read, ChartLine(name: "Write", values: now.series[.write], colour: ink.graph(1), dashed: true),
                      current: (now.values?.diskRead, now.values?.diskWrite), title: "Disk read and write", bars: bars)
            }
        }
    }

    // MARK: Network, Temperature, Fan

    private func network(_ now: Now, today: [StatsHistory.Point]) -> some View {
        let slow = now.raw?.slow
        let down = now.values?.down.map(StatsFormat.rate)
        let downLine = ChartLine(name: "↓ Down", values: now.series[.down], colour: ink.graph(0))
        let top = StatsFormat.ceiling(downLine.values, steps: StatsFormat.rateSteps)
        return StatsBlock(kind: .network, colour: .third, store: store, card: .network) {
            shown(.network, now, Gauge(value: down?.value ?? "–", unit: down?.unit ?? "", detail: "down now" + (slow?.wifi == nil ? "" : " · Wi-Fi"),
                                       share: now.values?.down.map { $0 / top }, line: downLine, top: top, format: StatsFormat.rateText)) { bars in
                rates(now, downLine, ChartLine(name: "↑ Up", values: now.series[.up], colour: ink.graph(1), dashed: true),
                      current: (now.values?.down, now.values?.up), title: "Download and upload", bars: bars)
            }
        }
    }

    private func temperature(_ now: Now) -> some View {
        let sensors = now.raw?.sensors
        let cpu = sensors.flatMap { SystemStats.temperature($0.temperatures, prefixes: SystemStats.cpuSensors) }
        let degrees = { (t: Double) in "\(StatsFormat.whole(t)) °C" }
        let line = ChartLine(name: "CPU", values: now.series[.heat], colour: ink.graph(2))
        let top = StatsFormat.ceiling(line.values, steps: StatsFormat.heatSteps, headroom: 1.25)
        // The ring against the charts' highest ceiling, so it never jumps as the chart's does.
        let most = StatsFormat.heatSteps[StatsFormat.heatSteps.count - 1]
        return StatsBlock(kind: .heat, colour: .problem, store: store, card: .temperature) {
            shown(.temperature, now, Gauge(value: now.values?.heat.map(StatsFormat.whole) ?? "–", unit: "°C",
                                           detail: cpu.map { "CPU average · hottest \(degrees($0.hottest))" } ?? "No temperature reads on this Mac",
                                           share: now.values?.heat.map { $0 / most }, line: line, top: top, format: degrees),
                  label: "\(Int(top))°", title: "CPU temperature")
        }
    }

    private func fan(_ now: Now) -> some View {
        let sane = { (rpm: Double) in rpm.isFinite && rpm >= 0 && rpm < 20_000 }
        let fans = now.raw?.sensors?.fans.filter { sane($0.actual) } ?? []
        let fan = fans.first
        let topSpeed = fan.flatMap { sane($0.maximum) && $0.maximum > 0 ? $0.maximum : nil }
        let line = ChartLine(name: "Fan", values: now.series[.fan], colour: ink.graph(2))
        let top = topSpeed ?? max(1000, (line.values.compactMap(\.self).max() ?? 0) * 1.2)
        let share = fan.flatMap { f in topSpeed.map { f.actual / $0 } }
        let feel = share.map { $0 < 0.35 ? "quiet" : $0 < 0.65 ? "audible" : "loud" }
        let rpm = { (value: Double) in "\(StatsFormat.whole(value)) rpm" }
        let counts = ["one", "two", "three", "four"]
        return StatsBlock("Fan", symbol: "fan", colour: .third, note: fans.isEmpty ? nil : fans.count <= counts.count ? counts[fans.count - 1] : "\(fans.count)",
                          card: .fan) {
            if let fan {
                shown(.fan, now, Gauge(value: StatsFormat.whole(fan.actual), unit: "rpm",
                                       detail: [feel, share.map { "\(StatsFormat.percent($0))% of its top speed" }].compactMap(\.self).joined(separator: " · "),
                                       share: fan.actual / top, line: line, top: top, format: rpm),
                      label: String(format: "%.1fk", top / 1000), title: "Fan speed")
            } else {
                FinePrint(text: now.raw?.sensors == nil ? "No fan reads on this Mac." : "This Mac has no fan.").padding(.top, 8)
            }
        }
    }

    // MARK: Graphics, Batteries

    private func graphics(_ now: Now) -> some View {
        let line = ChartLine(name: "Graphics", values: now.series[.gpu], colour: ink.graph(0))
        let top = StatsFormat.ceiling(line.values, steps: StatsFormat.shareSteps)
        return StatsBlock(kind: .graphics, colour: .good, store: store, card: .graphics) {
            shown(.graphics, now, Gauge(value: now.values?.gpu.map(StatsFormat.percent) ?? "–", unit: "%", detail: now.row("Graphics"),
                                        share: now.values?.gpu, line: line, top: top, format: Self.percent),
                  label: Self.percent(top), title: "Graphics")
        }
    }

    private func batteries(_ now: Now) -> some View {
        let battery = now.raw?.battery, slow = now.raw?.slow
        let devices = slow?.bluetooth ?? []
        return StatsBlock("Batteries", symbol: BarKind.battery.symbol, colour: .good, pin: (battery == nil ? .bluetoothBatteries : .battery, store)) {
            if let battery {
                let state = battery.charging ? "charging" : battery.pluggedIn ? "plugged in" : "on battery"
                let left = battery.minutesLeft.map { StatsFormat.duration(Double($0) * 60) + (battery.charging ? " to full" : " left") }
                BigValue(value: "\(battery.percent)", unit: "%", detail: [state, left].compactMap(\.self).joined(separator: " · "),
                         warn: battery.percent < 20 && !battery.pluggedIn)
                StatsFacts(facts: [slow?.batteryHealth.map { StatsFact("Health", "\($0.percent) %") }, slow?.batteryHealth.map { StatsFact("Cycles", "\($0.cycles)") },
                                   slow?.chargerWatts.map { StatsFact("Charger", "\($0) W") }, now.power.map { StatsFact("Power", String(format: "%.1f W", $0)) }])
            } else {
                NoBattery(power: now.power)
            }
            Text("Bluetooth").font(ink.ui(11, .semibold)).foregroundStyle(ink.muted).padding(.top, 12).accessibilityAddTraits(.isHeader)
            if devices.isEmpty {
                FinePrint(text: "No Bluetooth device reports a battery.").padding(.top, 8)
            } else {
                VStack(spacing: 6) { ForEach(Array(devices.enumerated()), id: \.offset) { DeviceRow(device: $1) } }.padding(.top, 8)
            }
        }
    }
}

/// Busiest apps: the five busiest by CPU, memory or network right now, each row its own observed slot; Memory carries
/// the setting that counts an app's helpers under it (moved here from the Menu bar page's Readings).
private struct BusiestBlock: View {
    @Environment(\.ink) private var ink
    let store: BarItemsStore
    @State private var by = MenuBarStats.Stat.cpu

    var body: some View {
        @Bindable var store = store
        let slots = SystemSampler.shared.busiestSlots[by] ?? []
        StatsBlock("Busiest apps", symbol: "flame", colour: .second) {
            Segments(selection: $by, options: [(.cpu, "CPU"), (.ram, "Memory"), (.network, "Network")], label: "Busiest by")
                .padding(.top, 8).padding(.bottom, 4)
            if slots.isEmpty {
                FinePrint(text: "Reading…").padding(.top, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(slots.prefix(5).enumerated()), id: \.element.id) { i, slot in BusyRow(slot: slot, first: i == 0) }
                }
            }
            if by == .ram {
                Toggle(isOn: $store.settings.combineProcesses) {
                    Text("Count an app's helpers under the app").font(ink.ui(12)).foregroundStyle(ink.text2)
                }
                .toggleStyle(.pilotSwitchRow(info: "Off, each helper process, such as a browser's tabs, is ranked on its own."))
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Parts

/// A Stats block's title: its coloured tile (Instrument its own title), the name, and a muted note ("4 of 7 on", "one").
/// The blocks' and the Menu bar page's Readings.
struct StatsTitle: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    let title: String
    let symbol: String
    let colour: TileColour
    var note: String?

    var body: some View {
        if style.kind == .instrument { InstrumentTitle(title: title, symbol: symbol, note: note) } else { tiled }
    }

    private var tiled: some View {
        HStack(spacing: 7) {
            KitTile(symbol: symbol, colour: colour, size: 22)
            Text(title).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
            if let note { Text(note).font(ink.ui(12)).foregroundStyle(ink.muted) }
        }
        // The name shortens before a narrow card's header runs past it (Stats' Compact).
        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A Stats block on its surface, at the mockup's insets (a little tighter than a Tile's, so the charts get the room).
    func statsBlock() -> some View {
        padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 15).blockSurface()
    }
}

extension EnvironmentValues {
    /// Where Stats' cards keep their views; nil outside Stats, where a block has no view switch.
    @Entry var statsViews: StatsViewsStore? = nil
}

/// A block: its title, In menu bar for a reading the bar can show, then its content. Stretches to its row, so the blocks
/// beside it end level.
struct StatsBlock<Content: View>: View {
    let title: String
    let symbol: String
    let colour: TileColour
    var note: String?
    /// The reading In menu bar flips, and the setting it lives in.
    var pin: (kind: BarKind, store: BarItemsStore)?
    /// A card with a chart, which carries a view switch.
    var card: StatsCard?
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, colour: TileColour, note: String? = nil, pin: (kind: BarKind, store: BarItemsStore)? = nil,
         card: StatsCard? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.colour = colour; self.note = note; self.pin = pin; self.card = card; self.content = content()
    }

    /// A reading the menu bar shows: the bar item's name and symbol, and its In menu bar.
    init(kind: BarKind, colour: TileColour, store: BarItemsStore, card: StatsCard? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(kind.statsTitle, symbol: kind.symbol, colour: colour, pin: (kind, store), card: card, content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A narrow card keeps In menu bar to its pin.
            ViewThatFits(in: .horizontal) { header(short: false); header(short: true) }
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .statsBlock()
    }

    private func header(short: Bool) -> some View {
        HStack(spacing: 6) {
            StatsTitle(title: title, symbol: symbol, colour: colour, note: note)
            Spacer(minLength: 0)
            if let card { ViewSwitch(card: card) }
            if let pin { PinButton(kind: pin.kind, store: pin.store, short: short) }
        }
    }
}

/// A card's view, small in its header: the view's glyph, a click listing Line, Bars, Ring and Number.
struct ViewSwitch: View {
    @Environment(\.ink) private var ink
    @Environment(\.statsViews) private var views
    let card: StatsCard

    var body: some View {
        let current = views?.views.view(card) ?? .line
        Menu {
            Picker("Show as", selection: Binding(get: { current }, set: { views?.set($0, for: card) })) {
                ForEach(StatsView.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden().menuRows()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: current.symbol).font(ink.ui(10.5, .semibold))
                Image(systemName: "chevron.down").font(ink.ui(7.5, .bold))
            }
            .foregroundStyle(ink.muted)
            .padding(.horizontal, 5).frame(minHeight: 22)
            .contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Show as Line, Bars, Ring or Number")
        .accessibilityLabel("Show as")
        .accessibilityValue(current.title)
    }
}

/// In menu bar: the reading's place in the macOS menu bar, the same setting as the Menu bar page's Readings chips.
struct PinButton: View {
    @Environment(\.ink) private var ink
    let kind: BarKind
    let store: BarItemsStore
    var short = false

    var body: some View {
        let on = store.settings.isOn(kind, in: .menuBar)
        Button { store.settings.toggleReading(kind) } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "pin.fill" : "pin").font(ink.ui(9.5, .semibold))
                if !short { Text(on ? "In menu bar" : "Menu bar") }
            }
            .font(ink.ui(11.5, .medium))
            .foregroundStyle(on ? ink.accentText : ink.muted)
            .padding(.horizontal, 6).frame(minHeight: 22)
            .background(on ? ink.selection : .clear, in: .rect(cornerRadius: ink.radius(4)))
            .contentShape(.rect)
            .animation(Kit.change, value: on)
        }
        .buttonStyle(.kitPress)
        .help(on ? "Take \(kind.statsTitle) out of the menu bar" : "Show \(kind.statsTitle) in the menu bar")
        .accessibilityLabel("\(kind.statsTitle) in the menu bar")
        .accessibilityValue(on ? "on" : "off")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The value now, big in the theme's display face, its unit small, and a line saying what it means;
/// amber with a warning sign when it needs attention. `size` scales the number (Number's view draws it larger).
struct BigValue: View {
    @Environment(\.ink) private var ink
    let value: String
    var unit = ""
    var detail: String?
    var warn = false
    var size: CGFloat = 1

    var body: some View {
        let number = Text(value).font(ink.display(30 * size)).tracking(ink.displayTracking(30 * size))
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let small = Text(unit).font(ink.display(10)).foregroundStyle(ink.muted)
            Text("\(number.foregroundStyle(ink.text))\(small)").fixedSize()
            if let detail {
                HStack(spacing: 3) {
                    if warn { Image(systemName: "exclamationmark.triangle").font(ink.ui(11)) }
                    Text(detail)
                }
                .font(ink.ui(12)).foregroundStyle(warn ? ink.warnText : ink.muted).lineLimit(1).truncationMode(.tail)
            }
        }
        .monospacedDigit()
        .padding(.top, 7).padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One detail: its name, its value, and a click when it does something (Public IP's Show).
struct StatsFact {
    let label: String
    let value: String
    var link = false
    var help: String?
    var action: (() -> Void)?

    init(_ label: String, _ value: String, link: Bool = false, help: String? = nil, action: (() -> Void)? = nil) {
        self.label = label; self.value = value; self.link = link; self.help = help; self.action = action
    }
}

/// A block's details, two to a line: each name muted, its value at the right of its half.
struct StatsFacts: View {
    @Environment(\.ink) private var ink
    let facts: [StatsFact]

    init(facts: [StatsFact?]) { self.facts = facts.compactMap(\.self) }

    var body: some View {
        if !facts.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(Array(stride(from: 0, to: facts.count, by: 2)), id: \.self) { i in
                    GridRow {
                        cell(facts[i])
                        if i + 1 < facts.count { cell(facts[i + 1]) } else { Color.clear.frame(height: 1).gridCellColumns(2) }
                    }
                }
            }
            .font(ink.ui(12)).lineLimit(1)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func cell(_ fact: StatsFact) -> some View {
        Text(fact.label).foregroundStyle(ink.muted)
        Group {
            if let action = fact.action {
                Button(action: action) {
                    Text(fact.value).fontWeight(fact.link ? .medium : .regular).foregroundStyle(fact.link ? ink.link : ink.text).contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Text(fact.value).foregroundStyle(ink.text)
            }
        }
        .monospacedDigit().truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .help(fact.help ?? "")
    }
}


/// No battery: what the Mac runs on, and what it draws now.
private struct NoBattery: View {
    @Environment(\.ink) private var ink
    let power: Double?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "powerplug").font(ink.ui(16)).foregroundStyle(ink.muted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("No battery in this Mac").font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text)
                Text(power.map { "It runs off the wall, drawing \(String(format: "%.1f", $0)) W now." } ?? "It runs off the wall.")
                    .font(ink.ui(12)).foregroundStyle(ink.muted)
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink.text.opacity(0.05), in: .rect(cornerRadius: ink.radius(6), style: .continuous))
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}


/// A Bluetooth device's charge: its kind, its name, a bar, the lowest of its batteries (earbuds' left and right).
private struct DeviceRow: View {
    @Environment(\.ink) private var ink
    let device: SystemStats.BluetoothDevice
    /// A word in the device's name and its symbol; the first that matches.
    private static let kinds = [("keyboard", "keyboard"), ("trackpad", "rectangle.and.hand.point.up.left"), ("mouse", "computermouse"),
                                ("airpods", "airpods"), ("headphone", "headphones"), ("beats", "headphones"), ("buds", "headphones"),
                                ("controller", "gamecontroller")]

    var body: some View {
        let level = device.percent ?? 0
        let colour = level < 20 ? ink.red : level < 50 ? ink.yellow : ink.green
        let name = device.name.lowercased()
        HStack(spacing: 8) {
            Image(systemName: Self.kinds.first { name.contains($0.0) }?.1 ?? "antenna.radiowaves.left.and.right")
                .font(ink.ui(13)).foregroundStyle(ink.muted).frame(width: 18)
            Text(device.name).font(ink.ui(12.5)).lineLimit(1).truncationMode(.tail).frame(minWidth: 70, maxWidth: 130, alignment: .leading)
            Capsule().fill(ink.text.opacity(0.1)).frame(height: 5)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Capsule().fill(colour).frame(width: g.size.width * Double(min(max(level, 0), 100)) / 100) }
                }
            Text("\(level)%").font(ink.mono(11)).foregroundStyle(ink.text2).frame(minWidth: 34, alignment: .trailing)
        }
        .help(device.level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.name)
        .accessibilityValue(device.level)
    }
}

/// One of the five busiest, its own observed row: the app's icon (a window glyph for a process with none), name and
/// share.
private struct BusyRow: View {
    @Environment(\.ink) private var ink
    let slot: LiveRow
    let first: Bool

    var body: some View {
        let row = slot.row
        HStack(spacing: 8) {
            AppLabel(name: row.name) { AppIcon(name: row.name, size: 20, glyph: "macwindow") } title: {
                Text(row.name).font(ink.ui(12.5)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(row.value).font(ink.mono(11)).foregroundStyle(ink.text2).lineLimit(1).fixedSize()
        }
        .frame(height: 27)
        .overlay(alignment: .top) { if !first { ink.line.frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }
}
