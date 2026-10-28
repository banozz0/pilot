import AppKit
import PilotCore

/// Configs (card agent-bo-95422841): Hyper+Space › Config › <app> and the Configs page open a config's real file in the
/// main editor (EditorChoice) through AppsModule.open, never typed into a terminal.
@MainActor
enum ConfigsModule {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// One row per config found, for the Config branch.
    static func menuRows(home: URL = home) -> [BindsPage.ActionInfo] {
        AppConfigs.find(home: home).found.map {
            .init(id: AppConfigs.actionID($0.config.id), label: label($0.config), module: Module.apps.rawValue, icon: icon($0.config))
        }
    }

    /// A Config row's icon (S2, Sven 2026-10-09), as its card on Configs shows: the first of its apps installed, else
    /// the config's tile.
    static func icon(_ config: AppConfig, installed: (String) -> Bool = { AppsModule.icon(bundle: $0) != nil }) -> MenuIcon {
        let tile = config.tile
        return MenuIcon.glyph(tile.symbol, MenuIcon.Tint(rawValue: tile.colour.rawValue) ?? .neutral).app(bundle: config.bundles.first(where: installed))
    }

    static func label(_ config: AppConfig) -> String { "\(config.name) config" }

    /// `configs.edit:<id>`: that config, looked up again when it runs, so a file made or removed since is followed.
    static func dynamic(_ id: String, home: URL = home, editor: @escaping @MainActor @Sendable () -> String = { EditorChoice.shared.app },
                        open: @escaping @MainActor @Sendable (URL, String) -> Bool = AppsModule.open(_:in:)) -> Action? {
        guard let config = AppConfigs.config(inAction: id) else { return nil }
        return Action(id: id, label: label(config), module: .apps) {
            guard let found = AppConfigs.find(home: home, among: [config]).found.first else {
                alog.notice("config \(config.id, privacy: .public): not on this Mac")
                return HUD.tip("No \(config.name) config on this Mac.")
            }
            edit(found.real, editor: editor(), open: open)
        }
    }

    /// Opens a file in the main editor; Pilot itself never writes it.
    static func edit(_ url: URL, editor: String = EditorChoice.shared.app,
                     open: @MainActor (URL, String) -> Bool = AppsModule.open(_:in:)) {
        if !open(url, editor) { HUD.tip("The main editor is not installed; pick one on Default apps.") }
    }
}
