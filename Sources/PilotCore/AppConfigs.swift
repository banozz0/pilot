import Foundation

/// The groups Configs shows configs in (mockup D, card agent-bo-95422980; Pilot, Q261), then Configs › Agents' groups:
/// the agents' settings (Sven 2026-10-10; moved off Configs 2026-10-19) and their instruction files.
public enum ConfigGroup: CaseIterable, Sendable {
    case terminal, windows, code, agents, pilot
    case agentRules, souls, repos

    public var label: String {
        switch self {
        case .terminal: "Terminal and shell"
        case .windows: "Windows and keys"
        case .code: "Code"
        case .agents: "Agent settings"
        case .pilot: "Pilot"
        case .agentRules: "Claude Code and Codex"
        case .souls: "Hermes souls"
        case .repos: "Repos"
        }
    }
}

/// One app's config file, by the paths under home where the app looks for it, most likely first.
public struct AppConfig: Equatable, Sendable {
    public let id: String, name: String
    public let paths: [String]
    public let group: ConfigGroup
    /// The apps whose icon its card shows, the first installed winning; none for a shell or a command-line tool.
    public var bundles: [String] = []
    /// A file another tool renders (a Hermes SOUL): its card says generated, as an edit to it is overwritten.
    public var generated = false
    /// Pilot's own file (Q261): previewed and shown in Finder, never opened in an editor from Configs.
    public var readOnly = false

    /// Its name or id holds `query`, any case.
    func isNamed(_ query: String) -> Bool { name.localizedCaseInsensitiveContains(query) || id.localizedCaseInsensitiveContains(query) }
}

/// A config found in a home folder: the path the app reads, the file it really is once symlinks are followed (in
/// ~/code/dotfiles on Sven's Mac) and when that file last changed, each read when asked, as the menu needs neither.
public struct FoundConfig: Equatable, Sendable {
    public let config: AppConfig
    public let path: URL
    public var real: URL { path.resolvingSymlinksInPath() }
    public var modified: Date? { (try? FileManager.default.attributesOfItem(atPath: real.path))?[.modificationDate] as? Date }
    public var isLinked: Bool { path != real }
    /// Defaults' dotfiles chip: the real file sits in a folder named dotfiles.
    public static func inDotfiles(_ real: URL) -> Bool { real.pathComponents.contains("dotfiles") }
}

/// One config card on Defaults: the config, its path written with ~, and whether it lives in dotfiles.
public struct ConfigCard: Equatable, Sendable {
    public let config: AppConfig
    public let path: String
    public let inDotfiles: Bool

    public init(config: AppConfig, path: String, inDotfiles: Bool) { self.config = config; self.path = path; self.inDotfiles = inDotfiles }
}

/// Defaults' filter chips: every config, the ones in dotfiles.
public enum ConfigFilter: CaseIterable, Sendable {
    case all, dotfiles

    public var label: String {
        switch self {
        case .all: "All"
        case .dotfiles: "In dotfiles"
        }
    }

    public func keeps(_ card: ConfigCard) -> Bool {
        switch self {
        case .all: true
        case .dotfiles: card.inDotfiles
        }
    }
}

