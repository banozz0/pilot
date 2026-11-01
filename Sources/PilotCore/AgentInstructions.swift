import Foundation

/// Agent instructions (Sven 2026-10-10): the instruction and persona files agents read, shown as Configs shows configs
/// and opened in the main editor; Pilot never writes them. Found with folder listings (Hermes' profiles, the agents'
/// skill folders, ~/code's repos a few folders down) and a look at each path, no file read.
public enum AgentInstructions {
    /// The files every Mac may have: Claude Code's, Codex's, Hermes' (its brief, and its default profile's soul) and Empryo's.
    public static let known: [AppConfig] = [
        .init(id: "claude-md", name: "Claude Code", paths: [".claude/CLAUDE.md"], group: .agentRules, bundles: [AppConfigs.claudeApp]),
        .init(id: "codex-agents", name: "Codex", paths: [".codex/AGENTS.md"], group: .agentRules),
        // Not hermes-…: that names a Hermes profile's config (AppConfigs.config(inAction:)).
        .init(id: "agents-md-hermes", name: "Hermes", paths: [".hermes/AGENTS.md", ".hermes/CLAUDE.md"], group: .agentRules),
        .init(id: "empryo-md", name: "Empryo", paths: [".empryo/EMPRYO.md"], group: .agentRules, bundles: ["dev.empryo.desktop"]),
        .init(id: "soul-default", name: "Hermes · default", paths: [".hermes/SOUL.md"], group: .souls, generated: true),
    ]

    /// ~/code's own brief, read in every session under it: with the agents' own instructions, ahead of the repos.
    static let workspace = AppConfig(id: "code-workspace", name: "code · workspace", paths: ["code/AGENTS.md", "code/CLAUDE.md"], group: .agentRules)

    /// How far below a repo's root a brief is looked for (Q718): Sources/Pilot/AGENTS.md is two folders down.
    static let briefDepth = 3

    /// A folder in ~/code that is one of Sven's repos (Q261): not other people's clones in oss nor the _ folders (_archive,
    /// _references, _tools), and its .git a folder, as a worktree's .git is a file and its brief its repo's.
    static func isOwnRepo(_ name: String, in code: URL) -> Bool {
        guard AppConfigs.isPlainName(name), name != "oss", !name.hasPrefix("_") else { return false }
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: code.appendingPathComponent(name).appendingPathComponent(".git").path, isDirectory: &folder)
            && folder.boolValue
    }

    /// The files `keep` takes in `folder` (a path under home) and up to `depth` folders below it, links followed, sorted;
    /// never into a hidden or _ folder, node_modules or a worktrees folder.
    static func walk(_ folder: String, home: URL, depth: Int, keep: (String) -> Bool) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(folder).path)) ?? []).sorted().flatMap { name -> [String] in
            let path = folder + "/" + name
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: home.appendingPathComponent(path).path, isDirectory: &isFolder) else { return [] }
            guard isFolder.boolValue else { return keep(name) ? [path] : [] }
            let skipped = !AppConfigs.isPlainName(name) || name.hasPrefix("_") || name == "node_modules" || name == "worktrees"
            return depth > 0 && !skipped ? walk(path, home: home, depth: depth - 1, keep: keep) : []
        }
    }

    /// One skill, agent, output style, command or rule (Q718): named by its folder for a SKILL.md, else by its file.
    static func kit(_ path: String, kind: String?, group: ConfigGroup) -> AppConfig {
        let file = (path as NSString).lastPathComponent
        let name = file == "SKILL.md" ? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent : (file as NSString).deletingPathExtension
        return AppConfig(id: "kit-" + path, name: kind.map { "\(name) · \($0)" } ?? name, paths: [path], group: group)
    }

    /// Claude Code's skills, agents, output styles and commands, Codex's skills and rules, and Hermes' skills: its own,
    /// the shared ones and each profile's, the ones under a category folder too.
    static func kits(home: URL) -> [AppConfig] {
        let skill = { (name: String) in name == "SKILL.md" }, markdown = { (name: String) in name.hasSuffix(".md") }
        let claude = walk(".claude/skills", home: home, depth: 1, keep: skill).map { kit($0, kind: nil, group: .claudeKit) }
            + [("agents", "agent"), ("output-styles", "output style"), ("commands", "command")].flatMap { folder, kind in
                walk(".claude/" + folder, home: home, depth: 1, keep: markdown).map { kit($0, kind: kind, group: .claudeKit) }
            }
        let codex = walk(".codex/skills", home: home, depth: 1, keep: skill).map { kit($0, kind: nil, group: .codexKit) }
            + walk(".codex/rules", home: home, depth: 0) { AppConfigs.isPlainName($0) }.map { kit($0, kind: "rule", group: .codexKit) }
        let hermes = ([(".hermes/skills", nil), (".hermes/shared-skills", "shared")] + AppConfigs.hermesProfiles(home: home).map { (".hermes/profiles/\($0)/skills", $0) })
            .flatMap { folder, kind in walk(folder, home: home, depth: 2, keep: skill).map { kit($0, kind: kind, group: .hermesKit) } }
        return claude + codex + hermes
    }

    /// A repo's cards: its AGENTS.md, else its CLAUDE.md, at its root; the briefs in its folders down to briefDepth; its
    /// .claude folder's settings, skills and commands (Q718).
    static func repo(_ name: String, home: URL) -> [AppConfig] {
        let root = "code/\(name)"
        // Under the repo: "Sources/Pilot/AGENTS.md", named by its folder, "pilot · Sources/Pilot".
        let inside = { (path: String) in String(path.dropFirst(root.count + 1)) }
        let card = { (path: String, named: String) in
            AppConfig(id: "repo-\(name)/\(inside(path))", name: "\(name) · \(named)", paths: [path], group: .repos, repo: name)
        }
        let nested = walk(root, home: home, depth: briefDepth) { $0 == "AGENTS.md" || $0 == "CLAUDE.md" }
            .filter { inside($0).contains("/") }
            .map { card($0, (inside($0) as NSString).deletingLastPathComponent) }
        let claude = walk(root + "/.claude", home: home, depth: 2) { $0.hasSuffix(".md") || $0.hasSuffix(".json") }.map { card($0, inside($0)) }
        return [AppConfig(id: "repo-\(name)", name: name, paths: [root + "/AGENTS.md", root + "/CLAUDE.md"], group: .repos, repo: name)] + nested + claude
    }

    /// Each Hermes profile's SOUL.md, generated (rendered from the agents repo), the agents' skills and the like, then
    /// ~/code's brief and each own repo's cards.
    public static func all(home: URL) -> [AppConfig] {
        let souls = AppConfigs.hermesProfiles(home: home).map {
            AppConfig(id: "soul-\($0)", name: "Hermes · \($0)", paths: [".hermes/profiles/\($0)/SOUL.md"], group: .souls, generated: true)
        }
        let code = home.appendingPathComponent("code")
        let repos = ((try? FileManager.default.contentsOfDirectory(atPath: code.path)) ?? []).filter { isOwnRepo($0, in: code) }.sorted()
            .flatMap { repo($0, home: home) }
        return known + souls + kits(home: home) + [workspace] + repos
    }

    /// The instruction files on this Mac, each file once (Q261): a repo's CLAUDE.md is a link to its AGENTS.md, so the
    /// first path to reach a file keeps its card, by that path, since the path names whose file it is; the preview
    /// shows the file it really is.
    public static func find(home: URL) -> [FoundConfig] {
        var seen = Set<String>()
        return AppConfigs.find(home: home, among: all(home: home)).found.filter { seen.insert($0.real.path).inserted }
    }
}
