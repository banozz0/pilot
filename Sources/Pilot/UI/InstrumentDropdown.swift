import AppKit
import PilotCore
import SwiftUI

/// Pilot's dropdown in Instrument (card agent-bo-95423181, ADR 0008), the one Pilot menu since spec pilot-ui-redesign
/// T21 (S4 B, shot 4b), the same for every install since 2026-11-20 (Sven: "pilot menu page shouldnt exist anymore
/// either pilot menu should be simple"): the face (DropdownPanelFace) with any problem first, the four switch tiles, the
/// workspaces, then Open Pilot and Quit Pilot; while Option is held, the developer rows and the recent presses. Nothing
/// is arranged. Hung by BarPanel under Pilot's item from either bar; past the room under it (`barPopoverRoom`) the face
/// scrolls its cards.
struct InstrumentDropdown: View {
    @Environment(Engine.self) private var engine
    let switches: QuickSwitches
    let option: Bool
    /// Who held secure input as the dropdown opened: the panel takes the keyboard, which can end the field's secure input
    /// a second later, and Make a password must stay put while it is reached for.
    @State private var heldAtOpen = Engine.shared?.secureInput.holder

    var body: some View {
        let problems = engine.homeProblems(secureInput: engine.secureInput.holder ?? heldAtOpen)
        return DropdownPanelFace(values: values(problems), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
            act($0, problems: problems)
        }
        // Settings and Quit keep their ⌘ keys while the panel has the keyboard.
        .background {
            ForEach(engine.dropdownFooter.filter { $0.command != nil }, id: \.self) { row in
                Button(row.title) { engine.runDropdownRow(row) }.dropdownCommand(row).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
    }

    /// A row as the face draws it: its glyph, title and bind as chips.
    private func command(_ row: Dropdown.Row) -> DropdownPanelValues.Command {
        .init(symbol: row.symbol, title: engine.dropdownTitle(row), keys: engine.dropdownKey(row).map(InstrumentHint.caps) ?? [])
    }

    private func values(_ problems: [HomeProblems.Problem]) -> DropdownPanelValues {
        let tiler = engine.observers.tiler, layerKeys = engine.settings.layerKeys
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
        values.switches = Dropdown.Switch.four.map { which in
            let on = switches[which].isOn
            return .init(which: which, on: on, state: tileState(which, on: on, tiler: tiler.tilerName), symbol: which.symbol(layerKeys: layerKeys))
        }
        if option {
            values.developer = Dropdown.Row.developer.map(command)
            values.presses = engine.presses.prefix(15).map(\.line)
        }
        values.updateReady = PilotUpdates.shared.updateWaiting
        values.canCheckForUpdates = PilotUpdates.shared.canCheck
        return values
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

    private func act(_ action: DropdownPanelFace.Action, problems: [HomeProblems.Problem]) {
        switch action {
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
        case .developer(let i):
            guard Dropdown.Row.developer.indices.contains(i) else { return }
            engine.runDropdownRow(Dropdown.Row.developer[i])
        case .updates: engine.runDropdownRow(.updates)
        case .settings: engine.runDropdownRow(.settings)
        case .quit: engine.runDropdownRow(.quit)
        }
    }
}
