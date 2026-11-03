import Foundation

/// One page of Pilot's app window (story 40; layout rework C3, Sven 2026-10-10, design Wa6fPGPUhV2VcmJ4vGXZQ5): the window
/// is where every setting lives, each on the page of the thing it changes. Each sits in an AppArea
/// (2026-10-11).
/// Sven 2026-10-10 ("the sidebar maybe needs to be better split"): Snippets left Clipboard for a page of its own, Files is
/// new (the file converter, and File search from Menu), and the tools you use all day sit in a Tools group. Stats left
/// Activity for a page of its own after it (Sven 2026-10-10: "set Stats as its own page under Activity").
/// Voice holds Dictation (was on Open with) and Read aloud (was System › Keyboard), so both sit with the tools (2026-10-16).
/// Page map (Sven, 2026-10-17, Q207-Q211): Agent instructions is Configs' Agents tab, Ask is AI. The menu's page is Launcher, in an
/// area of its own (P37, Sven 2026-10-18, Q284, Q285); still `menu` in links. Update & Clean left the top of Activity ›
/// Reports for a Mac page of its own (Sven 2026-10-20: "update and clean should be in the Pilot app under Mac"). Fonts left
/// Install for a page of its own after Configs (Sven, 2026-11-01: "for fonts i think its better to have its own page").
/// Repos (Pilot 1.0.2, Sven Q716) browses own repos' files after Configs; it and Configs are developer pages (isDeveloper).
public enum AppPage: String, CaseIterable, Sendable {
    case home, binds, menu, workspaces, tiling, menuBar, look, system, activity, upkeep, stats, clipboard, captures, snippets, notes, files, ai, voice,
         install, openWith, configs, repos, fonts, general, extensions, widgets

    /// The area the page sits in (window directions, Sven 2026-10-11).
    public var area: AppArea { AppArea.allCases.first { $0.pages.contains(self) } ?? .home }

    public var title: String {
        switch self {
        case .home: "Home"
        case .binds: "Binds"
        case .menu: "Launcher"
        case .workspaces: "Workspaces"
        case .tiling: "Tiling"
        case .menuBar: "Menu bar"
        case .look: "Look"
        case .system: "System"
        case .activity: "Activity"
        case .upkeep: "Update & Clean"
        case .stats: "Stats"
        case .clipboard: "Clipboard"
        case .captures: "Captures"
        case .snippets: "Snippets"
        case .notes: "Notes"
        case .files: "Files"
        case .install: "Install"
        case .openWith: "Open with"
        case .configs: "Configs"
        case .repos: "Repos"
        case .fonts: "Fonts"
        case .general: "General"
        case .ai: "AI"
        case .voice: "Voice"
        case .extensions: "Extensions"
        case .widgets: "Widgets"
        }
    }

    /// The page's SF Symbol.
    public var symbol: String {
        switch self {
        case .home: "house"
        case .binds: "command"
        case .menu: "text.magnifyingglass"
        case .workspaces: "square.grid.2x2"
        case .tiling: "rectangle.split.3x1"
        case .menuBar: "menubar.rectangle"
        case .look: "paintpalette"
        case .system: "slider.horizontal.3"
        case .activity: "gauge.with.dots.needle.67percent"
        case .upkeep: "arrow.triangle.2.circlepath"
        case .stats: "chart.xyaxis.line"
        case .clipboard: "doc.on.clipboard"
        case .captures: "camera.viewfinder"
        case .snippets: "text.quote"
        case .notes: "note.text"
        case .files: "doc.on.doc"
        case .install: "shippingbox"
        case .openWith: "arrow.up.forward.app"
        case .configs: "doc.badge.gearshape"
        case .repos: "arrow.triangle.branch"
        case .fonts: "textformat"
        case .general: "gearshape"
        case .ai: "sparkles"
        case .voice: "waveform"
        case .extensions: "puzzlepiece.extension"
        case .widgets: "square.grid.2x2"
        }
    }

    /// Calm's squircle colour: a module colour, 0 to 5.
    public var colour: Int {
        switch self {
        case .home, .clipboard, .captures, .upkeep: 0
        case .binds, .look, .ai, .snippets, .widgets: 1
        case .workspaces, .tiling, .system, .voice: 2
        case .menu, .menuBar, .general, .activity: 3
        case .install, .extensions, .files, .stats, .fonts, .repos: 4
        case .openWith, .configs, .notes: 5
        }
    }

    /// Developer pages (Pilot 1.0.2, Sven Q715): Configs, with its Agents tab, and Repos show only while General's Developer
    /// switch is on; off, the sidebar, the searches and `pilot open` leave them out and nothing reads their files.
    public var isDeveloper: Bool { self == .configs || self == .repos }

