import Foundation
import Testing
@testable import PilotCore

/// Story 158 (Sven, 2026-10-10): Hyper+Space's Extensions branch, above System, holds a sub-branch per installed
/// extension with its commands, then Browse catalogue; every extension says what it is for, with one or two examples.
@Suite("Extensions branch")
struct ExtensionsBranchTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-branch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let manifests = [
        ("ssh", #"""
            {"id": "ssh-hosts", "title": "SSH hosts", "icon": "🖥️", "version": "1.0.0",
             "description": "Opens a host from your ~/.ssh/config in Ghostty.",
             "examples": ["Type prod, Return: an SSH session to prod in a new Ghostty window", "  ", 7, "Cmd+K on a host: copy ssh prod", "a third, never shown"],
             "commands": [{"name": "hosts", "title": "SSH hosts", "mode": "list", "run": "run"},
                          {"name": "connect", "title": "Connect", "mode": "no-view", "run": "run", "hidden": true}]}
            """#),
        ("pomodoro", #"""
            {"id": "pomodoro", "title": "Pomodoro", "icon": "🍅", "description": 12, "examples": "not a list",
             "commands": [{"name": "focus", "title": "Start focus", "mode": "no-view", "run": "run"},
                          {"name": "stop", "title": "Stop timer", "mode": "no-view", "run": "run"}]}
            """#),
        ("ghost", #"{"id": "ghost", "title": "Ghost", "commands": [{"name": "end", "title": "End", "mode": "no-view", "run": "run", "hidden": true}]}"#),
    ]

    static func extensions(in dir: URL) throws -> [Extension] {
        for (name, json) in manifests {
            let ext = dir.appending(path: name)
            try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: ext.appending(path: Extension.manifestName))
            try Data("#!/bin/sh\n".utf8).write(to: ext.appending(path: "run"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ext.appending(path: "run").path)
        }
        return Extension.find(in: dir).extensions
    }

    @Test("A manifest's description and examples read: blank and non-string examples dropped, two at most; a wrong type shows none and still reads")
    func purpose() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try Self.extensions(in: dir)
        let ssh = try #require(found.first { $0.id == "ssh-hosts" })
        #expect(ssh.description == "Opens a host from your ~/.ssh/config in Ghostty.")
        #expect(ssh.examples == ["Type prod, Return: an SSH session to prod in a new Ghostty window", "Cmd+K on a host: copy ssh prod"])
        let pomodoro = try #require(found.first { $0.id == "pomodoro" })
        #expect(pomodoro.description.isEmpty && pomodoro.examples.isEmpty)
    }

    @Test("Extensions sits above System at the root")
    func placed() {
        #expect(Array(MenuBranch.top.suffix(4)) == [.clean, .extensions, .about, .system])
        #expect(MenuBranch.extensions.title == "Extensions" && MenuBranch.extensions.parent == nil)
        #expect(MenuLayout.extensionBranch("Pomodoro").parent == .extensions)
    }

    @Test("Extensions lists a sub-branch per extension with a listed command, by title, wearing its icon and its words, then Browse catalogue; each holds its commands")
    func rows() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try Self.extensions(in: dir)
        let menu = Extension.menu(found, catalogue: "extensions.catalogue")
        let actions = Extension.actions([BindsPage.ActionInfo(id: "extensions.catalogue", label: "Extension catalogue", module: "drive")], with: found)
        let entries = MenuEntries.build(apps: [], actions: actions, store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                        openID: { $0 }, running: [], extras: menu.extras, branches: menu.branches)

        var nav = MenuNavigator(entries: entries, branch: .extensions)
        #expect(nav.rows.map(\.title) == ["Pomodoro", "SSH hosts", "Browse catalogue"], "Ghost has only a hidden command: no sub-branch")
        let ssh = nav.rows[1]
        #expect(ssh.target == .branch(MenuLayout.extensionBranch("SSH hosts")))
        #expect(ssh.subtitle == "Opens a host from your ~/.ssh/config in Ghostty." && ssh.icon == .command(emoji: "🖥️"))
        #expect(nav.rows[0].subtitle == nil)
        #expect(nav.rows[2].target == .action("extensions.catalogue"))

        nav = MenuNavigator(entries: entries, branch: MenuLayout.extensionBranch("Pomodoro"))
        #expect(nav.rows.map(\.target) == [.action("ext.pomodoro.focus"), .action("ext.pomodoro.stop")])
        nav = MenuNavigator(entries: entries, branch: MenuLayout.extensionBranch("SSH hosts"))
        #expect(nav.rows.map(\.target) == [.action("ext.ssh-hosts.hosts")], "the hidden Connect is no row")

        // A root search still finds a command, once, at home in its extension's sub-branch.
        var root = MenuNavigator(entries: entries)
        root.query = "Start focus"
        let hits = root.rows.filter { $0.target == .action("ext.pomodoro.focus") }
        #expect(hits.count == 1 && hits.first?.home == MenuLayout.extensionBranch("Pomodoro"))
    }

    @Test("Cmd+K on an installed extension's row offers Uninstall…, which the panel asks about (never Remove's search); Browse catalogue has none")
    func uninstall() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try Self.extensions(in: dir)
        let menu = Extension.menu(found, catalogue: "extensions.catalogue")
        let actions = Extension.actions([BindsPage.ActionInfo(id: "extensions.catalogue", label: "Extension catalogue", module: "drive")], with: found)
        let entries = MenuEntries.build(apps: [], actions: actions, store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher",
                                        openID: { $0 }, running: [], extras: menu.extras, branches: menu.branches)

        var nav = MenuNavigator(entries: entries, branch: .extensions)
        for row in nav.rows.prefix(2) {
            #expect(RowAction.list(for: row, favourite: false).contains(.uninstall), "\(row.title)")
        }
        #expect(nav.rows[1].extensionID == "ssh-hosts")
        #expect(!RowAction.list(for: nav.rows[2], favourite: false).contains(.uninstall), "Browse catalogue")
        #expect(!RowAction.list(for: MenuEntry(title: "Pomodoro", target: .branch(MenuLayout.extensionBranch("Pomodoro"))), favourite: false)
            .contains(.uninstall), "a branch row with no extension id")

        _ = nav.handle(.down)
        _ = nav.handle(.commandK)
        nav.actionQuery = "uninstall"
        #expect(nav.actions?.selected == .row(.uninstall))
        let outcome = nav.handle(.return)
        #expect(outcome == .act(.uninstall, nav.rows[1]))
        #expect(nav.branch == .extensions, "Uninstall stays put for the panel's question, never opens Remove")
    }

    @Test("No extensions: Extensions holds only Browse catalogue")
    func empty() {
        let menu = Extension.menu([], catalogue: "extensions.catalogue")
        #expect(menu.branches.isEmpty)
        let entries = MenuEntries.build(apps: [], actions: [BindsPage.ActionInfo(id: "extensions.catalogue", label: "Extension catalogue", module: "drive")],
                                        store: BindStore(defaults: [:]), roleApps: [:], menu: "apps.launcher", openID: { $0 }, running: [],
                                        extras: menu.extras, branches: menu.branches)
        #expect(MenuNavigator(entries: entries, branch: .extensions).rows.map(\.title) == ["Browse catalogue"])
    }

    @Test("The catalogue's index carries examples and its search finds them; an entry without them has none")
    func catalogue() throws {
        let file = #"{"path": "extension.json", "sha256": "\#(String(repeating: "a", count: 64))", "size": 10}"#
        let json = #"""
            {"schema": 1, "extensions": [
              {"id": "obsidian", "title": "Obsidian search", "version": "1.0.0", "description": "Searches your vault without opening Obsidian.",
               "examples": ["Type invoice: every note that says it", "Return opens the note in Obsidian"], "files": [\#(file)]},
              {"id": "plain", "title": "Plain", "version": "1.0.0", "files": [\#(file)]}]}
            """#
        let index = try ExtensionCatalogue.index(Data(json.utf8))
        #expect(index.entry("obsidian")?.examples == ["Type invoice: every note that says it", "Return opens the note in Obsidian"])
        #expect(index.entry("plain")?.examples == [])
        #expect(ExtensionCatalogue.search(index.entries, "invoice").map(\.id) == ["obsidian"])
        #expect(ExtensionCatalogue.uninstallQuestion("Obsidian search") == "Uninstall Obsidian search?")
        #expect(ExtensionCatalogue.uninstallNote.contains("Trash") && ExtensionCatalogue.uninstallNote.contains("settings and data are kept"))
    }
}
