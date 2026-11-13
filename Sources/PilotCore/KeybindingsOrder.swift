import Foundation

/// Learn › Keybindings' order (Omarchy ideas idea 6): the essentials first, in Omarchy's order mapped to Pilot's ids,
/// then workspaces, moves, focus and resize, then the rest by module. A new user's first screen teaches what matters.
public enum KeybindingsOrder {
    /// Menu, Keybindings, terminal, browser, files, apps, close, fullscreen and maximise, float, pop-out, clipboard,
    /// capture, lock.
    public static let essentials = ["apps.launcher", "engine.sheet", "apps.terminal", "apps.browser", "apps.files", "apps.appsMenu",
                                    "windows.close", "windows.fullscreen", "windows.maximise", "windows.toggleFloat", "windows.popOut",
                                    "apps.clipboard", "captures.menu", "system.lock"]

    /// The groups after the essentials, each by id prefix: workspaces, moves, focus, resize, nudge.
    static let groups = [["workspaces.go:"], ["workspaces.move:"], ["windows.focus", "windows.vimFocus"],
                         ["windows.grow", "windows.shrink"], ["windows.nudge"]]

    /// `actions` in Keybindings' order; ties keep the order they came in.
    public static func sorted(_ actions: [BindsPage.ActionInfo]) -> [BindsPage.ActionInfo] {
        let modules = Module.allCases.map(\.rawValue)
        func place(_ a: BindsPage.ActionInfo, _ offset: Int) -> (Int, Int, Int) {
            if let i = essentials.firstIndex(of: a.id) { return (0, i, offset) }
            if let g = groups.firstIndex(where: { $0.contains(where: a.id.hasPrefix) }) { return (1, g, offset) }
            return (2, modules.firstIndex(of: a.module) ?? modules.count, offset)
        }
        return actions.enumerated().map { (place($1, $0), $1) }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