    /// The parts a page holds as tabs or places on it (Binds' conflicts open as a sheet, not a tab).
    public var sections: [AppSection] { AppSection.allCases.filter { $0.page == self } }

    /// Pages whose own content is their first tab, before their parts, or whose parts are places on it (General, Look); every
    /// other page with parts is its parts. Look opens on its top, its Wallpaper a place on it.
    public var hasOwnContent: Bool { [.binds, .menu, .activity, .files, .general, .extensions, .configs, .ai, .captures, .look].contains(self) }

    /// The part a page opens on: none for a page with its own content, else its first.
    public var firstSection: AppSection? { hasOwnContent ? nil : sections.first }

    /// The tabs in a page's header, at every window width (P36, Sven 2026-10-18, Q267): its own content first when it has
    /// some, then its parts; none for a single page.
    public var tabs: [(value: AppSection?, title: String)] {
        let parts = sections.filter(\.isTab).map { (value: Optional($0), title: $0.title) }
        guard !parts.isEmpty else { return [] }
        return hasOwnContent ? [(nil, ownTitle)] + parts : parts
    }

    /// The tab of a page's own content: Menu's the rows Hyper+Space shows, Activity's what runs now.
    var ownTitle: String {
        switch self {
        case .binds: "Keyboard"
        case .menu: "Your menu"
        case .activity: "Now"
        case .files: "Convert"
        case .configs: "Apps"
        case .ai: "Chat"
        case .captures: "Capture"
        default: title
        }
    }

    /// The settings the page itself holds, so the search lands on it from a setting's name.
    var keywords: [String] {
        switch self {
        case .home: ["status", "most used", "problems", "needs you", "this mac", "switch", "bad day", "pilot on/off"]
        case .binds: ["bind", "key", "shortcut", "preset", "omarchy", "my binds", "sublayer", "reset"]
        case .menu: ["launcher", "menu", "hyper+space", "root", "menu rows", "pin", "order", "translate", "translation", "language"]
        case .snippets: ["snippet", "keyword", "text expansion", "expand", "placeholder", "template"]
        case .files: ["convert", "converter", "format", "png", "jpg", "heic", "webp", "pdf", "mp4", "mov", "mp3", "gif", "docx", "finder",
                      "right-click", "services"]
        case .workspaces: ["app rule", "always opens on", "layout", "float", "snapshot", "save", "restore", "reopen", "monitor", "display",
                           "swipe", "trackpad", "name", "delete workspace", "add workspace", "your widths", "own sizes"]
        case .tiling: ["gaps", "inner", "outer", "tiler", "rescue", "always float", "drag", "border", "focused window", "defocus", "dim", "blur",
                       "shake"]
        case .menuBar: ["top bar", "status bar", "waybar", "hide", "autohide", "clock", "date and time", "two zones", "workspaces", "menu bar items", "in the menu bar", "item"]
        case .look: ["theme", "wallpaper", "accent", "colours", "ghostty", "omarchy", "font", "style", "instrument", "toybox",
                     "material", "glass", "transparency", "apps show as"]
        case .system: ["setup", "sound", "volume", "mute", "output", "input", "microphone", "speakers", "keep awake", "caffeinate", "sleep",
                       "bluetooth", "headphones", "airpods", "connect", "wi-fi", "wifi", "network", "join", "display", "resolution", "monitor",
                       "screen", "refresh rate", "keyboard layout", "input source", "pointer speed", "tracking speed", "mouse speed", "cursor speed"]
        case .activity: ["activity monitor", "process", "running", "quit", "force quit", "kill", "task manager", "hog", "helper"]
        case .upkeep: ["update", "upgrade", "outdated", "brew upgrade", "clean", "mole", "free space", "cache", "last run", "login items",
                       "open at login", "startup", "launch agent", "launchd", "daemon", "background items"]
        case .stats: ["stats", "history", "readings", "cpu", "memory", "ram", "storage", "disk", "network", "temperature", "heat", "fan", "graphics",
                      "gpu", "battery", "bluetooth", "busiest", "this mac"]
        case .clipboard: ["clipboard", "history", "paste", "keep", "never record", "images"]
        case .captures: ["capture", "screenshot", "screen shot", "pictures", "thumbnail", "delay"]
        case .notes: ["notes", "quick notes", "scratch", "markdown", "notes folder", "vault", "inbox"]
        case .install: ["install", "recommend apps", "recommendations", "self-updating", "casks"]
        case .openWith: ["default app", "open with", "main editor", "editor", "vs code", "browser", "defaults", "terminal app", "notes app",
                         "password manager", "music app"]
        case .configs: ["config", "dotfiles", "ghostty", "neovim", "zshrc", "gitconfig", "starship", "tmux", "settings.json"]
        case .repos: ["repo", "repos", "repository", "git", "branch", "commit", "code folder", "file tree", "source code"]
        case .fonts: ["font", "fonts", "typeface", "mono", "use fonts in", "nerd font"]
        case .general: ["hyper", "layer key", "caps lock", "escape", "overlay", "launch at login", "startup", "uninstall"]
        case .ai: ["ai", "ask", "chat", "quick ai", "claude", "ask claude", "ai chat"]
        case .extensions: ["extension", "preference", "password", "permission", "extensions folder"]
        case .widgets: ["widget", "widgets", "desktop widget", "ubersicht", "übersicht", "trust this widget", "this mac", "clock", "note"]
        case .voice: ["dictation", "dictate", "read aloud", "speech", "speak", "voice", "text to speech",
                      "tts", "speed", "speech to text", "whisper", "parakeet", "speech model", "transcribe"]
        }
    }
}

