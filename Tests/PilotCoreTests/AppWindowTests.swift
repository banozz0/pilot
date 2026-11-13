import Foundation
import Testing
@testable import PilotCore

@Suite("App window")
struct AppWindowTests {
    @Test("Twenty-seven pages in Home, eight areas and Pilot at the foot; Cmd+1 to 9 open the areas, Cmd+, Pilot; the menu's page is Launcher in an area of its own (P37), AI an area of its own, Agent instructions Configs' Agents tab (page map, Sven 2026-10-17)")
    func pages() {
        #expect(AppPage.allCases.map(\.title) == ["Home", "Binds", "Launcher", "Workspaces", "Tiling", "Menu bar", "Pilot menu", "Look", "System", "Activity",
                                                   "Update & Clean", "Stats", "Clipboard", "Captures", "Snippets", "Notes", "Files", "AI", "Voice", "Install", "Open with",
                                                   "Configs", "Repos", "Fonts", "Pilot", "Extensions", "Widgets"])
        #expect(AppArea.allCases.map(\.title) == ["Home", "Keys", "Launcher", "Desktop", "Mac", "Tools", "Apps", "AI", "Extensions", "Pilot"])
        // Every page in exactly one area.
        #expect(AppArea.allCases.flatMap(\.pages).sorted { $0.rawValue < $1.rawValue } == AppPage.allCases.sorted { $0.rawValue < $1.rawValue })
        for page in AppPage.allCases { #expect(page.area.pages.contains(page), "\(page)") }
        #expect(AppArea.home.pages == [.home] && AppArea.keys.pages == [.binds] && AppArea.launcher.pages == [.menu])
        // Pilot menu beside Menu bar (Sven, 2026-11-12, Q182).
        #expect(AppArea.desktop.pages == [.workspaces, .tiling, .menuBar, .pilotMenu, .look, .widgets])
        // Majors first (simplify-pages T11): ⌘5 opens Update & Clean, ⌘7 Open with.
        #expect(AppArea.mac.pages == [.upkeep, .system, .activity, .stats])
        #expect(AppArea.tools.pages == [.clipboard, .notes, .files, .voice, .captures, .snippets])
        #expect(AppArea.apps.pages == [.openWith, .install, .configs, .repos, .fonts])
        // The Developer switch off (Q715) leaves Configs and Repos out of the list, Ctrl+Tab and the search.
        #expect(AppArea.apps.pages(developer: false) == [.openWith, .install, .fonts])
        #expect(AppArea.next(after: .install, developer: false) == .fonts && AppPlace.search("zshrc", developer: false).isEmpty)
        // AI and Extensions are areas of their own (Sven 2026-10-16).
        #expect(AppArea.ai.pages == [.ai] && AppArea.extensions.pages == [.extensions])
        #expect(AppArea.pilot.pages == [.general])
        #expect(AppArea.allCases.map(\.key) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", ","])
        #expect(AppArea.main.count == 9 && !AppArea.main.contains(.pilot))
        // Ctrl+Tab steps through the area's pages, round to the first; a page alone stays.
        #expect(AppArea.next(after: .workspaces) == .tiling && AppArea.next(after: .look) == .widgets && AppArea.next(after: .widgets) == .workspaces)
        #expect(AppArea.next(after: .home) == .home && AppArea.next(after: .general) == .general)
        // The window layout: the rail by default, for a name it does not know and for the hub, taken out on 2026-10-11.
        #expect(WindowShape(saved: nil) == .rail && WindowShape(saved: "nope") == .rail && WindowShape(saved: "hub") == .rail)
        #expect(WindowShape(saved: "tabs") == .tabs)
        #expect(WindowShape.allCases.map(\.title) == ["Rail and page list", "Toolbar tabs"])
        // Direction 1: Home takes the width, any other page has its area's list, which folds under 900 pt; a search shows it.
        #expect(!RailLayout.showsList(.home, width: 1440, searching: false) && RailLayout.showsList(.home, width: 1440, searching: true))
        // AI takes the width as Home does, its tabs in the header; Extensions keeps its list, its extensions under it.
        #expect(!RailLayout.showsList(.ai, width: 1440, searching: false) && RailLayout.showsList(.extensions, width: 1440, searching: false))
        #expect(RailLayout.showsList(.install, width: 1000, searching: false) && !RailLayout.showsList(.install, width: 760, searching: false))
        #expect(RailLayout.showsList(.menuBar, width: 760, searching: true) && !RailLayout.showsList(.menu, width: 1440, searching: false))
        // An area of one page takes the width as AI does: Keys (Binds), Launcher and Pilot too (Sven 2026-10-18); Extensions lists its pages.
        #expect(!RailLayout.showsList(.binds, width: 1600, searching: false) && !RailLayout.showsList(.general, width: 1440, searching: false))
        #expect(RailLayout.showsList(.binds, width: 1440, searching: true))
        #expect([760, 1000, 1440, 1600, 2000].map(RailLayout.bucket) == [800, 1000, 1440, 1440, 1440])
        #expect(RailLayout.narrow(760) && !RailLayout.narrow(900) && !RailLayout.narrow(0))
        #expect(RailLayout.listWidth(1440) == 236 && RailLayout.listWidth(1000) == 212)
        #expect(RailLayout.hint(.mac) == "⌘5 Mac · ⌃Tab next page" && RailLayout.hint(.keys) == "⌘2 Keys" && RailLayout.hint(.pilot) == "⌘, Pilot")
        #expect(RailLayout.hint(.extensions) == "⌘9 Extensions" && RailLayout.hint(.extensions, rows: 3) == "⌘9 Extensions · ⌃Tab next page")
        // The parts as tabs in the page's header, the sidebar listing pages only (P36): Launcher's, Activity's and Files' own content first.
        #expect(AppPage.menu.tabs.map(\.title) == ["Your menu", "Abilities", "Rings", "More"])
        #expect(AppPage.files.tabs.map(\.title) == ["Convert", "File search", "Duplicates", "Folders"])
        #expect(AppPage.clipboard.tabs.isEmpty && AppPage.snippets.tabs.isEmpty)
        // Reports beside the runs it records, Install's tools and hidden apps on its More (simplify-pages T16).
        #expect(AppPage.upkeep.tabs.map(\.title) == ["Update & Clean", "Reports"] && AppPage.activity.tabs.isEmpty)
        #expect(AppPage.install.tabs.map(\.title) == ["Catalogue", "Web apps", "More"])
        // Overlay, Swap keys and Export and import are places on More (simplify-pages T14, Sven's Q1; Overlay was a tab, story 56).
        #expect(AppPage.binds.tabs.map(\.title) == ["Keyboard", "Mouse", "More"])
        // The page map (Sven 2026-10-17): Configs holds the agents' files, AI its setup, Captures its recording.
        #expect(AppPage.configs.tabs.map(\.title) == ["Apps", "Agents"] && AppPage.ai.tabs.map(\.title) == ["Chat", "Setup"])
        #expect(AppPage.captures.tabs.map(\.title) == ["Capture", "Recording", "History"])
        for page in [AppPage.stats, .activity] { #expect(page.tabs.isEmpty, "\(page)") }
        #expect(AppPage.workspaces.tabs.map(\.title) == ["Workspaces", "More"])
        // System's parts are cards on its front, no More (Sven, 2026-11-11, after 2276).
        #expect(AppPage.system.tabs.isEmpty)
        // Open with's and Tiling's blocks back on their fronts, their More gone (pages round 4, Sven's Q98, Q103).
        #expect(AppPage.openWith.tabs.isEmpty && AppPage.tiling.tabs.isEmpty)
        // Pilot's blocks back on its front, its More gone (pages round 4, Sven's Q106).
        #expect(AppPage.general.tabs.isEmpty)
    }

    /// Every name pilot://open has used for a page or a part, the 21 before the round-4 cut and the 7 C3 renamed or moved,
    /// and where it lands now (C3).
    static let moved: [(String, AppPlace)] = [
        ("home", AppPlace(.home)), ("binds", AppPlace(.binds)), ("plainCombos", AppPlace(.binds, .plainCombos)),
        ("conflicts", AppPlace(.binds, .conflicts)), ("workspaces", AppPlace(.workspaces)),
        ("snapshots", AppPlace(.workspaceRules)), ("tiling", AppPlace(.tiling)), ("topBar", AppPlace(.menuBar)),
        ("webApps", AppPlace(.install, .webApps)), ("installCatalogue", AppPlace(.install, .catalogue)),
        ("configs", AppPlace(.configs)), ("defaultApps", AppPlace(.openWith)), ("clipboard", AppPlace(.clipboard)),
        // Pomodoro became an extension (2026-10-10): its old link opens the Extensions page's catalogue, where it is installed.
        ("pomodoro", AppPlace(.extensions, .extensionCatalogue)), ("setup", AppPlace(.system)), ("general", AppPlace(.general)), ("look", AppPlace(.look)),
        ("permissions", AppPlace(.general, .permissions)), ("exportImport", AppPlace(.binds, .exportImport)),
        // The on/off switch lives on Home; C3 took the Other apps block off General.
        ("onOff", AppPlace(.home)), ("about", AppPlace(.general, .about)),
        // C3's renames and moves.
        ("pilot", AppPlace(.general)), ("stats", AppPlace(.stats)), ("defaults", AppPlace(.openWith)),
        ("otherApps", AppPlace(.general)), ("abilities", AppPlace(.menu, .abilities)), ("reports", AppPlace(.upkeep, .reports)),
        ("menubar", AppPlace(.menuBar)),
        // Activity's History tab is Stats, a page of its own now (Sven 2026-10-10).
        ("history", AppPlace(.stats)),
        // Snippets left Clipboard for a page; convert names the Files page (Sven 2026-10-10).
        ("snippets", AppPlace(.snippets)), ("convert", AppPlace(.files)),
        // AI was Ask (2026-10-11 to the page map); its raw name stays, so page=ai still opens it.
        ("ask", AppPlace(.ai)),
        // The page map (Sven 2026-10-17): Agent instructions is Configs › Agents, Launcher names the menu's page.
        ("instructions", AppPlace(.configs, .agents)), ("launcher", AppPlace(.menu)),
    ]

    @Test("Every old page name still opens: pilot://open lands on the page and part it went to, and a tab that moved follows it")
    func oldLinks() {
        #expect(Self.moved.count == 34 && Set(Self.moved.map(\.0)).count == 34)
        for (name, place) in Self.moved {
            #expect(AppPlace.linked(URL(string: "pilot://open?page=\(name)")!) == place, "\(name)")
            if let section = place.section { #expect(place.page.sections.contains(section), "\(name)") }
        }
        // The new names work too, and every section opens by its own name.
        for page in AppPage.allCases { #expect(AppPlace.linked(URL(string: "pilot://open?page=\(page.rawValue)")!) == AppPlace(page)) }
        for section in AppSection.allCases {
            #expect(AppPlace.linked(URL(string: "pilot://open?page=\(section.page.rawValue)&tab=\(section.rawValue)")!) == AppPlace(section.page, section))
        }
        // The tabs C3 moved to another page, by their old page and tab.
        let tabs: [(String, AppPlace)] = [
            ("page=workspaces&tab=tiling", AppPlace(.tiling)), ("page=binds&tab=abilities", AppPlace(.menu, .abilities)),
            ("page=install&tab=reports", AppPlace(.upkeep, .reports)), ("page=defaults&tab=configs", AppPlace(.configs)),
            ("page=defaults&tab=defaultApps", AppPlace(.openWith)), ("page=workspaces&tab=snapshots", AppPlace(.workspaceRules)),
            ("page=pilot&tab=about", AppPlace(.general, .about)), ("page=setup&section=wifi", AppPlace(.system)),
            ("page=extensions&tab=catalogue", AppPlace(.extensions, .extensionCatalogue)), ("page=install&tab=catalogue", AppPlace(.install, .catalogue)),
            ("page=activity&tab=history", AppPlace(.stats)), ("page=activity&tab=stats", AppPlace(.stats)),
            ("page=clipboard&tab=snippets", AppPlace(.snippets)), ("page=menu&tab=fileSearch", AppPlace(.files, .fileSearch)),
            // The page map's moves: General's export and import is Binds', its helpers Install's.
            ("page=general&tab=exportImport", AppPlace(.binds, .exportImport)), ("page=pilot&tab=exportImport", AppPlace(.binds, .exportImport)),
            ("page=general&tab=helpers", AppPlace(.install, .helpers)),
        ]
        for (query, place) in tabs { #expect(AppPlace.linked(URL(string: "pilot://open?\(query)")!) == place, "\(query)") }
        #expect(AppPlace.linked(URL(string: "pilot://open?page=home&tab=nope")!) == AppPlace(.home))
        #expect(AppPlace.linked(URL(string: "pilot://open")!) == nil)
        #expect(AppPlace.linked(URL(string: "pilot://open?page=nope")!) == nil)
    }

    /// Each page's search words before the cut (main at 5c058ad), by its old name, less the old tiler's config file
    /// ones R3 removed with it (2026-10-10).
    static let oldKeywords: [String: [String]] = [
        "home": ["status", "most used", "problems", "needs you"],
        "binds": ["bind", "key", "shortcut", "preset", "omarchy", "my binds", "sublayer", "reset"],
        "plainCombos": ["plain combo", "left option", "alt", "vim"],
        "conflicts": ["clash", "macos shortcut", "mission control"],
        "workspaces": ["app rule", "always opens on", "layout", "float"],
        "snapshots": ["snapshot", "save", "restore", "reopen"],
        "tiling": ["gaps", "inner", "outer", "rescue"],
        "topBar": ["menu bar", "status bar", "waybar", "hide", "autohide", "clock", "workspaces"],
        "webApps": ["web app", "url", "site", "sign out"],
        "installCatalogue": ["install", "homebrew", "cask", "formula", "catalogue"],
        "configs": ["config", "dotfiles", "ghostty", "neovim", "zshrc", "gitconfig", "starship", "tmux"],
        "defaultApps": ["default app", "open with", "main editor", "editor", "vs code"],
        "clipboard": ["clipboard", "history", "paste", "keep", "never record", "images"],
        "pomodoro": ["focus", "break", "timer"],
        "setup": ["sound", "volume", "mute", "output", "input", "microphone", "speakers", "keep awake", "caffeinate", "sleep", "bluetooth",
                  "headphones", "airpods", "connect", "wi-fi", "wifi", "network", "join", "display", "resolution", "monitor", "screen",
                  "refresh rate"],
        "general": ["hyper", "layer key", "caps lock", "escape", "overlay", "launch at login"],
        "look": ["theme", "wallpaper", "accent", "colours", "ghostty", "omarchy", "font"],
        "permissions": ["accessibility", "secure input", "health", "diagnostics", "log"],
        "exportImport": ["export", "import", "pack", "second mac"],
        // The apps Other apps named (Karabiner-Elements, Hammerspoon, yabai, skhd) left with it in C3; the switch's words find Home.
        "onOff": ["switch", "bad day"],
        "about": ["version", "made with", "licence"],
    ]

    @Test("The keyboard layout's words find System › Keyboard layout (Setup until C3), where section 7 moved it from Look (card agent-bo-95422898)")
    func keyboardLayoutFindsSetup() {
        for word in ["keyboard layout", "input source"] {
            #expect(AppPlace.search(word).contains(AppPlace(.keyboardLayout)) && !AppPlace.search(word).contains(AppPlace(.look)), "\(word)")
        }
    }

    @Test("Translate's language pair feeds the menu's answer, so its words find Launcher › More › Translate (page map, Sven 2026-10-17; was System's; More since simplify-pages T15)")
    func translateFindsLauncher() {
        for word in ["translate", "translation", "language"] { #expect(AppPlace.search(word) == [AppPlace(.translate)], "\(word)") }
    }

    /// Old words whose controls left Pilot's front for a block on its More (simplify-pages T8).
    static let movedToMore: [String: AppSection] = ["escape": .hyperKey, "overlay": .hyperKey, "secure input": .status, "health": .status,
                                                    "diagnostics": .status, "log": .status, "never record": .clipNever,
                                                    // System's input (simplify-pages T17).
                                                    "input": .soundInput, "microphone": .soundInput,
                                                    // Workspaces' rules and snapshot (simplify-pages T18); float lives on Tiling.
                                                    "app rule": .workspaceRules, "always opens on": .workspaceRules, "float": .floatApps,
                                                    "snapshot": .workspaceRules, "save": .workspaceRules, "restore": .workspaceRules,
                                                    "reopen": .workspaceRules]

    @Test("Every word that found a page before the cut finds where that page went, and its old title does too")
    func oldKeywordsFindTheirPlace() {
        #expect(Self.oldKeywords.count == 21 && Set(Self.oldKeywords.keys).isSubset(of: Set(Self.moved.map(\.0))))
        for (name, place) in Self.moved where Self.oldKeywords[name] != nil {
            for word in Self.oldKeywords[name] ?? [] {
                // A word whose control moved to a More tab finds its block there (simplify-pages T8).
                let found = AppPlace.search(word)
                #expect(found.contains(place) || Self.movedToMore[word].map { found.contains(AppPlace($0)) } == true,
                        "\(name): \"\(word)\" finds \(found.map(\.path))")
            }
        }
    }

    @Test("Search still finds every setting: a page's or section's title, or a setting on it, lands where it lives now")
    func search() {
        #expect(AppPlace.search("gaps") == [AppPlace(.tiling)])
        #expect(AppPlace.search("GAPS") == [AppPlace(.tiling)])
        #expect(AppPlace.search("clip") == [AppPlace(.clipboard)])
        #expect(AppPlace.search("caps lock") == [AppPlace(.general)])
        #expect(AppPlace.search("editor") == [AppPlace(.openWith)])
        #expect(AppPlace.search("zshrc") == [AppPlace(.configs)])
        #expect(AppPlace.search("api key") == [AppPlace(.ai, .aiSetup)] && AppPlace.search("claude").first == AppPlace(.ai))
        #expect(AppPlace.search("ask").contains(AppPlace(.ai)), "Ask was AI's name")
        #expect(AppPlace.search("launcher") == [AppPlace(.menu)] && AppPlace.search("agents.md") == [AppPlace(.configs, .agents)])
        #expect(AppPlace.search("homebrew").contains(AppPlace(.install, .helpers)) && AppPlace.search("export") == [AppPlace(.binds, .exportImport)])
        #expect(AppPlace.search("border").contains(AppPlace(.tiling)) && AppPlace.search("fps") == [AppPlace(.captures, .recordingQuality)])
        #expect(AppPlace.search("cpu") == [AppPlace(.stats)] && AppPlace.search("stats") == [AppPlace(.stats)])
        #expect(AppPlace.search("alias").first == AppPlace(.menu, .aliases) && AppPlace.search("never index") == [AppPlace(.files, .fileSearch)])
        #expect(AppPlace.search("convert") == [AppPlace(.files)] && AppPlace.search("heic") == [AppPlace(.files)])
        for word in ["sound", "volume", "output"] { #expect(AppPlace.search(word).first == AppPlace(.system), "\(word)") }
        // The input is its own place on System's front.
        #expect(AppPlace.search("microphone").contains(AppPlace(.soundInput)))
        // Setup was System's name; AI › Setup's title comes first now, System right after it.
        #expect(AppPlace.search("setup").prefix(2) == [AppPlace(.ai, .aiSetup), AppPlace(.system)])
        #expect(AppPlace.search("  ").isEmpty && AppPlace.search("zzz").isEmpty)
        #expect(AppPlace.search("work").first == AppPlace(.workspaces))
        // Each old part is found by its old title, at its new place.
        for (name, place) in Self.moved where place.section != nil {
            let title = place.section!.title
            #expect(AppPlace.search(title).contains(place), "\(name) by \(title)")
        }
        #expect(AppPlace.search("top bar").first == AppPlace(.menuBar) && AppPlace.search("karabiner").isEmpty)
    }

    @Test("pilot://open?page=setup&section= names a System section; none or an unknown one names none (card agent-bo-95422805)")
    func setupSection() {
        for section in SetupSection.allCases {
            #expect(SetupSection.linked(URL(string: "pilot://open?page=setup&section=\(section.rawValue)")!) == section)
        }
        #expect(SetupSection.linked(URL(string: "pilot://open?page=setup")!) == nil)
        #expect(SetupSection.linked(URL(string: "pilot://open?page=setup&section=nope")!) == nil)
    }

    @Test("The Dock shows Pilot only while one of its windows is open")
    func dock() {
        #expect(DockIcon.policy(openWindows: 0) == .menuBarOnly)
        #expect(DockIcon.policy(openWindows: 1) == .dock)
        #expect(DockIcon.policy(openWindows: 2) == .dock)
    }


    @Test("Home draws workspaces 1 to the highest in use, at least 4, empty ones included, named ones after")
    func homeWorkspaces() {
        let one = OccupiedWorkspace(name: "1", apps: ["Ghostty"]), six = OccupiedWorkspace(name: "6", apps: ["Zen"])
        let named = OccupiedWorkspace(name: "scratch", apps: ["Notes"])
        #expect(HomeWorkspaces.cells([one], focused: "1").map(\.name) == ["1", "2", "3", "4"])
        #expect(HomeWorkspaces.cells([one], focused: "1")[1].apps.isEmpty)
        #expect(HomeWorkspaces.cells([one, six, named], focused: "2").map(\.name) == ["1", "2", "3", "4", "5", "6", "scratch"])
        #expect(HomeWorkspaces.cells([], focused: "7").map(\.name) == ["1", "2", "3", "4", "5", "6", "7"])
        #expect(HomeWorkspaces.cells([six], focused: "6")[5] == six)
        // A deleted workspace (Sven 2026-10-17) is no empty cell, and the four drawn are four kept ones.
        let kept = ["1", "2", "4", "5", "6"]
        #expect(HomeWorkspaces.cells([one], focused: "1", kept: kept).map(\.name) == ["1", "2", "4", "5"])
        #expect(HomeWorkspaces.cells([one, six, named], focused: "2", kept: kept).map(\.name) == ["1", "2", "4", "5", "6", "scratch"])
        #expect(HomeWorkspaces.cells([], focused: nil, kept: ["1", "2"]).map(\.name) == ["1", "2"])
    }
}

/// Home's Needs you (card agent-bo-95422787; design round 4, card agent-bo-95422893).
@Suite("Home needs you")
struct HomeProblemsTests {
    @Test("Problems lists only what is wrong, most with the page that fixes it, and nothing when all is well")
    func problems() {
        #expect(HomeProblems.list(accessibilityGranted: true, secureInput: nil, tilerRunning: true,
                                  lastError: nil).isEmpty)
        let all = HomeProblems.list(accessibilityGranted: false, secureInput: .app("Vesktop"), tilerRunning: false,
                                    lastError: "Could not remap Caps Lock.")
        #expect(all.map(\.title) == ["Accessibility is not granted", "Vesktop has the keyboard (a password field)", "Pilot's tiler is not running",
                                      "Could not remap Caps Lock."])
        // Accessibility's Grant is on Pilot's front, Password field lock on More › Status (simplify-pages T8).
        #expect(all.map(\.place) == [AppPlace(.general), AppPlace(.status), AppPlace(.tiling), nil])
        #expect(all[2].kind == .tiler)
    }
}

