import Foundation
import Testing
@testable import PilotCore

/// Defaults as mockup D (card agent-bo-95422980): each config in one of three groups,
/// the dotfiles chip, when it changed in plain words, and the filter with its empty answer. Pure: no real home is read.
@Suite("Config cards")
struct ConfigCardsTests {
    @Test("Every known config sits in one group")
    func groups() {
        #expect(ConfigGroup.allCases.map(\.label) == ["Terminal and shell", "Windows and keys", "Code", "Agent settings", "Pilot", "Claude Code and Codex",
                                                     "Hermes souls", "Repos"])
        let group = Dictionary(uniqueKeysWithValues: AppConfigs.known.map { ($0.id, $0.group) })
        #expect(group["ghostty"] == .terminal && group["zsh"] == .terminal && group["fish"] == .terminal)
        #expect(group["aerospace"] == .windows && group["karabiner"] == .windows)
        #expect(group["git"] == .code && group["lazygit"] == .code && group["vscode"] == .code && group["neovim"] == .code)
        #expect(["claude", "claude-local", "codex", "hermes", "empryo", "opencode"].allSatisfy { group[$0] == .agents })
    }

    @Test("A config whose real file sits under a dotfiles folder is in dotfiles; a plain file or a link elsewhere is not")
    func dotfiles() {
        #expect(FoundConfig.inDotfiles(URL(filePath: "/Users/x/code/dotfiles/workstation/ghostty/config")))
        #expect(!FoundConfig.inDotfiles(URL(filePath: "/Users/x/.config/ghostty/config")))
        #expect(!FoundConfig.inDotfiles(URL(filePath: "/Users/x/code/notdotfiles/config")))
    }

    @Test("When a config changed, in plain words: minutes ago, hours ago today, yesterday, then its day and month, the year once it differs")
    func changed() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Malta"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 15, minute: 0)))
        func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let changed = { (date: Date) in AppConfigs.changed(date, now: now, calendar: calendar) }
        #expect(changed(now.addingTimeInterval(-20)) == "just now")
        #expect(changed(now.addingTimeInterval(-35 * 60)) == "35 min ago")
        #expect(changed(at(10, 7, 9)) == "6 h ago")
        #expect(changed(at(10, 6, 23, 50)) == "yesterday")
        #expect(changed(at(9, 21, 12)) == "21 Sep")
        #expect(changed(at(12, 2, 12, year: 2025)) == "2 Dec 2025")
    }

    @Test("The filter matches a name or a path, any case; All and In dotfiles narrow it")
    func filter() {
        let configs = [Self.found("ghostty", linked: true), Self.found("zsh", linked: false), Self.found("skhd", linked: true)]
        #expect(AppConfigs.filter(configs, query: "", by: .all).map(\.config.id) == ["ghostty", "zsh", "skhd"])
        #expect(AppConfigs.filter(configs, query: "GHOST", by: .all).map(\.config.id) == ["ghostty"])
        #expect(AppConfigs.filter(configs, query: ".zshrc", by: .all).map(\.config.id) == ["zsh"])
        #expect(AppConfigs.filter(configs, query: "", by: .dotfiles).map(\.config.id) == ["ghostty", "skhd"])
    }

    @Test("A filter that finds nothing names the config it would have been and the first path Pilot looks at")
    func notHere() {
        let missing = AppConfigs.known.filter { $0.id == "neovim" || $0.id == "tmux" }
        let looked = AppConfigs.notHere(query: "nvim", missing: missing)
        #expect(looked?.config.name == "Neovim" && looked?.path == "~/.config/nvim/init.lua")
        #expect(AppConfigs.notHere(query: "tmux", missing: missing)?.path == "~/.tmux.conf")
        #expect(AppConfigs.notHere(query: "emacs", missing: missing) == nil)
        #expect(AppConfigs.notHere(query: "", missing: missing) == nil)
    }

    @Test("A kind's name splits into its title and what it covers: Web links over http, https; Markdown over .md")
    func kindTitles() throws {
        let kinds = FileKinds.groups.flatMap(\.kinds)
        let web = try #require(kinds.first { $0.id == "web" }), md = try #require(kinds.first { $0.id == "net.daringfireball.markdown" })
        #expect(web.title == "Web links" && web.detail == "http, https")
        #expect(md.title == "Markdown" && md.detail == ".md")
        let png = try #require(kinds.first { $0.id == "public.png" })
        #expect(png.title == "PNG" && png.detail == nil)
    }

    @Test("A card's path shortens from the middle so its file always shows: the full path, then the first two parts, …, the last two, then … and the last two")
    func shortenings() {
        #expect(AppConfigs.shortenings("~/Library/Application Support/lazygit/config.yml")
                == ["~/Library/Application Support/lazygit/config.yml", "~/Library/…/lazygit/config.yml", "…/lazygit/config.yml"])
        #expect(AppConfigs.shortenings("~/.config/karabiner/karabiner.json") == ["~/.config/karabiner/karabiner.json", "…/karabiner/karabiner.json"])
        #expect(AppConfigs.shortenings("~/.config/ghostty/config") == ["~/.config/ghostty/config", "…/ghostty/config"])
        #expect(AppConfigs.shortenings("~/.zshrc") == ["~/.zshrc"])
        #expect(AppConfigs.shortenings("~/.hammerspoon/init.lua") == ["~/.hammerspoon/init.lua"])
    }

    @Test("A config names the apps whose icon its card shows: Ghostty, AeroSpace, Karabiner's settings app; a shell config none")
    func bundles() {
        let bundles = Dictionary(uniqueKeysWithValues: AppConfigs.known.map { ($0.id, $0.bundles) })
        #expect(bundles["ghostty"] == ["com.mitchellh.ghostty"] && bundles["aerospace"] == ["bobko.aerospace"])
        #expect(bundles["karabiner"]?.first == "org.pqrs.Karabiner-Elements.Settings" && bundles["vscode"] == ["com.microsoft.VSCode"])
        #expect(bundles["zsh"] == [] && bundles["git"] == [] && bundles["skhd"] == [])
        #expect(bundles["claude"] == ["com.anthropic.claudefordesktop"] && bundles["empryo"] == ["dev.empryo.desktop"])
    }

    @Test("A preview line is a comment, a setting (its key lit), or plain text")
    func previewLines() {
        #expect(AppConfigs.previewLine("theme = Ayu Tokyo Night") == .setting(key: "theme", rest: " = Ayu Tokyo Night"))
        #expect(AppConfigs.previewLine("font-family = Iosevka Nerd Font") == .setting(key: "font-family", rest: " = Iosevka Nerd Font"))
        #expect(AppConfigs.previewLine("  \"editor.fontSize\": 13,") == .setting(key: "  \"editor.fontSize\"", rest: ": 13,"))
        #expect(AppConfigs.previewLine("gui:") == .setting(key: "gui", rest: ":"))
        #expect(AppConfigs.previewLine("# Shared by Ghostty.app") == .comment)
        #expect(AppConfigs.previewLine("  -- a Lua comment") == .comment)
        #expect(AppConfigs.previewLine("// a JSON comment") == .comment)
        #expect(AppConfigs.previewLine("[core]") == .plain)
        #expect(AppConfigs.previewLine("https://example.com") == .plain)
        #expect(AppConfigs.previewLine("alias ll='ls -la'") == .plain)
        #expect(AppConfigs.previewLine("") == .plain)
    }

    /// A found config at a made-up path: linked ones resolve into ~/code/dotfiles only on a real disk, so the filter
    /// is asked through `inDotfiles`, given here.
    static func found(_ id: String, linked: Bool) -> ConfigCard {
        let config = AppConfigs.known.first { $0.id == id }!
        return ConfigCard(config: config, path: "~/" + config.paths[0], inDotfiles: linked)
    }
}
