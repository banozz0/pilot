import AppKit
import PilotCore
import SwiftUI

/// Activity (task N3, Sven 2026-10-09: "an own page which acts like activity monitor and we can remove from there"):
/// what runs on this Mac for a person, not a sysadmin. Apps first, each with its helpers rolled up under it (open the
/// chevron to see them), then the background. Each row its icon, name, CPU and memory, a bar and a Heavy chip on the
/// rows that hog; Quit and Force quit on a hovered row, confirmed in the row itself; macOS's and other users' processes
/// show a lock instead. Reads every 3 s only while the page shows (ActivityMonitor). Drawn through the Kit, so it takes
/// every style and layout, and kept to this file so a rework of the window's pages can move it whole.
struct ActivityPage: View {
    /// Where a render starts.
    struct Start {
        var sort = Activity.Sort.cpu
        var query = ""
        var expanded: Set<String> = []
        /// The row drawn as hovered.
        var hovered: String?
        var confirming: Confirm?
    }

    /// A quit waiting for its second click, in its row.
    struct Confirm: Equatable {
        let id: String
        let force: Bool
    }

    @Environment(\.ink) private var ink
    /// The window shows: the monitor reads only then.
    let onScreen: Bool
    var monitor: ActivityMonitor = .shared
    @State private var sort: Activity.Sort
    @State private var query: String
    @State private var expanded: Set<String>
    /// The render's hovered row; a real hover is each row's own, so moving the pointer redraws that row alone.
    private let hovered: String?
    @State private var confirming: Confirm?
    /// A quit macOS refused, said on its row until the next confirm.
    @State private var refused: [String: String] = [:]
    @State private var backgroundShown = Self.backgroundStep

    init(onScreen: Bool, monitor: ActivityMonitor = .shared, start: Start = .init()) {
        self.onScreen = onScreen
        self.monitor = monitor
        _sort = State(initialValue: start.sort)
        _query = State(initialValue: start.query)
        _expanded = State(initialValue: start.expanded)
        hovered = start.hovered
        _confirming = State(initialValue: start.confirming)
    }

    static let intro = "What runs on this Mac, heaviest first. Hover a row to quit it."
    /// The background rows shown at first, and how many more each Show more adds.
    static let backgroundStep = 15
    /// Narrower than this (a 760 pt window beside Calm's sidebar), a row's actions go on a line under it.
    static let compactWidth: CGFloat = 640

    var body: some View {
        // The width the window offers, not the page's own, which a row too wide for it would stretch.
        GeometryReader { g in page(compact: g.size.width < Self.compactWidth) }
            .task(id: onScreen) {
                if onScreen { await monitor.watch() }
            }
            .onExitCommand { confirming = nil }
            .onChange(of: query) { backgroundShown = Self.backgroundStep }
    }

