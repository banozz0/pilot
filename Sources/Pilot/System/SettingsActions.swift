import PilotCore

/// The settings rows' actions (Q131, SettingsSearch): `system.pane:<id>` opens that System Settings pane,
/// `window.page:<page or part>` that place of Pilot's window. Built per id, as a sound output's is, so any pane or place is
/// bindable without a registry row for each.
enum SettingsActions {
    static func dynamic(_ id: String) -> Action? {
        if let pane = SettingsSearch.pane(inAction: id) {
            let title = SettingsSearch.pane(pane)?.title ?? pane
            return Action(id: id, label: "\(title) in System Settings", module: .system) { SystemModule.pane(pane) }
        }
        guard let place = SettingsSearch.place(inAction: id) else { return nil }
        return Action(id: id, label: "\(place.path) in Pilot", module: .engine) { AppWindowController.shared.open(place) }
    }
}
