import Foundation

/// What macOS asks for a role's system default: the app for a URL, or for a kind of file.
public enum DefaultHandler: Hashable, Sendable {
    case url(String), contentType(String)
}

/// The apps Hyper+letter reaches by role (SPEC.md stories 17 and 18). Each role resolves to one bundle identifier:
/// a known alternative when installed, else the system default, else Apple's own app. The editor (card agent-bo-95422840)
/// puts the Mac's default for text first, when it is an editor. AI falls back to a website and Agent names a command,
/// not an app (Sven's Q462): `target` says which a value is.
public enum AppRole: String, CaseIterable, Codable, Sendable {
    case terminal, browser, files, notes, music, mail, calendar, messages, passwords, activityMonitor, editor, ai, agent

    /// What a role's pick or resolution names: an app's bundle id, a website (Q463), or Agent's command.
    public enum Target: Equatable, Sendable { case app(String), web(URL), command(String) }

    public func target(_ value: String) -> Target {
        if self == .agent { return .command(value) }
        if value.hasPrefix("https://") || value.hasPrefix("http://"), let url = URL(string: value), url.host != nil { return .web(url) }
        return .app(value)
    }

    /// Whether `value` is on this Mac: a website always, Agent's command when `found`, an app when `installed`.
    public func has(_ value: String, installed: (String) -> Bool, found: (String) -> Bool) -> Bool {
        switch target(value) {
        case .web: true
        case .command(let command): found(command)
        case .app(let bundle): installed(bundle)
        }
    }

    public var label: String {
        switch self {
        case .terminal: "Terminal"
        case .browser: "Browser"
        case .files: "Files"
        case .notes: "Notes"
        case .music: "Music"
        case .mail: "Mail"
        case .calendar: "Calendar"
        case .messages: "Chat"   // Messages or any chat app (Q462): the id stays apps.messages, so binds keep their row
        case .passwords: "Passwords"
        case .activityMonitor: "Activity Monitor"
        case .editor: "Editor"
        case .ai: "AI"
        case .agent: "Agent"
        }
    }

    /// Known alternatives, most preferred first. The first one installed wins over the system default.
    public var alternatives: [String] {
        switch self {
        case .terminal: ["com.mitchellh.ghostty", "com.googlecode.iterm2"]
        case .notes: ["md.obsidian"]
        case .passwords: ["com.1password.1password", "com.bitwarden.desktop"]
        case .editor: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4"]
        case .ai: ["com.anthropic.claudefordesktop", "com.openai.chat"]
        case .agent: ["claude", "codex", "gemini", "opencode"]
        default: []
        }
    }

    /// What macOS is asked for this role's system default, in turn.
    public var defaultHandlers: [DefaultHandler] {
        switch self {
        case .browser: [.url("https://example.com")]
        case .mail: [.url("mailto:someone@example.com")]
        case .calendar: [.url("webcal://example.com/calendar.ics")]
        case .editor: [.contentType("public.plain-text"), .contentType("public.source-code")]
        default: []
        }
    }

    /// The editors a text default counts as the editor for: VS Code and its forks, Zed, Sublime Text, CotEditor, BBEdit, Nova,
    /// MacVim and Neovide. Xcode and TextEdit claim source code and plain text as they install, so they say nothing of a choice.
    public static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4", "com.sublimetext.3",
        "com.coteditor.CotEditor", "com.barebones.bbedit", "com.panic.Nova", "org.vim.MacVim", "com.neovide.neovide",
    ]

    /// Apple's own app, the last resort; AI's is a website and Agent's Claude Code, which has no Apple app.
    public var appleApp: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .browser: "com.apple.Safari"
        case .files: "com.apple.finder"
        case .notes: "com.apple.Notes"
        case .music: "com.apple.Music"
        case .mail: "com.apple.mail"
        case .calendar: "com.apple.iCal"
        case .messages: "com.apple.MobileSMS"
        case .passwords: "com.apple.Passwords"
        case .activityMonitor: "com.apple.ActivityMonitor"
        case .editor: "com.apple.TextEdit"
        case .ai: "https://claude.ai"
        case .agent: "claude"
        }
    }

    /// Pure resolution: `installed` says whether a bundle id (Agent: a command) is on this Mac, `handler` gives the default app macOS has.
    /// The app resolves the editor every time and caches the other roles, re-resolving when the cached app is gone.
    public func resolve(installed: (String) -> Bool, handler: (DefaultHandler) -> String?) -> String {
        let system = defaultHandlers.lazy.compactMap(handler)
        if self == .editor, let h = system.first(where: Self.editors.contains) { return h }
        if let alt = alternatives.first(where: installed) { return alt }
        if self != .editor, let h = system.first { return h }
        return appleApp
    }
}
