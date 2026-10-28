import AppKit
import PilotCore
import SwiftUI

// Stats inline (P42, design-refs/launcher-ideas-2026-10-18.html; Q293 skipped, so its recommendation): typing stats, cpu,
// memory, ram or disk at the root puts five live cards above the rows in Line: CPU, memory, disk free, the top three apps
// by CPU and by memory. They read the sampler Mac › Stats and Activity read, every 2 s while they show and nothing once
// they are gone. The cards are readouts, never the selection: ↑ and ↓ stay on the rows.

extension MenuModel {
    /// The cards show: a root search in Line for one of the words, all kinds shown, no Cmd+K over it.
    var statsCards: Bool {
        layout == .line && searchingRoot && nav.only == nil && nav.actions == nil
            && StatsStrip.words.contains(nav.query.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

struct StatsStrip: View {
    @Environment(\.style) private var style
    /// A click: Stats from a reading, Activity from a top app.
    let open: (AppPlace) -> Void

    static let words: Set<String> = ["stats", "cpu", "memory", "ram", "disk"]
    /// The room above the rows: the eyebrow, the 116 pt cards and the gap under them.
    static let room: CGFloat = 28 + 116 + 10
    /// What the cards read; the renders give a seeded one, which nothing watches, so they never draw this Mac's.
    static var sampler = SystemSampler.shared

    var body: some View {
        let sampler = Self.sampler, raw = sampler.latest, cpu = sampler.latestValues?.cpu
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                InstrumentEyebrow(text: "This Mac")
                Spacer()
                Text(cpu == nil ? "reading…" : "every 2 s").font(style.font(\.mono, size: 11 / style.scale)).foregroundStyle(style.color(\.text3))
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            .frame(minHeight: 28, alignment: .bottom)
            HStack(spacing: 8) {
                reading("CPU", symbol: BarKind.cpu.symbol, value: cpu.map { (StatsFormat.percent($0), "%") }, of: nil, share: cpu)
                let memory = raw?.memory
                reading("Memory", symbol: BarKind.memory.symbol, value: memory.map { Self.split(SystemStats.memorySize($0.used)) },
                        of: memory.map { "of \(SystemStats.memorySize($0.total))" },
                        share: sampler.latestValues?.ram)
                let disk = raw?.slow.disk
                reading("Disk free", symbol: "internaldrive", value: disk.map { Self.split(SystemStats.decimal(Double($0.available))) },
                        of: disk.map { "of \(SystemStats.decimal(Double($0.total)))" },
                        share: raw?.diskUsed)
                top("Top CPU", symbol: BarKind.cpu.symbol, sampler.appsByCPU.prefix(3).map { ($0.name, Activity.cpuText($0.cpu)) })
                top("Top memory", symbol: BarKind.memory.symbol, sampler.appsByMemory.prefix(3).map { ($0.name, StatsFormat.memory($0.memory)) })
            }
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 10)
        .task {
            // The apps' listing without nettop, which only Activity's network list needs.
            guard Self.sampler === SystemSampler.shared else { return }
            await SystemSampler.shared.watch(needs: .apps, stats: [.cpu, .ram, .disk])
        }
    }

    /// "10.4 GB" as its number and its unit.
    static func split(_ text: String) -> (String, String) {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }

    /// A reading's card: its name, the number with its unit, what it is out of, and a meter of the share used.
    private func reading(_ title: String, symbol: String, value: (String, String)?, of: String?, share: Double?) -> some View {
        card(title, symbol: symbol, place: AppPlace(.stats)) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value?.0 ?? "—").font(style.font(\.mono, size: 24 / style.scale)).tracking(-0.5)
                    .foregroundStyle(style.color(value == nil ? \.text3 : \.text))
                if let unit = value?.1 { Text(unit).font(style.font(\.mono, size: 12 / style.scale)).foregroundStyle(style.color(\.text2)) }
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let of { Text(of).font(style.font(\.mono, size: 11 / style.scale)).foregroundStyle(style.color(\.text3)).lineLimit(1).padding(.top, 3) }
            GeometryReader { box in
                Capsule().fill(style.color(\.line2))
                    .overlay(alignment: .leading) { Capsule().fill(style.color(\.accent)).frame(width: box.size.width * min(1, max(0, share ?? 0))) }
            }
            .frame(height: 3).padding(.top, 9)
        }
        .frame(width: 112)
    }

    /// A top three's card: each app's icon, name and share; dashes until the process list is read.
    private func top(_ title: String, symbol: String, _ apps: [(name: String, value: String)]) -> some View {
        card(title, symbol: symbol, place: AppPlace(.activity)) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<3, id: \.self) { i in
                    let app = i < apps.count ? apps[i] : nil
                    HStack(spacing: 8) {
                        if let app { AppIcon(name: app.name, size: 16, glyph: "app.dashed") } else { Color.clear.frame(width: 16, height: 16) }
                        Text(app?.name ?? "—").styleText(\.caption).foregroundStyle(style.color(app == nil ? \.text3 : \.text))
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        Text(app?.value ?? "").font(style.font(\.mono, size: 11.5 / style.scale)).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    }
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ title: String, symbol: String, place: AppPlace, @ViewBuilder _ content: () -> some View) -> some View {
        Button { open(place) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 10)).accessibilityHidden(true)
                    Text(title.uppercased()).styleText(\.eyebrow).minimumScaleFactor(0.8)
                }
                .foregroundStyle(style.color(\.text3)).lineLimit(1)
                content()
            }
            .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(height: 116)
            .instrumentRaised(true, radius: 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityElement(children: .combine)
        .accessibilityHint(place.page == .stats ? "Opens Stats" : "Opens Activity")
    }
}
