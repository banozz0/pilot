import Foundation
import PilotCore

/// Pilot's ready widgets (Q671), each off until Sven adds it, read-only, and copied out by Duplicate to edit as an ordinary
/// widget folder made here:
/// - This Mac, the clock and calendar, a note, Mac upkeep, the Launcher, Notes, Repos, GitHub and Now playing live in
///   code under ids that start `pilot-`, fed by Pilot's readings, settings, notes, repo reads, gh reads and media
///   helper alone, so they need no trust and run nothing of their own.
/// - The desk widgets (Q694) are the designer's HTML folders on the look kit, bundled in Resources/widgets as `desk-*`:
///   Pilot's own, so trusted without a Trust step (WidgetStore.trust), their feeds run and their pages draw. No folder in
///   Widgets may take one's id.
enum ReadyWidgets {
    static let thisMac = "pilot-this-mac", clock = "pilot-clock", note = "pilot-note", upkeep = "pilot-upkeep"
    static let launcher = "pilot-launcher", notes = "pilot-notes", repos = "pilot-repos"
    static let github = "pilot-github"
    static let nowPlaying = "pilot-now-playing"
    static let folder = "pilot-folder"
    static let markets = "pilot-markets"

    /// Each one's widget.json, as Duplicate to edit writes it out.
    private static let manifests: [String: String] = [
        thisMac: """
            {"id": "pilot-this-mac", "title": "This Mac", "icon": "💻", "version": "1.0",
             "description": "CPU, memory, disk and battery, as Home's This Mac reads them.",
             "draw": "blocks", "data": {"reading": ["cpu", "memory", "disk", "battery"]}, "size": {"width": 260, "height": 230}}
            """,
        clock: """
            {"id": "pilot-clock", "title": "Clock and calendar", "icon": "🕐", "version": "1.0",
             "description": "The time and today's events, once Calendar access is given in the clock's popover.",
             "draw": "blocks", "data": {"reading": ["clock", "calendar"]}, "size": {"width": 260, "height": 220}}
            """,
        // A JSON widget with buttons (Q696, Q697): disk and memory, and Update and Clean, each its Hyper+Space step, which
        // asks before it runs.
        upkeep: """
            {"id": "pilot-upkeep", "title": "Mac upkeep", "icon": "🧹", "version": "1.0",
             "description": "Disk and memory, with Update and Clean a click away: each opens its step in Hyper+Space, which asks before it runs.",
             "draw": "blocks", "data": {"reading": ["disk", "memory"]}, "size": {"width": 260, "height": 160},
             "buttons": [{"title": "Clean", "action": "apps.clean"}, {"title": "Update", "action": "apps.update"}]}
            """,
        // Hyper+Space a click away (Sven, 1.0.2 build 6): the menu's apps, actions, commands and branches Sven picks in Edit
        // widget, as a grid of icon tiles (WidgetLauncher). Its setting keeps the name its action buttons had, so a
        // Launcher placed before keeps its picks.
        launcher: """
            {"id": "pilot-launcher", "title": "Launcher", "icon": "🚀", "version": "1.0",
             "description": "Anything Hyper+Space lists a click away, as a grid of tiles: pick them in Edit widget.",
             "draw": "blocks", "size": {"width": 300, "height": 170},
             "settings": [{"name": "actions", "label": "Tiles", "type": "menu",
                           "default": ["action:apps.clean", "action:apps.update", "action:notes.toggle", "action:apps.install"]}]}
            """,
        // Pilot's notes, by title (a click opens one) or one in full, as its setting picks (WidgetNotes).
        notes: """
            {"id": "pilot-notes", "title": "Notes", "icon": "📒", "version": "1.0",
             "description": "Your notes by title, a click opening one, or one note in full: pick in Edit widget.",
             "draw": "blocks", "data": {"notes": "note"}, "size": {"width": 280, "height": 260},
             "settings": [{"name": "note", "label": "Shows", "type": "note", "default": ""}]}
            """,
        // ~/code's repos with work not committed or pushed (Q725), a click opening one (WidgetRepos).
        repos: """
            {"id": "pilot-repos", "title": "Repos", "icon": "🌿", "version": "1.0",
             "description": "Your repos in ~/code with changes not committed or commits not pushed, read every 5 minutes; a click opens one.",
             "draw": "blocks", "data": {"repos": true}, "size": {"width": 280, "height": 200}}
            """,
        // A GitHub user's contributions (P82), gh's signed-in user unless Edit widget names one (WidgetGitHub).
        github: """
            {"id": "pilot-github", "title": "GitHub", "icon": "🟩", "version": "1.0",
             "description": "Your GitHub contributions over the last year, read by the GitHub CLI (gh) each hour while it shows; another user in Edit widget.",
             "draw": "blocks", "data": {"github": true}, "size": {"width": 540, "height": 190},
             "settings": [{"name": "user", "label": "GitHub user (empty: gh's)", "type": "text", "default": ""}]}
            """,
        // What the Mac plays, its cover and its controls (Q726, Q727; WidgetNowPlaying).
        nowPlaying: """
            {"id": "pilot-now-playing", "title": "Now playing", "icon": "🎵", "version": "1.0",
             "description": "What your Mac plays, from any app or browser tab, with its cover, previous, play or pause and next.",
             "draw": "blocks", "data": {"nowPlaying": true}, "size": {"width": 190, "height": 190}}
            """,
        folder: WidgetFolder.manifest,
        // Prices of the symbols Sven picks in Edit widget, through the Markets extension (P83, WidgetMarkets): one draws
        // its chart, several a list.
        markets: """
            {"id": "pilot-markets", "title": "Markets", "icon": "📈", "version": "1.0",
             "description": "Prices of any coins, stocks, currencies and indices you pick, every minute while it shows, from the Markets extension: one draws its chart, several a list.",
             "draw": "blocks", "data": {"markets": "symbols"}, "size": {"width": 300, "height": 240},
             "settings": [{"name": "symbols", "label": "Symbols", "type": "text",
                           "default": ["pair:BITSTAMP:BTCUSD", "pair:BITSTAMP:ETHUSD", "stock:NASDAQ:NVDA", "stock:NASDAQ:AAPL", "pair:FX:EURUSD"]},
                          {"name": "range", "label": "Chart opens on", "type": "choice", "choices": ["1D", "1W", "1M", "1Y"], "default": "1D"}]}
            """,
        note: """
            {"id": "pilot-note", "title": "Note", "icon": "📝", "version": "1.0",
             "description": "A note on the desktop: its text is this widget's setting.",
             "draw": "blocks", "data": {"setting": "text"}, "size": {"width": 240, "height": 160},
             "settings": [{"name": "text", "label": "Note", "type": "text", "default": "Write this note in the widget's settings on the Widgets page."}]}
            """,
    ]