/// Card agent-bo-95422757: the tiler reads nothing through Accessibility while the screen is locked, so a window made then
/// is never tiled; Pilot's app window asked for on a locked screen waits for the unlock instead.
@Suite("App window on a locked screen")
struct LockedOpenTests {
    @Test("Unlocked, an open shows at once; locked, it waits and the unlock shows the page last asked for")
    func waits() {
        let tiling = AppPlace(.tiling), conflicts = AppPlace(.binds, .conflicts)
        var gate = LockedOpen()
        #expect(gate.request(tiling, screenLocked: false) == .show(tiling))
        #expect(gate.unlocked() == nil, "nothing waits")
        #expect(gate.request(conflicts, screenLocked: true) == .wait)
        #expect(gate.request(nil, screenLocked: true) == .wait, "an open with no page keeps the page asked for")
        #expect(gate.request(AppPlace(.home), screenLocked: true) == .wait)
        #expect(gate.unlocked() == .show(AppPlace(.home)))
        #expect(gate.unlocked() == nil, "shown once")
        #expect(gate.request(nil, screenLocked: true) == .wait)
        #expect(gate.unlocked() == .show(nil), "no page asked for: the page shown last")
        // Moody's REJECT http://localhost:8228/p/ZIMZfj0ZVog: an open on an unlocked screen while one waits replaces it,
        // so the unlock never shows an older page over the newer one.
        #expect(gate.request(AppPlace(.binds), screenLocked: true) == .wait)
        #expect(gate.request(tiling, screenLocked: false) == .show(tiling))
        #expect(gate.unlocked() == nil)
    }

    @Test("The Menu bar page replaces the Top bar page: its links and the old ones land on it, its settings find it")
    func menuBarPage() {
        for link in ["menubar", "menuBar", "topbar", "topBar"] {
            #expect(AppPlace.linked(URL(string: "pilot://open?page=\(link)")!) == AppPlace(.menuBar), "\(link)")
        }
        #expect(AppPage.menuBar.title == "Menu bar")
        #expect(AppPlace.search("top bar").first == AppPlace(.menuBar) && AppPlace.search("waybar") == [AppPlace(.menuBar)]
                && AppPlace.search("in the menu bar").contains(AppPlace(.menuBar)))
        #expect(AppPlace.linked(URL(string: "pilot://open?page=nowhere")!) == nil)
    }
}
