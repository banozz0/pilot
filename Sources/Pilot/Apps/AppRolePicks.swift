import Foundation
import Observation
import PilotCore

/// Open with › Apps for keys (story 160; on Defaults until C3): the app each role key opens, Sven's pick while it is
/// installed, else Automatic, the first known alternative installed, then macOS's own (story 18). Music, Chat, AI and
/// Mail can pick a website too (Q463), and Agent a coding agent's command (Q462). The editor keeps its own card
/// (EditorChoice); Browser's and Mail's Automatic follow macOS's defaults, set under Opens with.
@Observable @MainActor
final class AppRolePicks {
    static let shared = AppRolePicks()

    /// The roles with a pick, in the block's order.
    static let roles: [AppRole] = [.terminal, .agent, .browser, .files, .messages, .ai, .mail, .notes, .music, .passwords]

    /// Each role's known apps (Agent: commands), offered in the picker when installed; "Other app…" picks any.
    static func candidates(_ role: AppRole) -> [String] {
        switch role {
        case .terminal: ["com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                         "com.github.wez.wezterm", "org.alacritty", "com.apple.Terminal"]
        case .browser: ["app.zen-browser.zen", "company.thebrowser.Browser", "company.thebrowser.dia", "com.google.Chrome",
                        "com.brave.Browser", "org.mozilla.firefox", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
                        "com.kagi.kagimacOS", "com.apple.Safari"]
        case .messages: ["com.hnc.Discord", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
                         "org.whispersystems.signal-desktop", "com.apple.MobileSMS"]
        case .mail: ["com.readdle.SparkDesktop", "com.mimestream.Mimestream", "com.microsoft.Outlook", "com.apple.mail"]
        case .notes: ["md.obsidian", "net.shinyfrog.bear", "notion.id", "com.logseq.logseq", "com.apple.Notes"]
        case .passwords: ["com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords"]
        case .music: ["com.spotify.client", "com.apple.Music"]
        case .ai, .agent: role.alternatives
        default: role.alternatives + [role.appleApp]
        }
    }

    /// Sites a key can open in the default browser instead of an app (Q463), always offered; AppsModule.openWeb prefers
    /// a web app made for the site.
    static func websites(_ role: AppRole) -> [String] { sites.filter { $0.role == role }.map(\.url) }

    private static let sites: [(role: AppRole, url: String, name: String)] = [
        (.music, "https://open.spotify.com", "Spotify web"), (.music, "https://music.youtube.com", "YouTube Music web"),
        (.messages, "https://discord.com/app", "Discord web"),
        (.ai, "https://claude.ai", "claude.ai"), (.ai, "https://chatgpt.com", "chatgpt.com"),
        (.mail, "https://mail.google.com", "Gmail web"),
    ]

    /// A pick as the picker names it: Pilot's own (Files' window or Notes' quick notes, by `role`), a known site or
    /// agent, else the app's name, else the value.
    static func name(_ value: String, role: AppRole? = nil, appName: (String) -> String?) -> String {
        if value == pilot { return role == .files ? "Pilot Files" : "Pilot quick notes" }
        if let known = sites.first(where: { $0.url == value })?.name ?? agents[value] { return known }
        return appName(value) ?? URL(string: value)?.host ?? value
    }

    private static let agents = ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "opencode": "opencode"]

    /// Pilot itself, the Notes key's choice of quick notes (Sven 2026-10-11) and the Files key's choice of the Pilot Files
    /// window (Q800): always offered, as it needs no install; the Notes key toggles the quick notes panel, the Files key
    /// brings Pilot Files forward (AppsModule).
    static let pilot = "dev.banozz.pilot"

    private(set) var picks: [AppRole: String]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installed: @MainActor (String) -> Bool
    @ObservationIgnored private let found: @MainActor (String) -> Bool

    /// `installed` says whether an app is on the Mac, `found` whether Agent's command is.
    init(defaults: UserDefaults = .pilot(), installed: @escaping @MainActor (String) -> Bool = AppsModule.isInstalled,
         found: @escaping @MainActor (String) -> Bool = { AppsModule.command($0) != nil }) {
        self.defaults = defaults
        self.installed = installed
        self.found = found
        picks = Dictionary(uniqueKeysWithValues: Self.roles.compactMap { role in defaults.string(forKey: Self.key(role)).map { (role, $0) } })
    }

    private static func key(_ role: AppRole) -> String { "apps.pick.\(role.rawValue)" }

    /// The picked app while it is installed (a website always is); nil is Automatic.
    func app(_ role: AppRole) -> String? { picks[role].flatMap { has(role, $0) ? $0 : nil } }

    /// Whether `value` is there for `role`: a website always, Agent's command when found, an app when installed.
    func has(_ role: AppRole, _ value: String) -> Bool {
        value == Self.pilot || role.has(value, installed: installed, found: found)
    }

    /// Picks `bundle` for `role`; nil goes back to Automatic.
    func set(_ role: AppRole, _ bundle: String?) {
        picks[role] = bundle
        defaults.set(bundle, forKey: Self.key(role))
    }

    /// The picker's choices: Pilot for Notes and Files, the role's known apps that are installed, its websites, and the
    /// pick, each once.
    func choices(_ role: AppRole) -> [String] {
        var seen = Set<String>()
        let pilot = role == .notes || role == .files ? [Self.pilot] : []
        let known = Self.candidates(role).filter { has(role, $0) }
        return (pilot + known + Self.websites(role) + [picks[role]].compactMap { $0 }).filter { seen.insert($0).inserted }
    }
}
