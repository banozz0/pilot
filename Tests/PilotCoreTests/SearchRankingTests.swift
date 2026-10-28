import Foundation
import Testing
@testable import PilotCore

/// The menu's ranking against what Sven really types (card agent-bo-95422766): his 107 installed apps plus Finder, the
/// actions and branches the root search lists, files from his index, and 40 queries, each with the row it must put first or in the
/// top few. Vicinae's results on the same rows: side-by-side card http://localhost:8228/p/i_uoBUaJho8.
@Suite("Search ranking on the user's rows")
struct SearchRankingTests {
    static let apps = [
        "Activity Monitor", "AeroSpace", "AirPort Utility", "App Store", "Apps", "Audio MIDI Setup", "Automator", "Bitwarden",
        "Blip", "Bluetooth File Exchange", "Books", "Calculator", "Calendar", "Cap", "Cardinal X", "ChatGPT", "Chess", "Claude",
        "Claude Code URL Handler", "ClipBook Rust", "Clock", "CodexBar", "ColorSync Utility", "Console", "Contacts", "CuaDriver",
        "Deskflow", "Dictionary", "Digital Color Meter", "Disk Utility", "Empryo", "FaceTime", "Finder", "FindMy", "FluidVoice",
        "Font Book", "Freeform", "Games", "Ghostex", "Ghostty", "Google Chrome", "Grapher", "Hammerspoon", "Hermes",
        "HermesContext", "Home", "Image Capture", "Image Playground", "Journal", "Karabiner-Elements", "Karabiner-EventViewer",
        "Magnifier", "Mail", "Maps", "Messages", "Migration Assistant", "Mission Control", "Music", "News", "NordVPN", "Notes",
        "Obsidian", "Passwords", "Phone", "Photo Booth", "Photos", "Podcasts", "Preview", "Print Center", "QuickTime Player",
        "Reminders", "Reminders MenuBar", "Remote Mouse", "Safari", "Screen Sharing", "Screenshot", "Script Editor", "Shortcuts",
        "Shottr", "Siri", "Siri AI", "SpaceO Viewer", "Spotifast", "Stats", "Stickies", "Stocks", "System Information",
        "System Settings", "TV", "Tailscale", "Telegram", "Terminal", "TextEdit", "Time Machine", "Tips", "Vicinae",
        "Visual Studio Code", "VoiceMemos", "VoiceOver Utility", "Weather", "WhatsApp", "Wispr Flow", "X", "Xcode", "Zen",
        "iPhone Mirroring", "uBlock Origin Lite", "vesktop",
    ]
    static let actions = [
        "Apps menu", "Bluetooth settings", "Capture menu", "Clipboard history", "Close all windows of the app", "Close window",
        "Colour picker", "Display settings", "Emoji picker", "Float or tile window",
        "Float or tile workspace", "Focus settings", "Lock screen", "Log out", "Minimise", "Mission Control", "Mute",
        "Next track", "Next window of the app", "Pilot menu", "Play or pause", "Previous track", "Restart",
        "Restore Shottr's own shortcuts", "Screen recording", "Shut down", "Sleep", "Sound settings", "System menu",
        "Dark mode on or off", "Fullscreen on or off", "Turn Shottr's own shortcuts off", "Wi-Fi on or off", "Volume down",
        "Volume up", "Wi-Fi settings", "lazygit: pick a repo", "Keybindings", "Open Pilot", "Rescue stranded windows",
        "Restore workspace snapshot", "Save workspace snapshot", "Gaps on or off", "Capture area", "Capture a window",
        "Capture full screen", "Capture scrolling", "Capture text",
    ]
    static let entries = apps.map { MenuEntry(title: $0, target: .app("app.\($0)"), home: .apps) }
        + actions.map { MenuEntry(title: $0, target: .action("action.\($0)")) }