/// Configs (card agent-bo-95422841, Sven 2026-10-05: "a space in pilot app so we see configs of apps like ghosty, neovim
/// etc"): the configs of known apps, shown read-only and opened in the main editor; Pilot never edits them.
public enum AppConfigs {
    public static let known: [AppConfig] = [
        .init(id: "ghostty", name: "Ghostty", paths: [".config/ghostty/config", ".config/ghostty/config.ghostty",
                                                      "Library/Application Support/com.mitchellh.ghostty/config"], group: .terminal, bundles: ["com.mitchellh.ghostty"]),
        .init(id: "neovim", name: "Neovim", paths: [".config/nvim/init.lua", ".config/nvim/init.vim"], group: .code),
        .init(id: "aerospace", name: "AeroSpace", paths: [".aerospace.toml", ".config/aerospace/aerospace.toml"], group: .windows, bundles: ["bobko.aerospace"]),
        .init(id: "zsh", name: "zsh", paths: [".zshrc"], group: .terminal),
        .init(id: "zshenv", name: "zsh environment", paths: [".zshenv"], group: .terminal),
        .init(id: "zprofile", name: "zsh login", paths: [".zprofile"], group: .terminal),
        .init(id: "git", name: "git", paths: [".gitconfig", ".config/git/config"], group: .code),
        .init(id: "starship", name: "Starship", paths: [".config/starship.toml"], group: .terminal),
        .init(id: "tmux", name: "tmux", paths: [".tmux.conf", ".config/tmux/tmux.conf"], group: .terminal),
        .init(id: "lazygit", name: "lazygit", paths: ["Library/Application Support/lazygit/config.yml", ".config/lazygit/config.yml"], group: .code),
        .init(id: "hammerspoon", name: "Hammerspoon", paths: [".hammerspoon/init.lua"], group: .windows, bundles: ["org.hammerspoon.Hammerspoon"]),
        .init(id: "karabiner", name: "Karabiner-Elements", paths: [".config/karabiner/karabiner.json"], group: .windows, bundles: ["org.pqrs.Karabiner-Elements.Settings", "org.pqrs.Karabiner-Elements.Preferences"]),
        .init(id: "vscode", name: "VS Code", paths: ["Library/Application Support/Code/User/settings.json"], group: .code, bundles: ["com.microsoft.VSCode"]),
        .init(id: "zed", name: "Zed", paths: [".config/zed/settings.json"], group: .code, bundles: ["dev.zed.Zed"]),
        .init(id: "wezterm", name: "WezTerm", paths: [".wezterm.lua", ".config/wezterm/wezterm.lua"], group: .terminal, bundles: ["com.github.wez.wezterm"]),
        .init(id: "kitty", name: "kitty", paths: [".config/kitty/kitty.conf"], group: .terminal, bundles: ["net.kovidgoyal.kitty"]),
        .init(id: "alacritty", name: "Alacritty", paths: [".config/alacritty/alacritty.toml"], group: .terminal, bundles: ["org.alacritty"]),
        .init(id: "fish", name: "fish", paths: [".config/fish/config.fish"], group: .terminal),
        .init(id: "helix", name: "Helix", paths: [".config/helix/config.toml"], group: .code),
        .init(id: "skhd", name: "skhd", paths: [".config/skhd/skhdrc", ".skhdrc"], group: .windows),
        .init(id: "yabai", name: "yabai", paths: [".config/yabai/yabairc", ".yabairc"], group: .windows),
        .init(id: "claude", name: "Claude Code", paths: [".claude/settings.json"], group: .agents, bundles: [claudeApp]),
        .init(id: "claude-local", name: "Claude Code · local", paths: [".claude/settings.local.json"], group: .agents, bundles: [claudeApp]),
        .init(id: "codex", name: "Codex", paths: [".codex/config.toml"], group: .agents),
        .init(id: "hermes", name: "Hermes", paths: [".hermes/config.yaml"], group: .agents),
        .init(id: "empryo", name: "Empryo", paths: [".empryo/config.json"], group: .agents, bundles: ["dev.empryo.desktop"]),
        .init(id: "opencode", name: "opencode", paths: [".config/opencode/opencode.json"], group: .agents),
    ]

    static let claudeApp = "com.anthropic.claudefordesktop"

    /// Pilot's own files (Sven 2026-10-17, Q261), read-only and only when there: never a menu row, never Not on this Mac.
    /// Its settings live in macOS defaults, a binary plist, so no settings file is listed.
    public static let pilotFiles: [AppConfig] = [
        .init(id: "pilot-binds", name: "Binds", paths: ["Library/Application Support/Pilot/binds.json"], group: .pilot, readOnly: true),
        .init(id: "pilot-workspace-presets", name: "Workspace presets", paths: ["Library/Application Support/Pilot/workspace-presets.json"],
              group: .pilot, readOnly: true),
    ]

