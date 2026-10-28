#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Hyper+Space menu in Instrument as Classic draws it (a model's default layout; ClassicMenu, menu Rail and Classic
/// T8), dark and light, through HUD.makePanel as Pilot shows it: the root, a root search with its sections and window glyphs, a kind picked, Cmd+K, a
/// narrow and a wide branch, System's switches, the Files view, Update and Remove, a picker, the ask-Claude and sum
/// answers, and every empty state (no match, a list being read, an empty Snippets, Clean's preview, Cmd+K's filter).
/// Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter InstrumentMenuRenders`
extension SharedLook {
@MainActor
@Suite("Instrument menu renders")
struct InstrumentMenuRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Ghostty's two windows side by side on workspace 1, Ghostex's on 2.
    static let windows = """
    [{"window-id": 412, "app-name": "Ghostty", "app-bundle-id": "com.mitchellh.ghostty", "app-pid": 2, "workspace": "1", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "~/code/pilot — zsh"},
     {"window-id": 418, "app-name": "Zen", "app-bundle-id": "app.zen-browser.zen", "app-pid": 4, "workspace": "1", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "Raycast — styles.refero.design"},
     {"window-id": 431, "app-name": "Ghostty", "app-bundle-id": "com.mitchellh.ghostty", "app-pid": 2, "workspace": "1", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "log stream — pilot"},
     {"window-id": 7, "app-name": "Ghostex", "app-bundle-id": "com.madda.ghostex.host", "app-pid": 1, "workspace": "2", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "Agentic dev environment"}]
    """

