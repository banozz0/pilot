#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Card agent-bo-95423262: the Defaults page's Configs list read Sven's real config files and said when each changed
/// ("35 min ago") from the moment it drew, so two draws a moment apart could differ (Style seam's two draws of Defaults
/// failed rarely). Tests give the list a home of their own and a fixed now.
@MainActor
@Suite("Configs list")
struct ConfigsListTests {
    /// What every other test that draws the Defaults page gives its Configs list: a home of its own holding Ghostty's
    /// config, changed 35 min before a fixed now.
    static let fixture: ConfigsList.Start = {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return ConfigsList.Start(home: try! home(changed: now - 35 * 60), now: now)
    }()

    /// A home in a temporary directory holding Ghostty's config, changed at `changed`.
    static func home(changed: Date) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "pilot-configs-list-\(UUID().uuidString)").resolvingSymlinksInPath()
        let config = home.appending(path: ".config/ghostty/config")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("font-size = 13\n".utf8).write(to: config)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: config.path)
        return home
    }

    /// The Configs page on `look` at 1000 by 900, its list's ages in view, drawn at 1x.
    func pixels(_ page: ConfigsPage, look: Look) throws -> Data {
        var data = Data()
        try LookPageTests().hosted(page.frame(width: 1000, height: 900).pilotTheme(look: look)) { host in
            let rep = try #require(snapshot(host))
            data = Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
        }
        return data
    }

    /// Ghostty's config changed 59 s before the first draw, which reads "just now"; the second draw starts past the
    /// minute, where a list counting from its own appearing read "1 min ago". Counted from the start's now, both read
    /// "just now".
    @Test("Two draws of Configs a moment apart are the same while a config's age ticks over from just now to 1 min ago between them")
    func ageHoldsStill() throws {
        let (look, _) = LookPageTests().look()
        let began = Date.now
        let home = try Self.home(changed: began - 59)
        defer { try? FileManager.default.removeItem(at: home) }
        let start = ConfigsList.Start(home: home, now: began)
        let first = try pixels(ConfigsPage(configs: start), look: look)
        AliasesListTests.until { Date.now > began + 1.2 }
        #expect(try pixels(ConfigsPage(configs: start), look: look) == first, "the page drew the config's age anew")
    }

    @Test("Every test that draws the Configs page gives its list a home of its own, never this Mac's")
    func everyDrawHasAHome() throws {
        let dir = URL(filePath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let bare = try files.flatMap { file in
            try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
                .filter { ($0.element.contains("ConfigsPage(") && !$0.element.contains("configs:"))
                    || ($0.element.contains("InstructionsPage(") && !$0.element.contains("start:")) }
                .map { "\(file.lastPathComponent):\($0.offset + 1)" }
        }
        #expect(bare == [], "these draw Configs on this Mac's configs: \(bare)")
    }

    /// A home with AI agents' configs and instruction files as on Sven's Mac, none of their real contents.
    static func agentsHome(now: Date) throws -> URL {
        let home = try home(changed: now - 35 * 60), fm = FileManager.default
        for (path, text) in [(".claude/settings.json", "{\n  \"model\": \"opus\",\n  \"theme\": \"dark\"\n}\n"),
                             (".claude/settings.local.json", "{\n  \"permissions\": {}\n}\n"), (".codex/config.toml", "model = \"gpt\"\n"),
                             (".hermes/config.yaml", "model: default\n"), (".hermes/profiles/harry/config.yaml", "model: harry\n"),
                             (".hermes/profiles/dobby/config.yaml", "model: dobby\n"), (".empryo/config.json", "{}\n"),
                             (".claude/CLAUDE.md", "# Claude Code\n\n## Identity\n"), (".codex/AGENTS.md", "# Codex\n"),
                             (".hermes/profiles/harry/SOUL.md", "# Harry\n"), (".hermes/profiles/dobby/SOUL.md", "# Dobby\n"),
                             ("code/pilot/AGENTS.md", "# pilot — agent brief\n"), ("code/agents/AGENTS.md", "# agents\n"),
                             // Q718: skills and the like by tool, a brief in a repo's folder, a repo's .claude, Ghostty's second file.
                             (".hermes/AGENTS.md", "# Hermes\n"), (".claude/skills/review/SKILL.md", "---\nname: review\ndescription: A strict PASS or REJECT\n---\n"),
                             (".claude/agents/designer.md", "---\nname: designer\n---\n"), (".claude/output-styles/sven.md", "# Sven\n"),
                             (".codex/skills/review/SKILL.md", "---\nname: review\n---\n"), (".codex/rules/git.rules", "prefix_rule(pattern = [\"git\"])\n"),
                             (".hermes/skills/apple/notes/SKILL.md", "---\nname: notes\n---\n"), (".hermes/profiles/harry/skills/flights/SKILL.md", "---\nname: flights\n---\n"),
                             ("code/agents/src/AGENTS.md", "# agents · src\n"), ("code/pilot/.claude/settings.json", "{}\n"),
                             ("Library/Application Support/com.mitchellh.ghostty/config.ghostty", "font-size = 13\n")] {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now - 3 * 3600], ofItemAtPath: url.path)
        }
        for repo in ["pilot", "agents"] { try fm.createDirectory(at: home.appending(path: "code/\(repo)/.git"), withIntermediateDirectories: true) }
        return home
    }

    /// Configs and its Agents tab (agents' settings and instruction files), in a home of their own. Opt-in:
    /// `PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ConfigsListTests`
    @Test("Configs and its Agents tab render", .enabled(if: ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] != nil))
    func renderAgents() throws {
        let dir = URL(filePath: ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"]!).appending(path: "configs-agents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let home = try Self.agentsHome(now: now)
        defer { try? FileManager.default.removeItem(at: home) }
        // Q261: Pilot's own files, each repo's CLAUDE.md a link to its AGENTS.md, ~/code's brief, and folders skipped.
        let fm = FileManager.default
        for (path, text) in [("Library/Application Support/Pilot/binds.json", "{\n  \"version\" : 1,\n  \"binds\" : []\n}\n"),
                             ("Library/Application Support/Pilot/workspace-presets.json", "[\n  { \"name\" : \"Code\" }\n]\n"),
                             ("code/CLAUDE.md", "# ~/code — workspace map\n"), ("code/oss/AGENTS.md", "# oss\n"), ("code/_archive/old/AGENTS.md", "# old\n")] {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        for repo in ["pilot", "agents"] { try fm.createSymbolicLink(atPath: home.appending(path: "code/\(repo)/CLAUDE.md").path, withDestinationPath: "AGENTS.md") }
        let (look, _) = LookPageTests().look()
        try writeRender(ConfigsPage(configs: .init(previewing: "pilot-binds", home: home, now: now)).frame(width: 1000, height: 1700)
                            .pilotTheme(look: look).background(Theme.background),
                        to: dir.appending(path: "configs-pilot-preview.png"))
        try writeRender(ConfigsPage(configs: .init(home: home, now: now)).frame(width: 1000, height: 1300).pilotTheme(look: look).background(Theme.background),
                        to: dir.appending(path: "configs.png"))
        // The Agents tab folded as a viewer first sees it, then filtered, then with Claude Code's group and the agents repo
        // open and a skill's source showing.
        try writeRender(InstructionsPage(start: .init(open: ConfigsList.openFirst, home: home, now: now)).frame(width: 1000, height: 1100)
                            .pilotTheme(look: look).background(Theme.background),
                        to: dir.appending(path: "instructions.png"))
        try writeRender(InstructionsPage(start: .init(query: "review", open: ConfigsList.openFirst, home: home, now: now)).frame(width: 1000, height: 900)
                            .pilotTheme(look: look).background(Theme.background),
                        to: dir.appending(path: "instructions-filtered.png"))
        try writeRender(InstructionsPage(start: .init(previewing: "kit-.claude/skills/review/SKILL.md", source: true,
                                                      open: ["agentRules", "claudeKit", "repo-agents"], home: home, now: now))
                            .frame(width: 1000, height: 1500).pilotTheme(look: look).background(Theme.background),
                        to: dir.appending(path: "instructions-open-source.png"))
        try writeRender(InstructionsPage(start: .init(previewing: "soul-harry", home: home, now: now)).frame(width: 1000, height: 1300)
                            .pilotTheme(look: look).background(Theme.background),
                        to: dir.appending(path: "instructions-preview.png"))
    }

    @Test("Configs › Agents draws its own cards, no filter chips, from its own home")
    func instructionsDraw() throws {
        let (look, _) = LookPageTests().look()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let home = try Self.agentsHome(now: now)
        defer { try? FileManager.default.removeItem(at: home) }
        try LookPageTests().hosted(InstructionsPage(start: .init(home: home, now: now)).frame(width: 1000, height: 1100).pilotTheme(look: look)) { host in
            let rep = try #require(snapshot(host))
            #expect(Set(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * rep.pixelsHigh)).count > 16, "a blank page")
        }
        #expect(ConfigsList.Kind.instructions.chips.isEmpty && ConfigsList.Kind.configs.chips == ConfigFilter.allCases)
    }
}
#endif
