import AppKit
import PilotCore
import SwiftUI

/// Update & Clean's Reports (story 153; Activity's until simplify-pages T16, Update & Clean's tab until Sven, 2026-11-16),
/// under the Update and Clean block: every Update and Clean run, newest first, the one picked opening to when it ran, how it
/// ended, the exact command, what it was to change (Update's versions from → to, Clean's items and the space Mole freed)
/// and what it printed. UpkeepPage reads the runs and the opened run's output, following one still in its terminal; this
/// draws them.
struct ReportsBlock: View {
    @Environment(\.ink) private var ink
    var store = ReportStore.standard
    /// Nil until the first read, so the block never says "No runs yet" while it reads.
    let records: [RunRecord]?
    /// The run opened, from a row or Update and Clean's Open report; nil opens the newest.
    @Binding var picked: String?
    /// What the opened run printed.
    let output: String

    /// The run opened: the one picked, else the newest.
    static func shown(_ records: [RunRecord]?, picked: String?) -> RunRecord? { records?.first { $0.id == picked } ?? records?.first }

    /// The runs, first, are where a link or Open report lands.
    var body: some View {
        if records != nil {
            let shown = Self.shown(records, picked: picked)
            if let shown {
                InstrumentPair(level: false) { runs(shown) } right: { detail(shown) }.id(AppSection.reports)
            } else {
                // Held at the page's width, so the runs sit under Update and Clean, never beside it (PageFlow).
                runs(shown).pageWide().id(AppSection.reports)
            }
        }
    }

    private func runs(_ shown: RunRecord?) -> some View {
        KitBlock(title: AppSection.reports.title, symbol: "list.bullet") {
            Text("\(records?.count ?? 0)").font(ink.mono(11.5))
        } content: {
            VStack(spacing: 2) {
                if records?.isEmpty == true {
                    EmptyState(title: "No runs yet", line: "Each Update and Clean run is kept here.").padding(.vertical, 12)
                }
                ForEach(records ?? []) { r in
                    let selected = r.id == shown?.id
                    Button { picked = r.id } label: {
                        KitRow(selected: selected) {
                            IconTile(icon: Self.icon(r.report.kind), size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.report.title).font(ink.ui(13, .semibold))
                                Text("\(Self.when(r.report.started)) · \(r.summary)").font(ink.ui(11.5)).foregroundStyle(ink.rowQuiet(selected))
                            }
                            Spacer(minLength: 6)
                            chip(r.end)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func detail(_ r: RunRecord) -> some View {
        KitBlock(title: r.report.title, symbol: Self.icon(r.report.kind).symbol) {
            chip(r.end)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    fact("Started", Self.when(r.report.started))
                    if let ended = r.ended { fact("Ended", "\(Self.when(ended)) · took \(Self.took(ended.timeIntervalSince(r.report.started)))") }
                    if r.report.kind == .clean {
                        fact("Space freed", r.freed ?? (r.end == .running ? "not yet" : "Mole did not say"))
                        if let estimate = r.report.estimate { fact("Mole estimated", estimate) }
                    }
                }
                part(r.itemsHeading) {
                    if r.report.items.isEmpty {
                        FinePrint(text: r.report.kind == .clean ? "No preview was kept for this clean." : "Nothing listed.")
                    }
                    ForEach(Array(r.report.items.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(item.name).font(ink.ui(12.5, .medium)).foregroundStyle(ink.text).lineLimit(1)
                            if !item.to.isEmpty {
                                Text(item.from.isEmpty ? "→ \(item.to)" : "\(item.from) → \(item.to)").font(ink.mono(11.5)).foregroundStyle(ink.text2)
                            }
                            Text(item.detail).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1)
                        }
                    }
                    if r.report.kind == .update, case .failed = r.end {
                        FinePrint(text: "The run failed, so some of these may not have changed: the output says where it stopped.", color: ink.red)
                    }
                }
                part("Command") { well(r.report.command, height: nil) }
                part("Output") {
                    well(output.isEmpty ? (r.end == .running ? "Running in its terminal; the output lands here as it ends." : "No output was kept.") : output,
                         height: 320)
                }
                HStack(spacing: 8) {
                    Button("Copy output") { SystemModule.copy(output) }.buttonStyle(.pilot).disabled(output.isEmpty)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.directory(r.id)]) }.buttonStyle(.pilot)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(ink.ui(12)).foregroundStyle(ink.muted).frame(width: 110, alignment: .leading)
            Text(value).font(ink.ui(12.5)).foregroundStyle(ink.text).textSelection(.enabled)
        }
    }

    private func part<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(ink.ui(12, .semibold)).foregroundStyle(ink.text2)
            content()
        }
    }

    /// Mono, selectable text on a sunk ground; scrolled past `height`, sized by its lines.
    private func well(_ text: String, height: CGFloat?) -> some View {
        let words = Text(verbatim: text).font(ink.mono(11.5)).foregroundStyle(ink.text).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        return Group {
            if let height {
                let lines = CGFloat(text.count { $0 == "\n" } + 1)
                ScrollView { words }.frame(height: min(height, lines * 15 + 22))
            } else { words }
        }
        .innerCard()
    }

    private func chip(_ end: RunEnd) -> some View { Self.chip(end, ink: ink) }

    /// How a run ended, coloured: done green, failed red, cancelled amber, running the accent.
    static func chip(_ end: RunEnd, ink: Ink) -> some View {
        let colour = switch end {
        case .running: ink.accent
        case .done: ink.green
        case .failed: ink.red
        case .cancelled: ink.warnText
        }
        return Chip(text: end.word, color: colour)
    }

    static func icon(_ kind: RunReport.Kind) -> MenuIcon {
        kind == .update ? .glyph("arrow.down.circle", .accent) : .glyph("sparkles", .good)
    }

    /// "Today 03:15", "Yesterday 21:40", else "9 Oct 21:40".
    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    /// "42 s", "3 min 5 s", "1 h 2 min".
    static func took(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }
}