    /// Under `compactWidth` the rows drop their bar and their actions column.
    @ViewBuilder private func page(compact: Bool) -> some View {
        let shown = Activity.filtered(Activity.sorted(monitor.snapshot, by: sort), query: query)
        let background = Array(shown.background.prefix(backgroundShown))
        // The bars measure against the heaviest row in view, so the hog's bar is the longest.
        let top = (shown.apps + background).map(value).max() ?? 0
        KitPage(intro: Self.intro) {
            toolbar(shown)
            if !monitor.hasRead {
                EmptyState(title: "Reading…", line: "What runs on this Mac shows in a moment.")
            } else if shown.apps.isEmpty && shown.background.isEmpty {
                EmptyState(title: "Nothing matches", line: "No app or process has “\(query.trimmingCharacters(in: .whitespaces))” in its name.")
            } else {
                if !shown.apps.isEmpty {
                    KitBlock(title: "Apps", symbol: "macwindow", trailing: { count(shown.apps.count, "open") }) {
                        rows(shown.apps, top: top, compact: compact)
                    }
                }
                if !shown.background.isEmpty {
                    KitBlock(title: "Background", symbol: "gearshape.2", note: "macOS and programs running without a window.",
                             trailing: { count(shown.background.count, "running") }) {
                        rows(background, top: top, compact: compact)
                        if shown.background.count > background.count {
                            Button("Show \(min(Self.backgroundStep, shown.background.count - background.count)) more of \(shown.background.count)") {
                                backgroundShown += Self.backgroundStep
                            }
                            .buttonStyle(.pilotSoft).padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    private func value(_ row: Activity.Row) -> Double { sort == .cpu ? row.cpu : Double(row.memory) }

    private func count(_ n: Int, _ word: String) -> some View {
        Text("\(n) \(word)").font(ink.ui(12)).foregroundStyle(ink.muted)
    }

    /// Search at the left, the sort at the right; one under the other when the window is narrow.
    private func toolbar(_ shown: Activity.Snapshot) -> some View {
        let search = SearchBox(prompt: "Search apps and processes", text: $query)
        let sorter = HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Sort by").font(ink.ui(12)).foregroundStyle(ink.muted)
                InfoMark(text: "Heaviest first, by CPU or by memory; each app's helpers sort the same way under it.")
            }
            Segments(selection: $sort, options: Activity.Sort.allCases.map { ($0, $0.title) }, label: "Sort by")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                search.frame(minWidth: 260, maxWidth: 380)
                Spacer(minLength: 0)
                sorter.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) { search; sorter }
        }
        .padding(.top, 12).padding(.bottom, 4)
    }

    /// The column heads, then each row and, opened, its helpers under it.
    @ViewBuilder private func rows(_ rows: [Activity.Row], top: Double, compact: Bool) -> some View {
        ActivityColumns(sort: sort, compact: compact)
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        ForEach(rows) { row in
            // A search opens every app it kept a helper of, so the match shows.
            let open = !row.children.isEmpty && (expanded.contains(row.id) || searching)
            line(row, top: top, open: open, child: false, compact: compact)
            if open {
                ForEach(row.children) { line($0, top: top, open: false, child: true, compact: compact) }
            }
        }
    }

    private func line(_ row: Activity.Row, top: Double, open: Bool, child: Bool, compact: Bool) -> some View {
        BlockRow {
            ActivityRowView(row: row, sort: sort, top: top, open: open, child: child, compact: compact,
                            physicalMemory: monitor.physicalMemory,
                            startHovered: hovered == row.id, confirming: confirming?.id == row.id ? confirming : nil,
                            quitting: monitor.quitting.contains(row.id), refused: refused[row.id],
                            toggle: { if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) } },
                            ask: { force in refused[row.id] = nil; confirming = Confirm(id: row.id, force: force) },
                            cancel: { confirming = nil },
                            quit: { force in
                                confirming = nil
                                if !monitor.quit(row, force: force) { refused[row.id] = "\(row.name) is gone or not yours to quit" }
                            })
        }
    }
}

/// The column heads over a block's rows, the sorted one lit.
private struct ActivityColumns: View {
    @Environment(\.ink) private var ink
    let sort: Activity.Sort
    let compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, ActivityRowView.lead)
            Text("CPU").foregroundStyle(sort == .cpu ? ink.text2 : ink.muted).frame(width: ActivityRowView.cpuWidth, alignment: .trailing)
            Text("Memory").foregroundStyle(sort == .memory ? ink.text2 : ink.muted).frame(width: ActivityRowView.memoryWidth, alignment: .trailing)
            if !compact { Color.clear.frame(width: ActivityRowView.actionsWidth, height: 1) }
        }
        .font(ink.ui(11, .medium)).foregroundStyle(ink.muted)
        .padding(.top, 6).padding(.bottom, 4)
        .accessibilityHidden(true)
    }
}

/// One row: the chevron for an app with helpers, its icon and name with what it is under it, its bar, CPU and memory,
/// and at the right Quit and Force quit while hovered, a lock for one Pilot may not quit; a quit asked for confirms in a
/// line under it.
private struct ActivityRowView: View {
    @Environment(\.ink) private var ink
    let row: Activity.Row
    let sort: Activity.Sort
    let top: Double
    let open: Bool
    let child: Bool
    /// A narrow page: no bar, and the actions on a line under the row.
    let compact: Bool
    let physicalMemory: UInt64
    let startHovered: Bool
    let confirming: ActivityPage.Confirm?
    let quitting: Bool
    let refused: String?
    let toggle: () -> Void
    let ask: (Bool) -> Void
    let cancel: () -> Void
    let quit: (Bool) -> Void

    /// The chevron's room and the icon's, so the Name head sits over the names.
    static let lead: CGFloat = 18 + 10 + 22 + 10
    static let cpuWidth: CGFloat = 64, memoryWidth: CGFloat = 76, actionsWidth: CGFloat = 200

    @State private var pointer: Bool?
    private var hovered: Bool { pointer ?? startHovered }

    var body: some View {
        let cpuHeat = Activity.heat(cpu: row.cpu), memoryHeat = Activity.heat(memory: row.memory, physicalMemory: physicalMemory)
        let heat = max(cpuHeat, memoryHeat)
        // An app follows Apps show as (story 154); a helper or a process keeps its glyph and name.
        let shows = AppsShowAs.current.shows(row.kind == .app ? .app : nil)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Opens an app's helpers; a row with none does nothing (not disabled, which would dim its Heavy chip).
                Button { if !row.children.isEmpty { toggle() } } label: {
                    HStack(spacing: 10) {
                        chevron
                        if shows.icon { ActivityIcon(row: row, size: child ? 18 : 22).frame(width: 22) }
                        names(heat, title: shows.title)
                        Spacer(minLength: 6)
                    }
                    .contentShape(.rect)
                    .appTip(row.name, when: !shows.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.name)
                .accessibilityHint(row.children.isEmpty ? "" : open ? "Hides its helpers" : "Shows its helpers")
                if !compact {
                    ActivityBar(share: top > 0 ? (sort == .cpu ? row.cpu : Double(row.memory)) / top : 0, heat: heat).frame(width: 44)
                }
                Text(Activity.cpuText(row.cpu)).font(ink.mono(11.5)).foregroundStyle(tone(cpuHeat))
                    .frame(width: Self.cpuWidth, alignment: .trailing)
                Text(Activity.memoryText(row.memory)).font(ink.mono(11.5))
                    .foregroundStyle(tone(memoryHeat))
                    .frame(width: Self.memoryWidth, alignment: .trailing)
                // The column keeps its width with nothing in it, so the numbers line up whether a row is hovered or not.
                if !compact {
                    ZStack(alignment: .trailing) { Color.clear.frame(height: 1); actions }.frame(width: Self.actionsWidth, alignment: .trailing)
                }
            }
            .padding(.leading, child ? 28 : 0)
            if let confirming { confirm(confirming.force) }
            else if compact, hovered, row.rights.canQuit, !quitting {
                actions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, confirming != nil || (compact && hovered && row.rights.canQuit) ? 8 : 0)
        .opacity(quitting ? 0.55 : 1)
        .onHover { pointer = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if row.rights.canQuit { Button("Quit \(row.name)") { ask(false) } }
            if row.rights.canForce { Button("Force quit \(row.name)") { ask(true) } }
        }
    }

