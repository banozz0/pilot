import AppKit
import PilotCore
import SwiftUI

/// Pilot's dropdown in Instrument (card agent-bo-95423181, ADR 0008; mockup A's sidebar foot and Home): the status with
/// Pilot's mark, the layer key's chip lit in the signal colour while Hyper is on, any problem after attention's tick;
/// the workspaces as tiles with the live one's number in the signal's text colour; the quick switches, Hyper's lit;
/// Now; the developer rows while Option is held; and the footer's rows with their keys as chips. Blocks on hairlines, on
/// the style's popover (KitPopover). The same blocks, switches, actions and words as PilotDropdown.
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
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Dropdown.blocks(option: option), id: \.self) { block in
                    if block != .status { InstrumentRule() }
                    Group {
                        switch block {
                        case .status: status(problems)
                        case .workspaces: workspaces
                        case .quickSwitches: quickSwitches
                        case .now: InstrumentNowBlock(observers: engine.observers, presses: engine.presses)
                        case .developer: developer
                        case .footer: footer
                        }
                    }
                    .padding(.horizontal, block == .footer ? 6 : 14).padding(.vertical, block == .footer ? 6 : 12)
                }
            }
        }
    }

    // MARK: Status

    private func status(_ problems: [HomeProblems.Problem]) -> some View {
        let pilotSwitch = engine.pilotSwitch
        let hyperOn = switches[.hyper].isOn
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                InstrumentMark(size: 20).foregroundStyle(style.color(\.text2))
                    .frame(width: 32, height: 32)
                    .background(style.color(\.raised), in: .rect(cornerRadius: style.radii.control, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: style.radii.control, style: .continuous).strokeBorder(style.color(\.line)) }
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
            if let share = ExtrasDownloads.shared.share { downloads(share) }
        }
    }

    /// Onboarding's Extras still downloading (Sven, 2026-10-28, Q543): the share the menu-bar icon's meter shows, and each
    /// download where it stands.
    private func downloads(_ share: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloading extras").styleText(\.strong).foregroundStyle(style.color(\.text))
                Spacer()
                Text("\(Int(share * 100))%").styleText(\.caption).monospacedDigit().foregroundStyle(style.color(\.text3))
            }
            InstrumentMeter(share: share)
            ForEach(ExtrasDownloads.shared.downloads, id: \.title) { download in
                HStack { Text(download.title); Spacer(); Text(download.words).monospacedDigit() }
                    .styleText(\.caption).foregroundStyle(style.color(\.text3))
            }
        }
        .padding(10)
        .background(style.color(\.raised), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line)) }
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

    private var workspaces: some View {
        let tiler = engine.observers.tiler
        let cells = tiler.homeCells
        return VStack(alignment: .leading, spacing: 0) {
            InstrumentDropdownHeader(title: "Workspaces", trailing: Dropdown.workspaceKeys(layerKeys: engine.settings.layerKeys, count: cells.count))
            if !tiler.isAnswering {
                Text("Tiling is off while \(tiler.tilerName) is stopped.").styleText(\.caption).foregroundStyle(style.color(\.text3))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(cells, id: \.name) { workspace in
                        tile(workspace, current: workspace.name == tiler.focused) { tiler.go(workspace.name, from: "dropdown") }
                    }
                }
            }
        }
        .opacity(tiler.isAnswering ? 1 : 0.6)
    }

    /// A workspace: its apps' icons over its number in mono; the live one ringed in the signal's line, its number in the
    /// signal's text colour.
    private func tile(_ workspace: OccupiedWorkspace, current: Bool, go: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return Button(action: go) {
            VStack(spacing: 5) {
                CompactApps(names: Array(workspace.apps.prefix(3)), bundles: workspace.bundles, spacing: 3)
                .frame(height: 18)
                Text(workspace.name).font(style.font(\.key, size: 11.5))
                    .foregroundStyle(style.color(current ? \.accentText : workspace.apps.isEmpty ? \.text3 : \.text))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(style.color(current ? \.raised : \.sunken), in: shape)
            .overlay { shape.strokeBorder(style.color(current ? \.accentLine : \.line)) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(workspace.apps.isEmpty ? "Workspace \(workspace.name), empty" : "Workspace \(workspace.name): \(workspace.apps.joined(separator: ", "))")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    // MARK: Quick switches

    /// Hyper across the full width, its switch lit in the signal colour; the other four two by two below it.
    private var quickSwitches: some View {
        VStack(alignment: .leading, spacing: 0) {
            InstrumentDropdownHeader(title: "Quick switches")
            VStack(spacing: 6) {
                switchTile(.hyper)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(Dropdown.Switch.grid, id: \.self) { switchTile($0) }
                }
            }
        }
    }

    /// A quick switch: its glyph, its name and what it is doing now, raised on a hairline ring while on; Hyper's, across the
    /// width, its switch at the right in the signal colour.
    private func switchTile(_ which: Dropdown.Switch) -> some View {
        let on = switches[which].isOn
        let layerKeys = engine.settings.layerKeys
        let shape = RoundedRectangle(cornerRadius: style.radii.control, style: .continuous)
        return Button { switches[which].toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: which.symbol(layerKeys: layerKeys)).font(style.font(\.icon)).foregroundStyle(style.color(on ? \.text : \.text3)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(which.title).styleText(\.strong).foregroundStyle(style.color(\.text))
                    Text(which.state(on, layerKeys: layerKeys, tiler: engine.observers.tiler.tilerName)).styleText(\.small)
                        .foregroundStyle(style.color(\.text3))
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if which == .hyper { InstrumentSwitchFace(isOn: on).accessibilityHidden(true) }
            }
            .padding(8)
            .background(style.color(on ? \.raised : \.panel), in: shape)
            .overlay { shape.strokeBorder(style.color(on ? \.line2 : \.line)) }
            .contentShape(shape)
            .animation(Kit.change, value: on)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Developer, Option held

    private var developer: some View {
        VStack(alignment: .leading, spacing: 4) {
            InstrumentDropdownHeader(title: "Developer · Option held")
            ForEach(Dropdown.Row.developer, id: \.self) { row in InstrumentDropdownRow(symbol: row.symbol, title: row.title) { engine.runDropdownRow(row) } }
            if !engine.presses.isEmpty {
                DisclosureGroup("Recent presses") {
                    ForEach(engine.presses.prefix(15)) { Text($0.line).styleText(\.mono).lineLimit(1).truncationMode(.middle) }
                }
                .styleText(\.body)
            }
        }
    }

    // MARK: Footer

    /// The footer's rows (Dropdown.Row), each group on a hairline.
    private var footer: some View {
        VStack(spacing: 0) {
            ForEach(Array(engine.dropdownFooter.enumerated()), id: \.offset) { index, group in
                if index > 0 { InstrumentRule().padding(.horizontal, 8).padding(.vertical, 5) }
                ForEach(group, id: \.self) { row in
                    InstrumentDropdownRow(symbol: row.symbol, title: engine.dropdownTitle(row), key: engine.dropdownKey(row),
                                          layerKeys: engine.settings.layerKeys) { engine.runDropdownRow(row) }
                        .dropdownCommand(row)
                }
            }
        }
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

/// The Now block: the timer (its ring in the signal colour while one runs), the app in front and the last press; its own
/// view so the countdown redraws only it.
private struct InstrumentNowBlock: View {
    @Environment(\.style) private var style
    let observers: EngineObservers
    let presses: [Press]

    var body: some View {
        let timer = ExtensionTimer.shared
        let app = observers.focusedApp
        VStack(alignment: .leading, spacing: 8) {
            InstrumentDropdownHeader(title: "Now")
            HStack(spacing: 8) {
                TimerRing(left: timer.left ?? 0, lineWidth: 2, track: style.color(\.line2), tint: style.color(\.accent)).frame(width: 14, height: 14)
                if let line = NowTimer.line(timer) {
                    Text(line).monospacedDigit()
                    Spacer()
                    if let first = timer.buttons.first { Button(first.label) { timer.press(0) }.buttonStyle(InstrumentButtonStyle(kind: .ghost)) }
                } else {
                    Text("No timer running").foregroundStyle(style.color(\.text3))
                    Spacer()
                }
            }
            .frame(minHeight: 24)
            if let app {
                HStack(spacing: 8) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 15, height: 15) }
                    Text("\(app.localizedName ?? "–")\(observers.tiler.focused.map { " · workspace \($0)" } ?? "")")
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "bolt").foregroundStyle(style.color(\.text3)).frame(width: 15)
                if let press = presses.first {
                    Text("Last: \(press.line)").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(press.time.formatted(date: .omitted, time: .shortened)).styleText(\.mono).foregroundStyle(style.color(\.text3))
                } else {
                    Text("No presses yet").foregroundStyle(style.color(\.text3))
                    Spacer()
                }
            }
        }
        .styleText(\.body)
    }
}

/// A block's heading: mono capitals, a mono hint at the right.
private struct InstrumentDropdownHeader: View {
    @Environment(\.style) private var style
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            InstrumentEyebrow(text: title)
            Spacer()
            if let trailing { Text(trailing).styleText(\.key).foregroundStyle(style.color(\.text3)) }
        }
        .padding(.bottom, 10)
    }
}