/// The window's top level (window directions, Sven 2026-10-11, design 6D3E1T482hjVZaUkgMvvDb): Home, eight areas, and
/// Pilot at the foot. A page shows only inside its area; Cmd+1 to 9 open the areas top to bottom, Cmd+, opens Pilot, as
/// any Mac app's settings. Page names and pilot:// links stay as they were: an area is only where a page sits.
public enum AppArea: String, CaseIterable, Sendable {
    // Pilot stays last: its key is ",", the rest count down the rail.
    case home, keys, launcher, desktop, mac, tools, apps, ai, extensions, pilot

    /// Its pages in order. Voice is Dictation and Read aloud (in Tools, Sven 2026-10-16); AI (the chat and its setup) and Extensions
    /// are areas of their own, Extensions listing every installed extension under its page (Sven 2026-10-16); General
    /// alone is Pilot. Launcher (the menu's page) left Keys for an area of its own after it (P37, Sven 2026-10-18, Q285).
    public var pages: [AppPage] {
        switch self {
        case .home: [.home]
        case .keys: [.binds]
        case .launcher: [.menu]
        case .desktop: [.workspaces, .tiling, .menuBar, .look, .widgets]
        case .mac: [.system, .activity, .upkeep, .stats]
        case .tools: [.clipboard, .captures, .snippets, .notes, .files, .voice]
        case .apps: [.install, .openWith, .configs, .repos, .fonts]
        case .ai: [.ai]
        case .extensions: [.extensions]
        case .pilot: [.general]
        }
    }

    public var title: String {
        switch self {
        case .home: "Home"
        case .keys: "Keys"
        case .launcher: "Launcher"
        case .desktop: "Desktop"
        case .mac: "Mac"
        case .tools: "Tools"
        case .apps: "Apps"
        case .ai: "AI"
        case .extensions: "Extensions"
        case .pilot: "Pilot"
        }
    }

    public var symbol: String {
        switch self {
        case .home: "house"
        case .keys: "command"
        case .launcher: "text.magnifyingglass"
        case .desktop: "square.grid.2x2"
        case .mac: "slider.horizontal.3"
        case .tools: "doc.on.clipboard"
        case .apps: "shippingbox"
        case .ai: "sparkles"
        case .extensions: "puzzlepiece.extension"
        case .pilot: "gearshape"
        }
    }

    /// The key that opens it with Cmd: "1" to "9" top to bottom, "," for Pilot at the foot.
    public var key: Character {
        self == .pilot ? "," : Character(String((AppArea.allCases.firstIndex(of: self) ?? 0) + 1))
    }

    /// Its pages the window lists: all of them while `developer` is on, else all but the developer pages.
    public func pages(developer: Bool) -> [AppPage] { developer ? pages : pages.filter { !$0.isDeveloper } }

    /// The areas above the foot, in order; Pilot sits apart at the foot.
    public static let main: [AppArea] = allCases.filter { $0 != .pilot }

    /// The page after `page` among its area's listed pages, round to the first (Ctrl+Tab).
    public static func next(after page: AppPage, developer: Bool = true) -> AppPage {
        let pages = page.area.pages(developer: developer)
        return pages[((pages.firstIndex(of: page) ?? -1) + 1) % pages.count]
    }
}

/// How the window draws the areas (window directions, Sven 2026-10-11: "can we have all 3 implemented, then I test and see
/// which is best?"): picked on Look as Window layout, each in Instrument and Toybox.
public enum WindowShape: String, CaseIterable, Sendable {
    /// Direction 1, the default: a rail of the areas, the area's pages listed beside it, the open page's tabs in its header.
    case rail
    /// Direction 2: the areas as big tabs in the toolbar, the area's pages as a row of tabs under it.
    case tabs