    // MARK: AI agents

    /// Hermes' profiles: the folders in ~/.hermes/profiles, one listing, nothing read, sorted.
    public static func hermesProfiles(home: URL) -> [String] {
        let folder = home.appendingPathComponent(".hermes/profiles")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(isPlainName).sorted()
    }

    /// A name fit for a path part: no dot first, no slash.
    static func isPlainName(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") }

    private static let hermesPrefix = "hermes-"

    /// One Hermes profile's config, its id `hermes-<profile>`, so its action and bind survive a relaunch.
    static func hermesProfile(_ profile: String) -> AppConfig {
        .init(id: hermesPrefix + profile, name: "Hermes · \(profile)", paths: [".hermes/profiles/\(profile)/config.yaml"], group: .agents)
    }

    /// Every config Pilot looks for in `home`: the known ones, each Hermes profile's right after Hermes'.
    public static func all(home: URL) -> [AppConfig] {
        var all = known
        all.insert(contentsOf: hermesProfiles(home: home).map(hermesProfile), at: (all.firstIndex { $0.id == "hermes" } ?? all.count - 1) + 1)
        return all
    }

    /// Files that hold keys rather than settings; never a config here, so never read or shown.
    public static func holdsSecrets(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name == "auth.json" || name.hasPrefix(".env") || name.contains("credential") || name.hasSuffix(".pem") || name.hasSuffix(".key")
    }

    /// Each config's first path that is a file (a link to one counts), never one holding secrets, and the known configs
    /// with none; nil looks for every config (`all`).
    public static func find(home: URL, among configs: [AppConfig]? = nil) -> (found: [FoundConfig], missing: [AppConfig]) {
        var found: [FoundConfig] = [], missing: [AppConfig] = []
        for config in configs ?? all(home: home) {
            let file = config.paths.lazy.filter { !holdsSecrets($0) }.map { home.appendingPathComponent($0) }.first { url in
                var folder: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && !folder.boolValue
            }
            guard let file else {
                if known.contains(config) { missing.append(config) }
                continue
            }
            found.append(FoundConfig(config: config, path: file))
        }
        return (found, missing)
    }

    /// A path with the home folder written ~.
    public static func tilde(_ path: String, home: String) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: cards

    /// When a config changed, in the words Defaults shows: "just now", "35 min ago", "6 h ago", "yesterday", "21 Sep",
    /// "2 Dec 2025" once the year differs.
    public static func changed(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) h ago" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style.locale(Locale(identifier: "en_GB")))
    }

    /// The cards whose name, id or path holds `query` (any case), else, when none, those a typo of it names
    /// (FuzzyRanker.Filter), narrowed by the chip picked.
    public static func filter(_ cards: [ConfigCard], query: String, by filter: ConfigFilter) -> [ConfigCard] {
        let typed = FuzzyRanker.Filter(query)
        return typed.filter(cards.filter(filter.keeps)) { [$0.config.name, $0.config.id, $0.path] }
    }

