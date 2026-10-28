import Foundation
import Testing
@testable import PilotCore

/// Learn › Keybindings lists the essentials first (Omarchy ideas T5): menu, Keybindings, terminal, browser and on, then
/// workspaces, moves, focus and resize, then the rest by module. Pure, through MenuEntries.build.
@Suite("Keybindings order")
struct KeybindingsOrderTests {
    /// Every bind, in the registry's order (by id), each its own key.
    static let ids = ["apps.appsMenu", "apps.browser", "apps.clipboard", "apps.emoji", "apps.files", "apps.launcher", "apps.terminal",
                      "captures.area", "captures.menu", "engine.sheet", "media.playPause", "system.lock", "windows.close",
                      "windows.focusLeft", "windows.fullscreen", "windows.grow", "windows.maximise", "windows.popOut", "windows.snapLeft",
                      "windows.toggleFloat", "windows.vimFocusLeft", "workspaces.go:1", "workspaces.go:2", "workspaces.move:1"]
    static let modules = ["apps", "captures", "engine", "media", "system", "windows", "workspaces"]

    static func rows() -> [String] {
        let actions = ids.map { id in BindsPage.ActionInfo(id: id, label: "label \(id)", module: modules.first { id.hasPrefix($0 + ".") }!) }
        let keys = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        let store = BindStore(defaults: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Key(keys[$0])) }))
        let entries = MenuEntries.build(apps: [], actions: actions, store: store, roleApps: [:], menu: "apps.launcher",
                                        openID: { "apps.open:\($0)" }, running: [])
        return MenuNavigator(entries: entries, branch: .keybindings).rows.map { if case .action(let id) = $0.target { id } else { "?" } }
    }

    @Test("The first ten rows are the essentials, in Omarchy's order")
    func essentialsFirst() {
        #expect(Self.rows().prefix(10) == ["apps.launcher", "engine.sheet", "apps.terminal", "apps.browser", "apps.files", "apps.appsMenu",
                                           "windows.close", "windows.fullscreen", "windows.maximise", "windows.toggleFloat"])
    }

    @Test("After the essentials: workspaces, moves, focus, resize, then the rest by module, every bind listed once")
    func thenGroups() {
        let rows = Self.rows()
        #expect(rows.count == Self.ids.count && Set(rows) == Set(Self.ids))
        #expect(rows.dropFirst(14) == ["workspaces.go:1", "workspaces.go:2", "workspaces.move:1", "windows.focusLeft", "windows.vimFocusLeft",
                                       "windows.grow", "windows.snapLeft", "apps.emoji", "captures.area", "media.playPause"])
    }

    @Test("Every essential is an action Pilot registers, so a rename never sinks a row silently")
    func registered() {
        // Abilities.lines names only registered actions (AbilitiesTests.noStaleEntries, against the live registry).
        let missing = KeybindingsOrder.essentials.filter { Abilities.lines[$0] == nil }
        #expect(missing.isEmpty, "not registered: \(missing)")
        #expect(Set(KeybindingsOrder.essentials).count == KeybindingsOrder.essentials.count)
    }
}