    /// The query, the row Sven means, and how high it must rank (1 is first).
    static let cases: [(query: String, want: String, within: Int)] = [
        ("vsc", "Visual Studio Code", 1), ("calc", "Calculator", 1), ("zen", "Zen", 1), ("term", "Terminal", 1),
        ("sys", "System Settings", 3), ("safri", "Safari", 1), ("fidner", "Finder", 1), ("ghost", "Ghostty", 2),
        ("obs", "Obsidian", 1), ("tele", "Telegram", 1), ("chrome", "Google Chrome", 1), ("whats", "WhatsApp", 1),
        ("act", "Activity Monitor", 1), ("am", "Activity Monitor", 1), ("xc", "Xcode", 1), ("msg", "Messages", 1),
        ("rem", "Reminders", 1), ("settings", "System Settings", 1), ("wifi", "Wi-Fi settings", 2),
        ("blue", "Bluetooth settings", 2), ("display", "Display settings", 1),
        // Second since P53: macOS's Sound pane, titled exactly "sound", leads with the settings rows added.
        ("sound", "Sound settings", 2),
        ("lock", "Lock screen", 1), ("dark", "Dark mode on or off", 1), ("close win", "Close window", 1), ("mute", "Mute", 1),
        ("clip", "Clipboard history", 2), ("emoji", "Emoji picker", 1), ("snapshot", "Save workspace snapshot", 2),
        ("rescue", "Rescue stranded windows", 1), ("telegarm", "Telegram", 1), ("obsidain", "Obsidian", 1),
        // Typos that listed nothing or the wrong row before Sven 2026-10-19: two edits from eight letters, and Mail by
        // a swap over a row that only holds the letters.
        ("calcualtro", "Calculator", 1), ("keybnidigns", "Keybindings", 1), ("mial", "Mail", 1),
    ]

    /// Files as the index answers them on Sven's Mac (side-by-side card), all provided to every search so they
    /// compete with the apps and actions, as they do in the menu.
    static let files = MenuEntries.files([
        "/Users/ada/code/dotfiles/keymap", "/Users/ada/code/dotfiles/keymap/keymap.toml",
        "/Users/ada/code/_references/zed/crates/gpui/src/keymap", "/Users/ada/code/pilot/SPEC.md",
        "/Users/ada/code/recipes/SPEC.md", "/Users/ada/Notes/Projects/Pilot/Journal/Round 6 built.md",
        "/Users/ada/Notes/Projects/Pilot/Journal/Round 5 built.md", "/Users/ada/code/oss/sideshow",
        "/Users/ada/code/pilot", "/Users/ada/code/dotfiles/workstation/aerospace/aerospace.toml",
        "/Users/ada/code/oss/agent-kit/tools/budget_config.py",
    ].map { (path: $0, edited: nil) }, home: "/Users/ada")

    /// File queries from the side-by-side card, typos included. pilot also names Pilot's own actions (Pilot menu, Open
    /// Pilot), which came before the folder when files counted 0.8 under All (card agent-bo-95422777); since card
    /// agent-bo-95422968 they rank in the Files view, among files only.
    static let fileCases: [(query: String, want: String, within: Int)] = [
        ("spec.md", "SPEC.md", 1), ("round 6", "Round 6 built.md", 1), ("kemap", "keymap", 2), ("keymap", "keymap", 1),
        ("sidehsow", "sideshow", 1), ("pilot", "pilot", 3), ("aerospace", "aerospace.toml", 2), ("budget", "budget_config.py", 1),
    ]

    /// The rows a root search lists, or the Files view's.
    func top(_ query: String, files: Bool = false) -> [String] {
        var nav = MenuNavigator(entries: Self.entries)
        nav.provide(.file, Self.files)
        nav.query = query
        if files { nav.openFiles() }
        return nav.matched.map(\.title)
    }