    static let ids = [thisMac, clock, note, upkeep, launcher, notes, repos, github, nowPlaying, folder, markets]

    /// The desk widgets' folder in the app, `desk-*` folders beside the kit; nil in a test bundle without PILOT_RESOURCES.
    static let deskFolder = BundledJSON.folder("widgets")

    /// The bundled desk widgets that read, each from a folder named as its id, read once: the app's files do not change
    /// while it runs.
    static let desk: [Widget] = {
        guard let root = deskFolder, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().filter { $0.hasPrefix(deskPrefix) }.compactMap { name in
            (try? Widget(folder: root.appending(path: name, directoryHint: .isDirectory))).flatMap { $0.id == name ? $0 : nil }
        }
    }()

    /// The desk widgets' ids start with it; like `pilot-`, no folder in Widgets may take one, bundled or not yet.
    static let deskPrefix = "desk-"

    /// Whether `id` is kept for Pilot's ready widgets: a `pilot-` or a `desk-` id.
    static func isReady(_ id: String) -> Bool { Widget.isReserved(id) || id.hasPrefix(deskPrefix) }

    /// Whether `widget` is a bundled desk widget, read from the app's own folder, not a folder claiming its id.
    static func isDesk(_ widget: Widget) -> Bool { desk.contains(widget) }

    /// Where a ready widget says it lives: nowhere Sven's files are, an empty system folder, so it holds no trust.
    private static let home = URL(filePath: "/var/empty", directoryHint: .isDirectory)

    /// The ones in code, then the desk widgets.
    static let inCode: [Widget] = ids.compactMap(widget)
    static var all: [Widget] { inCode + desk }

    static func widget(_ id: String) -> Widget? {
        guard let text = manifests[id] else { return desk.first { $0.id == id } }
        return try? Widget(manifest: Data(text.utf8), folder: home.appending(path: id, directoryHint: .isDirectory))
    }

    static func manifest(_ id: String) -> Data { Data((manifests[id] ?? "{}").utf8) }
}
