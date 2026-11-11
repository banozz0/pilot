import PilotCore
import SwiftUI

/// Mac › Update & Clean (Sven 2026-10-20, was the top of Activity › Reports; Reports its tab since simplify-pages T16): Update and Clean themselves, each with its
/// last run and an Open report link to that run on Reports. A run still in its terminal is read again every 2 s until it
/// ends, so its last run follows it. Under them, what starts at login (LoginItemsBlock, Q386).
struct UpkeepPage: View {
    @Environment(\.ink) private var ink
    var store = ReportStore.standard
    /// Mole is there for Clean to run (CleanModule.mole); a render says which.
    var mole = CleanModule.mole != nil
    /// Homebrew is there for Update to read and Mole to install through; a render says which.
    var homebrew = Helper.homebrew.path() != nil
    /// Opens the Reports tab on a run.
    var openReport: (String) -> Void = { _ in }
    /// Nil until the first read, so the page never says "No run yet" while it reads.
    @State private var records: [RunRecord]?
    /// Bumped when a run begins, so the page follows it to its end.
    @State private var wake = 0

    static let intro = "Update previews upgrades and Clean what it would remove; each asks first."
    static let introInfo = "Clean runs Mole. Each run is kept on the Reports tab."

    var body: some View {
        KitPage(intro: Self.intro, info: Self.introInfo) {
            start
            LoginItemsBlock()
        }
            .task(id: wake) {
                reload()
                while records?.contains(where: { $0.end == .running }) == true {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    reload()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ReportStore.began)) { _ in wake += 1 }
    }

    private func reload() {
        let read = store.list()
        if read != records { records = read }
    }

    /// Update and Clean open their Hyper+Space branch, so the preview, the confirm and the run are the menu's own; Clean
    /// without Mole installs it through Install's confirm step, as the menu's Install Mole row does, with Homebrew in the
    /// same run when that is missing too (Q557).
    private var start: some View {
        KitBlock(title: "Update and Clean", symbol: "arrow.triangle.2.circlepath") {
            VStack(spacing: 0) {
                BlockRow(first: true) {
                    starter(.update, line: "Previews every upgrade, version to version, then asks before it runs.") {
                        Button("Update…") { PilotMenu.shared.toggle(branch: .update) }.buttonStyle(.pilotPrimary)
                    }
                }
                BlockRow {
                    if mole {
                        starter(.clean, line: "Shows what Mole would remove and the space it frees; cleans only after you confirm.") {
                            Button("Clean…") { PilotMenu.shared.toggle(branch: .clean) }.buttonStyle(.pilotPrimary)
                        }
                    } else {
                        starter(.clean, line: homebrew ? "Clean runs through Mole, which is not installed." : "Clean runs through Mole, which installs through Homebrew; neither is installed.") {
                            Button(homebrew ? "Install Mole…" : "Install Homebrew and Mole…") { CleanModule.pick(.install) }.buttonStyle(.pilot)
                        }
                    }
                }
            }
        }
    }

    /// One of the two: its icon, name and what it does, its last run with a link to that report, and its button.
    private func starter<Action: View>(_ kind: RunReport.Kind, line: String, @ViewBuilder action: () -> Action) -> some View {
        let last = records?.first { $0.report.kind == kind }
        return HStack(spacing: 12) {
            IconTile(icon: ReportsPage.icon(kind), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .update ? "Update" : "Clean").font(ink.ui(13, .semibold)).foregroundStyle(ink.text)
                Text(line).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(2)
                if let last {
                    HStack(spacing: 6) {
                        Text("Last run \(ReportsPage.when(last.report.started)) · \(last.summary)").font(ink.ui(11.5)).foregroundStyle(ink.text2)
                        ReportsPage.chip(last.end, ink: ink)
                        Button("Open report") { openReport(last.id) }.buttonStyle(.link).font(ink.ui(11.5))
                    }
                } else if records != nil {
                    Text("No run yet").font(ink.ui(11.5)).foregroundStyle(ink.text2)
                }
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.vertical, 8)
    }
}