    public var title: String {
        switch self {
        case .rail: "Rail and page list"
        case .tabs: "Toolbar tabs"
        }
    }

    /// A saved name, or the rail for none or an unknown one (a saved "hub", the layout taken out on 2026-10-11, among them).
    public init(saved: String?) { self = saved.flatMap(WindowShape.init(rawValue:)) ?? .rail }
}

/// Direction 1's rules, both styles: a rail of the areas, and beside it the area's pages, one row each; a page's parts are
/// tabs in its own header at every width (P36, Sven 2026-10-18, Q267: the sidebar lists pages, the header holds the
/// page's parts). An area of one page takes the whole width; a window under 900 pt folds the list away and the page's
/// header carries the area's pages beside its parts. The search shows the list wherever it is asked for.
public enum RailLayout {
    /// A window under 900 pt (0 is not measured yet).
    public static func narrow(_ width: Double) -> Bool { width > 0 && width < 900 }

    /// Whether the list of the area's pages shows beside the rail in a window `width` wide (0 is not measured yet).
    public static func showsList(_ page: AppPage, width: Double, searching: Bool) -> Bool {
        searching || (!fullWidth(page.area) && !narrow(width))
    }

    /// Areas of one page take the whole width, the list's one row saying nothing, its tabs in the page's header (Sven,
    /// 2026-10-18): Home, Keys, Launcher, AI and Pilot. Extensions keeps its list, each extension's page a row in it.
    public static func fullWidth(_ area: AppArea) -> Bool { area.pages.count == 1 && area != .extensions }

    /// A measured window width kept to the widths these rules tell apart, so only crossing a line redraws a frame.
    public static func bucket(_ width: Double) -> Double {
        narrow(width) ? 800 : width < 1100 ? 1000 : 1440
    }

    /// The list's width: 236 pt, 212 in a window under 1100.
    public static func listWidth(_ window: Double) -> Double { window > 0 && window < 1100 ? 212 : 236 }

    /// The list's foot: the area's key, then how to step through its pages when it has more than one; `rows` counts the
    /// rows listed under its pages that ⌃Tab steps through too (Extensions' installed extensions).
    public static func hint(_ area: AppArea, rows: Int = 0) -> String {
        "⌘\(area.key) \(area.title)" + (area.pages.count + rows > 1 ? " · ⌃Tab next page" : "")
    }

    /// Beside a page's tabs while they fit: the key that steps to the next (P36).
    public static let partsHint = "⌘⇧] next"
}

/// A part of a page: a tab across its top, or a place on its body a link scrolls to.
public enum AppSection: String, CaseIterable, Sendable {
    case plainCombos, conflicts
    /// Menu's parts (C3): every ability Pilot has (story 155, was Binds › Abilities), the rows' aliases and the quicklinks
    /// (were on Defaults).
    case abilities, aliases, quicklinks
    /// Files' tab: what the menu's file search leaves out (Menu's until Sven 2026-10-10).
    case fileSearch
    /// Files' tab: identical files and the space they take, moved to the Trash on a yes (Homy-style Files, T5).
    case duplicates
    /// Files' tab: folders dressed in Pilot's designs or a picture, and Reset (P43).
    case folders
    /// Activity's part (C3): Reports, every Update and Clean run (story 153, was Install's; Update and Clean themselves are
    /// their own page, Sven 2026-10-20). Stats was its other part until it became a page (Sven 2026-10-10).
    case reports
    case catalogue, webApps
    /// Install's tab: the command-line tools other features run (General's until the page map, Sven 2026-10-17).
    case helpers
    /// Install's tab: apps left out of Pilot's lists, and Finder's where it can (Pilot 1.0.2, Sven Q713).
    case hiddenApps
    /// General's places a link scrolls to.
    case permissions, about
    /// The extension catalogue's part of the one Extensions list (2026-10-10; a tab until Q601): `tab=catalogue` names it on
    /// the Extensions page, which picks its first row.
    case extensionCatalogue
    /// Binds' third tab: what the hold-Hyper overlay shows, a switch per bind (story 56, 2026-10-10).
    case overlay
    /// Binds' tab for a mouse's extra buttons (Q184).
    case mouse
    /// Binds' tab: pairs of keys swapped while Pilot runs, Caps Lock ↔ Control and the like (Q406).
    case keySwaps
    /// Launcher's tab for the Ring menu (P74; Binds' until Sven on Build 76): the rings, their wedges, what opens each, and
    /// how they open and run.
    case rings
    /// Binds' tab: export binds as a pack and import one (General › Data's until the page map, Sven 2026-10-17).
    case exportImport
    /// Configs' tab: agents' settings (on Configs until 2026-10-19) and the files they read before they work (the Agent
    /// instructions page until the page map).
    case agents
    /// AI's tab: providers, models, keys and when a chat starts over (the chat's popovers until the page map).
    case aiSetup
    /// Captures' tab: screen recording's own settings and keys.
    case recording
    /// Captures' tab: every capture and recording, and Combine images (P73); `tab=history` already means Stats.
    case captureHistory
    /// Look's Wallpaper block, which a link and the desktop's Hyper + right-click › Wallpaper settings… scroll to.
    case wallpaper