    @ViewBuilder private var chevron: some View {
        if row.children.isEmpty || child {
            Color.clear.frame(width: 18, height: 1)
        } else {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink.muted)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 18)
        }
    }

    private func names(_ heat: Activity.Heat, title: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                if title {
                    Text(row.name).font(ink.ui(child ? 12.5 : 13, child ? .regular : .medium)).foregroundStyle(ink.text)
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                }
                if heat == .hog && !quitting { Chip(text: "Heavy", color: ink.red) }
            }
            if let under {
                Text(under).font(ink.ui(11.5)).foregroundStyle(refused == nil ? ink.muted : ink.red).lineLimit(1)
            }
        }
    }

    /// What the row is, under its name: Quitting…, a refusal, an app's helper count, or who a background one belongs to.
    private var under: String? {
        if quitting { return "Quitting…" }
        if let refused { return refused }
        if row.kind == .app { return row.children.isEmpty ? nil : "\(row.processCount) processes" }
        let owner: String? = switch row.rights {
        case .none(let reason): reason.rawValue
        case .quitOnly: "macOS"
        case .quitAndForce: nil
        }
        return (["pid \(row.pid)"] + [owner].compactMap(\.self)).joined(separator: " · ")
    }

    private func tone(_ heat: Activity.Heat) -> Color {
        switch heat {
        case .hog: ink.red
        case .busy: ink.warnText
        case .calm: ink.text2
        }
    }

    /// Quit and Force quit on the hovered row, as the row's rights allow; a lock and why on one Pilot may not quit.
    @ViewBuilder private var actions: some View {
        if case .none(let reason) = row.rights {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text(reason == .pilot ? "Pilot" : "Can't quit")
            }
            .font(ink.ui(11.5)).foregroundStyle(ink.muted)
            .opacity(hovered ? 1 : 0.7)
            .help(reason == .pilot ? "Pilot itself; quit it from its menu" : "macOS needs it, or it is another user's")
        } else if hovered && confirming == nil && !quitting {
            HStack(spacing: 6) {
                Button("Quit") { ask(false) }.buttonStyle(.pilot)
                if row.rights.canForce { Button("Force quit") { ask(true) }.buttonStyle(.pilotDestructive) }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// The confirm in the row: what the quit does, Cancel, and the quit itself.
    private func confirm(_ force: Bool) -> some View {
        let what = force ? "Force quit \(row.name)? Anything unsaved in it is lost."
            : row.kind == .app ? "Quit \(row.name)? It may ask to save first."
            : "Quit \(row.name)?" + (row.rights == .quitOnly ? " macOS starts it again when it needs it." : "")
        return HStack(spacing: 8) {
            Image(systemName: force ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                .foregroundStyle(force ? ink.red : ink.muted)
            Text(what).font(ink.ui(12.5)).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel", action: cancel).buttonStyle(.pilot)
            Button(force ? "Force quit" : "Quit") { quit(force) }
                .buttonStyle(force ? .pilotDestructive : .pilotPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.leading, Self.lead + (child ? 28 : 0))
    }
}

/// A row's share of the heaviest in view, coloured by how heavy it is: the hog's the longest and red.
private struct ActivityBar: View {
    @Environment(\.ink) private var ink
    let share: Double
    let heat: Activity.Heat

    var body: some View {
        let fill = switch heat {
        case .hog: ink.red
        case .busy: ink.yellow
        case .calm: ink.muted.opacity(0.6)
        }
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.line)
                Capsule().fill(fill).frame(width: max(share > 0 ? 3 : 0, g.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// An app's own icon from its bundle; a helper or a background process a gear on a soft tile.
private struct ActivityIcon: View {
    @Environment(\.ink) private var ink
    let row: Activity.Row
    let size: CGFloat

    var body: some View {
        if let path = row.bundlePath {
            Image(nsImage: AppsModule.icon(file: path)).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: row.rights.canQuit ? "gearshape" : "lock")
                .font(.system(size: size * 0.5)).foregroundStyle(ink.muted)
                .frame(width: size, height: size)
                .background(ink.text.opacity(0.07), in: .rect(cornerRadius: size * 0.27))
        }
    }
}
