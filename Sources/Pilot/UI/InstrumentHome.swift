import AppKit
import Clipboard
import PilotCore
import SwiftUI

/// Home in Instrument (mockup A's home.html, card agent-bo-95423181, ADR 0008), on direction 2 "Now beside the board"
/// (HomeNowPage, Sven's pick 2026-10-12): what needs you as a notice with an accent tick across the top, the column of
/// now, and the board: the Hyper keyboard, the workspace map on each display, Presses, Clipboard (as many copies as its
/// block holds), This Mac and extension pages, medium ones two to a row.
struct InstrumentHome: View {
    let parts: HomeParts

    var body: some View {
        HomeNowPage(parts: parts, side: 28, gap: 16) {
            ForEach(Array(parts.problems.enumerated()), id: \.offset) { i, problem in InstrumentNotice(parts: parts, problem: problem, index: i) }
        } board: { id, fill, width in
            block(id, width: width, fill: fill)
        }
    }

    /// A board block; the forms every style shares (HomeSharedBlock) first.
    @ViewBuilder private func block(_ id: String, width: CGFloat, fill: Bool) -> some View {
        if let shared = HomeSharedBlock(id: id, parts: parts) { shared } else { own(id, width: width, fill: fill) }
    }

    @ViewBuilder private func own(_ id: String, width: CGFloat, fill: Bool) -> some View {
        switch HomeLayout.Block(rawValue: id) {
        case .keyboard: InstrumentHyperKeyboard(parts: parts, whole: width >= HomeNow.wholeBoard)
        case .workspaces: InstrumentWorkspaces(width: width)
        case .mostUsed: InstrumentPresses(fill: fill)
        case .clipboard: InstrumentClipboard(parts: parts)
        // This Mac's readings carry their own heading.
        case .thisMac: InstrumentMac(fill: fill).frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading).styleSurface(\.card)
        case .pilot, .quickActions, nil: EmptyView()
        }
    }
}

// MARK: - What needs you

/// One thing that needs you, as the mockup's milestone notice: an accent tick, its kind in mono capitals, what is wrong
/// and what it means, then its button, which holds Return when Home says so.
private struct InstrumentNotice: View {
    @Environment(\.style) private var style
    let parts: HomeParts
    let problem: HomeProblems.Problem
    let index: Int

    var body: some View {
        let detail = problem.detail.map { " " + Self.sentence($0) } ?? ""
        HStack(spacing: 14) {
            InstrumentEyebrow(text: Self.eyebrow(problem.kind), role: \.accentText)
            Text("\(Text(Self.sentence(problem.title)).foregroundStyle(style.color(\.text)))\(Text(detail).foregroundStyle(style.color(\.text2)))")
                .styleText(\.body).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .help(problem.detail ?? problem.title)
            if let fix = parts.fix(problem) {
                let held = parts.holdsReturn(index)
                Button(action: fix.run) {
                    HStack(spacing: 7) { Text(fix.title); if held { InstrumentKey(text: ReturnButton.hint) } }
                }
                .buttonStyle(InstrumentButtonStyle())
                .keyboardShortcut(held ? .defaultAction : nil)
            }
        }
        .instrumentNotice()
        .accessibilityElement(children: .contain)
    }

    /// The words over a problem: what it is about.
    static func eyebrow(_ kind: HomeProblems.Problem.Kind) -> String {
        switch kind {
        case .accessibility: "Accessibility"
        case .secureInput: "Secure input"
        case .tiler: "Tiling"
        case .error: "Pilot"
        }
    }

    /// `text` ending in a full stop.
    static func sentence(_ text: String) -> String { text.hasSuffix(".") ? text : text + "." }
}

// MARK: - Hyper keyboard

/// The Hyper keyboard: Binds' Instrument board, each bound key with its bind's short name, at the top of Home; a click
/// is `HomeParts.openKey`. Hyper off: the board rests, dimmed, with Turn on.
private struct InstrumentHyperKeyboard: View {
    @Environment(Engine.self) private var engine
    let parts: HomeParts
    /// The board whole, its names shrunk, rather than split (HomeNow.wholeBoard).
    var whole = false