    public var page: AppPage {
        switch self {
        case .plainCombos, .conflicts, .overlay, .mouse, .keySwaps, .exportImport: .binds
        case .abilities, .aliases, .quicklinks, .rings: .menu
        case .fileSearch, .duplicates, .folders: .files
        case .reports: .activity
        case .catalogue, .webApps, .helpers, .hiddenApps: .install
        case .permissions, .about: .general
        case .extensionCatalogue: .extensions
        case .agents: .configs
        case .aiSetup: .ai
        case .recording, .captureHistory: .captures
        case .wallpaper: .look
        }
    }

    /// The part a `tab=` name stands for on `page`: its raw name, but on Extensions `catalogue` is its own Catalogue,
    /// not Install's.
    public static func tab(_ name: String, on page: AppPage) -> AppSection? {
        page == .extensions && name == "catalogue" ? .extensionCatalogue : AppSection(rawValue: name)
    }

    /// Binds' tabs drawn as a plain page under the frame's bar, not on the keyboard: Overlay, Mouse, Swap keys, Export and
    /// import.
    public var isPlainBindsPage: Bool { [.overlay, .mouse, .keySwaps, .exportImport].contains(self) }

    /// Conflicts open as a sheet over Binds rather than as a tab.
    public var opensAsSheet: Bool { self == .conflicts }
    /// Shown as a tab across the page's top; Plain combos is Binds' last sublayer tab instead (card agent-bo-95422894),
    /// conflicts a sheet.
    public var isTab: Bool { !opensAsSheet && !isMerged }

    /// Parts drawn on their page's own body: Plain combos as a sublayer, and General's places, the extension catalogue
    /// (Q601) and Look's Wallpaper, which a link scrolls to. The search still lands on them.
    public var isMerged: Bool { self == .plainCombos || page == .general || self == .extensionCatalogue || self == .wallpaper }

    public var title: String {
        switch self {
        case .plainCombos: "Plain combos"
        case .conflicts: "Conflicts"
        case .abilities: "Abilities"
        case .aliases: "Aliases"
        case .quicklinks: "Quicklinks"
        case .fileSearch: "File search"
        case .duplicates: "Duplicates"
        case .folders: "Folders"
        case .reports: "Reports"
        case .catalogue: "Catalogue"
        case .webApps: "Web apps"
        case .helpers: "Helpers"
        case .hiddenApps: "Hidden apps"
        case .permissions: "Permissions"
        case .exportImport: "Export and import"
        case .about: "About"
        case .extensionCatalogue: "Catalogue"
        case .overlay: "Overlay"
        case .mouse: "Mouse"
        case .keySwaps: "Swap keys"
        case .rings: "Rings"
        case .agents: "Agents"
        case .aiSetup: "Setup"
        case .recording: "Recording"
        case .captureHistory: "History"
        case .wallpaper: "Wallpaper"
        }
    }