    @Test("The menu renders in Instrument dark and light, every state", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        // The styles' faces from the repo; put back after, so a later render in the run draws with the faces it had.
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = look.style
        defer { look.style = saved }
        look.style = .instrument
        let only = Self.env["PILOT_RENDER_ONLY"]
        for dark in [true, false] {
            let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("menu-instrument-\(dark ? "dark" : "light")")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, model) in try Self.states() where only.map(name.contains) ?? true {
                try Self.render(MenuView(model: model), name, in: dir)
            }
        }
    }

    /// Every state, named for its file.
    static func states() throws -> [(String, MenuModel)] {
        let windows = try AeroWindow.parse(Self.windows)
        let engine = Engine()
        let built = MenuEntries.build(
            apps: [("Ghostty", "com.mitchellh.ghostty"), ("Ghostex", "com.madda.ghostex.host"), ("Finder", "com.apple.finder"),
                   ("TextEdit", "com.apple.TextEdit"), ("Bitwarden", "com.bitwarden.desktop")],
            actions: engine.bindActions,
            store: BindStore(defaults: ["apps.terminal": Key("return"), AppsModule.openID(bundle: "com.madda.ghostex.host"): Key("g"),
                                        "system.lock": Key("escape"), "system.darkMode": Key("d", shift: true),
                                        "captures.menu": Key("c", .ctrl), "apps.emoji": Key("e", .ctrl)]),
            roleApps: ["apps.terminal": "com.mitchellh.ghostty"], menu: AppsModule.menuID, openID: AppsModule.openID(bundle:),
            running: ["com.mitchellh.ghostty", "com.apple.finder"],
            extras: [MenuLayout.system("Sound"): [BindsPage.ActionInfo(id: "system.output:73", label: "Play through AirPods", module: "system")]],
            switches: ["system.darkMode": true, "system.keepAwake": false, "system.idleLock": true, "system.nightShift": false, "system.wifi": true])
        func model(_ nav: MenuNavigator) -> MenuModel {
            let m = MenuModel(nav: nav)
            m.windows = windows
            return m
        }
        var states: [(String, MenuModel)] = [("01-root", model(MenuNavigator(entries: built)))]

        // The mockup's search: the app, its two windows (each its own glyph), Ghostex, the cask and two files.
        let home = NSHomeDirectory(), day = Date(timeIntervalSince1970: 1_791_028_800)
        func ghost(_ query: String) -> MenuNavigator {
            var nav = MenuNavigator(entries: built)
            nav.query = query
            nav.provide(.window, MenuEntries.windows(windows, excluding: nil))
            nav.provide(.package, [MenuEntry(title: "Ghostty", target: .package("cask:ghostty"), detail: "1.2.0 → 1.2.1", icon: .cask)])
            nav.provide(.file, MenuEntries.files([(home + "/.claude/memory/ghostty-spawns-fullscreen.md", day),
                                                  (home + "/.config/ghostty/config", day)], home: home))
            return nav
        }
        states.append(("02-search", model(ghost("ghost"))))
        var apps = ghost("ghost")
        _ = apps.handle(.tab)
        states.append(("03-search-apps", model(apps)))
        var windowsTab = ghost("ghost")
        for _ in 0..<2 { _ = windowsTab.handle(.tab) }
        _ = windowsTab.handle(.down)
        states.append(("03-search-windows", model(windowsTab)))
        var actions = ghost("ghost")
        _ = actions.handle(.commandK)
        states.append(("04-search-actions", model(actions)))
        var filtered = actions
        filtered.actionQuery = "zz"
        states.append(("04-search-actions-empty", model(filtered)))
        states.append(("05-no-match", model(ghost("zzqxv"))))
        var ask = MenuNavigator(entries: built)
        ask.query = "ask why does Caps Lock make a good Hyper key"
        ask.provide(.answer, RootAnswers.entries(for: ask.query, now: day))
        states.append(("06-ask-claude", model(ask)))
        var sum = MenuNavigator(entries: built)
        sum.query = "12*7+3"
        sum.provide(.answer, RootAnswers.entries(for: sum.query, now: day))
        states.append(("06-sum", model(sum)))

        states.append(("07-trigger", model(MenuNavigator(entries: built, branch: .trigger))))
        var triggerActions = MenuNavigator(entries: built, branch: .trigger)
        _ = triggerActions.handle(.down)
        _ = triggerActions.handle(.commandK)
        states.append(("07-trigger-actions", model(triggerActions)))
        states.append(("08-system", model(MenuNavigator(entries: built, branch: .system))))
        // C6: a sub-branch with its switches, Keep awake current with Space's Toggle in the foot (S1).
        var power = MenuNavigator(entries: built, branch: MenuLayout.system("Power"))
        for _ in 0..<6 where power.selected?.target != .action("system.keepAwake") { _ = power.handle(.down) }
        states.append(("08-system-power", model(power)))
        var dark = MenuNavigator(entries: built, branch: .system)
        dark.query = "dark"
        states.append(("08-system-dark", model(dark)))
        var files = MenuNavigator(entries: built)
        files.query = "bitwa"
        for _ in 0..<3 { _ = files.handle(.tab) }
        files.provide(.file, MenuEntries.files([(home + "/code/oss/vaultkit/agent/secret_sources/bitwarden.py", day),
                                                (home + "/code/oss/vaultkit/website/docs/guides/secrets/bitwarden.md", day)], home: home))
        states.append(("09-files", model(files)))
        var bitwarden = MenuNavigator(entries: built)
        bitwarden.query = "bitwa"
        states.append(("09-bitwarden", model(bitwarden)))
        states.append(("10-install", model(MenuNavigator(entries: built, branch: .install))))
        states.append(("11-update", model(MenuBrowseRenders.update())))
        states.append(("11-remove", model(MenuBrowseRenders.remove())))
        var removeApps = MenuBrowseRenders.remove()
        _ = removeApps.handle(.return)
        states.append(("11-remove-apps", model(removeApps)))
        var updateApps = MenuBrowseRenders.update()
        _ = updateApps.handle(.down)
        _ = updateApps.handle(.return)
        states.append(("11-update-apps", model(updateApps)))
        states.append(("12-update-reading", model(MenuNavigator(entries: [], branch: .update))))
        states.append(("12-snippets-empty", model(MenuNavigator(entries: built, branch: .snippets))))
        states.append(("12-clean-waiting", model(MenuNavigator(entries: [], branch: .clean))))
        states.append(("12-remove-reading", model(MenuNavigator(entries: [], branch: .remove))))
        states.append(("12-install-searching", model(MenuBrowseRenders.installSearching())))
        let kill = Activity.entries(Activity.Snapshot(apps: [], background: [
            Activity.Row(kind: .process, pid: 30061, name: "swift-frontend", cpu: 84, memory: 517_120 << 10, rights: .quitAndForce),
            Activity.Row(kind: .process, pid: 33146, name: "find", cpu: 70, memory: 2048 << 10, rights: .quitAndForce),
            Activity.Row(kind: .process, pid: 7811, name: "Ghostex", cpu: 31, memory: 350_208 << 10, rights: .quitAndForce)]))
        states.append(("13-picker", model(MenuNavigator(list: kill, title: "Kill a process",
                                                         back: MenuNavigator.Spot(branch: MenuLayout.system("Fix it"), row: .action("system.killProcess"))))))
        return states
    }

    /// The panel as HUD.makePanel builds it for the menu, its content drawn at Retina scale with the clear margins kept.
    static func render(_ view: some View, _ name: String, in dir: URL) throws {
        let panel = HUD.makePanel(view, surface: .menu)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // A view that measures itself (Clean's wait) sets the panel's height after it shows, as MenuSizer then follows.
        if let host = (panel.contentView as? MaterialBackdrop)?.content, host.fittingSize != panel.frame.size {
            panel.setContentSize(host.fittingSize)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        // The menu is typed into, so its caret sits after the text; here the text was there before the field took the
        // keyboard, which selects it all.
        if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
        content.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(content, scale: 2))
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
}
#endif