    var body: some View {
        let binds = parts.binds, boards = KeyboardCaptions.current
        let taken = boards.compact.codes.filter { binds.bound[$0] != nil }.count
        let off = !engine.hyperSwitch.isOn
        InstrumentPanel(title: "Hyper keyboard", note: "\(taken) bound · \(boards.compact.codes.count - taken) free") {
            HStack(spacing: 8) {
                if off { Button("Turn on Hyper") { engine.hyperSwitch.set(true) }.buttonStyle(InstrumentButtonStyle(kind: .primary)) }
                Button("All binds") { parts.go(AppPlace(.binds)) }.buttonStyle(InstrumentButtonStyle(kind: .ghost))
            }
        } content: {
            InstrumentBindsBoard(boards: boards, binds: binds, layerKeys: engine.settings.layerKeys, layer: .hyper, picked: nil,
                                 marks: InstrumentBoardFit.Marks(binds, boards: boards), module: nil, pick: parts.openKey, whole: whole)
            .opacity(off ? 0.38 : 1)
            .allowsHitTesting(!off)
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
        }
    }
}

// MARK: - Workspaces

/// The workspace map: each display's workspaces as small screens of their windows, the focused one ringed in the
/// signal colour; under each, its number, apps and layout. A click goes there; a right-click opens its editor.
struct InstrumentWorkspaces: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    /// The panel's width.
    let width: CGFloat

    /// One display and the workspaces on it.
    struct Display: Identifiable {
        let id: Int
        let name: String
        let workspaces: [OccupiedWorkspace]
    }

    var body: some View {
        let tiler = engine.observers.tiler
        let displays = Self.displays(occupied: tiler.occupied, windows: tiler.windows, focused: tiler.focused,
                                     monitors: tiler.perMonitor)
        let top = tiler.homeCells.compactMap { Int($0.name) }.max() ?? 4
        let windows = tiler.windows.count
        InstrumentPanel(title: "Workspaces", note: tiler.focused == nil ? nil
                        : "\(Self.count(displays.count, "display")) · \(Self.count(windows, "window"))") {
            HStack(spacing: 8) {
                Text("Go to").styleText(\.caption).foregroundStyle(style.color(\.text3))
                InstrumentKeys(caps: ["1–\(top)"])
                style.color(\.line2).frame(width: 1, height: 16).padding(.horizontal, 6)
                Button { engine.action("workspaces.saveSnapshot")?.run() } label: {
                    InstrumentKeyedLabel(title: "Save snapshot", trigger: engine.binds.store.trigger(for: "workspaces.saveSnapshot"))
                }
                .buttonStyle(InstrumentButtonStyle(kind: .ghost))
            }
        } content: {
            if tiler.focused == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(tiler.tilerName) is not running").styleText(\.strong).foregroundStyle(style.color(\.text))
                    Text("Pilot reads your workspaces from it; they come back when it starts.").styleText(\.caption)
                        .foregroundStyle(style.color(\.text3))
                }
                .padding(20)
            } else {
                map(displays, focused: tiler.focused).padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
            }
        }
    }

    /// The displays side by side, every workspace one width, while each screen keeps 150 pt; else one display under
    /// the other, its workspaces in as many columns as fit.
    @ViewBuilder private func map(_ displays: [Display], focused: String?) -> some View {
        let inner = max(0, width - 40)
        let count = displays.reduce(0) { $0 + $1.workspaces.count }
        let each = (inner - 28 * CGFloat(displays.count - 1) - 20 * CGFloat(count - displays.count)) / CGFloat(max(1, count))
        if each >= 150 {
            HStack(alignment: .top, spacing: 28) {
                ForEach(displays) { display in
                    column(display, perRow: display.workspaces.count, each: each, focused: focused)
                        .frame(width: each * CGFloat(display.workspaces.count) + 20 * CGFloat(display.workspaces.count - 1))
                }
            }
        } else {
            let perRow = max(1, Int((inner + 20) / 170))
            VStack(alignment: .leading, spacing: 18) {
                // A display with fewer workspaces than a row holds spreads them across it.
                ForEach(displays) { display in
                    let row = min(perRow, max(1, display.workspaces.count))
                    column(display, perRow: row, each: (inner - 20 * CGFloat(row - 1)) / CGFloat(row), focused: focused)
                }
            }
        }
    }

    /// A display's eyebrow over a hairline, then its workspaces, `perRow` a row.
    func column(_ display: Display, perRow: Int, each: CGFloat, focused: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(display.name).styleText(\.eyebrow).foregroundStyle(style.color(\.text3)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader).help(display.name)
                InstrumentRule()
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(stride(from: 0, to: display.workspaces.count, by: perRow)), id: \.self) { start in
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(display.workspaces[start..<min(start + perRow, display.workspaces.count)], id: \.name) { workspace in
                            InstrumentWorkspace(workspace: workspace, focused: workspace.name == focused, tall: each >= 200).frame(width: each)
                        }
                    }
                }
            }
        }
    }

    /// "1 display", "9 windows".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// The workspaces with windows, and the focused one, on the display each shows on (its first window's, else the
    /// one the tiler shows it on), displays by the tiler's number; a display named as the tiler names it, else by
    /// number, or "Display" when there is one.
    static func displays(occupied: [OccupiedWorkspace], windows: [AeroWindow], focused: String?, monitors: [AeroMonitorWorkspace],
                         nicknames: DisplayNicknames = .shared) -> [Display] {
        var shown = occupied
        if let focused, !shown.contains(where: { $0.name == focused }) {
            let at = shown.firstIndex { a in Int(a.name).map { n in Int(focused).map { n > $0 } ?? true } ?? true } ?? shown.endIndex
            shown.insert(OccupiedWorkspace(name: focused, apps: []), at: at)
        }
        let first = monitors.map(\.monitorId).min() ?? windows.map(\.monitorId).min() ?? 1
        let monitor = { (name: String) in
            windows.first { $0.workspace == name }?.monitorId ?? monitors.first { $0.workspace == name }?.monitorId ?? first
        }
        let ids = Array(Set(shown.map { monitor($0.name) })).sorted()
        return ids.map { id in
            let metadata = monitors.filter { $0.monitorId == id }
            let systemName = metadata.first?.monitorName ?? (ids.count == 1 ? "Display" : "Display \(id)")
            let uuid = metadata.count == 1 ? metadata.first?.displayUUID : nil
            let unique = uuid.map { value in monitors.filter { $0.displayUUID == value }.count == 1 } ?? false
            let name = nicknames.label(systemName: systemName, displayUUID: unique ? uuid : nil)
            return Display(id: id, name: name, workspaces: shown.filter { monitor($0.name) == id })
        }
    }
}