    var keywords: [String] {
        switch self {
        case .plainCombos: ["plain combo", "left option", "alt", "vim"]
        case .conflicts: ["clash", "macos shortcut", "mission control"]
        case .abilities: ["ability", "abilities", "what can pilot do", "every action", "features", "discover", "try"]
        case .aliases: ["alias", "aliases", "short name"]
        case .quicklinks: ["quicklink", "keyword", "search link", "bookmark"]
        case .fileSearch: ["file search", "hidden files", "never index", "index", "find files"]
        case .duplicates: ["duplicate", "identical", "same file", "copies", "free space", "wasted space"]
        case .folders: ["folder", "folder icon", "folder design", "folder colour", "custom icon", "dress folders", "reset folder icon"]
        case .reports: ["report", "run", "output", "exit code"]
        case .catalogue: ["install catalogue", "catalogue", "homebrew", "cask", "formula"]
        case .webApps: ["web app", "url", "site", "sign out"]
        case .helpers: ["helper", "homebrew", "brew", "mole", "mas", "npm", "cargo", "command-line tools"]
        case .hiddenApps: ["hide app", "hidden app", "unhide", "hide from finder", "declutter", "chess"]
        case .permissions: ["accessibility", "secure input", "health", "diagnostics", "log", "full disk access", "permission", "microphone",
                            "screen recording", "input monitoring", "system events", "automation"]
        case .exportImport: ["export", "import", "pack", "second mac", "backup"]
        case .about: ["version", "made with", "licence", "credits", "acknowledgements", "open source", "feedback", "bug", "crash"]
        // Pomodoro's old page's words too: it is the catalogue's Pomodoro extension now (2026-10-10).
        case .extensionCatalogue: ["extension catalogue", "install extension", "get extension", "update extension", "pomodoro", "timer", "focus",
                                   "break"]
        case .overlay: ["overlay", "hold hyper", "cheat sheet", "what the overlay shows", "show in overlay", "my own pick", "most used"]
        case .mouse: ["mouse", "mouse button", "side button", "extra button", "hyperx", "learn button", "hold button"]
        case .keySwaps: ["swap keys", "swap", "remap", "key mapping", "hidutil"]
        case .rings: ["ring", "ring menu", "radial menu", "pie menu", "wheel", "flick", "opie", "wedge", "hold to open"]
        case .agents: ["agent instructions", "instructions", "agents.md", "claude.md", "soul", "persona", "agent brief", "ai agents",
                       "agent settings", "codex", "hermes", "empryo", "opencode"]
        case .aiSetup: ["provider", "api key", "model", "effort", "anthropic", "openai", "ollama", "codex", "sign in", "fix text",
                        "fix selected text", "new chat after", "ai keys"]
        case .recording: ["recording", "screen recording", "record", "movies", "mp4", "frame rate", "fps", "show clicks", "countdown"]
        case .captureHistory: ["capture history", "past captures", "old screenshots", "combine images", "stitch images", "size cap"]
        case .wallpaper: ["wallpaper", "desktop picture", "background", "next wallpaper", "per workspace wallpaper", "cycle wallpaper"]
        }
    }
}

/// Where the window opens: a page, and the part of it.
public struct AppPlace: Hashable, Sendable {
    public let page: AppPage
    public let section: AppSection?

    public init(_ page: AppPage, _ section: AppSection? = nil) { self.page = page; self.section = section }
    public init(_ section: AppSection) { self.init(section.page, section) }

    /// Names that are neither a page's nor a part's now, each where it went: the page map's (2026-10-17) Agent instructions
    /// (Configs › Agents) and Launcher (the menu page's name since P37, still `menu` in links); the Menu bar page's lower-case spellings
    /// (card agent-bo-95422913), Pomodoro (an extension now), and every page and part the C3 rework renamed, moved or
    /// folded: Pilot is General, Setup is System, History is Stats, Defaults and its Default apps are Open with,
    /// Snapshots are on Workspaces, and the on/off switch (Other apps' old name) is on Home; convert lands on Files.
    /// Monitors and the swipe left Tiling for Workspaces (Sven's Q207 page map, 2026-10-17).
    static let renamed: [String: AppPlace] = [
        "topBar": AppPlace(.menuBar), "topbar": AppPlace(.menuBar), "menubar": AppPlace(.menuBar),
        "installCatalogue": AppPlace(.catalogue), "pomodoro": AppPlace(.extensionCatalogue),
        "pilot": AppPlace(.general), "setup": AppPlace(.system), "history": AppPlace(.stats), "defaults": AppPlace(.openWith),
        "defaultApps": AppPlace(.openWith), "snapshots": AppPlace(.workspaces), "onOff": AppPlace(.home), "otherApps": AppPlace(.general),
        "convert": AppPlace(.files), "ask": AppPlace(.ai), "monitors": AppPlace(.workspaces), "swipe": AppPlace(.workspaces),
        "instructions": AppPlace(.agents), "launcher": AppPlace(.menu),
    ]

    /// The place a page name stands for: a page, a part, an old name, or nil.
    public static func named(_ name: String) -> AppPlace? {
        renamed[name] ?? AppPage(rawValue: name).map { AppPlace($0) } ?? AppSection(rawValue: name).map { AppPlace($0) }
    }

