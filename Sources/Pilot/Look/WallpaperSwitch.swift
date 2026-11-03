import AppKit
import PilotCore

/// Hyper+Ctrl+Space, Omarchy's background key (story 146, card agent-bo-95423316): the next or previous image on the
/// focused window's screen, or on every screen (Look › Wallpaper, story 160), from the folders and images picked there.
/// The images are listed only on a press, never watched; the theme and Ghostty's colours stay as they are. A workspace
/// with its own folders gets its last image back on its screen when it is switched to (Sven 2026-10-19, Q333).
@MainActor
enum WallpaperSwitch {
    nonisolated static let shapes = ImageShapes()

    static func step(forward: Bool) {
        step(forward: forward, everyScreen: WallpaperSettings.shared.scope == .everyScreen)
    }

    /// `quiet`: no HUD, for the timer.
    static func step(forward: Bool, everyScreen: Bool, quiet: Bool = false, settings: WallpaperSettings = .shared) {
        let screens = everyScreen ? NSScreen.screens : Screens.focusedScreen.map { [$0] } ?? []
        step(forward: forward, screens: screens, quiet: quiet, settings: settings)
    }

    /// One step on each of `screens`, each from its own current image and its own folders while each screen has its own;
    /// the Wallpaper block's buttons pass one screen.
    /// Steps run one after another, each from the image the one before set, so quick presses never pick the same image.
    static func step(forward: Bool, screens: [NSScreen], quiet: Bool = false, settings: WallpaperSettings = .shared) {
        guard !screens.isEmpty else { return }
        let order = settings.order, seed = settings.seed, fit = settings.fitShape
        let displays = screens.map { DisplayIdentity.uuid(of: $0) }
        let lists = displays.map(settings.urls(for:))
        let workspaces = displays.map { $0.flatMap(settings.ownWorkspace(on:)) }
        enqueue {
            let listed = await Task.detached { WallpaperSettings.imageLists(lists, order: order, seed: seed) }.value
            var last: (url: URL, place: Int, count: Int)?
            for (screen, (urls, workspace)) in zip(screens, zip(lists, workspaces)) {
                let shape = shape(of: screen), current = current(on: screen), images = listed[urls] ?? []
                let pick = await Task.detached {
                    WallpaperCycle.step(images, shape: shapes.shape, screen: shape, fit: fit, current: current, forward: forward)
                }.value
                guard let pick else {
                    if !quiet { HUD.tip("No images in \(urls.map { AppConfigs.tilde($0.path, home: NSHomeDirectory()) }.joined(separator: ", "))") }
                    return
                }
                guard show(pick.url, on: screen, replacing: current, quiet: quiet) else { return }
                if let workspace { settings.shown(pick.url, workspace: workspace) }
                looklog.notice("wallpaper \(pick.place)/\(pick.count) on \(screen.localizedName, privacy: .public): \(pick.url.lastPathComponent, privacy: .public)")
                last = pick
            }
            NotificationCenter.default.post(name: changed, object: nil)
            guard !quiet, let last else { return }
            let screensNote = screens.count > 1 ? " · \(screens.count) screens" : ""
            HUD.tip("\(last.url.deletingPathExtension().lastPathComponent) · \(last.place) of \(last.count)\(screensNote)", seconds: 2)
        }
    }

    /// The gallery's pick (P90): `url` on the screen with display UUID `display`, else on `fallback`, alone, queued
    /// behind any step and kept as the screen's current, so Next steps on from it; while the workspace shown there cycles
    /// its own folders, also as that workspace's image. The tip says where it went.
    static func set(_ url: URL, display: String?, fallback: NSScreen?, settings: WallpaperSettings = .shared) {
        guard let screen = screen(display) ?? fallback ?? NSScreen.main else { return HUD.tip("No screen to set the wallpaper on") }
        let workspace = DisplayIdentity.uuid(of: screen).flatMap(settings.ownWorkspace(on:))
        enqueue {
            guard show(url, on: screen, replacing: current(on: screen), quiet: false) else { return }
            if let workspace { settings.shown(url, workspace: workspace) }
            looklog.notice("wallpaper picked on \(screen.localizedName, privacy: .public): \(url.lastPathComponent, privacy: .public)")
            NotificationCenter.default.post(name: changed, object: nil)
            let place = workspace.map { Engine.shared?.presets.contents.title(for: $0) ?? WorkspacePreset.unnamed($0) } ?? screen.localizedName
            HUD.tip("\(url.deletingPathExtension().lastPathComponent) · \(place)", seconds: 2)
        }
    }