/// One workspace: its windows on a small screen, then its number, apps and layout.
private struct InstrumentWorkspace: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Environment(\.editWorkspace) private var editWorkspace
    let workspace: OccupiedWorkspace
    let focused: Bool
    let tall: Bool

    var body: some View {
        let tiler = engine.observers.tiler
        let windows = tiler.windows.filter { $0.workspace == workspace.name }
        let saved = engine.layouts.layout(workspace.name)
        let radius = style.radii.card - 2
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button {
            if workspace.apps.isEmpty, let editWorkspace { editWorkspace(workspace.name) } else { tiler.go(workspace.name, from: "home") }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                InstrumentScreen(windows: windows, preset: saved.preset)
                    .frame(height: tall ? 164 : 120)
                    .background(style.color(\.well), in: shape)
                    .overlay { shape.strokeBorder(style.color(focused ? \.accentLine : \.line)) }
                    .background { if focused { RoundedRectangle(cornerRadius: radius + 3, style: .continuous).fill(style.color(\.accentSoft)).padding(-3) } }
                // The layout gives way before a word of the apps does.
                ViewThatFits(in: .horizontal) {
                    label(layout: Self.layout(saved, windows))
                    label(layout: nil)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .editsWorkspace(workspace.name)
        .help(workspace.apps.isEmpty ? "Set workspace \(workspace.name) up" : "Go to workspace \(workspace.name)")
        .accessibilityLabel("Workspace \(workspace.name)" + (workspace.apps.isEmpty ? ", empty" : ": " + workspace.apps.joined(separator: ", ")))
        .accessibilityAddTraits(focused ? .isSelected : [])
    }

    /// The workspace's number, its apps and, when it has room, its layout.
    private func label(layout: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(workspace.name).styleText(\.mono).foregroundStyle(style.color(focused ? \.accentText : \.text)).fixedSize()
            Text(workspace.apps.isEmpty ? "empty" : workspace.apps.joined(separator: ", ")).styleText(\.caption)
                .foregroundStyle(style.color(workspace.apps.isEmpty ? \.text3 : \.text2)).truncationMode(.tail)
                .fixedSize(horizontal: layout != nil, vertical: false)
            if let layout, !layout.isEmpty {
                Spacer(minLength: 6)
                Text(layout).styleText(\.small).foregroundStyle(style.color(\.text3)).fixedSize()
            }
        }
        .lineLimit(1)
    }

    /// The saved layout ("Columns · auto"), else how the tiler has the windows; nothing for an empty workspace.
    static func layout(_ saved: WorkspaceLayout, _ windows: [AeroWindow]) -> String {
        if let preset = saved.preset { return preset.label + (saved.auto ? " · auto" : "") }
        guard !windows.isEmpty else { return "" }
        return HomeNowBlock.arrangement(windows)
    }
}