    /// The place `pilot://open?page=<page>[&tab=<section>]` names, the old page names included; nil when it names none or
    /// an unknown one (the window opens as usual). A tab that moved off its old page in C3 follows it there:
    /// `page=workspaces&tab=tiling` opens Tiling, `page=binds&tab=abilities` Launcher › Abilities, `page=install&tab=reports`
    /// Activity › Reports, `page=defaults&tab=configs` Configs. Sven 2026-10-10: `page=clipboard&tab=snippets` opens
    /// Snippets, `page=menu&tab=fileSearch` Files › File search, `page=activity&tab=stats` (or `tab=history`) Stats.
    public static func linked(_ url: URL) -> AppPlace? {
        guard let place = url.queryValue("page").flatMap(named) else { return nil }
        guard place.section == nil, let name = url.queryValue("tab") else { return place }
        if let tab = AppSection.tab(name, on: place.page), tab.page == place.page { return AppPlace(tab) }
        return movedTabs[name] ?? place
    }

    /// The tabs that left their page in C3, or took a new name, by their old `tab=` name.
    static let movedTabs: [String: AppPlace] = [
        "tiling": AppPlace(.tiling), "abilities": AppPlace(.abilities), "reports": AppPlace(.reports), "configs": AppPlace(.configs),
        "defaultApps": AppPlace(.openWith), "snapshots": AppPlace(.workspaces), "history": AppPlace(.stats),
        "snippets": AppPlace(.snippets), "fileSearch": AppPlace(.fileSearch), "stats": AppPlace(.stats),
        "monitors": AppPlace(.workspaces), "swipe": AppPlace(.workspaces),
        // The page map (2026-10-17): General's export and import is Binds'; Helpers, once a General block, is Install's.
        "exportImport": AppPlace(.exportImport), "helpers": AppPlace(.helpers),
        // Rings left Binds for Launcher (Sven on Build 76).
        "rings": AppPlace(.rings),
    ]

    /// Places whose title holds the query first (a page's, then a part's), then places with a setting that does; when
    /// none, those a typo of it finds, the closest first, a title before a setting (FuzzyRanker.Filter); empty for a
    /// blank query. Developer pages and their parts only while `developer` is on.
    public static func search(_ query: String, developer: Bool = true) -> [AppPlace] {
        let filter = FuzzyRanker.Filter(query)
        guard !filter.typed.isEmpty else { return [] }
        let all = (AppPage.allCases.map { AppPlace($0) } + AppSection.allCases.map { AppPlace($0) }).filter { developer || !$0.page.isDeveloper }
        let byTitle = all.filter { filter.holds([$0.title]) }
        let held = byTitle + all.filter { place in !byTitle.contains(place) && filter.holds(place.keywords) }
        guard held.isEmpty else { return held }
        return FuzzyRanker.Filter.closest(all) { place in
            filter.edits([place.title]).map { $0 * 2 } ?? filter.edits(place.keywords).map { $0 * 2 + 1 }
        }
    }

    /// "Activity › Reports", or the page's title; messages name a place by it, so a renamed page renames them too
    /// (card agent-bo-95423031).
    public var title: String { section.map { $0.title } ?? page.title }
    public var path: String { section.map { "\(page.title) › \($0.title)" } ?? page.title }
    var keywords: [String] { section?.keywords ?? page.keywords }
}

/// A part of the System page (Setup until C3) a key or a link opens it at (card agent-bo-95422805): Hyper+Ctrl+A, B and W
/// land on Sound, Bluetooth and Wi-Fi.
public enum SetupSection: String, CaseIterable, Sendable {
    case sound, wifi, bluetooth, displays, keepAwake, keyboard, mouse

    /// The section `pilot://open?page=system&section=<name>` (or the old `page=setup`) names; nil when it names none or an unknown one.
    public static func linked(_ url: URL) -> SetupSection? { url.queryValue("section").flatMap(SetupSection.init(rawValue:)) }
}

extension URL {
    /// The value of one query item: pilot://press?key=k → queryValue("key") is "k".
    public func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

/// The Dock rule (approved mockup GhzZ3FBlEJA): Pilot runs from login with only its menu-bar icon, gains a Dock icon
/// and a Cmd+Tab entry while one of its windows is open, and loses them when the last one closes.
public enum DockIcon: Sendable, Equatable {
    case menuBarOnly, dock

    public static func policy(openWindows: Int) -> DockIcon { openWindows > 0 ? .dock : .menuBarOnly }
}

/// Who tiles, as Pilot names it (card agent-bo-95423025).
public let tilerName = "Pilot's tiler"

/// Home's Needs you (card agent-bo-95422787; design round 4 names it Needs you again): only what Pilot knows is wrong right now, most blocking first, with the page
/// that fixes it where one does (Pilot's last error has none); empty when all is well.
public enum HomeProblems {
    public struct Problem: Sendable {
        /// `tiler`: Pilot's tiler is not answering.
        public enum Kind: Sendable { case accessibility, secureInput, tiler, error }
        public let kind: Kind
        public let title: String
        public var detail: String?
        public var place: AppPlace?
    }

