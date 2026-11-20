import AppKit
import PilotCore
import SwiftUI

/// Pilot's dropdown in Instrument (card agent-bo-95423181, ADR 0008), the one Pilot menu since spec pilot-ui-redesign
/// T21 (S4 B, shot 4b): the face (DropdownPanelFace) fed from the saved arrangement. A new install shows the four switch
/// tiles, the workspaces, then Open Pilot and Quit Pilot; an install from before keeps its tall menu (status, workspaces,
/// the switches it shows, what is running, the rows with their keys and, while Option is held, the developer rows and
/// the recent presses). A problem always leads, Status hidden or not. Hung by BarPanel under Pilot's item from either bar;
/// past the room under it (`barPopoverRoom`) the face scrolls what is not pinned.
struct InstrumentDropdown: View {
    @Environment(Engine.self) private var engine
    let switches: QuickSwitches
    let option: Bool
    var layout: DropdownLayoutStore = .shared
    /// Who held secure input as the dropdown opened: the panel takes the keyboard, which can end the field's secure input
    /// a second later, and Make a password must stay put while it is reached for.
    @State private var heldAtOpen = Engine.shared?.secureInput.holder

    var body: some View {
        let optional = Set(layout.layout.shown).intersection(Dropdown.Layout.optional)
        // A clock or a countdown is running: its reading moves once a second; otherwise nothing ticks.
        Group {
            if DropdownNow.items.isEmpty { panel } else { TimelineView(.periodic(from: .now, by: 1)) { _ in panel } }
        }
        // The optional blocks shown read only while the panel is up (T4), the Extensions card's picks with them.
        .task(id: Reading(blocks: optional, extensions: layout.layout.extensions)) {
            guard !optional.isEmpty else { return }
            await DropdownBlocks.hold(optional, extensions: layout.layout.extensions, readings: engine.barSources.readings)
        }
    }

    /// What the open panel reads: the optional blocks shown and the extensions picked for the card.
    private struct Reading: Equatable { let blocks: Set<Dropdown.Block>; let extensions: [String] }

