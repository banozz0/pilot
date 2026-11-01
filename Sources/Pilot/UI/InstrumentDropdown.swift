import AppKit
import PilotCore
import SwiftUI

/// Pilot's dropdown in Instrument (card agent-bo-95423181, ADR 0008), compact since spec pilot-1-1 T29 (Q644 A, rows A of
/// Q683): the status with Pilot's mark, the layer key's chip lit in the signal colour while Hyper is on, any problem after
/// attention's tick; the workspaces in one row; six switches; Now while something runs; the rows with their keys as chips,
/// in groups; the developer rows while Option is held; Check for updates, Settings and Quit on one line. One column on the
/// style's popover (KitPopover). The same blocks, switches, rows and words as ToyDropdown.
struct InstrumentDropdown: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let switches: QuickSwitches
    let option: Bool

    var body: some View {
        let problems = HomeProblems.list(accessibilityGranted: engine.gate.isTrusted, secureInput: engine.secureInput.holder,
                                         tilerRunning: engine.observers.tiler.isAnswering,
                                         lastError: engine.lastError)
        KitPopover(width: 330, inset: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Dropdown.blocks(option: option), id: \.self) { block in
                    switch block {
                    case .status: status(problems)
                    case .workspaces: workspaces
                    case .quickSwitches: quickSwitches
                    case .now: InstrumentNowBlock()
                    case .rows: rows
                    case .developer: developer
                    case .footer: VStack(spacing: 6) { InstrumentRule(); footer }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
        }
    }

    // MARK: Status

    private func status(_ problems: [HomeProblems.Problem]) -> some View {
        let pilotSwitch = engine.pilotSwitch
        let hyperOn = switches[.hyper].isOn
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                InstrumentMark(size: 20).foregroundStyle(style.color(\.text2)).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Dropdown.headline(isOn: pilotSwitch.isOn, problems: problems.count))
                        .styleText(\.title).foregroundStyle(style.color(\.text))
                    // One chip tall whatever it says, so switching Hyper in the open dropdown never moves the tiles under the pointer.
                    ZStack(alignment: .leading) {
                        InstrumentKey(text: " ").hidden()
                        if hyperOn, problems.isEmpty, engine.gate.isTrusted, !engine.hyperHeld {
                            HStack(spacing: 6) {
                                Text("Hyper is")
                                InstrumentKey(text: engine.settings.layerKeys.label, hyper: true)
                            }
                        } else {
                            Text(Dropdown.hyperLine(hyperOn: hyperOn, trusted: engine.gate.isTrusted, secureInput: engine.secureInput.isActive,
                                                    held: engine.hyperHeld, layerKey: engine.settings.layerKeys.label, problems: problems.count))
                        }
                    }
                    .styleText(\.caption).foregroundStyle(style.color(\.text3))
                }
                Spacer(minLength: 0)
            }
            ForEach(problems, id: \.kind) { problem in problemRow(problem) }
        }
        .padding(.horizontal, 2)
    }

    /// A problem: attention's tick, what is wrong and what to do, its one button (primary where it fixes it).
    private func problemRow(_ problem: HomeProblems.Problem) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return HStack(alignment: .top, spacing: 10) {
            InstrumentTick().padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title).styleText(\.strong).foregroundStyle(style.color(\.text))
                if let detail = problem.detail { Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            switch (problem.kind, problem.place) {
            case (.accessibility, _): Button("Allow") { OnboardingWindow.openPermissions() }.buttonStyle(InstrumentButtonStyle(kind: .primary))
            case (.tiler, _): Button("Restart") { engine.startTiler() }.buttonStyle(InstrumentButtonStyle(kind: .primary))
            case (_, let place?): Button("Open") { AppWindowController.shared.open(place) }.buttonStyle(InstrumentButtonStyle(kind: .raised))
            case (_, nil): EmptyView()
            }
        }
        .padding(10)
        .background(style.color(\.raised), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line)) }
    }

    // MARK: Workspaces

    /// The workspaces in one row (five a row), each its number over its apps' icons.
    private var workspaces: some View {
        let tiler = engine.observers.tiler
        let cells = tiler.homeCells
        return Group {
            if !tiler.isAnswering {
                Text("Tiling is off while \(tiler.tilerName) is stopped.").styleText(\.caption).foregroundStyle(style.color(\.text3))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: max(min(cells.count, 5), 4)), spacing: 5) {
                    ForEach(cells, id: \.name) { workspace in
                        tile(workspace, current: workspace.name == tiler.focused) { tiler.go(workspace.name, from: "dropdown") }
                    }
                }
            }
        }
        .opacity(tiler.isAnswering ? 1 : 0.6)
    }

    /// A workspace: its number in mono at the top left over its apps' icons; the live one ringed in the signal's line, its
    /// number in the signal's text colour.
    private func tile(_ workspace: OccupiedWorkspace, current: Bool, go: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return Button(action: go) {
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name).font(style.font(\.key, size: 10.5))
                    .foregroundStyle(style.color(current ? \.accentText : workspace.apps.isEmpty ? \.text3 : \.text2))
                CompactApps(names: Array(workspace.apps.prefix(2)), bundles: workspace.bundles, size: 13, spacing: 3).frame(height: 14)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .background(style.color(current ? \.raised : \.sunken), in: shape)
            .overlay { shape.strokeBorder(style.color(current ? \.accentLine : \.line)) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(workspace.apps.isEmpty ? "Workspace \(workspace.name), empty" : "Workspace \(workspace.name): \(workspace.apps.joined(separator: ", "))")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    // MARK: Switches

    /// The six switches in one row: a glyph on a key, raised while on, its word under it.
    private var quickSwitches: some View {
        HStack(spacing: 4) {
            ForEach(Dropdown.Switch.allCases, id: \.self) { switchTile($0) }
        }
    }

    private func switchTile(_ which: Dropdown.Switch) -> some View {
        let on = switches[which].isOn
        let layerKeys = engine.settings.layerKeys
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return Button { switches[which].toggle() } label: {
            VStack(spacing: 5) {
                Image(systemName: which.symbol(layerKeys: layerKeys)).font(style.font(\.icon))
                    .foregroundStyle(style.color(on ? \.text : \.text3))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(style.color(on ? \.raised : \.panel), in: shape)
                    .overlay { shape.strokeBorder(style.color(on ? \.line2 : \.line)) }
                Text(which.short).styleText(\.small).foregroundStyle(style.color(on ? \.text : \.text3)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(Kit.change, value: on)
        }
        .buttonStyle(.plain)
        .help(which.tooltip(on, layerKeys: layerKeys, tiler: engine.observers.tiler.tilerName))
        .accessibilityLabel(which.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Rows

    /// The rows in their groups, each under its heading.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Dropdown.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 0) {
                    InstrumentEyebrow(text: group.title).padding(.horizontal, 6).padding(.bottom, 2)
                    ForEach(group.rows, id: \.self) { row in
                        InstrumentDropdownRow(symbol: row.symbol, title: engine.dropdownTitle(row), key: engine.dropdownKey(row),
                                              layerKeys: engine.settings.layerKeys) { engine.runDropdownRow(row) }
                            .dropdownCommand(row)
                    }
                }
            }
        }
    }

    // MARK: Developer, Option held

    private var developer: some View {
        VStack(alignment: .leading, spacing: 4) {
            InstrumentEyebrow(text: "Developer · Option held").padding(.bottom, 10)
            ForEach(Dropdown.Row.developer, id: \.self) { row in InstrumentDropdownRow(symbol: row.symbol, title: row.title) { engine.runDropdownRow(row) } }
            if !engine.presses.isEmpty {
                DisclosureGroup("Recent presses") {
                    ForEach(engine.presses.prefix(15)) { Text($0.line).styleText(\.mono).lineLimit(1).truncationMode(.middle) }
                }
                .styleText(\.body)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Footer

    /// Check for updates at the left, Settings and Quit with their keys at the right, on one line.
    private var footer: some View {
        HStack(spacing: 10) {
            ForEach(engine.dropdownFooter, id: \.self) { row in
                if row == .settings { Spacer(minLength: 0) }
                Button { engine.runDropdownRow(row) } label: {
                    HStack(spacing: 5) {
                        if row != .quit { Image(systemName: row.symbol).font(style.font(\.icon, size: 11)) }
                        Text(engine.dropdownTitle(row))
                        if let key = engine.dropdownKey(row) { InstrumentKeys(caps: InstrumentHint.caps(key), hyper: false) }
                    }
                    .styleText(\.caption).foregroundStyle(style.color(\.text2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dropdownCommand(row)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }
}

/// A row of the footer or the developer block: its glyph, its title, its keys as chips (the layer key's in the signal
/// colour); raised on a hairline ring under the pointer.
private struct InstrumentDropdownRow: View {
    @Environment(\.style) private var style
    let symbol: String
    let title: String
    var key: String?
    /// The layer key, whose sign in `key` is lit.
    var layerKeys: [LayerKey]?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(style.font(\.icon)).foregroundStyle(style.color(hovered ? \.text : \.text2)).frame(width: 16)
                Text(title).styleText(\.body).foregroundStyle(style.color(\.text))
                Spacer()
                if let key {
                    HStack(spacing: 3) {
                        ForEach(Array(InstrumentHint.caps(key).enumerated()), id: \.offset) { _, cap in
                            InstrumentKey(text: cap, hyper: cap == layerKeys?.symbol)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .instrumentRaised(hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Now, only while something runs (spec pilot-1-1 T29): a recording with Stop, the focus timer with its first button,
/// Extras downloading with its share; its own view so the clock and countdown redraw only it.
private struct InstrumentNowBlock: View {
    @Environment(\.style) private var style

    var body: some View {
        let items = DropdownNow.items
        if !items.isEmpty {
            let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
            VStack(alignment: .leading, spacing: 8) {
                InstrumentEyebrow(text: "Now")
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in self.item(item).frame(minHeight: 26) }
            }
            .styleText(\.body)
            .padding(10)
            .background(style.color(\.raised), in: shape)
            .overlay { shape.strokeBorder(style.color(\.line)) }
        }
    }

    @ViewBuilder private func item(_ item: DropdownNow.Item) -> some View {
        switch item {
        case .recording:
            line("video") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in Text(Recorder.shared.reading?.words ?? "").monospacedDigit() }
                Spacer()
                Button("Stop") { Recorder.shared.stop() }.buttonStyle(InstrumentButtonStyle(kind: .raised))
            }
        case .timer(let text):
            line("timer") {
                Text(text).monospacedDigit()
                Spacer()
                if let first = ExtensionTimer.shared.buttons.first {
                    Button(first.label) { ExtensionTimer.shared.press(0) }.buttonStyle(InstrumentButtonStyle(kind: .raised))
                }
            }
        case .download(let title, let share):
            line("arrow.down.to.line") {
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(Int(share * 100)) %").styleText(\.mono).monospacedDigit().foregroundStyle(style.color(\.text3))
            }
        }
    }

    private func line(_ symbol: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(style.font(\.icon)).foregroundStyle(style.color(\.text3)).frame(width: 16)
            content()
        }
    }
}
