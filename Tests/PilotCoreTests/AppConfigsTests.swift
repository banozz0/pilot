import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95422841 (Sven, 2026-10-05: "a space in pilot app so we see configs of apps like ghosty, neovim etc"):
/// the known configs found in a home folder, where each really lives, when it changed, and a capped preview.
@Suite("App configs")
struct AppConfigsTests {
    /// A home folder in a temporary directory with a dotfiles repo, as on Sven's Mac.
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-configs-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("code/dotfiles/ghostty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/ghostty"), withIntermediateDirectories: true)
        return home
    }

    @Test("A symlinked config is found with its real file in the dotfiles repo and the date that file changed")
    func symlinked() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent("code/dotfiles/ghostty/config")
        try Data("font-size = 14\n".utf8).write(to: real)
        let changed = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".config/ghostty/config"), withDestinationURL: real)

        let result = AppConfigs.find(home: home)
        let ghostty = try #require(result.found.first { $0.config.id == "ghostty" })
        #expect(ghostty.path == home.appendingPathComponent(".config/ghostty/config"))
        #expect(ghostty.real == real)
        #expect(ghostty.isLinked)
        #expect(ghostty.modified == changed)
        #expect(AppConfigs.tilde(ghostty.real.path, home: home.path) == "~/code/dotfiles/ghostty/config")
        // Nothing else exists in this home, so every other known config is listed as not found.
        #expect(result.found.count == 1)
        #expect(result.missing.map(\.id) == AppConfigs.known.map(\.id).filter { $0 != "ghostty" })
        #expect(result.missing.contains { $0.name == "Neovim" })
    }

    @Test("The first path that exists wins, and a folder is never taken for a config file")
    func firstPathWins() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".aerospace.toml"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/aerospace"), withIntermediateDirectories: true)
        try Data("gaps\n".utf8).write(to: home.appendingPathComponent(".config/aerospace/aerospace.toml"))
        let tiler = try #require(AppConfigs.find(home: home).found.first { $0.config.id == "aerospace" })
        #expect(tiler.path.lastPathComponent == "aerospace.toml" && tiler.path.pathComponents.contains("aerospace"))
        #expect(!tiler.isLinked)
    }

    @Test("Every known config names Ghostty, Neovim, AeroSpace, zsh, git, Starship and tmux, each with a path under home")
    func known() {
        let names = AppConfigs.known.map(\.name)
        for name in ["Ghostty", "Neovim", "AeroSpace", "zsh", "git", "Starship", "tmux"] { #expect(names.contains(name), "\(name)") }
        #expect(Set(AppConfigs.known.map(\.id)).count == AppConfigs.known.count)
        #expect(AppConfigs.known.allSatisfy { !$0.paths.isEmpty && $0.paths.allSatisfy { !$0.hasPrefix("/") } })
    }

    @Test("The preview stops at its cap, on a line end, and says it was cut")
    func previewCap() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("long.conf")
        try Data(String(repeating: "abcdefghi\n", count: 100).utf8).write(to: file)
        guard case .text(let text, let cut) = AppConfigs.preview(file, cap: 95) else { Issue.record("not text"); return }
        #expect(cut)
        #expect(text == String(repeating: "abcdefghi\n", count: 9))
        guard case .text(let whole, let wholeCut) = AppConfigs.preview(file) else { Issue.record("not text"); return }
        #expect(!wholeCut && whole.count == 1000)
        try Data([0xff, 0xfe, 0x00, 0x81]).write(to: file)
        #expect(AppConfigs.preview(file) == .notText)
    }

    @Test("A line whose key names a token, secret, password or API key shows its value hidden; other lines stay")
    func secretsHidden() {
        let text = """
        export GITHUB_TOKEN=FAKE_ghp_abc123
        export PATH=/opt/homebrew/bin:$PATH
        api_key: FAKE_sk_live
        "openai.apiKey": "FAKE_sk_123",
        password = FAKE_hunter2
        CLIENT_SECRET="FAKE_shh"
        font-size = 14
        """
        let shown = AppConfigs.hidingSecrets(text)
        for secret in ["FAKE_ghp_abc123", "FAKE_sk_live", "FAKE_sk_123", "FAKE_hunter2", "FAKE_shh"] { #expect(!shown.contains(secret), "\(secret)") }
        #expect(shown.contains("export GITHUB_TOKEN=••••••"))
        #expect(shown.contains("export PATH=/opt/homebrew/bin:$PATH"))
        #expect(shown.contains("font-size = 14"))
        #expect(shown.components(separatedBy: "\n").count == 7)
    }

    @Test("A config's action id holds its id, and nothing else reads as one")
    func actionID() {
        #expect(AppConfigs.actionID("ghostty") == "configs.edit:ghostty")
        #expect(AppConfigs.config(inAction: "configs.edit:ghostty")?.name == "Ghostty")
        #expect(AppConfigs.config(inAction: "configs.edit:nope") == nil)
        #expect(AppConfigs.config(inAction: "apps.editor") == nil)
    }

    // MARK: AI agents and their instructions (Sven 2026-10-10)

    /// A home with Claude Code, Codex and Hermes as on Sven's Mac: two Hermes profiles (one with no config), a folder that
    /// is not a profile, secrets beside the configs, and ~/code with two repos briefed and one not.
    private func agentsHome() throws -> URL {
        let home = try home(), fm = FileManager.default
        let write = { (path: String, text: String) in
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write(".claude/settings.json", "{}\n")
        try write(".claude/CLAUDE.md", "# Claude\n")
        try write(".codex/config.toml", "model = \"x\"\n")
        try write(".codex/auth.json", "{\"token\": \"no\"}\n")
        try write(".hermes/config.yaml", "model: x\n")
        try write(".hermes/.env", "KEY=no\n")
        try write(".hermes/profiles/harry/config.yaml", "model: x\n")
        try write(".hermes/profiles/harry/SOUL.md", "# Harry\n")
        try write(".hermes/profiles/dobby/SOUL.md", "# Dobby\n")
        try write(".hermes/profiles/.hidden/config.yaml", "x\n")
        try write(".empryo/config.json", "{}\n")
        try write("code/pilot/AGENTS.md", "# pilot\n")
        try write("code/agents/AGENTS.md", "# agents\n")
        try write("code/agents/deep/AGENTS.md", "# too deep\n")
        try fm.createDirectory(at: home.appendingPathComponent("code/notes"), withIntermediateDirectories: true)
        return home
    }

    @Test("AI agents: Claude Code, Codex, Hermes, each Hermes profile with a config, and Empryo show; no secret file, no hidden profile")
    func agents() throws {
        let home = try agentsHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AppConfigs.hermesProfiles(home: home) == ["dobby", "harry"])
        let result = AppConfigs.find(home: home)
        let agents = result.found.filter { $0.config.group == .agents }
        #expect(agents.map(\.config.id) == ["claude", "codex", "hermes", "hermes-harry", "empryo"])
        #expect(agents.first { $0.config.id == "hermes-harry" }?.config.name == "Hermes · harry")
        #expect(result.found.allSatisfy { !AppConfigs.holdsSecrets($0.path.path) })
        // A profile with no config is neither found nor listed as not on this Mac; opencode, which Pilot knows, is.
        #expect(!result.missing.contains { $0.id.hasPrefix("hermes-") } && result.missing.contains { $0.id == "opencode" })
    }

    @Test("A Hermes profile's config has a stable action id that resolves without a listing; a path in its name never does")
    func hermesAction() {
        let harry = AppConfigs.config(inAction: "configs.edit:hermes-harry")
        #expect(harry?.name == "Hermes · harry" && harry?.paths == [".hermes/profiles/harry/config.yaml"] && harry?.group == .agents)
        #expect(AppConfigs.config(inAction: "configs.edit:hermes-../x") == nil)
        #expect(AppConfigs.config(inAction: "configs.edit:hermes-") == nil)
        #expect(AppConfigs.config(inAction: "configs.edit:hermes")?.name == "Hermes")
    }

    @Test("Files holding keys are never configs: auth.json, .env files, credentials, keys")
    func secrets() {
        for path in [".codex/auth.json", ".hermes/.env", ".env.local", ".aws/credentials", "x/Credentials.json", "id.pem", "a.key"] {
            #expect(AppConfigs.holdsSecrets(path), "\(path)")
        }
        for path in [".claude/settings.json", ".hermes/config.yaml", ".codex/config.toml", "code/pilot/AGENTS.md"] {
            #expect(!AppConfigs.holdsSecrets(path), "\(path)")
        }
        #expect(AppConfigs.all(home: URL(filePath: "/nonexistent")).allSatisfy { $0.paths.allSatisfy { !AppConfigs.holdsSecrets($0) } })
    }

    @Test("Agent instructions: CLAUDE.md, each Hermes soul marked generated, each top-level repo's AGENTS.md and no deeper one")
    func instructions() throws {
        let home = try agentsHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let found = AgentInstructions.find(home: home)
        #expect(found.map(\.config.id) == ["claude-md", "soul-dobby", "soul-harry", "repo-agents", "repo-pilot"])
        #expect(found.map(\.config.group) == [.agentRules, .souls, .souls, .repos, .repos])
        #expect(found.filter(\.config.generated).map(\.config.id) == ["soul-dobby", "soul-harry"])
        #expect(found.first { $0.config.id == "repo-pilot" }?.path == home.appendingPathComponent("code/pilot/AGENTS.md"))
        #expect(!found.contains { $0.path.path.contains("deep") })
    }
}
