import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423029 (audit gap 3): every executable in Pilot's Scripts folder is a Hyper+Space command, titled,
/// iconed and run as its Raycast-style header says. Nothing here runs a script.
@Suite("Script commands")
struct ScriptCommandTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-scripts-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ name: String, in folder: URL, executable: Bool = true) throws {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    @Test("Raycast's header names the title, the emoji icon and the mode, whatever the comment marker")
    func header() {
        let bash = ScriptCommand(file: "pr.sh", header: """
            #!/bin/bash
            # Required parameters:
            # @raycast.schemaVersion 1
            # @raycast.title Open my pull requests
            # @raycast.mode fullOutput
            # @raycast.icon 🐙
            echo hi
            """)
        #expect(bash.title == "Open my pull requests")
        #expect(bash.icon == "🐙")
        #expect(bash.mode == .terminal)
        #expect(bash.actionID == "scripts.run:pr.sh")

        let js = ScriptCommand(file: "a.js", header: "#!/usr/bin/env node\n// @raycast.title Count tabs\n// @raycast.mode compact\n")
        #expect(js.title == "Count tabs" && js.mode == .hud && js.icon == nil)
        let lua = ScriptCommand(file: "b.lua", header: "-- @raycast.title Mute\n-- @raycast.mode silent\n-- @raycast.icon images/mute.png\n")
        #expect(lua.title == "Mute" && lua.mode == .silent)
        // A path or a URL is Raycast's too, but Pilot draws only an emoji.
        #expect(lua.icon == nil)
        #expect(ScriptCommand(file: "c.sh", header: "# @raycast.mode inline").mode == .hud)
    }

    @Test("With no header the file name is the title and the last output line shows as a HUD line")
    func noHeader() {
        let script = ScriptCommand(file: "restart-dock_now.sh", header: "#!/bin/zsh\nkillall Dock\n")
        #expect(script.title == "Restart dock now")
        #expect(script.mode == .hud)
        #expect(script.icon == nil)
        #expect(ScriptCommand(file: ".sh", header: "").title == ".sh")
    }

    @Test("A folder lists its executable files by title; hidden, plain and missing ones are left out")
    func find() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("# @raycast.title Zip downloads\n", "zip.sh", in: dir)
        try write("echo\n", "brew-cleanup", in: dir)
        try write("# @raycast.title Notes\n", "notes.md", in: dir, executable: false)
        try write("echo\n", ".hidden.sh", in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)

        #expect(ScriptCommand.find(in: dir).map(\.title) == ["Brew cleanup", "Zip downloads"])
        #expect(ScriptCommand.find(in: dir.appendingPathComponent("nope")).isEmpty)
        #expect(ScriptCommand.named("zip.sh", in: dir)?.title == "Zip downloads")
        #expect(ScriptCommand.named("notes.md", in: dir) == nil)
        #expect(ScriptCommand.named("../zip.sh", in: dir) == nil)
    }

    @Test("A script runs through the drive shell route, its path quoted, so a name with a quote runs nothing else")
    func command() {
        let line = VisibleRun.quoted("/Users/s/Scripts/it's.sh")
        #expect(line == "'/Users/s/Scripts/it'\\''s.sh'")
        #expect(DriveRoute.shell(line).command(loginShell: "/bin/zsh") == .init(path: "/bin/zsh", arguments: ["-l", "-c", line]))
        #expect(ScriptCommand.file(inAction: "scripts.run:zip.sh") == "zip.sh")
        #expect(ScriptCommand.file(inAction: "scripts.run:") == nil)
        #expect(ScriptCommand.file(inAction: "drive.shell:zip.sh") == nil)
    }

    @Test("The HUD line is the last line printed, trimmed and capped; nothing printed says the script ran")
    func hudLine() {
        #expect(ScriptCommand.hudLine("one\ntwo  \n\n", title: "Zip") == "two")
        #expect(ScriptCommand.hudLine("", title: "Zip") == "Zip ran")
        #expect(ScriptCommand.hudLine(String(repeating: "x", count: 300), title: "Zip").count == 120)
    }

    @Test("A script row wears its emoji, else the terminal glyph")
    func icon() {
        #expect(ScriptCommand(file: "a.sh", header: "# @raycast.icon 🐙").menuIcon.emoji == "🐙")
        let plain = ScriptCommand(file: "a.sh", header: "").menuIcon
        #expect(plain.emoji == nil && plain.symbol == "terminal")
    }

    @Test("Unbound scripts join the root search as action rows; a bound one keeps its Keybindings row; both wear the icon")
    func menuRows() {
        let zip = ScriptCommand(file: "zip.sh", header: "# @raycast.title Zip downloads\n# @raycast.icon 🗜️")
        let mute = ScriptCommand(file: "mute.sh", header: "")
        let bound = BindsPage.ActionInfo(id: mute.actionID, label: "Mute", module: "drive")
        let lock = BindsPage.ActionInfo(id: "system.lock", label: "Lock", module: "system")
        let actions = ScriptCommand.actions([lock, bound], with: [zip, mute])
        #expect(actions.map(\.id) == ["system.lock", "scripts.run:zip.sh", "scripts.run:mute.sh"])
        let store = BindStore(defaults: [mute.actionID: Key("m", hyper: true)])
        let rows = MenuEntries.build(apps: [], actions: actions, store: store, roleApps: [:], menu: "apps.launcher", openID: { $0 }, running: [])
        let muteRow = rows.first { $0.target == .action(mute.actionID) }, zipRow = rows.first { $0.target == .action(zip.actionID) }
        #expect(muteRow?.home == .keybindings && muteRow?.icon?.symbol == "terminal")
        #expect(zipRow?.title == "Zip downloads" && zipRow?.home == nil && zipRow?.inSearch == true && zipRow?.icon?.emoji == "🗜️")
        #expect(rows.first { $0.target == .action("system.lock") }?.icon == nil)
        #expect(zipRow.map { RowAction.list(for: $0, favourite: false).contains(.setBind) } == true)
    }

    @Test("A script runs a command: a link needs the token to run or bind it, and an imported bind of one arrives off (Moody f0FISQ2s1B4)")
    func linkGate() throws {
        #expect(BindStore.arrivesOff("scripts.run:zip.sh"))
        let token = LinkToken(url: FileManager.default.temporaryDirectory.appending(path: "pilot-link-\(UUID().uuidString)/Pilot/link-token"))
        defer { try? FileManager.default.removeItem(at: token.url.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(!token.allows("scripts.run:zip.sh", token: nil))
        #expect(token.allows("scripts.run:zip.sh", token: try token.value()))
    }

    @Test("A symlinked script is listed by its link's name")
    func symlink() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("# @raycast.title Real\n", "real.sh", in: dir)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.sh"), withDestinationURL: dir.appendingPathComponent("real.sh"))
        #expect(ScriptCommand.named("link.sh", in: dir)?.file == "link.sh")
    }
}
