import Foundation
import PilotCore

extension SettingsSchema {
    /// The dock's keys (spec pilot-dock), on its own Dock page (round 4): its switch, which answers once it went through
    /// (it turns the macOS Dock's auto-hide on through System Events and makes room in the Pilot block), its style (the
    /// top bar's Solid, Glass and Clear), size and magnification, placement, icon colours and visualizer. Its widgets are a list (`pilot dock-widgets`), System
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
            // Rice round (Sven 2026-11-13, Q220 A, Q221, Q222): on the screen's bottom edge or floating over it, the icons
            // in the theme's colours, and the visualizer, whose switch asks macOS for System Audio Recording Only.
            .choice("dock.placement", "Dock placement", page: "dock", DockPlacement.allCases, standard: .attached, read: { dock.settings.placement },
                    write: { placement throws(ControlError) in dock.settings.placement = placement }),
            .choice("dock.tint", "Dock icon colours", page: "dock", DockIconTint.allCases, standard: .theme, read: { dock.settings.tint },
                    write: { tint throws(ControlError) in dock.settings.tint = tint }),
            .bool("dock.visualizer", "Dock visualizer", page: "dock", standard: false, read: { dock.settings.visualizer },
                  write: { on throws(ControlError) in await dock.setVisualizer(on) }),
        ])
    }
}

extension DockController: Flipping {}
