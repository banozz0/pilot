import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95423029: a script in the Scripts folder runs from Hyper+Space or its bind in the mode its header names.
/// Every run here goes to fakes; no script runs.
@MainActor
final class ScriptRuns {
    var shell: [String] = [], terminal: [(String, String)] = [], hud: [String] = [], asked: [String] = []
    var output: String? = ""
}

@MainActor
@Suite("Scripts module")
struct ScriptsModuleTests {
    private func folder(_ scripts: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-scripts-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in scripts {
            try Data(text.utf8).write(to: url.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent(name).path)
        }
        return url
    }

    private func perform(_ id: String, in folder: URL, _ runs: ScriptRuns) async throws {
        await ScriptsModule.perform(try #require(ScriptCommand.file(inAction: id)), in: folder, arguments: ScriptCommand.arguments(inAction: id),
                                    ask: { runs.asked.append($0) },
                                    shell: { runs.shell.append($0); return runs.output },
                                    terminal: { runs.terminal.append(($0, $1)) }, hud: { runs.hud.append($0) })
    }

    @Test("A HUD script runs through the shell route, its path quoted, and shows its last line")
    func hud() async throws {
        let dir = try folder(["zip.sh": "# @raycast.title Zip downloads\n# @raycast.mode compact\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let runs = ScriptRuns()
        runs.output = "zipping\n12 files zipped\n"
        let action = try #require(ScriptsModule.dynamic("scripts.run:zip.sh", folder: dir))
        #expect(action.label == "Zip downloads")
        try await perform("scripts.run:zip.sh", in: dir, runs)
        #expect(runs.shell == [VisibleRun.quoted(dir.appendingPathComponent("zip.sh").path)])
        #expect(runs.hud == ["12 files zipped"])
        #expect(runs.terminal.isEmpty)
    }

    @Test("A silent script shows only a line it printed or its failure; a fullOutput one opens a visible terminal")
    func modes() async throws {
        let dir = try folder(["mute.sh": "# @raycast.mode silent\n", "pr.sh": "# @raycast.title PRs\n# @raycast.mode fullOutput\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let silent = ScriptRuns()
        try await perform("scripts.run:mute.sh", in: dir, silent)
        #expect(silent.shell.count == 1 && silent.hud.isEmpty)
        // Raycast's silent: the last line in a HUD when the script printed one.
        let said = ScriptRuns()
        said.output = "muted\n"
        try await perform("scripts.run:mute.sh", in: dir, said)
        #expect(said.hud == ["muted"])
        let failed = ScriptRuns()
        failed.output = nil
        try await perform("scripts.run:mute.sh", in: dir, failed)
        #expect(failed.hud == ["Mute failed; Pilot's log says why."])
        let visible = ScriptRuns()
        try await perform("scripts.run:pr.sh", in: dir, visible)
        #expect(visible.shell.isEmpty)
        #expect(visible.terminal.map(\.1) == ["PRs"])
        #expect(visible.terminal.first?.0 == VisibleRun.quoted(dir.appendingPathComponent("pr.sh").path))
    }

    @Test("A bound script that is gone says so; any other id is not a script's")
    func gone() async throws {
        let dir = try folder([:])
        defer { try? FileManager.default.removeItem(at: dir) }
        let runs = ScriptRuns()
        try await perform("scripts.run:gone.sh", in: dir, runs)
        #expect(runs.shell.isEmpty && runs.hud == ["No script gone.sh in Scripts."])
        #expect(ScriptsModule.dynamic("scripts.run:gone.sh", folder: dir)?.label == "Gone")
        #expect(ScriptsModule.dynamic("drive.shell:ls", folder: dir) == nil)
    }

    @Test("Arguments reach the script quoted after its path, in a terminal too (card agent-bo-95423048)")
    func arguments() async throws {
        let dir = try folder(["f.sh": "# @raycast.title Flights\n# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"from\" }\n",
                              "t.sh": "# @raycast.mode fullOutput\n# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"tag\", \"optional\": true }\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let runs = ScriptRuns()
        let flights = try #require(ScriptCommand.named("f.sh", in: dir))
        try await perform(flights.actionID(arguments: ["it's"]), in: dir, runs)
        #expect(runs.shell == [VisibleRun.quoted(dir.appendingPathComponent("f.sh").path) + " 'it'\\''s'"])
        #expect(runs.asked.isEmpty)
        let visible = ScriptRuns()
        try await perform("scripts.run:t.sh", in: dir, visible)
        #expect(visible.terminal.first?.0 == VisibleRun.quoted(dir.appendingPathComponent("t.sh").path))
        try await perform(try #require(ScriptCommand.named("t.sh", in: dir)).actionID(arguments: ["x"]), in: dir, visible)
        #expect(visible.terminal.last?.0 == VisibleRun.quoted(dir.appendingPathComponent("t.sh").path) + " 'x'")
    }

    @Test("A bind or link missing a required argument opens Hyper+Space with the title typed and runs nothing; a password one says so")
    func asks() async throws {
        let dir = try folder(["f.sh": "# @raycast.title Flights\n# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"from\" }\n",
                              "p.sh": "# @raycast.title Log in\n# @raycast.argument1 { \"type\": \"password\", \"placeholder\": \"pw\" }\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let runs = ScriptRuns()
        try await perform("scripts.run:f.sh", in: dir, runs)
        #expect(runs.asked == ["Flights "] && runs.shell.isEmpty && runs.terminal.isEmpty && runs.hud.isEmpty)
        // Present but empty is missing too.
        try await perform(try #require(ScriptCommand.named("f.sh", in: dir)).actionID(arguments: [""]), in: dir, runs)
        #expect(runs.asked == ["Flights ", "Flights "] && runs.shell.isEmpty)
        let password = ScriptRuns()
        try await perform("scripts.run:p.sh", in: dir, password)
        try await perform(try #require(ScriptCommand.named("p.sh", in: dir)).actionID(arguments: ["hunter2"]), in: dir, password)
        #expect(password.shell.isEmpty && password.asked.isEmpty)
        #expect(password.hud == Array(repeating: "Log in takes a password; Pilot does not ask for one yet.", count: 2))
        #expect(ScriptsModule.dynamic(try #require(ScriptCommand.named("f.sh", in: dir)).actionID(arguments: ["a"]), folder: dir)?.label == "Flights")
    }

    @Test("A script's emoji draws as an image in the icon's place")
    func emojiArt() {
        var icon = MenuIcon.formula
        icon.emoji = "🐙"
        guard case .icon(let image, nil) = MenuEntry.art(icon, tiled: false) else { Issue.record("no emoji image"); return }
        #expect(image.size.width == image.size.height)
        #expect(icon.app(path: "/nope").emoji == "🐙")
    }

    @Test("Set Hyper bind on an unbound script names it in the bind editor's actions (Moody f0FISQ2s1B4)")
    func editorNamesScript() {
        let id = "scripts.run:pilot-test-\(UUID().uuidString).sh"
        let engine = Engine()
        #expect(!engine.bindActions.contains { $0.id == id })
        #expect(engine.bindActions(including: id).last?.id == id)
        #expect(engine.bindActions(including: nil).count == engine.bindActions.count)
    }
}
