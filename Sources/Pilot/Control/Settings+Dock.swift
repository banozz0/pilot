import Foundation
import PilotCore

extension SettingsSchema {
    /// The dock's keys (spec pilot-dock), on its own Dock page (round 4): its switch, which answers once it went through
    /// (it turns the macOS Dock's auto-hide on through System Events and makes room in the Pilot block), its style (the
    /// top bar's Solid, Glass and Clear), size and magnification. Its widgets are a list (`pilot dock-widgets`), System
    /// stats' picks `pilot dock stats`.
    func registerDock(_ dock: DockController) {
        register([
            .bool("dock.on", "Dock", page: "dock", standard: false, read: { dock.isOn }, write: { on throws(ControlError) in try await Self.flip(dock, to: on) }),
            .choice("dock.style", "Dock style", page: "dock", TopBarBackground.allCases, standard: .glass, read: { dock.settings.style },
                    write: { style throws(ControlError) in dock.settings.style = style }),
            .choice("dock.size", "Dock size", page: "dock", DockSize.allCases, standard: .medium, read: { dock.settings.size },
                    write: { size throws(ControlError) in dock.settings.size = size }),
            .choice("dock.magnify", "Dock magnification", page: "dock", DockMagnification.allCases, standard: .medium, read: { dock.settings.magnify },
                    write: { magnify throws(ControlError) in dock.settings.magnify = magnify }),
        ])
    }
}

extension DockController: Flipping {}