    @Test("Each query puts the row the user means at the top", arguments: cases.map { [$0.query, $0.want, String($0.within)] })
    func ranks(_ c: [String]) {
        let rows = top(c[0]), rank = rows.firstIndex(of: c[1]).map { $0 + 1 }
        #expect(rank != nil && rank! <= Int(c[2])!, "\(c[0]): \(c[1]) ranked \(rank.map(String.init) ?? "nowhere") in \(rows.prefix(3))")
    }

    @Test("Each file query puts the file the user means at the top of the Files view",
          arguments: fileCases.map { [$0.query, $0.want, String($0.within)] })
    func ranksFiles(_ c: [String]) {
        let rows = top(c[0], files: true), rank = rows.firstIndex(of: c[1]).map { $0 + 1 }
        #expect(rank != nil && rank! <= Int(c[2])!, "\(c[0]): \(c[1]) ranked \(rank.map(String.init) ?? "nowhere") in \(rows.prefix(3))")
    }

    /// Sven's screenshot, 2026-10-05 (card agent-bo-95422777): typing am, the index's files arrived after the menu showed
    /// Activity Monitor first, and eight files whose names start with am pushed it to the bottom, still selected.
    @Test("am keeps Activity Monitor first and selected; files starting with am never list under All (card agent-bo-95422968)")
    func appsBeforeFiles() {
        var nav = MenuNavigator(entries: Self.entries)
        nav.query = "am"
        #expect(nav.rows.first?.title == "Activity Monitor")
        nav.provide(.file, MenuEntries.files([
            "/Users/ada/code/oss/agent-kit/fixtures/amazon-order.eml", "/Users/ada/Notes/Films/American Psycho.md",
            "/Users/ada/code/oss/editor/tools/amend-existing.mjs", "/Users/ada/Notes/Garden/Amaryllis bulbs.md",
            "/Users/ada/Notes/Films/American Gangster.md", "/Users/ada/code/oss/yt-dlp/americastestkitchen.py",
            "/Users/ada/code/oss/editor/tools/amend-existing-lib.mjs", "/Users/ada/Downloads/Amber-eyed cat.png",
        ].map { (path: $0, edited: nil) }, home: "/Users/ada"))
        #expect(nav.rows.first?.title == "Activity Monitor")
        #expect(nav.selection == 0 && nav.selected?.title == "Activity Monitor")
        #expect(!nav.rows.contains { $0.title == "American Psycho.md" })
    }

    @Test("A typo lists only while no row spells the query surely, and a row named by a typo then leads one that holds the letters")
    func typosOnlyWhenNothingIsSpelledSurely() {
        #expect(FuzzyRanker.rank(["Finder", "fidner notes.md"], query: "fidner") { $0 } == ["fidner notes.md"])
        #expect(FuzzyRanker.rank(["Finder", "Notes"], query: "fidner") { $0 } == ["Finder"])
        #expect(top("tele").prefix(2) == ["Telegram"])
        #expect(!top("wifi").contains("Wispr Flow"))
        // Terminal holds m, i, a, l in order, 67: too weak to keep the typo out (Sven 2026-10-19).
        #expect(FuzzyRanker.rank(["Terminal", "Mail"], query: "mial", title: { $0 }, name: { $0 }) == ["Mail", "Terminal"])
    }

    @Test("Letters scattered across words match nothing; a two-letter run inside a word is too weak to list")
    func gate() {
        #expect(FuzzyRanker.score("txe", in: "TextEdit") == nil)
        #expect(FuzzyRanker.score("ss", in: "Messages") == nil)
        #expect(FuzzyRanker.score("lock", in: "Clock") != nil)
        #expect(FuzzyRanker.score("msg", in: "Messages") != nil)
    }

    @Test("Frecency still lifts a picked row over an equal match never picked")
    func frecencyKept() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var picks = Frecency()
        picks.record("app:app.System Information", at: now)
        var nav = MenuNavigator(entries: Self.entries, frecency: picks, now: now)
        nav.query = "sys"
        #expect(nav.rows.first?.title == "System Information")
    }
}
