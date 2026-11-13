import Foundation
import PilotCore

extension SettingsSchema {
    /// The dock's keys (spec pilot-dock), on the Menu bar page: its switch, which answers once it went through (it turns
    /// the macOS Dock's auto-hide on through System Events and makes room in the Pilot block), and its size. Its widgets
    /// are a list (`pilot dock-widgets`).
    func registerDock(_ dock: DockController) {
        register([
            .bool("dock.on", "Dock", page: "menuBar", standard: false, read: { dock.isOn }, write: { on throws(ControlError) in try await Self.flip(dock, to: on) }),
            .choice("dock.size", "Dock size", page: "menuBar", DockSize.allCases, standard: .medium, read: { dock.settings.size },
                    write: { size throws(ControlError) in dock.settings.size = size }),
        ])
    }
}

extension DockController: Flipping {}
