import AppKit
import PilotCore
import SwiftUI

// The top bar's Pilot dropdown and a reading's popover in Toybox (card agent-bo-95423182, batch 6), on the style's pop
// block (KitPopover): blocks between ink rules, the Pilot mark and a Fredoka headline, workspaces and quick switches as
// keycaps (the live workspace and an on switch raised, the rest sunk), the menu's sun row under the pointer. The same
// blocks, switches, actions and words as PilotDropdown and StatPopover.

/// Pilot's dropdown: the status with Pilot's mark, Hyper's sun cap while it is on, any problem on a coral-dotted well;
/// the workspaces; the quick switches, Hyper's across the width with its switch; Now; the developer rows while Option is
/// held; the footer's rows with their keys as caps.
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
                    if block != .status { ToyRule() }
                    Group {
                        switch block {
                        case .status: status(problems)
                        case .workspaces: workspaces
                        case .quickSwitches: quickSwitches
                        case .now: ToyNowBlock(observers: engine.observers, presses: engine.presses)
                        case .developer: developer
                        case .footer: footer
                        }
                    }
                    .padding(.horizontal, block == .footer ? 8 : 16).padding(.vertical, block == .footer ? 8 : 14)
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
            if let share = ExtrasDownloads.shared.share { downloads(share) }
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

    /// Onboarding's Extras still downloading (Sven, 2026-10-28, Q543): the share the menu-bar icon's meter shows, and each
    /// download where it stands, on a sunk well.
    private func downloads(_ share: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloading extras").font(Toy.nunito(800, 13.5)).foregroundStyle(style.color(\.text))
                Spacer()
                Text("\(Int(share * 100))%").monospacedDigit().font(Toy.nunito(700, 12)).foregroundStyle(style.color(\.text2))
            }
            ToyChunkyMeter(share: share, colour: style.color(\.accent)).accessibilityHidden(true)
            ForEach(ExtrasDownloads.shared.downloads, id: \.title) { download in
                HStack { Text(download.title); Spacer(); Text(download.words).monospacedDigit() }
                    .font(Toy.nunito(700, 12)).foregroundStyle(style.color(\.text2))
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

    // MARK: Quick switches

    /// Hyper across the full width with its switch; the other four two by two below it.
    private var quickSwitches: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToyDropdownHeader(title: "Quick switches")
            VStack(spacing: 8) {
                switchTile(.hyper)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Dropdown.Switch.grid, id: \.self) { switchTile($0) }
                }
            }
        }
    }

    /// A quick switch as a key: raised on the panel colour with its glyph on a candy tile while on, sunk with a plain
    /// glyph while off; Hyper's tile the sun and its switch at the right.
    private func switchTile(_ which: Dropdown.Switch) -> some View {
        let on = switches[which].isOn
        let layerKeys = engine.settings.layerKeys
        let candy = which == .hyper ? style.color(\.hyper) : Toy.module(Dropdown.Switch.allCases.firstIndex(of: which) ?? 0, style)
        return Button { switches[which].toggle() } label: {
            HStack(spacing: 9) {
                ToyTile(symbol: which.symbol(layerKeys: layerKeys), color: on ? candy : style.color(\.sunken), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(which.title).font(Toy.nunito(800, 13)).foregroundStyle(style.color(\.text))
                    Text(which.state(on, layerKeys: layerKeys, tiler: engine.observers.tiler.tilerName)).font(Toy.nunito(700, 11.5))
                        .foregroundStyle(style.color(\.text2))
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                if which == .hyper { ToySwitchFace(isOn: on, width: 40, height: 24).accessibilityHidden(true) }
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, on ? 10 : 8)
            .background { key(on ? style.color(\.raised) : nil) }
            .contentShape(.rect)
            .animation(Kit.change, value: on)
        }
        .buttonStyle(.kitPress)
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

    // MARK: Footer

    /// The footer's rows (Dropdown.Row), each group on a rule.
    private var footer: some View {
        VStack(spacing: 2) {
            ForEach(Array(engine.dropdownFooter.enumerated()), id: \.offset) { index, group in
                if index > 0 { ToyRule().padding(.horizontal, 8).padding(.vertical, 4) }
                ForEach(group, id: \.self) { row in
                    ToyDropdownRow(symbol: row.symbol, title: engine.dropdownTitle(row), key: engine.dropdownKey(row),
                                   layerKeys: engine.settings.layerKeys) { engine.runDropdownRow(row) }
                        .dropdownCommand(row)
                }
            }
        }
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

/// The Now block: the timer (its ring in the tomato's coral while one runs), the app in front and the last press;
/// its own view so the countdown redraws only it.
private struct ToyNowBlock: View {
    @Environment(\.style) private var style
    let observers: EngineObservers
    let presses: [Press]

    var body: some View {
        let timer = ExtensionTimer.shared
        let app = observers.focusedApp
        VStack(alignment: .leading, spacing: 8) {
            ToyDropdownHeader(title: "Now")
            HStack(spacing: 8) {
                TimerRing(left: timer.left ?? 0, lineWidth: 3.5, track: style.color(\.sunken), tint: Toy.module(3, style)).frame(width: 16, height: 16)
                if let line = NowTimer.line(timer) {
                    Text(line).monospacedDigit()
                    Spacer()
                    if let first = timer.buttons.first { textButton(first.label) { timer.press(0) } }
                } else {
                    Text("No timer running").foregroundStyle(style.color(\.text2))
                    Spacer()
                }
            }
            .frame(minHeight: 26)
            if let app {
                HStack(spacing: 8) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                    Text("\(app.localizedName ?? "–")\(observers.tiler.focused.map { " · workspace \($0)" } ?? "")")
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(style.color(\.text3)).frame(width: 16)
                if let press = presses.first {
                    Text("Last: \(press.line)").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(press.time.formatted(date: .omitted, time: .shortened)).font(Toy.mono(11)).foregroundStyle(style.color(\.text3))
                } else {
                    Text("No presses yet").foregroundStyle(style.color(\.text2))
                    Spacer()
                }
            }
        }
        .font(Toy.nunito(700, 13)).foregroundStyle(style.color(\.text))
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