/// A workspace's windows as tiles: Main + stack the first beside the rest stacked, rows one over the other, else side
/// by side, three a row; the floating ones after the tiled; at most six.
private struct InstrumentScreen: View {
    @Environment(Engine.self) private var engine
    let windows: [AeroWindow]
    let preset: LayoutPreset?

    var body: some View {
        let shown = Array(windows.tiledFirst.prefix(6))
        let front = shown.first { engine.observers.isInFront($0) }?.id
        Group {
            if preset == .mainStack, shown.count > 1 {
                GeometryReader { g in
                    HStack(spacing: 6) {
                        InstrumentWindowTile(window: shown[0], front: front == shown[0].id).frame(width: (g.size.width - 6) * 0.6)
                        VStack(spacing: 6) { ForEach(shown.dropFirst(), id: \.id) { InstrumentWindowTile(window: $0, front: front == $0.id) } }
                    }
                }
            } else {
                let rows = preset == .rows ? shown.map { [$0] } : shown.layoutRows
                VStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) { ForEach(row, id: \.id) { InstrumentWindowTile(window: $0, front: front == $0.id) } }
                    }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One window: its app's icon and its title, the window macOS has in front ringed in the signal colour.
private struct InstrumentWindowTile: View {
    @Environment(\.style) private var style
    let window: AeroWindow
    /// The window macOS has in front.
    let front: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous)
        GeometryReader { g in
            let h = g.size.height
            VStack(spacing: 6) {
                InstrumentAppIcon(bundle: window.bundleId, symbol: "macwindow", size: h >= 90 ? 30 : h >= 56 ? 24 : 18)
                if h >= 56 {
                    Text(window.title.isEmpty ? window.appName : window.title).styleText(\.small).foregroundStyle(style.color(\.text2))
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(6)
            .frame(width: g.size.width, height: h)
        }
        .background(style.color(\.tile), in: shape)
        .overlay { shape.strokeBorder(style.color(front ? \.accentLine : \.line)) }
        .help(window.title.isEmpty ? window.appName : "\(window.appName): \(window.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title.isEmpty ? window.appName : "\(window.appName): \(window.title)")
    }
}

// MARK: - Presses

/// Today's presses: the count as a readout, a bar for each hour from the first with a press to this one (eight at least),
/// this hour in the signal colour, then the binds pressed most today. Pilot keeps no earlier days, so the mockup's
/// fourteen days are today's hours.
private struct InstrumentPresses: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    /// The page fills the window: the bars take the height its row has spare.
    let fill: Bool

    var body: some View {
        let now = Date()
        let today = engine.today
        let hours = today.hours(now: now), total = today.total(now: now)
        let hour = Calendar.current.component(.hour, from: now)
        let peak = hours.indices.max { hours[$0] < hours[$1] } ?? 0
        let span = Self.span(hours, now: hour)
        let rows = today.top(6, now: now)
        InstrumentPanel(title: "Presses", stretch: true) {
            Text("Today by hour").styleText(\.caption).foregroundStyle(style.color(\.text3))
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text(total.formatted()).styleText(\.display).monospacedDigit().foregroundStyle(style.color(\.text))
                    Text(total == 0 ? "nothing pressed yet today" : "today · busiest at \(String(format: "%02d", peak)):00")
                        .styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1)
                }
                .padding(.horizontal, 20).padding(.top, 18)
                bars(Array(hours[span]), now: hour - span.lowerBound)
                    .frame(minHeight: 58, maxHeight: fill ? 110 : 58)
                    .padding(.horizontal, 20).padding(.top, 18)
                HStack {
                    Text(String(format: "%02d:00", span.lowerBound)); Spacer()
                    Text(String(format: "%02d:00", (span.lowerBound + span.upperBound + 1) / 2)); Spacer(); Text("Now")
                }
                .styleText(\.key).foregroundStyle(style.color(\.text3))
                .padding(.horizontal, 20).padding(.top, 6)
                VStack(alignment: .leading, spacing: 0) {
                    InstrumentEyebrow(text: "Most used today").padding(.horizontal, 12).padding(.bottom, 6)
                    if rows.isEmpty {
                        Text("Hold \(engine.settings.layerKeys.label) and press a key; it counts here.").styleText(\.caption)
                            .foregroundStyle(style.color(\.text3)).padding(.horizontal, 12).frame(height: 34)
                    }
                    ForEach(rows, id: \.action) { row in line(row, top: rows.first?.count ?? 1) }
                }
                .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 8)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The hours the chart draws: from the first with a press to this one, eight at least, so the bars carry the panel
    /// rather than a run of empty hours before the day began. It ends now: no later hour has presses yet.
    static func span(_ hours: [Int], now: Int) -> ClosedRange<Int> {
        let start = min(hours.firstIndex { $0 > 0 } ?? now, now)
        return max(0, min(start, now - 7))...now
    }

    /// The hours' bars, this hour lit; an hour without presses a stub.
    private func bars(_ hours: [Int], now: Int) -> some View {
        let top = CGFloat(max(1, hours.max() ?? 1))
        return GeometryReader { g in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(hours.indices, id: \.self) { h in
                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                        .fill(style.color(h == now ? \.accent : hours[h] == 0 ? \.line : \.bar))
                        .frame(height: hours[h] == 0 ? 2 : max(3, g.size.height * CGFloat(hours[h]) / top))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Presses by hour today")
        .accessibilityValue(hours.enumerated().filter { $0.element > 0 }.map { "\($0.offset):00, \($0.element)" }.joined(separator: "; "))
    }

    /// One bind: its keys, name, a meter against the busiest and its count.
    private func line(_ row: (action: String, count: Int), top: Int) -> some View {
        HStack(spacing: 12) {
            Group {
                if let key = engine.binds.store.trigger(for: row.action) { InstrumentKeys(trigger: key) } else { Color.clear.frame(height: 1) }
            }
            .frame(width: 64, alignment: .leading)
            Text(engine.action(row.action)?.label ?? row.action).styleText(\.body).foregroundStyle(style.color(\.text))
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                .help(engine.action(row.action)?.label ?? row.action)
            InstrumentMeter(share: Double(row.count) / Double(max(1, top))).frame(width: 48)
            Text("\(row.count)").styleText(\.mono).foregroundStyle(style.color(\.text2)).monospacedDigit().frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 12).frame(height: 34)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Clipboard

/// The newest copies, newest first and raised: the app each came from, its words (a colour with its swatch), its kind
/// and age; a click opens the clipboard. Under them, that a password manager's copies are never kept (SPEC.md).
private struct InstrumentClipboard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let parts: HomeParts
    @State private var clips: [StoredClip] = []
    /// How many rows the panel's height holds, and each one's height.
    @State private var fit = InstrumentClips.shown
    @State private var rowHeight: CGFloat = 44

    var body: some View {
        InstrumentPanel(title: "Clipboard", note: parts.copy.map { "\($0.count) kept" }, stretch: true) {
            if let key = engine.binds.store.trigger(for: "apps.clipboard") { InstrumentKeys(trigger: key) }
        } content: {
            VStack(spacing: 0) {
                if clips.isEmpty {
                    Text("Nothing copied yet; what you copy shows here, newest first.").styleText(\.caption)
                        .foregroundStyle(style.color(\.text3)).frame(maxWidth: .infinity, minHeight: 88, maxHeight: .infinity)
                } else {
                    // Eight rows on their own; as many more as the panel's share of its row holds, the rows sharing what is
                    // left over, so no band is left above the foot.
                    Color.clear
                        .frame(minHeight: CGFloat(min(clips.count, InstrumentClips.shown)) * 44 + 12, maxHeight: .infinity)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height - 12 }) { height in
                            fit = max(1, min(clips.count, Int(height / 44)))
                            rowHeight = clips.count > fit ? height / CGFloat(fit) : 44
                        }
                        .overlay(alignment: .top) {
                            // The last row that fits says how many more and opens the clipboard (HomeFold).
                            let fold = HomeFold.rows(total: max(parts.copy?.count ?? 0, clips.count), fits: fit)
                            TimelineView(.everyMinute) { context in
                                VStack(spacing: 0) {
                                    ForEach(Array(clips.prefix(fold.shown).enumerated()), id: \.element.id) { i, clip in
                                        row(clip, newest: i == 0, now: context.date).frame(height: rowHeight)
                                    }
                                    if fold.more > 0 {
                                        HomeMoreRow(count: fold.more, more: HomeMore(title: "Open Clipboard", key: engine.binds.store.trigger(for: "apps.clipboard")) {
                                            engine.action("apps.clipboard")?.run()
                                        })
                                        .padding(.horizontal, 12).frame(height: rowHeight)
                                    }
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                        .clipped()
                }
                InstrumentRule()
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").font(.system(size: style.type.caption.size)).accessibilityHidden(true)
                    Text("Password-manager copies are never kept")
                }
                .styleText(\.caption).foregroundStyle(style.color(\.text3))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).frame(height: 40)
            }
            .frame(maxHeight: .infinity)
        }
        // Read only while it is on Home, as the window shows.
        .task(id: parts.onScreen) { clips = Array(parts.sources.recentCopies().prefix(InstrumentClips.most)) }
    }

    private func row(_ clip: StoredClip, newest: Bool, now: Date) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        let words = Snippet.firstLine(String(clip.title.prefix(300))) ?? ""
        return Button { engine.action("apps.clipboard")?.run() } label: {
            HStack(spacing: 11) {
                InstrumentAppIcon(bundle: clip.sourceApp, symbol: clip.kind.symbol, size: 18)
                HStack(spacing: 10) {
                    if let swatch = clip.swatch {
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: swatch)).frame(width: 14, height: 14)
                            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(style.color(\.imageOutline)) }
                    }
                    Text(words).styleText(clip.kind == .colour ? \.mono : \.body).foregroundStyle(style.color(\.text))
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(clip.kind.label).styleText(\.small).foregroundStyle(style.color(\.text3)).lineLimit(1).frame(width: 52, alignment: .leading)
                Text(InstrumentClips.ago(now.timeIntervalSince(clip.copiedAt))).styleText(\.mono).foregroundStyle(style.color(\.text3))
                    .lineLimit(1).frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(height: 44)
            .background { if newest { shape.fill(style.color(\.raised)) } }
            .overlay { if newest { shape.strokeBorder(style.color(\.line)) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(clip.title)
        .accessibilityLabel("\(clip.kind.label): \(words)")
    }
}

/// Instrument's Clipboard panel's numbers.
enum InstrumentClips {
    /// How many copies the panel lists when it sets its own height; a taller row shows more, up to `most`.
    static let shown = 8, most = 20

    /// A copy's age as the panel's narrow column says it: "now", "2m", "1h", "3d".
    static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "now"
        case ..<3600: "\(Int(seconds / 60))m"
        case ..<86_400: "\(Int(seconds / 3600))h"
        default: "\(Int(seconds / 86_400))d"
        }
    }
}

// MARK: - This Mac

/// This Mac now: CPU, memory, the startup disk and the CPU's temperature, each with its last minutes as a line (the
/// disk its use as a meter) and its reading.
private struct InstrumentMac: View {
    @Environment(\.style) private var style
    let fill: Bool

    struct Reading {
        let label: String
        var line: [Double] = []
        var share: Double?
        let value: String
        let unit: String
    }

    var body: some View {
        let system = SystemSampler.shared
        let values = system.latestValues, raw = system.latest
        let memory = raw?.memory
        let gib = Double(1 << 30)
        // "412 GB": the number as the reading, its unit small after it.
        let free = raw?.slow.disk.map { StatsFormat.bytes(Double($0.available)).split(separator: " ").map(String.init) }
        let readings = [
            Reading(label: "CPU", line: system.history.compactMap(\.cpu), value: values?.cpu.map(StatsFormat.percent) ?? "–", unit: "%"),
            Reading(label: "Memory", line: system.history.map(\.ram),
                    value: memory.map { String(format: "%.1f", Double($0.used) / gib) } ?? "–",
                    unit: memory.map { "/ \(Int((Double($0.total) / gib).rounded())) GB" } ?? ""),
            Reading(label: "Disk", share: raw?.diskUsed,
                    value: free?.first ?? "–", unit: free.map { ($0.last ?? "") + " free" } ?? ""),
            Reading(label: "Temperature", line: system.history.compactMap(\.heat), value: values?.heat.map(StatsFormat.whole) ?? "–", unit: "°C"),
        ]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("This Mac").styleText(\.title).foregroundStyle(style.color(\.text)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let chip = raw?.slow.machine?.chip { Text(chip).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            }
            .lineLimit(1)
            .padding(.horizontal, 20).frame(height: 38).padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(readings, id: \.label) { row($0) }
            }
            .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 8)
            .frame(maxHeight: fill ? .infinity : nil)
        }
    }

    private func row(_ reading: Reading) -> some View {
        HStack(spacing: 14) {
            Text(reading.label).styleText(\.body).foregroundStyle(style.color(\.text2)).lineLimit(1).frame(width: 92, alignment: .leading)
            Group {
                if let share = reading.share { InstrumentMeter(share: share) } else { InstrumentSpark(values: reading.line) }
            }
            .frame(height: 22).frame(maxWidth: .infinity)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reading.value).styleText(\.mono).foregroundStyle(style.color(\.text)).monospacedDigit()
                Text(reading.unit).styleText(\.key).foregroundStyle(style.color(\.text3))
            }
            .lineLimit(1).fixedSize().frame(minWidth: 92, alignment: .trailing)
        }
        .frame(minHeight: 40).frame(maxHeight: fill ? .infinity : 40)
        .accessibilityElement(children: .combine)
    }
}
