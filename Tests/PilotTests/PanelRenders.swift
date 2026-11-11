#if DEBUG
import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Offscreen renders of every panel (card agent-bo-95422727): the menu, a picker, the clipboard panel, the overlay and
/// each HUD, drawn through HUD.makePanel as Pilot shows them, on sample rows. Opt-in like the app window's renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter PilotTests`
@MainActor
@Suite("Panel renders")
struct PanelRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Each panel renders", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderEveryPanel() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        // The Panels material as a flat fill: glass draws nothing offscreen.
        Look.shared.glass = false
        defer { Look.shared.glass = false }
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("panels")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try renderEveryPanel(in: dir)
    }

    private func renderEveryPanel(in dir: URL) throws {

        let entries = [
            MenuEntry(title: "Ghostty", target: .app("com.mitchellh.ghostty"), home: .apps, detail: "Hyper+Return", detailIsKey: true, running: true),
            MenuEntry(title: "Finder", target: .app("com.apple.finder"), home: .apps, running: true),
            MenuEntry(title: "TextEdit", target: .app("com.apple.TextEdit"), home: .apps),
            MenuEntry(title: "Open terminal", target: .action("apps.terminal"), home: .keybindings, detail: "Hyper+Return", detailIsKey: true),
            MenuEntry(title: "Go to workspace 2", target: .action("workspaces.go:2"), home: .keybindings, detail: "Hyper+2", detailIsKey: true),
            MenuEntry(title: "Toggle floating", target: .action("windows.float"), home: .keybindings, detail: "Hyper+Shift+T", detailIsKey: true),
        ]
        var root = MenuNavigator(entries: entries)
        try render(MenuView(model: MenuModel(nav: root)), "01-menu-root", in: dir)
        root.query = "te"
        root.provide(.window, [MenuEntry(title: "Notes — TextEdit", target: .window(4), detail: "workspace 3")])
        root.provide(.file, [MenuEntry(title: "terminal-notes.md", target: .file("/tmp/terminal-notes.md"), detail: "~/notes · today")])
        try render(MenuView(model: MenuModel(nav: root)), "02-menu-search", in: dir)
        // Cmd+K on the best match (card agent-bo-95422968).
        _ = root.handle(.commandK)
        try render(MenuView(model: MenuModel(nav: root)), "02-menu-actions", in: dir)
        try render(MenuView(model: MenuModel(nav: MenuNavigator(entries: entries, branch: .keybindings))), "03-menu-branch", in: dir)
        let confirm = MenuNavigator(list: [MenuEntry(title: "Install hello", target: .action("install.go"), detail: "brew install hello"),
                                           MenuEntry(title: "Cancel", target: .action("install.cancel"))])
        try render(MenuView(model: MenuModel(nav: confirm)), "04-menu-confirm", in: dir)
        let picker = MenuNavigator(list: ["~/code/pilot", "~/code/agents", "~/code/dotfiles"].map { MenuEntry(title: $0, target: .action($0)) },
                                   title: "lazygit · pick a repo")
        try render(MenuView(model: MenuModel(nav: picker)), "05-picker", in: dir)
        // The round 11 menu (card agent-bo-95422981): the live builder on the registry's own labels, so the root lists the
        // nine branches, Trigger and System their layout rows, System its switches, and Bitwarden's actions wear its icon.
        let engine = Engine()
        let built = MenuEntries.build(
            apps: [("Ghostty", "com.mitchellh.ghostty"), ("Finder", "com.apple.finder"), ("TextEdit", "com.apple.TextEdit"),
                   ("Bitwarden", "com.bitwarden.desktop")],
            actions: engine.bindActions, store: BindStore(defaults: ["system.lock": Key("escape"), "system.darkMode": Key("d", shift: true),
                                                                 "captures.menu": Key("c", .ctrl), "apps.emoji": Key("e", .ctrl)]),
            roleApps: [:], menu: AppsModule.menuID,
            openID: AppsModule.openID(bundle:), running: ["com.mitchellh.ghostty", "com.apple.finder"],
            extras: [MenuLayout.system("Sound"): [BindsPage.ActionInfo(id: "system.output:73", label: "Play through AirPods", module: "system")]],
            switches: ["system.darkMode": true, "system.keepAwake": false, "system.idleLock": true, "system.nightShift": false, "system.wifi": true])
        try render(MenuView(model: MenuModel(nav: MenuNavigator(entries: built))), "12-menu-root-live", in: dir)
        try render(MenuView(model: MenuModel(nav: MenuNavigator(entries: built, branch: .trigger))), "13-menu-trigger", in: dir)
        // Mockup A's branch: every row on its tile, only the current one with its key and chevron (Moody's blocker).
        var emoji = MenuNavigator(entries: built, branch: .trigger)
        _ = emoji.handle(.down)
        try render(MenuView(model: MenuModel(nav: emoji)), "13-menu-trigger-emoji", in: dir)
        try render(MenuView(model: MenuModel(nav: MenuNavigator(entries: built, branch: .capture))), "13-menu-capture", in: dir)
        // Cmd+K in a narrow branch: the popover stays between the search line and the foot.
        var triggerActions = MenuNavigator(entries: built, branch: .trigger)
        _ = triggerActions.handle(.commandK)
        try render(MenuView(model: MenuModel(nav: triggerActions)), "13-menu-trigger-actions", in: dir)
        try render(MenuView(model: MenuModel(nav: MenuNavigator(entries: built, branch: .system))), "14-menu-system", in: dir)
        // Install's own rows (card agent-bo-95422994): Search Homebrew, and Make a web app on its tile, then current.
        var webApp = MenuNavigator(entries: built, branch: .install)
        try render(MenuView(model: MenuModel(nav: webApp)), "20-menu-install", in: dir)
        _ = webApp.handle(.down)
        try render(MenuView(model: MenuModel(nav: webApp)), "20-menu-install-webapp", in: dir)
        // Mockup B's filter: typing inside System heads the match with its sub-branch's name, the current row its key.
        var dark = MenuNavigator(entries: built, branch: .system)
        dark.query = "dark"
        try render(MenuView(model: MenuModel(nav: dark)), "14-menu-system-dark", in: dir)
        // System's sub-branches (C6): Power with its switches, and Sound with the sound output.
        try render(MenuView(model: MenuModel(nav: MenuNavigator(entries: built, branch: MenuLayout.system("Power")))), "14-menu-system-power", in: dir)
        try render(MenuView(model: MenuModel(nav: MenuNavigator(entries: built, branch: MenuLayout.system("Sound")))), "14-menu-system-sound", in: dir)
        var bitwarden = MenuNavigator(entries: built)
        bitwarden.query = "bitwa"
        // Mockup C's package and files: a cask under Install, a .py and a .md with their folders and day.
        bitwarden.provide(.package, [MenuEntry(title: "Bitwarden", target: .package("cask:bitwarden"), detail: "cask · installed")])
        let home = NSHomeDirectory(), third = Date(timeIntervalSince1970: 1_791_028_800)
        bitwarden.provide(.file, MenuEntries.files([(home + "/code/oss/vaultkit/agent/secret_sources/bitwarden.py", third),
                                                    (home + "/code/oss/vaultkit/website/docs/guides/secrets/bitwarden.md", third)],
                                                   home: home))
        try render(MenuView(model: MenuModel(nav: bitwarden)), "15-menu-bitwarden", in: dir)
        var files = bitwarden
        for _ in 0..<3 { _ = files.handle(.tab) }
        try render(MenuView(model: MenuModel(nav: files)), "15-menu-bitwarden-files", in: dir)
        _ = bitwarden.handle(.down)
        _ = bitwarden.handle(.commandK)
        try render(MenuView(model: MenuModel(nav: bitwarden)), "16-menu-bitwarden-actions", in: dir)
        // Sven's glass panel: offscreen glass draws nothing, so the list shows through anything clear over it; the
        // popover's own ground must hide the selected row and its key behind it.
        Look.shared.glass = true
        try render(MenuView(model: MenuModel(nav: bitwarden)), "19-menu-actions-glass", in: dir)
        Look.shared.glass = false
        var finder = MenuNavigator(entries: built)
        finder.query = "finder"
        _ = finder.handle(.commandK)
        try render(MenuView(model: MenuModel(nav: finder)), "17-menu-finder-actions", in: dir)
        // Mockup C's filter with no match: what was typed and how many actions there are.
        finder.actionQuery = "zz"
        try render(MenuView(model: MenuModel(nav: finder)), "18-menu-actions-empty", in: dir)

        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-render-clips-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) } }
        let store = try ClipboardStore(path: db)
        let now = Date()
        let samples: [(String, String?)] = [("open -g \"pilot://run?action=windows.close&app=Finder\"", "com.mitchellh.ghostty"),
                                            ("https://github.com/nikitabobko/AeroSpace", "app.zen-browser.zen"),
                                            ("Pilot makes a Mac feel as close to Omarchy as macOS allows.", "md.obsidian"),
                                            ("#7AA2F7", nil)]
        for (i, (text, app)) in samples.enumerated() {
            let item = ClipItem(kind: text.hasPrefix("#") ? .colour : .text, text: text,
                                contents: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]], sourceApp: app)
            let id = try store.add(item, at: now.addingTimeInterval(Double(-60 * i)))
            if i == 3 { try store.setPinned(id, true) }
        }
        try render(ClipboardPanelView(model: PanelModel(store: store), returnCopies: false), "06-clipboard", in: dir)
        let picked = PanelModel(store: store)
        picked.move(1)
        picked.extend(1)
        picked.extend(1)
        #expect(picked.pickCount == 3, "rows \(picked.rows.count), cursor \(picked.cursor)")
        try render(ClipboardPanelView(model: picked, returnCopies: false), "06-clipboard-picks", in: dir)
        let keys = PanelModel(store: store)
        keys.showsKeys = true
        let kept = Look.shared.style
        Look.shared.style = .instrument
        try render(ClipboardPanelView(model: keys, returnCopies: false), "06-clipboard-keys", in: dir)
        Look.shared.style = .toybox
        try render(ClipboardPanelView(model: keys, returnCopies: false), "06-clipboard-keys-toybox", in: dir)
        Look.shared.style = kept
        try store.tag([try #require(store.recent().last?.id)], with: "omarchy")
        try store.tag([try #require(store.recent().last?.id)], with: "pilot")
        let tagging = PanelModel(store: store)
        tagging.move(3)
        tagging.open(.tag)
        tagging.type("o")
        try render(ClipboardPanelView(model: tagging, returnCopies: false), "06-clipboard-tag", in: dir)
        let acting = PanelModel(store: store)
        acting.move(1)
        acting.open(.actions)
        try render(ClipboardPanelView(model: acting, returnCopies: false), "06-clipboard-actions", in: dir)
        let editing = PanelModel(store: store)
        editing.move(3)
        editing.open(.edit)
        try render(ClipboardPanelView(model: editing, returnCopies: false), "06-clipboard-edit", in: dir)
        let searched = PanelModel(store: store)
        searched.tab = .kind(.text)
        searched.query = "pilot"
        try render(ClipboardPanelView(model: searched, returnCopies: false), "06-clipboard-search", in: dir)

        let rows = [("Return", "Open terminal"), ("B", "Open browser"), ("Space", "Pilot menu"), ("1", "Go to workspace 1"),
                    ("2", "Go to workspace 2"), ("H", "Focus left"), ("L", "Focus right"), ("W", "Close window"), ("F", "Full width")]
            .map { BindsPage.Row(id: $0.1, key: $0.0, label: $0.1, module: "", custom: false) }
        try render(OverlayView(title: "Hyper", rows: rows), "07-overlay", in: dir)
        try render(OverlayView(title: "Hyper+Ctrl", rows: []), "08-overlay-empty", in: dir)
        try render(TipView(text: "Workspace 2 saved: 3 windows"), "09-tip", in: dir)
        // Convert's tips with their button (card agent-bo-95423211), in the theme of the run and in Folio, the light one,
        // previewed so nothing is saved.
        for (id, suffix) in [(Look.shared.themeID, ""), ("folio", "-workshop")] {
            Look.shared.preview(id)
            try render(TipView(text: "Converting 2 of 5 to JPG…", action: HUD.TipAction(title: "Cancel") {}), "09-tip-progress\(suffix)", in: dir)
            try render(TipView(text: "3 files converted to JPG", action: HUD.TipAction(title: "Reveal") {}), "09-tip-done\(suffix)", in: dir)
        }
        Look.shared.preview(Look.shared.themeID)
        try render(ExtensionAlertView(alert: ExtensionTimerTests.alert), "11-alert", in: dir)
    }

    /// The panel as HUD.makePanel builds it, its content drawn at Retina scale with the clear corners kept.
    private func render(_ view: some View, _ name: String, in dir: URL) throws {
        let panel = HUD.makePanel(view)
        defer { panel.close() }
        let content = try #require(panel.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        content.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(content, scale: 2))
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
}
#endif
