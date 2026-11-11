import AppKit
import PilotCore
import SwiftUI

// The top bar's Pilot dropdown and a reading's popover in Toybox (card agent-bo-95423182, batch 6), on the style's pop
// block (KitPopover): blocks between ink rules, the Pilot mark and a Fredoka headline, workspaces and quick switches as
// keycaps (the live workspace and an on switch raised, the rest sunk), the menu's sun row under the pointer. The same
// blocks, switches, actions and words as PilotDropdown and StatPopover.

/// Pilot's dropdown, compact since spec pilot-1-1 T29 as Instrument's: the status with Pilot's mark, Hyper's sun cap
/// while it is on, any problem on a coral-dotted well; the workspaces; six switches as keys in one row; Now while something
/// runs; the rows in groups with their keys as caps; the developer rows while Option is held; Check for updates, Settings
/// and Quit on one line.
struct ToyDropdown: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let switches: QuickSwitches
    let option: Bool

    var body: some View {
        let problems = HomeProblems.list(accessibilityGranted: engine.gate.isTrusted, secureInput: engine.secureInput.holder,
                                         tilerRunning: engine.observers.tiler.isAnswering,
                                         lastError: engine.lastError)
        KitPopover(width: 340, inset: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Dropdown.blocks(option: option), id: \.self) { block in
                    if block == .now {
                        // Its own rule and room, and nothing while nothing runs.
                        ToyNowBlock()
                    } else {
                        if block != .status { ToyRule() }
                        Group {
                            switch block {
                            case .status: status(problems)
                            case .workspaces: workspaces
                            case .quickSwitches: quickSwitches
                            case .rows: rows
                            case .developer: developer
                            case .footer: footer
                            case .now: EmptyView()
                            case .extensions, .sound, .connections, .display, .media, .stats: EmptyView()  // The tall menu's alone (T4).
                            }
                        }
                        .padding(.horizontal, block == .footer ? 8 : 16).padding(.vertical, block == .footer ? 8 : 14)
                    }
                }
            }
        }
    }

    // MARK: Status

    private func status(_ problems: [HomeProblems.Problem]) -> some View {
        let pilotSwitch = engine.pilotSwitch
        let hyperOn = switches[.hyper].isOn
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PilotMark(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Dropdown.headline(isOn: pilotSwitch.isOn, problems: problems.count))
                        .font(Toy.fredoka(18)).foregroundStyle(style.color(\.text))
                    // One cap tall whatever it says, so switching Hyper in the open dropdown never moves the tiles under the pointer.
                    ZStack(alignment: .leading) {
                        ToyMenuCap(label: " ", height: 24).hidden()
                        if hyperOn, problems.isEmpty, engine.gate.isTrusted, !engine.hyperHeld {
                            HStack(spacing: 6) {
                                Text("Hyper is")
                                ToyKeycap(label: engine.settings.layerKeys.label, hyper: true, small: true)
                            }
                        } else {
                            Text(Dropdown.hyperLine(hyperOn: hyperOn, trusted: engine.gate.isTrusted, secureInput: engine.secureInput.isActive,
                                                    held: engine.hyperHeld, layerKey: engine.settings.layerKeys.label, problems: problems.count))
                        }
                    }
                    .font(Toy.nunito(700, 12.5)).foregroundStyle(style.color(\.text2))
                }
                Spacer(minLength: 0)
            }
            ForEach(problems, id: \.kind) { problem in problemRow(problem) }
        }
    }

    /// A problem: a coral dot, what is wrong and what to do, its one button (the sun where it fixes it), on a sunk well.
    private func problemRow(_ problem: HomeProblems.Problem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ToyDot(color: style.color(\.problem)).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title).font(Toy.nunito(800, 13.5)).foregroundStyle(style.color(\.text))
                if let detail = problem.detail { Text(detail).font(Toy.nunito(700, 12)).foregroundStyle(style.color(\.text2)) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            switch (problem.kind, problem.place) {
            case (.accessibility, _): Button("Allow") { OnboardingWindow.openPermissions() }.buttonStyle(.pilotPrimary)
            case (.tiler, _): Button("Restart") { engine.startTiler() }.buttonStyle(.pilotPrimary)
            case (_, let place?): Button("Open") { AppWindowController.shared.open(place) }.buttonStyle(.pilot)
            case (_, nil): EmptyView()
            }
        }
        .padding(12)
        .toyWell(radius: 16)
    }

    // MARK: Workspaces

    private var workspaces: some View {
        let tiler = engine.observers.tiler
        let cells = tiler.homeCells
        return VStack(alignment: .leading, spacing: 0) {
            ToyDropdownHeader(title: "Workspaces", trailing: Dropdown.workspaceKeys(layerKeys: engine.settings.layerKeys, count: cells.count))
            if !tiler.isAnswering {
                Text("Tiling is off while \(tiler.tilerName) is stopped.").font(Toy.nunito(700, 12.5)).foregroundStyle(style.color(\.text2))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(cells, id: \.name) { workspace in
                        tile(workspace, current: workspace.name == tiler.focused) { tiler.go(workspace.name, from: "dropdown") }
                    }
                }
            }
        }
        .opacity(tiler.isAnswering ? 1 : 0.6)
    }

    /// A workspace: its apps' icons over its number in Fredoka on a sunk well; the live one a sun keycap.
    private func tile(_ workspace: OccupiedWorkspace, current: Bool, go: @escaping () -> Void) -> some View {
        Button(action: go) {
            VStack(spacing: 4) {
                CompactApps(names: Array(workspace.apps.prefix(3)), bundles: workspace.bundles, spacing: 3)
                .frame(height: 18)
                Text(workspace.name).font(Toy.fredoka(17))
                    .foregroundStyle(current ? style.color(\.onAccent) : style.color(workspace.apps.isEmpty ? \.text3 : \.text))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background { key(current ? style.color(\.accent) : nil) }
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .help(workspace.apps.isEmpty ? "Workspace \(workspace.name), empty" : "Workspace \(workspace.name): \(workspace.apps.joined(separator: ", "))")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    // MARK: Switches

    /// The six switches as keys in one row: raised with a candy tile while on, sunk while off, the word under each.
    private var quickSwitches: some View {
        HStack(spacing: 6) {
            ForEach(Dropdown.Switch.allCases, id: \.self) { switchTile($0) }
        }
    }

    private func switchTile(_ which: Dropdown.Switch) -> some View {
        let on = switches[which].isOn
        let layerKeys = engine.settings.layerKeys
        let candy = which == .hyper ? style.color(\.hyper) : Toy.module(Dropdown.Switch.allCases.firstIndex(of: which) ?? 0, style)
        return Button { switches[which].toggle() } label: {
            VStack(spacing: 5) {
                ToyTile(symbol: which.symbol(layerKeys: layerKeys), color: on ? candy : style.color(\.sunken), size: 24)
                    .frame(maxWidth: .infinity).padding(.top, 6).padding(.bottom, on ? 8 : 6)
                    .background { key(on ? style.color(\.raised) : nil) }
                Text(which.short).font(Toy.nunito(800, 11)).foregroundStyle(style.color(on ? \.text : \.text2)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .animation(Kit.change, value: on)
        }
        .buttonStyle(.kitPress)
        .help(which.tooltip(on, layerKeys: layerKeys, tiler: engine.observers.tiler.tilerName))
        .accessibilityLabel(which.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// A key's face: raised in `fill` on the ink's edge, or sunk into a well when nil.
    @ViewBuilder private func key(_ fill: Color?) -> some View {
        if let fill { Toy.block(style, fill: fill, radius: 14, edge: 4) } else { Color.clear.toyWell(radius: 14) }
    }

    // MARK: Developer, Option held

    private var developer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ToyDropdownHeader(title: "Developer · Option held")
            ForEach(Dropdown.Row.developer, id: \.self) { row in ToyDropdownRow(symbol: row.symbol, title: row.title) { engine.runDropdownRow(row) } }
            if !engine.presses.isEmpty {
                DisclosureGroup("Recent presses") {
                    ForEach(engine.presses.prefix(15)) { Text($0.line).font(Toy.mono(11)).lineLimit(1).truncationMode(.middle) }
                }
                .font(Toy.nunito(700, 13))
            }
        }
    }

    // MARK: Rows

    /// The rows in their groups, each under its eyebrow.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Dropdown.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 2) {
                    ToyEyebrow(text: group.title).padding(.horizontal, 8).padding(.bottom, 2)
                    ForEach(group.rows, id: \.self) { row in
                        ToyDropdownRow(symbol: row.symbol, title: engine.dropdownTitle(row), key: engine.dropdownKey(row),
                                       layerKeys: engine.settings.layerKeys) { engine.runDropdownRow(row) }
                            .dropdownCommand(row)
                    }
                }
            }
        }
    }

    // MARK: Footer

    /// Check for updates at the left, Settings and Quit with their caps at the right, on one line.
    private var footer: some View {
        HStack(spacing: 10) {
            ForEach(engine.dropdownFooter, id: \.self) { row in
                if row == .settings { Spacer(minLength: 0) }
                Button { engine.runDropdownRow(row) } label: {
                    HStack(spacing: 5) {
                        if row != .quit { Image(systemName: row.symbol).font(.system(size: 11, weight: .bold)) }
                        Text(engine.dropdownTitle(row))
                        if let key = engine.dropdownKey(row) {
                            ForEach(Array(ToyCaps.hint(key).enumerated()), id: \.offset) { ToyMenuCap(label: $1, height: 20) }
                        }
                    }
                    .font(Toy.nunito(800, 12)).foregroundStyle(style.color(\.text2))
                    .contentShape(.rect)
                }
                .buttonStyle(.kitPress)
                .dropdownCommand(row)
            }
        }
        .padding(.horizontal, 8)
    }
}