    /// `secureInput`: who holds secure input while it is on, nil while it is off.
    public static func list(accessibilityGranted: Bool, secureInput: SecureInputHolder?, tilerRunning: Bool,
                            lastError: String?) -> [Problem] {
        var list: [Problem] = []
        if !accessibilityGranted { list.append(Problem(kind: .accessibility, title: "Accessibility is not granted", detail: "Pilot sees no keys until it is", place: AppPlace(.permissions))) }
        if let secureInput { list.append(Problem(kind: .secureInput, title: secureInput.title, detail: secureInput.detail, place: AppPlace(.permissions))) }
        if !tilerRunning {
            list.append(Problem(kind: .tiler, title: "\(tilerName) is not running",
                                detail: "Tiling and workspaces are off", place: AppPlace(.tiling)))
        }
        if let lastError { list.append(Problem(kind: .error, title: lastError)) }
        return list
    }
}

/// Who holds secure input, as far as macOS says. It records only the last process to turn it on, "best effort" (Apple
/// DTS, developer.apple.com/forums/thread/726353): an app that quit, or the login window once unlocked, names nobody,
/// and another app may still hold it (2026-10-21: Vesktop quit, the lock stayed; a lock and unlock did not clear it).
public enum SecureInputHolder: Sendable, Equatable {
    /// The app that turned it on, still running.
    case app(String)
    /// The app that turned it on quit, its name when known, and secure input stayed on.
    case quit(String?)
    /// No app macOS names: none, or the login window while the screen is unlocked.
    case unknown

    /// The fix when the named app is no help: quit whichever app has a password field open, else log out.
    static let unstick = "Quit the app with a password field open (a password manager, say); logging out always clears it"

    /// Home's line adds ", so Hyper waits."
    public var title: String {
        switch self {
        case .app(let name): "\(name) has the keyboard (a password field)"
        case .quit(let name): "\(name ?? "An app") quit but left the keyboard locked"
        case .unknown: "A password field has the keyboard"
        }
    }

    public var detail: String {
        switch self {
        case .app: "Hyper is off until you leave it"
        case .quit: "Another app may still hold it. \(Self.unstick)"
        case .unknown: "Hyper is off until you leave it. Stuck? \(Self.unstick)"
        }
    }
}

/// Home's workspace map: workspaces 1 to the highest in use or focused (at least `atLeast`), an empty one drawn as
/// such, then any named workspace that has windows. Given the workspaces `kept`, one deleted (Sven 2026-10-17) is no
/// empty cell, and `atLeast` counts kept ones: kept 1, 2, 4 and 5 draw 1, 2, 4 and 5.
public enum HomeWorkspaces {
    /// The most empty cells Home's layouts draw.
    public static let drawn = 4

    public static func cells(_ occupied: [OccupiedWorkspace], focused: String?, atLeast: Int = drawn, kept: [String]? = nil) -> [OccupiedWorkspace] {
        let byName = Dictionary(occupied.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let live = (occupied.map(\.name) + [focused].compactMap { $0 }).compactMap(Int.init)
        let least = kept.map { $0.prefix(atLeast).compactMap(Int.init).max() ?? 0 } ?? atLeast
        let top = live.reduce(least, max)
        let shown = Set((kept?.compactMap(Int.init) ?? Array(1...max(top, 1))).filter { $0 <= top } + live)
        let numbered = shown.sorted().map { byName[String($0)] ?? OccupiedWorkspace(name: String($0), apps: []) }
        return numbered + occupied.filter { Int($0.name) == nil }
    }
}

/// Opening the app window while the screen is locked (card agent-bo-95422757): the tiler reads nothing through
/// Accessibility then, so a window made on a locked screen is never registered and never tiles. The open waits for the
/// unlock instead, and the window is made then, which the tiler sees as any new window.
public struct LockedOpen: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Make the window now, at this place (nil: the page shown last).
        case show(AppPlace?)
        case wait
    }

    private var waiting = false
    private var page: AppPlace?

    public init() {}

    /// An open on an unlocked screen shows at once and drops one that waited, so the unlock never shows an older page.
    public mutating func request(_ page: AppPlace?, screenLocked: Bool) -> Decision {
        guard screenLocked else {
            (waiting, self.page) = (false, nil)
            return .show(page)
        }
        waiting = true
        if let page { self.page = page }
        return .wait
    }

    /// The screen unlocked: the open that waited, once.
    public mutating func unlocked() -> Decision? {
        guard waiting else { return nil }
        defer { waiting = false; page = nil }
        return .show(page)
    }
}
