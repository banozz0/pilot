import PilotCore
import SwiftUI

/// Hyper+Space › Stats (Sven 2026-10-21, Q400 B): six live cards in the list's place, two rows of three at the panel's
/// width: CPU, Memory, Storage; Network, Temperature and fan, Busiest apps. They read the sampler Mac › Stats and the stats
/// strip read (StatsStrip.sampler), every 2 s while they show and nothing once they are gone. Readouts, never the
/// selection: Return, and a click on CPU, Memory or Busiest apps, opens Activity. Each card sits on the style's raised
/// surface (Instrument's, as the stats strip's on the menu's glass; Toybox's card).
struct MenuStatsScreen: View {
    @Environment(\.style) private var style
    /// Opens Activity.
    let open: () -> Void

    static let cardHeight: CGFloat = 168, gap: CGFloat = 8, inset: CGFloat = 10
    /// What the cards take in the list's place, which the panel's sizers add (MenuModel's).
    static let height = 2 * cardHeight + gap + 2 * inset
    /// What the cards read.
    static let reads: Set<MenuBarStats.Stat> = [.cpu, .ram, .disk, .network, .sensors]

    var body: some View {
        let sampler = StatsStrip.sampler, raw = sampler.latest, now = sampler.latestValues, history = sampler.history
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            GridRow {
                card("CPU", symbol: BarKind.cpu.symbol, opens: true) {
                    number(now?.cpu.map { (StatsFormat.percent($0), "%") })
                    note(raw.map { "\($0.cores.isEmpty ? "" : "\($0.cores.count) cores · ")busiest \(sampler.appsByCPU.first?.name ?? "—")" })
                    spark(history.compactMap(\.cpu))
                }
                card("Memory", symbol: BarKind.memory.symbol, opens: true) {
                    let memory = raw?.memory
                    number(memory.map { StatsStrip.split(SystemStats.memorySize($0.used)) })
                    note(memory.map { "of \(SystemStats.memorySize($0.total))" })
                    meter(now?.ram)
                }
                card("Storage", symbol: "internaldrive") {
                    let disk = raw?.slow.disk
                    number(disk.map { StatsStrip.split(SystemStats.decimal(Double($0.available))) }, unit: "free")
                    note(disk.map { "of \(SystemStats.decimal(Double($0.total)))" })
                    meter(raw?.diskUsed)
                }
            }
            GridRow {
                card("Network", symbol: "arrow.up.arrow.down") {
                    number(now?.down.map { let r = StatsFormat.rate($0); return (r.value, r.unit) }, unit: "down")
                    note(now?.up.map { "\(StatsFormat.rateText($0)) up" })
                    spark(history.compactMap(\.down))
                }
                card("Temperature and fan", symbol: "thermometer.medium") {
                    number(now?.heat.map { (String(Int($0.rounded())), "°C") })
                    note(now.map { $0.fan.map { "Fan \(Int($0.rounded()).formatted()) rpm" } ?? "No fan reading" })
                    spark(history.compactMap(\.heat))
                }
                card("Busiest apps", symbol: "flame", opens: true) { busiest(sampler.appsByCPU.prefix(3).map { ($0.name, Activity.cpuText($0.cpu)) }) }
            }
        }
        .padding(Self.inset)
        .frame(maxWidth: .infinity, alignment: .top)
        .task {
            // A render's seeded sampler is never watched, so it never draws this Mac's.
            guard StatsStrip.sampler === SystemSampler.shared else { return }
            await SystemSampler.shared.watch(needs: .apps, stats: Self.reads)
        }
    }

    /// The value now, big, its unit small after it; a dash until the first reading.
    private func number(_ value: (String, String)?, unit extra: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value?.0 ?? "—").font(style.font(\.mono, size: 28 / style.scale)).tracking(-0.5)
                .foregroundStyle(style.color(value == nil ? \.text3 : \.text))
            let unit = [value?.1, extra].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
            if value != nil, !unit.isEmpty { Text(unit).font(style.font(\.mono, size: 12.5 / style.scale)).foregroundStyle(style.color(\.text2)) }
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        .padding(.top, 12)
    }

    private func note(_ text: String?) -> some View {
        Text(text ?? " ").font(style.font(\.mono, size: 11.5 / style.scale)).foregroundStyle(style.color(\.text3))
            .lineLimit(1).truncationMode(.tail).padding(.top, 4)
    }

    /// The last two minutes under the number.
    private func spark(_ values: [Double]) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            InstrumentSpark(values: values).frame(height: 40)
        }
    }

    /// The share used, across the card's foot.
    private func meter(_ share: Double?) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            GeometryReader { box in
                Capsule().fill(style.color(\.line2))
                    .overlay(alignment: .leading) { Capsule().fill(style.color(\.accent)).frame(width: box.size.width * min(1, max(0, share ?? 0))) }
            }
            .frame(height: 5)
        }
    }

    /// The three busiest apps by CPU: each one's icon, name and share; dashes until the process list is read.
    private func busiest(_ apps: [(name: String, value: String)]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<3, id: \.self) { i in
                let app = i < apps.count ? apps[i] : nil
                HStack(spacing: 8) {
                    if let app { AppIcon(name: app.name, size: 18, glyph: "app.dashed") } else { Color.clear.frame(width: 18, height: 18) }
                    Text(app?.name ?? "—").styleText(\.body).foregroundStyle(style.color(app == nil ? \.text3 : \.text))
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    Text(app?.value ?? "").font(style.font(\.mono, size: 12 / style.scale)).foregroundStyle(style.color(\.text2)).lineLimit(1)
                }
            }
        }
        .padding(.top, 14)
    }

    /// A card: its glyph and name in the eyebrow, then what it reads; `opens` makes it a button to Activity.
    @ViewBuilder private func card(_ title: String, symbol: String, opens: Bool = false, @ViewBuilder _ content: () -> some View) -> some View {
        let face = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10)).accessibilityHidden(true)
                Text(title.uppercased()).styleText(\.eyebrow).minimumScaleFactor(0.8)
            }
            .foregroundStyle(style.color(\.text3)).lineLimit(1)
            content()
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: Self.cardHeight)
        .modifier(MenuStatsCardFace())
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        if opens {
            Button(action: open) { face }.buttonStyle(.plain).focusable(false).accessibilityHint("Opens Activity")
        } else {
            face
        }
    }
}

/// A card's surface in the style the menu draws: Instrument's raised ring, as the stats strip's; Toybox's card.
struct MenuStatsCardFace: ViewModifier {
    @Environment(\.style) private var style

    func body(content: Content) -> some View {
        if style.kind == .toybox {
            content.styleSurface(\.card, fill: \.panel, shadows: false)
        } else {
            content.instrumentRaised(true, radius: 10)
        }
    }
}