/// A row of the footer or the developer block: its glyph, its title, its keys as caps (the layer key's the sun's Hyper
/// cap); the menu's sun keycap under the pointer.
private struct ToyDropdownRow: View {
    @Environment(\.style) private var style
    let symbol: String
    let title: String
    var key: String?
    /// The layer key, whose sign in `key` is Hyper's cap.
    var layerKeys: [LayerKey]?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let ink = hovered ? style.color(\.onAccent) : style.color(\.text)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(hovered ? ink : style.color(\.text2)).frame(width: 18)
                Text(title).font(Toy.nunito(800, 13.5)).foregroundStyle(ink)
                Spacer()
                if let key {
                    HStack(spacing: 4) {
                        ForEach(Array(ToyCaps.hint(key).enumerated()), id: \.offset) { _, cap in
                            ToyMenuCap(label: cap == layerKeys?.symbol ? nil : cap, hyper: cap == layerKeys?.symbol, onSun: hovered, height: 24)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .toySunRow(hovered, radius: 12, style: style)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Now, only while something runs (spec pilot-1-1 T29), with its own rule above: a recording with Stop, the focus timer
/// (its ring in the tomato's coral) with its first button, Extras downloading with its share; its own view so the clock
/// and countdown redraw only it.
private struct ToyNowBlock: View {
    @Environment(\.style) private var style

    var body: some View {
        let items = DropdownNow.items
        if !items.isEmpty {
            ToyRule()
            VStack(alignment: .leading, spacing: 8) {
                ToyDropdownHeader(title: "Now")
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in self.item(item) }
            }
            .font(Toy.nunito(700, 13)).foregroundStyle(style.color(\.text))
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }

    @ViewBuilder private func item(_ item: DropdownNow.Item) -> some View {
        switch item {
        case .recording:
            line { Image(systemName: "video.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(style.color(\.problem)) } content: {
                TimelineView(.periodic(from: .now, by: 1)) { _ in Text(Recorder.shared.reading?.words ?? "").monospacedDigit() }
                Spacer()
                textButton("Stop") { Recorder.shared.stop() }
            }
        case .timer(let text):
            let timer = ExtensionTimer.shared
            line { TimerRing(left: timer.left ?? 0, lineWidth: 3.5, track: style.color(\.sunken), tint: Toy.module(3, style)) } content: {
                Text(text).monospacedDigit()
                Spacer()
                if let first = timer.buttons.first { textButton(first.label) { timer.press(0) } }
            }
        case .download(let title, let share):
            VStack(alignment: .leading, spacing: 6) {
                line { Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .bold)).foregroundStyle(style.color(\.text3)) } content: {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Int(share * 100)) %").monospacedDigit().foregroundStyle(style.color(\.text2))
                }
                ToyChunkyMeter(share: share, colour: style.color(\.accent)).accessibilityHidden(true)
            }
        }
    }

    /// A line: its glyph in a 16 point column, then what it says.
    private func line(@ViewBuilder glyph: () -> some View, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            glyph().frame(width: 16, height: 16)
            content()
        }
        .frame(minHeight: 26)
    }

    /// A quiet action in the row's own height: its words in Nunito 800, the second ink.
    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(Toy.nunito(800, 13)).foregroundStyle(style.color(\.text2)).contentShape(.rect) }
            .buttonStyle(.kitPress)
    }
}