    /// The missing config a filter that found nothing was after, and the first place Pilot looks for it: "nvim" names
    /// Neovim at ~/.config/nvim/init.lua.
    public static func notHere(query: String, missing: [AppConfig]) -> (config: AppConfig, path: String)? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        return missing.lazy.compactMap { config in
            let path = config.isNamed(query) ? config.paths.first : config.paths.first { $0.localizedCaseInsensitiveContains(query) }
            return path.map { (config, "~/" + $0) }
        }.first
    }

    /// A card's path, longest first, each shorter one cut from the middle so the file always shows:
    /// "~/Library/Application Support/lazygit/config.yml", "~/Library/…/lazygit/config.yml", "…/lazygit/config.yml".
    /// The card shows the first that fits.
    public static func shortenings(_ path: String) -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let tail = parts.suffix(2).joined(separator: "/")
        let cuts = (parts.count > 4 ? [parts.prefix(2).joined(separator: "/") + "/…/" + tail] : []) + ["…/" + tail]
        return [path] + cuts.filter { $0.count < path.count }
    }

    // MARK: preview

    /// One line of a preview as Defaults colours it: a comment muted, a setting's key lit, the rest plain.
    public enum PreviewLine: Equatable, Sendable {
        case comment
        /// `key` with its indent and quotes, `rest` from the = or : on.
        case setting(key: String, rest: String)
        case plain
    }

    public static func previewLine(_ line: String) -> PreviewLine {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if ["#", "//", "--", ";"].contains(where: trimmed.hasPrefix) { return .comment }
        guard let match = line.wholeMatch(of: settingLine) else { return .plain }
        return .setting(key: String(match.output.key), rest: String(match.output.rest))
    }

    /// A key (letters, digits, . _ - @, quoted or not) then = or a : ending the key; a : that starts a URL is not one.
    nonisolated(unsafe) private static let settingLine = /(?<key>[ \t]*"?[\w.@-]+"?)(?<rest>[ \t]*(?:=|:(?=[ \t]|$)).*)/

    public enum Preview: Equatable, Sendable {
        /// The text, secrets hidden; `cut` when the file is longer than the cap.
        case text(String, cut: Bool)
        case notText
        case unreadable(String)
    }

    public static let previewCap = 64 * 1024

    /// The file's first `cap` bytes, ending on a line, with secrets hidden (hidingSecrets).
    public static func preview(_ url: URL, cap: Int = previewCap) -> Preview {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: cap + 1) ?? Data()
        } catch {
            return .unreadable(error.localizedDescription)
        }
        let cut = data.count > cap
        var kept = data.prefix(cap)
        if cut, let lastLine = kept.lastIndex(of: UInt8(ascii: "\n")) { kept = kept[...lastLine] }
        guard let text = String(data: kept, encoding: .utf8), !text.contains("\0") else { return .notText }
        return .text(hidingSecrets(text), cut: cut)
    }

    /// A card's glimpse of a config: its first `count` lines that say something, blank ones skipped and trailing spaces
    /// trimmed, secrets as dots (hidingSecrets).
    public static func head(_ text: String, _ count: Int) -> [String] {
        Array(hidingSecrets(text).components(separatedBy: "\n").lazy
            .map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
            .filter { !$0.isEmpty }
            .prefix(count))
    }

    /// The value after a key naming a token, secret, password, credential or API key, written as dots, so a preview
    /// on a shared screen never shows one.
    public static func hidingSecrets(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let lower = line.lowercased()
            guard secretWords.contains(where: lower.contains), let match = line.firstMatch(of: secretLine) else { return line }
            return String(line[..<match.output.value.startIndex]) + "••••••"
        }.joined(separator: "\n")
    }

    /// A cheap look before the pattern, which most lines fail.
    private static let secretWords = ["token", "secret", "passw", "credential", "api"]
    nonisolated(unsafe) private static let secretLine =
        /(?i)(?:token|secret|passw(?:or)?d|credential|api[_-]?key)[^=:\n]*["']?\s*[=:]\s*(?<value>\S.*)/

    // MARK: menu

    /// Hyper+Space › Config › <app>: `configs.edit:<id>` opens that config in the main editor.
    public static func actionID(_ id: String) -> String { "configs.edit:" + id }
    /// The config an action edits: a known one, or a Hermes profile's by its name.
    public static func config(inAction action: String) -> AppConfig? {
        guard action.hasPrefix(actionID("")) else { return nil }
        let id = String(action.dropFirst(actionID("").count))
        if let config = known.first(where: { $0.id == id }) { return config }
        guard id.hasPrefix(hermesPrefix), case let profile = String(id.dropFirst(hermesPrefix.count)), isPlainName(profile) else { return nil }
        return hermesProfile(profile)
    }
}