    /// Sets `url` on `screen` and keeps it as the screen's current; false, logged and tipped unless `quiet`, when macOS
    /// refuses it.
    private static func show(_ url: URL, on screen: NSScreen, replacing current: URL?, quiet: Bool) -> Bool {
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        } catch {
            looklog.error("wallpaper \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            if !quiet { HUD.tip("macOS refused \(url.lastPathComponent)") }
            return false
        }
        if let number = WallpaperScreen.number(screen) { set.record(url, replacing: current, on: number) }
        return true
    }

    /// The tiler shows `workspace` on the screen with this display UUID, `previous` before it, while each workspace can
    /// have its own folders. One with its own gets the image it last showed back on that screen, or the first of its
    /// cycle the first time or once that file is gone; one without, after one with, gets the screen's own image back as
    /// global has it (Sven 2026-10-19, "use same as global"), or the screen's next one when that is unknown or gone.
    /// Queued behind any step under way, so the switch itself waits for nothing; nothing is set when the image already
    /// shows, and nothing at all between two workspaces without their own.
    static func workspaceShown(_ workspace: String, after previous: String?, display: String?, settings: WallpaperSettings = .shared) {
        let own = settings.cyclesOwn(workspace), leaving = previous.map(settings.cyclesOwn) ?? false
        guard own || leaving,
              let screen = screen(display) ?? Screens.focusedScreen
        else { return }
        let key = display ?? DisplayIdentity.uuid(of: screen)
        let last = own ? settings.workspaceImages[workspace].map { URL(filePath: $0) } : key.flatMap { screenImages[$0] }
        enqueue {
            let current = current(on: screen)
            // The screen's own image, kept while workspaces with their own show there.
            if own, !leaving, let key, let current { screenImages[key] = current }
            if let last, current?.standardizedFileURL.path == last.standardizedFileURL.path { return }
            guard let last, await Task.detached(operation: { FileManager.default.fileExists(atPath: last.path) }).value else {
                if own { settings.forget(workspace: workspace) }
                return step(forward: true, screens: [screen], quiet: true, settings: settings)
            }
            guard show(last, on: screen, replacing: current, quiet: true) else { return }
            looklog.notice("wallpaper workspace \(workspace, privacy: .public) on \(screen.localizedName, privacy: .public): \(last.lastPathComponent, privacy: .public)")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// The screen with this display UUID, when it is connected.
    private static func screen(_ display: String?) -> NSScreen? {
        display.flatMap { d in NSScreen.screens.first { DisplayIdentity.uuid(of: $0) == d } }
    }

    /// Each screen's own image by its display UUID, kept when a workspace with its own folders takes the screen over, for
    /// the switch back to one without; in memory only.
    private static var screenImages: [String: URL] = [:]

    /// Runs `body` once the step under way has finished, so steps and switches never set a screen at once.
    private static func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let before = stepping
        stepping = Task {
            await before?.value
            await body()
        }
    }

    /// The step under way, which the next one waits for.
    private static var stepping: Task<Void, Never>?
    /// What Pilot set on each screen, while macOS's own read still trails it.
    private static var set = SetWallpapers()

    /// `screen`'s wallpaper now: the one Pilot just set while macOS still reads the one before.
    static func current(on screen: NSScreen) -> URL? {
        let read = NSWorkspace.shared.desktopImageURL(for: screen)
        guard let number = WallpaperScreen.number(screen) else { return read }
        return set.current(on: number, read: read)
    }

    /// Posted once a step has set its images, so the Wallpaper block reads the screens again.
    static let changed = Notification.Name("dev.banozz.pilot.wallpaperChanged")

    static func shape(of screen: NSScreen) -> WallpaperCycle.Shape {
        screen.frame.height > screen.frame.width ? .portrait : .landscape
    }
}