/// A block's heading: the eyebrow, a hint in mono at the right.
private struct ToyDropdownHeader: View {
    @Environment(\.style) private var style
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            ToyEyebrow(text: title).accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing { Text(trailing).font(Toy.mono(11)).foregroundStyle(style.color(\.text3)) }
        }
        .padding(.bottom, 10)
    }
}

/// A reading's popover in Toybox (Home's This Mac): a line per reading with its name, its last minutes as candy bars and
/// its value in Fredoka; then each reading's rows under its eyebrow and candy dot on a sunk well, the busiest processes
/// quieter; then the way into This Mac. The same rows and words as StatPopover.
struct ToyStatPopover: View {
    @Environment(\.style) private var style
    let popover: StatPopover

    /// A reading's candy colour, Home's This Mac's where it has one: CPU sky, RAM grape, disk mint, temperature pink.
    static func module(_ stat: MenuBarStats.Stat) -> Int {
        switch stat {
        case .cpu, .bluetooth: 0
        case .ram: 1
        case .disk, .battery: 2
        case .gpu: 3
        case .sensors: 4
        case .network: 5
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                ForEach(popover.stats, id: \.self) { stat in
                    if let value = MenuBarStats.value(stat, values: popover.values, raw: popover.latest) {
                        // The words stand on the bars' foot.
                        HStack(alignment: .bottom, spacing: 12) {
                            Text(stat.title).font(Toy.nunito(800, 13)).foregroundStyle(style.color(\.text2)).frame(width: 84, alignment: .leading)
                            if stat.graphable {
                                ToySpark(bars: Array(MenuBarStats.graph(stat, history: popover.history).suffix(14)), colour: Toy.module(Self.module(stat), style))
                                    .frame(width: 124, height: 24).accessibilityHidden(true)
                            }
                            Spacer(minLength: 8)
                            Text(value).font(Toy.fredoka(17)).monospacedDigit().foregroundStyle(style.color(\.text))
                        }
                        .frame(minHeight: 32)
                    }
                }
            }
            ForEach(popover.stats, id: \.self) { stat in
                let rows = MenuBarStats.rows(stat, in: popover.rows), busiest = popover.busiest[stat] ?? []
                HStack(spacing: 6) {
                    ToyDot(color: Toy.module(Self.module(stat), style))
                    ToyEyebrow(text: stat.title)
                }
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 16).padding(.bottom, 8)
                VStack(spacing: 0) {
                    if rows.isEmpty { line("No reading on this Mac", nil, first: true).foregroundStyle(style.color(\.text3)) }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        line(row.name, row.value, first: index == 0).help(row.explanation)
                    }
                    ForEach(Array(busiest.enumerated()), id: \.element.id) { index, row in
                        line(row.name, row.value, first: rows.isEmpty && index == 0, busiest: true)
                    }
                }
                .padding(.horizontal, 12)
                .toyWell(radius: 14)
            }
            Button("Open This Mac in Pilot", action: popover.openHome).buttonStyle(.pilot).padding(.top, 16)
        }
        .barPopover(width: 360)
    }

    /// A row on a faint rule: its name, then its value in mono; a busiest process in the second ink, cut in the middle.
    private func line(_ name: String, _ value: String?, first: Bool, busiest: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(name).font(Toy.nunito(700, 13)).lineLimit(1).truncationMode(busiest ? .middle : .tail)
            Spacer(minLength: 8)
            if let value { Text(value).font(Toy.mono(12)).monospacedDigit() }
        }
        .foregroundStyle(style.color(busiest ? \.text2 : \.text))
        .frame(minHeight: 32)
        .overlay(alignment: .top) { if !first { style.color(\.line2).frame(height: 1.5) } }
    }
}