    private var panel: some View {
        let problems = engine.homeProblems(secureInput: engine.secureInput.holder ?? heldAtOpen)
        let commands = self.commands
        return DropdownPanelFace(values: values(problems, commands: commands), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
            act($0, problems: problems, commands: commands)
        }
        // Settings and Quit keep their ⌘ keys while the panel has the keyboard.
        .background {
            ForEach(engine.dropdownFooter.filter { $0.command != nil }, id: \.self) { row in
                Button(row.title) { engine.runDropdownRow(row) }.dropdownCommand(row).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
    }

    /// Today's rows in their groups' order.
    private var commands: [Dropdown.Row] { Dropdown.groups.flatMap(\.rows) }

    /// A row as the face draws it: its glyph, title and bind as chips.
    private func command(_ row: Dropdown.Row) -> DropdownPanelValues.Command {
        .init(symbol: row.symbol, title: engine.dropdownTitle(row), keys: engine.dropdownKey(row).map(InstrumentHint.caps) ?? [])
    }

    private func values(_ problems: [HomeProblems.Problem], commands: [Dropdown.Row]) -> DropdownPanelValues {
        let tiler = engine.observers.tiler, layerKeys = engine.settings.layerKeys
        let shown = Set(layout.layout.shown), readings = engine.barSources.readings
        var values = DropdownPanelValues()
        values.pilotOn = engine.pilotSwitch.isOn
        values.hyperOn = switches[.hyper].isOn
        values.launcherOn = switches[.launcher].isOn
        values.trusted = engine.gate.isTrusted
        values.secureInput = engine.secureInput.isActive
        values.held = engine.hyperHeld
        values.layerSign = layerKeys.symbol
        values.layerName = layerKeys.label
        values.problems = problems.map { problem in
            switch (problem.kind, problem.place) {
            case _ where problem.action != nil: .init(title: problem.title, detail: problem.detail, button: "Make a password")
            case (.accessibility, _): .init(title: problem.title, detail: problem.detail, button: "Allow")
            case (.tiler, _): .init(title: problem.title, detail: problem.detail, button: "Restart")
            case (_, _?): .init(title: problem.title, detail: problem.detail, button: "Open", fixes: false)
            case (_, nil): .init(title: problem.title, detail: problem.detail)
            }
        }
        values.screen = Screens.focusedScreen?.localizedName ?? ""
        // The tiler's problem leads while it is stopped; the Workspaces card says it is stopped.
        values.workspacesStopped = !tiler.isAnswering
        values.workspaces = tiler.isAnswering ? tiler.homeCells.map { workspace in
            .init(name: workspace.name, apps: workspace.apps.prefix(3).compactMap { name in
                workspace.bundles[name].flatMap(AppsModule.icon(bundle:)) ?? AppsModule.icon(named: name)
            }, current: workspace.name == tiler.focused)
        } : []
        values.switches = layout.layout.shownSwitches.map { which in
            let on = switches[which].isOn
            return .init(which: which, on: on, state: tileState(which, on: on, tiler: tiler.tilerName), symbol: which.symbol(layerKeys: layerKeys))
        }
        values.running = DropdownNow.rows
        values.commands = commands.map(command)
        if option {
            values.developer = Dropdown.Row.developer.map(command)
            values.presses = engine.presses.prefix(15).map(\.line)
        }
        values.updateReady = PilotUpdates.shared.updateWaiting
        values.canCheckForUpdates = PilotUpdates.shared.canCheck
        Self.arrange(&values, layout: layout.layout, problems: !problems.isEmpty)
        if !shown.contains(.now) { values.running = [] }
        if !shown.contains(.rows) { values.commands = [] }
        if shown.contains(.sound) { values.sound = DropdownBlocks.sound(readings) }
        if shown.contains(.connections) { values.connections = DropdownBlocks.connections(readings) }
        if shown.contains(.display) { values.display = DropdownBlocks.display() }
        if shown.contains(.media) { values.media = DropdownBlocks.media() }
        if shown.contains(.stats) { values.stats = DropdownBlocks.stats(readings, sampler: engine.barSources.sampler) }
        if shown.contains(.extensions) { values.extensions = DropdownBlocks.extensions(layout.layout.extensions) }
        return values
    }

    /// The saved arrangement on the face (desktop-controls T4, pilot-ui-redesign T20): the blocks it draws in the saved
    /// order, a hidden Status back while a problem waits, pinned ones above the scroll; the workspaces and the switch
    /// tiles leave when hidden, and only the switches the layout shows stay. MenuBarRenders draws through this too.
    static func arrange(_ values: inout DropdownPanelValues, layout: Dropdown.Layout, problems: Bool) {
        values.order = layout.shown(problems: problems)
        values.pinned = layout.pinned
        let shown = Set(values.order)
        if !shown.contains(.workspaces) { values.workspaces = []; values.workspacesStopped = false }
        if !shown.contains(.quickSwitches) { values.switches = [] }
        let switches = Set(layout.shownSwitches)
        values.switches.removeAll { !switches.contains($0.which) }
    }

    /// A switch tile's line, Home's words (InstrumentHome's switches): the launcher's key ("Hyper+Space"), how many keys
    /// are bound, else On or Off; the three switches beyond the four keep their sentence ("macOS bar hidden").
    private func tileState(_ which: Dropdown.Switch, on: Bool, tiler: String) -> String {
        switch which {
        case _ where !on && Dropdown.Switch.four.contains(which): "Off"
        case .launcher: engine.binds.store.trigger(for: Dropdown.launcherAction)?.label ?? "No key"
        case .hyper: "\(engine.binds.store.binds.count) bound"
        case .tiling, .clipboard: "On"
        default: DropdownPanelFace.sentence(which.state(on, layerKeys: engine.settings.layerKeys, tiler: tiler))
        }
    }

    private func act(_ action: DropdownPanelFace.Action, problems: [HomeProblems.Problem], commands: [Dropdown.Row]) {
        switch action {
        // The edit list lives on the Menu bar page (T4).
        case .arrange: BarPanel.shared.close(); AppWindowController.shared.open(AppPlace(.menuBar))
        case .fix(let i):
            guard problems.indices.contains(i) else { return }
            // Closed first, so the keyboard goes back to the password field for ⌘V.
            if let id = problems[i].action {
                BarPanel.shared.close()
                RunCaller.with("dropdown") { engine.action(id)?.run() }
                return
            }
            switch (problems[i].kind, problems[i].place) {
            case (.accessibility, _): OnboardingWindow.openPermissions()
            case (.tiler, _): engine.startTiler()
            case (_, let place?): AppWindowController.shared.open(place)
            case (_, nil): break
            }
        case .workspace(let name): engine.observers.tiler.go(name, from: "dropdown")
        case .toggle(let which): switches[which].toggle()
        case .pause(let i): DropdownNow.press(i, pause: true)
        case .stop(let i): DropdownNow.press(i, pause: false)
        case .command(let i):
            guard commands.indices.contains(i) else { return }
            engine.runDropdownRow(commands[i])
        case .developer(let i):
            guard Dropdown.Row.developer.indices.contains(i) else { return }
            engine.runDropdownRow(Dropdown.Row.developer[i])
        case .allCommands: engine.runDropdownRow(.menu)
        case .updates: engine.runDropdownRow(.updates)
        case .settings: engine.runDropdownRow(.settings)
        case .quit: engine.runDropdownRow(.quit)
        case .extensionPage(let i): DropdownBlocks.openPage(layout.layout.extensions, at: i)
        case .connection, .level, .media: DropdownBlocks.act(action, readings: engine.barSources.readings)
        }
    }
}
