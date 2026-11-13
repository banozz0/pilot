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
    case home, binds, menu, workspaces, tiling, menuBar, dock, pilotMenu, look, system, activity, upkeep, stats, clipboard, captures, snippets, notes, files, ai, voice,
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
        case .dock: "Dock"
        case .pilotMenu: "Pilot menu"
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
        case .general: "Pilot"
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
        case .dock: "dock.rectangle"
        case .pilotMenu: "list.bullet.below.rectangle"
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
        case .menu, .menuBar, .dock, .pilotMenu, .general, .activity: 3
        case .install, .extensions, .files, .stats, .fonts, .repos: 4
        case .openWith, .configs, .notes: 5
        }
    }

    /// Developer pages (Pilot 1.0.2, Sven Q715): Configs, with its Agents tab, and Repos show only while General's Developer
    /// switch is on; off, the sidebar, the searches and `pilot open` leave them out and nothing reads their files.
    public var isDeveloper: Bool { self == .configs || self == .repos }

    /// The parts a page holds as tabs or places on it (Binds' conflicts open as a sheet, not a tab).
    public var sections: [AppSection] { AppSection.allCases.filter { $0.page == self } }

    /// Pages whose own content is their first tab, before their parts, or whose parts are places on it (General, Look):
    /// every page but those that are only their parts. Look opens on its top, its Wallpaper a place on it.
    public var hasOwnContent: Bool { !Self.onlyParts.contains(self) }

    /// The pages that are their parts, opening on the first: Install on Catalogue.
    static let onlyParts: Set<AppPage> = [.install]

    /// The part a page opens on: none for a page with its own content, else its first.
    public var firstSection: AppSection? { hasOwnContent ? nil : sections.first }

    /// The tabs in a page's header, at every window width (P36, Sven 2026-10-18, Q267): its own content first when it has
    /// some, then its parts; none for a single page.
    public var tabs: [(value: AppSection?, title: String)] {
        // A More tab last, whatever order the parts are declared in (simplify-pages T7).
        let tabs = sections.filter(\.isTab)
        let parts = (tabs.filter { !$0.isMore } + tabs.filter(\.isMore)).map { (value: Optional($0), title: $0.title) }
        guard !parts.isEmpty else { return [] }
        return hasOwnContent ? [(nil, ownTitle)] + parts : parts
    }

    /// The tab of a page's own content: Menu's the rows Hyper+Space shows.
    var ownTitle: String {
        switch self {
        case .binds: "Keyboard"
        case .menu: "Your menu"
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
        // The front's words; Translate's and the rows to add moved with them to More (simplify-pages T15).
        case .menu: ["launcher", "menu", "hyper+space", "root", "menu rows", "pin", "order", "reorder", "show first"]
        case .snippets: ["snippet", "keyword", "text expansion", "expand", "placeholder", "template"]
        case .files: ["convert", "converter", "format", "png", "jpg", "heic", "webp", "pdf", "mp4", "mov", "mp3", "gif", "docx", "finder",
                      "right-click", "services"]
        // The front's words; the rest moved with their parts to More (simplify-pages T18).
        case .workspaces: ["layout", "name", "delete workspace", "add workspace", "your widths", "own sizes", "spot", "preview"]
        // The front's words; the rest moved with their controls to Tiling's More places (simplify-pages T9).
        case .tiling: ["gaps", "inner", "outer", "between windows", "screen edges", "tiler", "rescue", "border", "defocus", "dim", "blur",
                       "dim other windows"]
        case .pilotMenu: ["pilot menu", "pilot's menu", "dropdown", "menu bar icon", "blocks", "pinned", "quick switches", "running now",
                          "control centre", "control center", "extensions card"]
        case .menuBar: ["top bar", "status bar", "waybar", "hide", "autohide", "clock", "date and time", "two zones", "workspaces", "menu bar items", "in the menu bar", "item",
                        "bar preset", "full bar", "floating strip", "three islands", "pills", "adjust sizes", "bar height"]
        // The front's words; the style, the menu's and window's layouts, the glass's tuning, the cursor and the wallpaper
        // folders moved with their blocks to Look's More (simplify-pages T20).
        case .look: ["theme", "wallpaper", "accent", "colours", "ghostty", "omarchy", "font", "material", "glass", "light or dark"]
        // The front's words; the input, the keyboard layout and the mouse have their own places. Each part's keys are in its
        // card (pages round 5), so their words land here.
        case .system: ["setup", "sound", "volume", "mute", "output", "speakers", "keep awake", "caffeinate", "sleep",
                       "bluetooth", "headphones", "airpods", "connect", "wi-fi", "wifi", "network", "join", "display", "resolution", "monitor",
                       "screen", "refresh rate", "sound in pilot", "wi-fi in pilot", "bluetooth in pilot", "displays in pilot", "media keys",
                       "volume up", "volume down"]
        case .activity: ["activity monitor", "process", "running", "quit", "force quit", "kill", "task manager", "hog", "helper"]
        case .upkeep: ["update", "upgrade", "outdated", "brew upgrade", "clean", "mole", "free space", "cache", "last run", "login items",
                       "open at login", "startup", "launch agent", "launchd", "daemon", "background items"]
        case .stats: ["stats", "history", "readings", "cpu", "memory", "ram", "storage", "disk", "network", "temperature", "heat", "fan", "graphics",
                      "gpu", "battery", "bluetooth", "busiest", "this mac"]
        // The front's words; the rest moved with their controls to Clipboard's More places (simplify-pages T10).
        case .clipboard: ["clipboard", "history", "paste", "keep", "keep the last", "images", "save images", "passwords", "skip passwords",
                          "clear history", "open clipboard"]
        // The front's words; the rest moved with their controls to Captures' More places (simplify-pages T13).
        case .captures: ["capture", "screenshot", "screen shot", "pictures", "after capture", "area", "full screen", "captures folder"]
        case .notes: ["notes", "quick notes", "scratch", "markdown", "notes folder", "vault", "inbox"]
        // Recommend apps and the self-updating casks moved with their switches to More (simplify-pages T16).
        case .install: ["install", "catalogue", "search to install"]
        // The front's words; the role keys' moved with them to More (simplify-pages T11).
        case .openWith: ["default app", "open with", "main editor", "editor", "vs code", "browser", "defaults", "text", "markdown",
                         "all kinds"]
        case .configs: ["config", "dotfiles", "ghostty", "neovim", "zshrc", "gitconfig", "starship", "tmux", "settings.json"]
        case .repos: ["repo", "repos", "repository", "git", "branch", "commit", "code folder", "file tree", "source code"]
        case .fonts: ["font", "fonts", "typeface", "mono", "use fonts in", "nerd font"]
        // The front's words; the rest moved with their controls to Pilot's More places (simplify-pages T8).
        case .general: ["general", "hyper", "layer key", "caps lock", "launch at login", "startup", "setup again", "onboarding", "updates",
                        "check for updates", "support", "sponsor"]
        case .ai: ["ai", "ask", "chat", "quick ai", "claude", "ask claude", "ai chat"]
        case .extensions: ["extension", "preference", "password", "permission", "extensions folder"]
        case .dock: ["dock", "pilot dock", "dock widgets", "dock style", "magnification", "magnify", "dock size", "auto-hide", "pins", "keep in dock"]
        case .widgets: ["widget", "widgets", "desktop widget", "ubersicht", "übersicht", "trust this widget", "this mac", "clock", "note"]
        // The front's words; the rest moved with their controls to Voice's More places (simplify-pages T12).
        case .voice: ["dictation", "dictate", "read aloud", "speech", "speak", "voice", "text to speech", "tts", "speed", "speech to text",
                      "whisper", "parakeet", "speech model", "transcribe", "microphone", "kokoro"]
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
        // Pilot menu beside Menu bar: what the menu under Pilot's icon shows (Sven, 2026-11-12, Q182: Menu bar was crowded).
        // Dock beside Menu bar, its own page (round 4, Sven 2026-11-13: "maybe dock should have its own page in desktop").
        case .desktop: [.workspaces, .tiling, .menuBar, .dock, .pilotMenu, .look, .widgets]
        // Majors first (simplify-pages T11): Update & Clean before System, so ⌘5 opens it; Clipboard, Notes, Files, Voice;
        // Open with first in Apps, so ⌘7 opens it.
        case .mac: [.upkeep, .system, .activity, .stats]
        case .tools: [.clipboard, .notes, .files, .voice, .captures, .snippets]
        case .apps: [.openWith, .install, .configs, .repos, .fonts]
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
    /// Update & Clean's tab: Reports, every Update and Clean run (story 153, was Install's, then Activity's until
    /// simplify-pages T16, beside the runs it records). Stats was Activity's other part until it became a page (Sven 2026-10-10).
    case reports
    case catalogue, webApps
    /// A place on Install's More: the command-line tools other features run (General's until the page map, Sven
    /// 2026-10-17; a tab until simplify-pages T16).
    case helpers
    /// A place on Install's More: apps left out of Pilot's lists, and Finder's where it can (Pilot 1.0.2, Sven Q713; a tab
    /// until simplify-pages T16).
    case hiddenApps
    /// General's places a link scrolls to.
    case permissions, about
    /// The extension catalogue's part of the one Extensions list (2026-10-10; a tab until Q601): `tab=catalogue` names it on
    /// the Extensions page, which picks its first row.
    case extensionCatalogue
    /// Binds' third tab: what the hold-Hyper overlay shows, a switch per bind (story 56, 2026-10-10).
    case overlay
    /// Binds' tab for a mouse's extra buttons (Q184); on System beside its Mouse card from Sven's Q68 until his round 3
    /// notes on build 2300 (2026-11-11), when it came back.
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
    /// Look's Wallpaper block on its front (Previous, Next, Change on its own), which a link and the desktop's Hyper +
    /// right-click › Wallpaper settings… scroll to.
    case wallpaper
    /// Look's Catalogue (public-repo-catalogue T22, Sven's variant C): every theme pack in Pilot's catalogue as a gallery
    /// of desks, each acting from its own tile (Get, Update, Apply, Remove).
    case themeCatalogue
    /// Look's More (simplify-pages T20) and its places: the style, the Hyper+Space menu's and this window's layouts and how
    /// apps show (back on More in pages round 5); the glass's transparency and blur (under Glass, pages round 5), the cursor,
    /// and the folders and order the wallpaper cycles through are places on the front (pages round 4, Sven's Q99).
    case lookMore, lookStyle, menuLayout, windowLayout, appsShowAs, glassTuning, cursor, wallpaperCycle
    /// Pilot's places on its front beside `permissions` and `about` (on its More from simplify-pages T7 until pages round 4,
    /// Sven's Q106, when the page lost its More): the Hyper keys and their options, what runs, and Pilot's folder, command
    /// and Uninstall.
    case hyperKey, status, data
    /// Pilot's front: other apps' notifications as Pilot's cards, and hiding macOS's own banner (spec notifications).
    case notifications
    /// Tiling's places on its front: the always-float apps and the focused window (Sven, 2026-11-11, after 2276), and the
    /// always-float window titles and the mouse and motion, back from More (pages round 4, Sven's Q98); Tiling has no More.
    case floatApps, floatTitles, motion, focusedWindow
    /// Workspaces' More's window shelf (on Tiling's More until Sven, 2026-11-11, after 2276).
    case windowShelf
    /// Clipboard's places on its front, back from More with its More (pages round 4, Sven's Q100): the apps never
    /// recorded, card numbers and keys that expire, the panel's Return and sort, and the tags.
    case clipNever, clipExpire, clipPanel, clipTags
    /// Open with's place on its front, back from More with its More (pages round 4, Sven's Q103): the app or site each
    /// role key opens.
    case appsForKeys
    /// Voice's More (simplify-pages T12) and its places: the recent takes, the replacements, and Read aloud's media and
    /// better voices; dictation's key and what shows while you speak (Sven, 2026-11-11, after 2276) and the taught words
    /// (pages round 4, Sven's Q101) are places on the front again.
    case voiceMore, voiceDictation, voiceTakes, voiceWords, voiceReplacements, voiceReadAloud
    /// Captures' places on its fronts, back from More with its More (pages round 4, Sven's Q102: "recording stuff in
    /// recording front and capture (screenshot) stuff in capture front"): the capture options and the ten other capture
    /// keys on Capture, a recording's quality, resolution, frame rate and clicks on Recording.
    case captureOptions, captureKeys, recordingQuality
    /// Launcher's More (simplify-pages T15) and its place beside `aliases` and `quicklinks`: Translate's pair; and the rows
    /// the root can list too, a place on Your menu again (pages round 4, Sven's Q96).
    case menuMore, menuExtras, translate
    /// What Install and Update list, Recommend apps and the self-updating casks: a place on Install's Catalogue (on its More,
    /// beside `helpers` and `hiddenApps`, from simplify-pages T16 until pages round 4, Sven's Q104).
    case installMore, installLists
    /// System's places on its front: the sound input, the keyboard layout and the mouse's speeds (on a More tab from
    /// simplify-pages T17 until Sven, 2026-11-11, after 2276). Each part's keys sit in its own card (pages round 5).
    case soundInput, keyboardLayout, mouseSpeed
    /// AI Setup's places, back from More with AI's More (pages round 4, Sven's Q105): the fallback provider, the AI's keys
    /// and when a chat starts over.
    case aiFallback, aiKeys, aiNewChat
    /// Keys' More (simplify-pages T14) and its place beside `overlay`, `keySwaps` and `exportImport`, Binds' tabs until
    /// then: the keyboard's lock for cleaning.
    case bindsMore, cleaning
    /// Workspaces' More (simplify-pages T18) and its places, each for the workspace picked on the front: the Scrolling
    /// layout's rules and the swipe. What opens there (Sven, 2026-11-11, after 2276), the rules, a preset and the window
    /// snapshot (Sven's round 3 notes on build 2300) and each workspace's monitor (pages round 4, Sven's Q97) are places on
    /// the front again.
    case workspacesMore, workspaceOpens, workspaceRules, workspaceScrolling, workspaceMonitors, workspaceSwipe

    public var page: AppPage {
        switch self {
        case .plainCombos, .conflicts, .overlay, .mouse, .keySwaps, .exportImport, .bindsMore, .cleaning: .binds
        case .abilities, .aliases, .quicklinks, .rings, .menuMore, .menuExtras, .translate: .menu
        case .fileSearch, .duplicates, .folders: .files
        case .reports: .upkeep
        case .catalogue, .webApps, .helpers, .hiddenApps, .installMore, .installLists: .install
        case .soundInput, .keyboardLayout, .mouseSpeed: .system
        case .workspacesMore, .workspaceOpens, .workspaceRules, .workspaceScrolling, .workspaceMonitors, .workspaceSwipe, .windowShelf: .workspaces
        case .permissions, .about, .hyperKey, .status, .data, .notifications: .general
        case .floatApps, .floatTitles, .motion, .focusedWindow: .tiling
        case .clipNever, .clipExpire, .clipPanel, .clipTags: .clipboard
        case .appsForKeys: .openWith
        case .voiceMore, .voiceDictation, .voiceTakes, .voiceWords, .voiceReplacements, .voiceReadAloud: .voice
        case .captureOptions, .captureKeys, .recordingQuality: .captures
        case .extensionCatalogue: .extensions
        case .agents: .configs
        case .aiSetup, .aiFallback, .aiKeys, .aiNewChat: .ai
        case .recording, .captureHistory: .captures
        case .wallpaper, .themeCatalogue, .lookMore, .lookStyle, .menuLayout, .windowLayout, .appsShowAs, .glassTuning, .cursor, .wallpaperCycle: .look
        }
    }

    /// The part a `tab=` name stands for on `page`: its raw name, but on Extensions `catalogue` is its own Catalogue,
    /// not Install's.
    /// `more` is the page's More tab.
    public static func tab(_ name: String, on page: AppPage) -> AppSection? {
        // AI's More went back onto Setup (pages round 4): its link lands there, not on the chat.
        if name == "more" { return more(of: page) ?? (page == .ai ? .aiSetup : nil) }
        return page == .extensions && name == "catalogue" ? .extensionCatalogue : AppSection(rawValue: name)
    }

    /// A page's More tab (simplify-pages T7), nil while its front holds everything. A page that gains one adds it here and
    /// its blocks to `onMoreTab`.
    public static func more(of page: AppPage) -> AppSection? {
        switch page {
        case .voice: .voiceMore
        case .menu: .menuMore
        case .install: .installMore
        case .binds: .bindsMore
        case .workspaces: .workspacesMore
        case .look: .lookMore
        default: nil
        }
    }

    /// The places that are blocks on their page's More tab.
    private static let onMoreTab: Set<AppSection> = [.windowShelf,
                                                     .voiceTakes, .voiceReplacements, .voiceReadAloud,
                                                     .translate, .aliases, .quicklinks,
                                                     .helpers, .hiddenApps,
                                                     .exportImport, .cleaning,
                                                     .workspaceScrolling, .workspaceSwipe,
                                                     .lookStyle, .menuLayout, .windowLayout, .appsShowAs]

    /// The places that are blocks on their page's front (Sven, 2026-11-11, after 2276: back from More): a link or the search
    /// opens the front and scrolls to the block (the window's `blockFocus`, as for a block on More).
    private static let onFrontOf: Set<AppSection> = [.workspaceOpens, .workspaceRules, .workspaceMonitors, .focusedWindow, .floatApps, .floatTitles, .motion, .appsForKeys,
                                                     .clipNever, .clipExpire, .clipPanel, .clipTags,
                                                     .captureOptions, .captureKeys, .recordingQuality, .aiFallback, .aiKeys, .aiNewChat,
                                                     .hyperKey, .permissions, .status, .data, .notifications, .about,
                                                     .keySwaps, .overlay, .menuExtras, .glassTuning, .cursor, .wallpaperCycle,
                                                     .soundInput, .keyboardLayout, .mouseSpeed, .voiceDictation,
                                                     .voiceWords, .installLists]

    /// A block on its page's front that a link or the search scrolls to.
    public var onFront: Bool { Self.onFrontOf.contains(self) }

    /// The tab a front block sits on when it is not the page's first view (pages round 4): a recording's quality on
    /// Captures' Recording, the AI's fallback, keys and new chat on AI's Setup, and what Install lists on its Catalogue
    /// (Install is only its parts). Nil for the page's own first view.
    public var frontTab: AppSection? {
        switch self {
        case .recordingQuality: .recording
        case .aiFallback, .aiKeys, .aiNewChat: .aiSetup
        case .installLists: .catalogue
        default: nil
        }
    }

    public var isMore: Bool { Self.more(of: page) == self }

    /// The More tab a place sits on: a link or a search to it opens that tab and marks the place's block there.
    public var onMore: AppSection? { Self.onMoreTab.contains(self) ? Self.more(of: page) : nil }

    /// Binds' tabs drawn as a plain page under the frame's bar, not on the keyboard: Mouse and More (Overlay, Swap keys,
    /// Export and import and Cleaning, simplify-pages T14).
    public var isPlainBindsPage: Bool { [.mouse, .bindsMore].contains(self) }

    /// Conflicts open as a sheet over Binds rather than as a tab.
    public var opensAsSheet: Bool { self == .conflicts }
    /// Shown as a tab across the page's top; Plain combos is Binds' last sublayer tab instead (card agent-bo-95422894),
    /// conflicts a sheet.
    public var isTab: Bool { !opensAsSheet && !isMerged }

    /// Parts drawn on their page's own body: Plain combos as a sublayer, the places on a More tab or a front, the extension
    /// catalogue (Q601) and Look's Wallpaper, which a link scrolls to. The search still lands on them.
    public var isMerged: Bool { self == .plainCombos || onMore != nil || onFront || self == .extensionCatalogue || self == .wallpaper }

    public var title: String {
        switch self {
        case .plainCombos: "Without Hyper"
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
        case .helpers: "Command-line tools"
        case .hiddenApps: "Hidden apps"
        case .permissions: "Permissions"
        case .hyperKey: "Hyper key"
        case .status: "Status"
        case .data: "Data"
        case .notifications: "Notifications"
        case .voiceMore, .menuMore, .installMore, .bindsMore, .workspacesMore, .lookMore: "More"
        case .workspaceOpens: "Opens here"
        case .workspaceRules: "Rules and snapshot"
        case .workspaceScrolling: "Scrolling"
        case .workspaceMonitors: "Monitors"
        case .workspaceSwipe: "Swipe"
        case .cleaning: "Cleaning"
        case .aiFallback: "Fallback"
        case .aiKeys: "Keys"
        case .aiNewChat: "New chat"
        case .soundInput: "Input"
        case .keyboardLayout: "Keyboard layout"
        case .mouseSpeed: "Mouse"
        case .installLists: "What Pilot lists"
        case .menuExtras: "More rows"
        case .translate: "Translate"
        case .captureOptions: "Capture options"
        case .captureKeys: "More capture keys"
        case .recordingQuality: "Recording quality"
        case .voiceDictation: "Dictation"
        case .voiceTakes: "Fix what you just said"
        case .voiceWords: "Words"
        case .voiceReplacements: "Replacements"
        case .voiceReadAloud: "Read aloud"
        case .appsForKeys: "Apps for keys"
        case .clipNever: "Never record from"
        case .clipExpire: "Card numbers and keys"
        case .clipPanel: "In the panel"
        case .clipTags: "Tags"
        case .floatApps: "Always float: apps"
        case .floatTitles: "Always float: window titles"
        case .motion: "Mouse and motion"
        case .focusedWindow: "Focused window"
        case .windowShelf: "Window shelf"
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
        case .themeCatalogue: "Catalogue"
        case .lookStyle: "Style"
        case .menuLayout: "Hyper+Space menu"
        case .windowLayout: "Window layout"
        case .appsShowAs: "Apps show as"
        case .glassTuning: "Transparency and blur"
        case .cursor: "Cursor"
        case .wallpaperCycle: "Wallpaper folders"
        }
    }

    var keywords: [String] {
        switch self {
        case .plainCombos: ["plain combo", "plain combos", "left option", "alt", "vim"]
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
        case .helpers: ["helper", "helpers", "homebrew", "brew", "mole", "mas", "npm", "cargo", "command-line tools"]
        case .hiddenApps: ["hide app", "hidden app", "unhide", "hide from finder", "declutter", "chess"]
        case .permissions: ["accessibility", "full disk access", "permission", "microphone", "screen recording", "input monitoring",
                            "system events", "automation"]
        case .hyperKey: ["hyper keys", "layer keys", "left option", "right option", "left command", "right command", "left control",
                         "right control", "escape", "quick tap", "bind hints", "nudge", "hold hyper", "overlay delay"]
        case .status: ["key engine", "keyboard engine", "password field lock", "secure input", "tiler", "health", "diagnostics", "log", "running"]
        case .data: ["folder", "application support", "pilot command", "cli", "link", "developer", "developer pages", "uninstall", "terminal",
                     "ghostty"]
        case .notifications: ["notification", "notifications", "banner", "bell", "cards", "notification center", "hide banner"]
        case .voiceMore, .menuMore, .installMore, .bindsMore, .workspacesMore, .lookMore: []
        case .themeCatalogue: ["theme catalogue", "browse themes", "more themes", "get theme", "download theme", "update theme", "remove theme",
                               "theme gallery"]
        case .workspaceOpens: ["opens here", "open what is missing", "open now", "at login", "keep this layout"]
        case .workspaceRules: ["app rule", "always opens on", "always lands here", "from a preset", "preset", "snapshot", "save", "restore",
                               "reopen"]
        case .workspaceScrolling: ["scrolling", "centre column", "center column", "column width", "focus stays"]
        case .workspaceMonitors: ["monitor", "display", "which screen"]
        case .workspaceSwipe: ["swipe", "trackpad", "three fingers"]
        case .cleaning: ["cleaning", "lock keyboard", "keyboard lock", "clean the keyboard", "wipe"]
        case .aiFallback: ["fallback", "backup ai", "when the ai fails"]
        case .aiKeys: ["ai keys", "ask ai key", "fix text", "fix selected text", "selection tools", "selection pill"]
        case .aiNewChat: ["new chat after", "new chat", "start a new chat", "chat resets"]
        case .soundInput: ["input", "microphone", "mic", "input volume", "input device"]
        case .keyboardLayout: ["keyboard layout", "input source", "layout", "typing in"]
        case .mouseSpeed: ["pointer speed", "tracking speed", "mouse speed", "cursor speed", "cycle speeds"]
        case .installLists: ["recommend apps", "recommendations", "picks", "self-updating", "casks", "update themselves"]
        case .menuExtras: ["more rows", "add a row", "extra rows", "rows to add", "rows you can add"]
        case .translate: ["translate", "translation", "language", "translate into"]
        case .captureOptions: ["capture menu", "hide desktop icons", "hide icons", "thumbnail", "thumbnail place", "scrolling capture",
                               "scrolls for you", "delay"]
        case .captureKeys: ["capture keys", "read text", "qr code", "ocr", "ui element", "subject", "background removed", "mark up",
                            "pick a colour", "colour picker", "last area", "edit the last capture", "scrolling upward"]
        case .recordingQuality: ["quality", "resolution", "frame rate", "fps", "show clicks", "retina"]
        case .voiceDictation: ["dictation key", "while you speak", "show it in", "pill", "position", "waveform", "waveform colour",
                               "copy the words", "pause media"]
        case .voiceTakes: ["fix a take", "fix what you just said", "recent takes", "take"]
        case .voiceWords: ["words", "vocabulary", "custom words", "teach"]
        case .voiceReplacements: ["replacements", "replace", "replacement"]
        case .voiceReadAloud: ["media playing", "get better voices", "premium voices", "enhanced voices"]
        case .appsForKeys: ["apps for keys", "role", "role key", "terminal app", "notes app", "password manager", "music app", "mail app"]
        case .clipNever: ["never record", "never record from", "ignore app", "exclude app", "password manager"]
        case .clipExpire: ["expire", "card number", "card numbers", "copied key", "secret", "minutes"]
        case .clipPanel: ["return", "paste or copy", "copy only", "sort", "sort by", "reversed", "order"]
        case .clipTags: ["tags", "tag", "tag colour"]
        case .floatApps: ["always float", "float apps", "float", "floating"]
        case .floatTitles: ["window title", "float titles", "title"]
        case .motion: ["drag", "drag windows", "move windows", "resize", "glide", "animate", "animate windows"]
        case .focusedWindow: ["focused window", "border width", "border colour", "border color", "how dark", "shake", "swings", "within",
                              "contrast"]
        case .windowShelf: ["window shelf", "shelf", "stage", "stills", "live", "window pictures"]
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
        // Its keys, fallback and new chat are places of their own on Setup (pages round 4).
        case .aiSetup: ["provider", "api key", "model", "effort", "anthropic", "openai", "ollama", "codex", "sign in"]
        case .recording: ["recording", "screen recording", "record", "movies", "mp4", "countdown", "count down", "recordings folder"]
        case .captureHistory: ["capture history", "past captures", "old screenshots", "combine images", "stitch images", "size cap"]
        case .wallpaper: ["wallpaper", "desktop picture", "background", "next wallpaper", "previous wallpaper", "change on its own"]
        case .lookStyle: ["style", "instrument", "toybox", "look of pilot"]
        case .menuLayout: ["menu layout", "menu style", "line menu", "classic menu", "rail menu"]
        case .windowLayout: ["window layout", "toolbar tabs", "rail and page list"]
        case .appsShowAs: ["apps show as", "app icons", "icon only", "title only", "app names"]
        case .glassTuning: ["transparency", "blur", "see through", "frosted"]
        case .cursor: ["cursor", "pointer", "trail", "ripple", "spotlight", "cursor colour", "cursor shape", "cursor size", "bigger cursor",
                       "pilot draws it", "restore cursor", "classic cursor"]
        case .wallpaperCycle: ["wallpaper folders", "own folders", "per workspace wallpaper", "per screen wallpaper", "cycle wallpaper", "shuffle",
                               "wallpaper order", "screens", "every screen", "browse as gallery", "next wallpaper key"]
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
        "pilotmenu": AppPlace(.pilotMenu), "dropdown": AppPlace(.pilotMenu),
        "installCatalogue": AppPlace(.catalogue), "pomodoro": AppPlace(.extensionCatalogue),
        "pilot": AppPlace(.general), "setup": AppPlace(.system), "history": AppPlace(.stats), "defaults": AppPlace(.openWith),
        "defaultApps": AppPlace(.openWith), "snapshots": AppPlace(.workspaceRules), "onOff": AppPlace(.home), "otherApps": AppPlace(.general),
        "convert": AppPlace(.files), "ask": AppPlace(.ai), "monitors": AppPlace(.workspaceMonitors), "swipe": AppPlace(.workspaceSwipe),
        "instructions": AppPlace(.agents), "launcher": AppPlace(.menu),
        // System's More, gone since its parts came back to the front (Sven, 2026-11-11, after 2276).
        "systemMore": AppPlace(.system),
        // More tabs gone since Sven ticked their blocks back onto the fronts (pages round 4).
        "tilingMore": AppPlace(.tiling), "openWithMore": AppPlace(.openWith), "clipboardMore": AppPlace(.clipboard),
        "capturesMore": AppPlace(.captures), "aiMore": AppPlace(.aiSetup), "pilotMore": AppPlace(.general),
    ]

    /// The place a page name stands for: a page, a part, an old name, or nil.
    public static func named(_ name: String) -> AppPlace? {
        renamed[name] ?? AppPage(rawValue: name).map { AppPlace($0) } ?? AppSection(rawValue: name).map { AppPlace($0) }
    }

    /// The place `pilot://open?page=<page>[&tab=<section>]` names, the old page names included; nil when it names none or
    /// an unknown one (the window opens as usual). A tab that moved off its old page in C3 follows it there:
    /// `page=workspaces&tab=tiling` opens Tiling, `page=binds&tab=abilities` Launcher › Abilities, `page=install&tab=reports`
    /// Update & Clean › Reports, `page=defaults&tab=configs` Configs. Sven 2026-10-10: `page=clipboard&tab=snippets` opens
    /// Snippets, `page=menu&tab=fileSearch` Files › File search, `page=activity&tab=stats` (or `tab=history`) Stats.
    public static func linked(_ url: URL) -> AppPlace? {
        guard let place = url.queryValue("page").flatMap(named) else { return nil }
        // System's section, a card on its front or the keyboard layout's or the mouse's place.
        if place == AppPlace(.system), let setup = SetupSection.linked(url) { return setup.place }
        guard place.section == nil, let name = url.queryValue("tab") else { return place }
        if let tab = AppSection.tab(name, on: place.page), tab.page == place.page { return AppPlace(tab) }
        return movedTabs[name] ?? place
    }

    /// The tabs that left their page in C3, or took a new name, by their old `tab=` name.
    static let movedTabs: [String: AppPlace] = [
        "tiling": AppPlace(.tiling), "abilities": AppPlace(.abilities), "reports": AppPlace(.reports), "configs": AppPlace(.configs),
        "defaultApps": AppPlace(.openWith), "snapshots": AppPlace(.workspaceRules), "history": AppPlace(.stats),
        "snippets": AppPlace(.snippets), "fileSearch": AppPlace(.fileSearch), "stats": AppPlace(.stats),
        "monitors": AppPlace(.workspaceMonitors), "swipe": AppPlace(.workspaceSwipe),
        // The page map (2026-10-17): General's export and import is Binds'; Helpers, once a General block, is Install's.
        "exportImport": AppPlace(.exportImport), "helpers": AppPlace(.helpers),
        // Rings left Binds for Launcher (Sven on Build 76).
        "rings": AppPlace(.rings),
        // The window shelf left Tiling's More for Workspaces' (Sven, 2026-11-11, after 2276); the mouse's buttons left
        // Binds for System (Sven's Q68) and came back (round 3), so `page=system&tab=mouse` lands on Binds; Tiling's
        // mouse and motion went there too (Q78) and came back (Q81), so `page=system&tab=motion` lands on Tiling's front.
        "windowShelf": AppPlace(.windowShelf), "mouse": AppPlace(.mouse), "motion": AppPlace(.motion),
    ]

    /// Places whose title holds the query first (a page's, then a part's), then places with a setting that does; when
    /// none, those a typo of it finds, the closest first, a title before a setting (FuzzyRanker.Filter); empty for a
    /// blank query. Developer pages and their parts only while `developer` is on.
    public static func search(_ query: String, developer: Bool = true) -> [AppPlace] {
        let filter = FuzzyRanker.Filter(query)
        guard !filter.typed.isEmpty else { return [] }
        // A More tab is found by its blocks, each a place of its own, never by its title.
        let all = (AppPage.allCases.map { AppPlace($0) } + AppSection.allCases.filter { !$0.isMore }.map { AppPlace($0) })
            .filter { developer || !$0.page.isDeveloper }
        let byTitle = all.filter { filter.holds([$0.title]) }
        let held = byTitle + all.filter { place in !byTitle.contains(place) && filter.holds(place.keywords) }
        guard held.isEmpty else { return held }
        return FuzzyRanker.Filter.closest(all) { place in
            filter.edits([place.title]).map { $0 * 2 } ?? filter.edits(place.keywords).map { $0 * 2 + 1 }
        }
    }

    /// "Update & Clean › Reports", or the page's title; messages name a place by it, so a renamed page renames them too
    /// (card agent-bo-95423031).
    public var title: String { section.map { $0.title } ?? page.title }
    /// A place on a More tab or on a front's other tab names the tab too: "Pilot › More › Permissions", "Captures ›
    /// Recording › Recording quality".
    public var path: String {
        guard let section else { return page.title }
        return [page.title, section.onMore?.title ?? section.frontTab?.title, section.title].compactMap(\.self).joined(separator: " › ")
    }
    var keywords: [String] { section?.keywords ?? page.keywords }
}

/// A part of the System page (Setup until C3) a key or a link opens it at (card agent-bo-95422805): Hyper+Ctrl+A, B and W
/// land on Sound, Bluetooth and Wi-Fi.
public enum SetupSection: String, CaseIterable, Sendable {
    case sound, wifi, bluetooth, displays, keepAwake, keyboard, mouse

    /// The section `pilot://open?page=system&section=<name>` (or the old `page=setup`) names; nil when it names none or an unknown one.
    public static func linked(_ url: URL) -> SetupSection? { url.queryValue("section").flatMap(SetupSection.init(rawValue:)) }

    /// Where a link or a key to this part lands: System, or the keyboard layout's or the mouse's place on its front (on
    /// its More from simplify-pages T17 until Sven, 2026-11-11, after 2276).
    public var place: AppPlace {
        switch self {
        case .keyboard: AppPlace(.keyboardLayout)
        case .mouse: AppPlace(.mouseSpeed)
        default: AppPlace(.system)
        }
    }
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
        if !accessibilityGranted { list.append(Problem(kind: .accessibility, title: "Accessibility is not granted", detail: "Pilot sees no keys until it is", place: AppPlace(.general))) }
        // Accessibility's Grant is Needs you on Pilot's front until it is granted; Password field lock is on its Status.
        if let secureInput { list.append(Problem(kind: .secureInput, title: secureInput.title, detail: secureInput.detail, place: AppPlace(.status))) }
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
