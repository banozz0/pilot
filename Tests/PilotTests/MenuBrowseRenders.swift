#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Offscreen renders of the menu's sub-lists for cards agent-bo-95423020 to 022: a picker opened from a menu row, a root
/// search's kinds, Remove and Update. Opt-in like PanelRenders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter MenuBrowseRenders`
@MainActor
@Suite("Menu browse renders")
struct MenuBrowseRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The sub-lists render", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderSubLists() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        Look.shared.glass = false
        defer { Look.shared.glass = false }
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("browse")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try renderSubLists(in: dir)
    }

    private func renderSubLists(in dir: URL) throws {
        let kill = Activity.entries(Activity.Snapshot(apps: [], background: [
            Activity.Row(kind: .process, pid: 30061, name: "swift-frontend", cpu: 84, memory: 517_120 << 10, rights: .quitAndForce),
            Activity.Row(kind: .process, pid: 33146, name: "find", cpu: 70, memory: 2048 << 10, rights: .quitAndForce),
            Activity.Row(kind: .process, pid: 7811, name: "Ghostex", cpu: 31, memory: 350_208 << 10, rights: .quitAndForce)]))
        let fromSystem = MenuNavigator.Spot(branch: MenuLayout.system("Fix it"), row: .action("system.killProcess"))
        try render(MenuView(model: MenuModel(nav: MenuNavigator(list: kill, title: "Kill a process", back: fromSystem))), "01-kill-a-process", in: dir)
        var search = MenuNavigator(entries: [MenuEntry(title: "Shottr", target: .app("cc.ffitch.shottr"), home: .apps)])
        search.query = "shottr"
        try render(MenuView(model: MenuModel(nav: search)), "02-root-search", in: dir)
        var remove = Self.remove()
        try render(MenuView(model: MenuModel(nav: remove)), "03-remove", in: dir)
        _ = remove.handle(.return)
        try render(MenuView(model: MenuModel(nav: remove)), "03-remove-apps", in: dir)
        _ = remove.handle(.escape)
        _ = remove.handle(.down)
        _ = remove.handle(.return)
        try render(MenuView(model: MenuModel(nav: remove)), "03-remove-tools", in: dir)
        var update = Self.update()
        try render(MenuView(model: MenuModel(nav: update)), "04-update", in: dir)
        _ = update.handle(.down)
        _ = update.handle(.return)
        try render(MenuView(model: MenuModel(nav: update)), "04-update-apps", in: dir)
        // Story 158: the root with Extensions above System, Extensions, and one extension's commands.
        let entries = Self.extensionEntries()
        try render(MenuView(model: MenuModel(nav: MenuNavigator(entries: entries))), "05-root", in: dir)
        var extensions = MenuNavigator(entries: entries, branch: .extensions)
        try render(MenuView(model: MenuModel(nav: extensions)), "05-extensions", in: dir)
        _ = extensions.handle(.return)
        try render(MenuView(model: MenuModel(nav: extensions)), "05-extensions-pomodoro", in: dir)
    }

    /// The Extensions branch's rows for three installed extensions, as Extension.menu makes them, and the catalogue.
    static func extensionEntries() -> [MenuEntry] {
        let installed: [(title: String, icon: String, words: String?, commands: [(String, String)])] = [
            ("Pomodoro", "🍅", "Focus blocks and breaks, counted down in the menu bar.", [("focus", "Start focus"), ("break", "Start break"), ("stop", "Stop timer")]),
            ("Ports", "🔌", "See which program holds a listening port and quit it.", [("kill-port", "Kill port")]),
            ("SSH hosts", "🖥️", nil, [("hosts", "SSH hosts")])]
        var branches: [MenuEntry] = [], extras: [MenuBranch: [BindsPage.ActionInfo]] = [:]
        for ext in installed {
            let sub = MenuLayout.extensionBranch(ext.title), id = ext.title.lowercased().replacingOccurrences(of: " ", with: "-")
            branches.append(MenuEntry(title: ext.title, target: .branch(sub), home: .extensions, subtitle: ext.words, icon: .command(emoji: ext.icon)))
            extras[sub] = ext.commands.map { BindsPage.ActionInfo(id: "ext.\(id).\($0.0)", label: $0.1, module: "drive", icon: .command(emoji: ext.icon)) }
        }
        extras[.extensions] = [BindsPage.ActionInfo(id: "extensions.catalogue", label: MenuLayout.browseCatalogue, module: "drive")]
        return MenuEntries.build(apps: [], actions: [], store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher", openID: { $0 },
                                 running: [], extras: extras, branches: [.extensions: branches])
    }

    static func removeRows() -> [RemoveRow] {
        var rows = [RemoveRow(source: .package(Package(.cask, "zed")!), name: "Zed", app: "/Applications/Zed.app"),
                    RemoveRow(source: .package(Package(.formula, "ripgrep")!), name: "ripgrep"),
                    RemoveRow(source: .package(Package(.formula, "lazygit")!), name: "lazygit"),
                    RemoveRow(source: .package(Package(.uv, "ruff")!), name: "ruff"),
                    RemoveRow(source: .app(path: "/Applications/Xcode.app"), name: "Xcode", app: "/Applications/Xcode.app"),
                    RemoveRow(source: .app(path: "/Applications/Things3.app"), name: "Things3", app: "/Applications/Things3.app"),
                    RemoveRow(source: .package(Package(.cask, "font-jetbrains-mono")!), name: "JetBrains Mono"),
                    RemoveRow(source: .webApp(bundleID: "dev.banozz.pilot.webapp.linear-app"), name: "Linear")]
        rows[0].pilot = true
        rows[5].appStore = true
        for (i, bytes) in [412_000_000, 6_100_000, 21_400_000, 38_000_000, 12_600_000_000, 96_000_000, 4_800_000, 2_900_000].enumerated() {
            rows[i].size = Int64(bytes)
        }
        return rows
    }

    static func remove() -> MenuNavigator {
        var nav = MenuNavigator(entries: [], branch: .remove)
        nav.provide(.package, home: .remove, RemoveList.entries(RemoveList.sorted(removeRows(), .pilotFirst)))
        return nav
    }

    static func updateRows() -> [UpdateRow] {
        [UpdateRow(item: .package(Package(.cask, "zed")!), from: "0.205.4", to: "0.206.1"),
         UpdateRow(item: .package(Package(.formula, "ripgrep")!), from: "14.1.1", to: "15.0.0"),
         UpdateRow(item: .appStore(id: "497799835", name: "Xcode"), from: "26.0", to: "26.0.1"),
         UpdateRow(item: .package(Package(.uv, "ruff")!), from: "0.13.0", to: "0.13.3"),
         UpdateRow(item: .macOS(label: "macOS Tahoe 26.1-25B78", title: "macOS Tahoe 26.1", restart: true), from: "26.0.1", to: "26.1")]
    }

    /// Install as a search starts: only the Searching row, naming the sources still asked.
    static func installSearching() -> MenuNavigator {
        var nav = MenuNavigator(entries: [], branch: .install)
        nav.query = "raycast"
        nav.provide(.package, home: .homebrew, MenuEntries.searching(InstallSearch.Query("raycast")!, waiting: [.homebrew, .appStore, .github, .tools]))
        return nav
    }

    static func update() -> MenuNavigator {
        var nav = MenuNavigator(entries: [], branch: .update)
        nav.provide(.package, home: .update, UpdateList.entries(updateRows(), includeSelfUpdating: false))
        return nav
    }

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
