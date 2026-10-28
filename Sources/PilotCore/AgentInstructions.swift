import Foundation

/// Agent instructions (Sven 2026-10-10): the instruction and persona files agents read, shown as Configs shows configs
/// and opened in the main editor; Pilot never writes them. Found with two folder listings (Hermes' profiles, ~/code)
/// and a look at each path, no file read.
public enum AgentInstructions {
    /// The files every Mac may have: Claude Code's and Codex's own.
    public static let known: [AppConfig] = [
        .init(id: "claude-md", name: "Claude Code", paths: [".claude/CLAUDE.md"], group: .agentRules, bundles: [AppConfigs.claudeApp]),
        .init(id: "codex-agents", name: "Codex", paths: [".codex/AGENTS.md"], group: .agentRules),
    ]

    /// ~/code's own brief, read in every session under it, ahead of the repos.
    static let workspace = AppConfig(id: "code-workspace", name: "code · workspace", paths: ["code/AGENTS.md", "code/CLAUDE.md"], group: .repos)

    /// Folders in ~/code that are not Sven's repos (Q261): other people's clones in oss, and the _ folders (_archive,
    /// _references, _tools).
    static func isOwnRepo(_ name: String) -> Bool { AppConfigs.isPlainName(name) && name != "oss" && !name.hasPrefix("_") }

    /// Each Hermes profile's SOUL.md, generated (rendered from the agents repo), then ~/code's brief and each top-level
    /// repo's AGENTS.md, else its CLAUDE.md, at the repo's root only.
    public static func all(home: URL) -> [AppConfig] {
        let souls = AppConfigs.hermesProfiles(home: home).map {
            AppConfig(id: "soul-\($0)", name: "Hermes · \($0)", paths: [".hermes/profiles/\($0)/SOUL.md"], group: .souls, generated: true)
        }
        let code = home.appendingPathComponent("code")
        let repos = ((try? FileManager.default.contentsOfDirectory(atPath: code.path)) ?? []).filter(isOwnRepo).sorted()
            .map { AppConfig(id: "repo-\($0)", name: $0, paths: ["code/\($0)/AGENTS.md", "code/\($0)/CLAUDE.md"], group: .repos) }
        return known + souls + [workspace] + repos
    }

    /// The instruction files on this Mac, each file once (Q261): a repo's CLAUDE.md is a link to its AGENTS.md, so the
    /// first path to reach a file keeps its card, by that path, since the path names whose file it is; the preview
    /// shows the file it really is.
    public static func find(home: URL) -> [FoundConfig] {
        var seen = Set<String>()
        return AppConfigs.find(home: home, among: all(home: home)).found.filter { seen.insert($0.real.path).inserted }
    }
}
