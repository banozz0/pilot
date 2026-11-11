import Foundation
import Observation
import PilotCore

/// Look › Wallpaper (story 160, Sven 2026-10-10: "where do I even set which wallpapers cycle?"): the folders and images
/// Next wallpaper steps through (~/Pictures/Wallpapers until one is picked), by name or shuffled, on the screen in front
/// or every screen, and how often they change on their own; the same folders on every screen, or each screen its own
/// (Sven 2026-10-17), and each workspace its own if picked, shown on its screen when switched to (Sven 2026-10-19,
/// Q333); a timed step steps every screen from its own. Its own store, as FileSearchSettings is, so the block renders
/// without an engine. The timer runs only while an interval is set and waits while the screen is locked or asleep.
@Observable @MainActor
final class WallpaperSettings: ScreenPausing {
    static let shared = WallpaperSettings()

    /// The folders and image files, as paths; an empty list falls back to ~/Pictures/Wallpapers. With each screen its
    /// own, the shared ones a screen without folders of its own takes.
    private(set) var sources: [String] { didSet { defaults.set(sources, forKey: Self.sourcesKey) } }
    /// The same folders on every screen, or each screen its own (Sven 2026-10-17); shared until changed.
    var folders: WallpaperCycle.Folders { didSet { defaults.set(folders.rawValue, forKey: Self.foldersKey) } }
    /// Each screen's own folders and images by its display UUID (DisplayIdentity, as Monitors keys its pins), read
    /// only while `folders` is perScreen; a screen not here takes `sources`.
    private(set) var screenSources: [String: [String]] { didSet { defaults.set(screenSources, forKey: Self.screenSourcesKey) } }
    /// Workspaces share the screen's folders, or each can have its own (Sven 2026-10-19, Q333); shared until changed.
    var workspaces: WallpaperCycle.Workspaces { didSet { defaults.set(workspaces.rawValue, forKey: Self.workspacesKey) } }
    /// Each workspace's own folders and images by its number, read only while `workspaces` is perWorkspace; a workspace
    /// not here takes its screen's.
    private(set) var workspaceSources: [String: [String]] { didSet { defaults.set(workspaceSources, forKey: Self.workspaceSourcesKey) } }
    /// The image each workspace with its own folders last showed, so going back shows it again rather than a new pick.
    private(set) var workspaceImages: [String: String] { didSet { defaults.set(workspaceImages, forKey: Self.workspaceImagesKey) } }
    /// The Carousel's favourite wallpapers by path (spec desktop-controls T8), in the order they were marked; F marks or
    /// unmarks the centre one and Tab shows only these.
    private(set) var favourites: [String] { didSet { defaults.set(favourites, forKey: Self.favouritesKey) } }
    /// Each screen only gets images of its own shape, unless none fit; off, every screen steps through every image, a
    /// wide one cropped to its middle on a portrait screen (Sven 2026-10-19, Q329). On until changed.
    var fitShape: Bool { didSet { defaults.set(fitShape, forKey: Self.fitShapeKey) } }
    var order: WallpaperCycle.Order { didSet { defaults.set(order.rawValue, forKey: Self.orderKey) } }
    /// The shuffle's seed: the same order until Shuffle again, so Previous goes back.
    private(set) var seed: UInt64 { didSet { defaults.set(String(seed), forKey: Self.seedKey) } }
    var scope: WallpaperCycle.Scope { didSet { defaults.set(scope.rawValue, forKey: Self.scopeKey) } }
    /// Minutes between steps on their own (WallpaperCycle.intervals); 0 never.
    var interval: Int {
        didSet {
            defaults.set(interval, forKey: Self.intervalKey)
            schedule()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// What a timed step does: every screen one on; a test passes its own.
    @ObservationIgnored var tick: @MainActor () -> Void = { WallpaperSwitch.step(forward: true, everyScreen: true, quiet: true) }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var paused = false
    /// The workspace the screen with this display UUID shows; the engine reads its tiler's, nil without one.
    @ObservationIgnored var shownWorkspace: @MainActor (String) -> String? = { _ in nil }
    private static let sourcesKey = "wallpaper.sources", orderKey = "wallpaper.order", seedKey = "wallpaper.seed",
                       scopeKey = "wallpaper.scope", intervalKey = "wallpaper.interval", foldersKey = "wallpaper.folders",
                       screenSourcesKey = "wallpaper.screenSources", fitShapeKey = "wallpaper.fitShape",
                       workspacesKey = "wallpaper.workspaces", workspaceSourcesKey = "wallpaper.workspaceSources",
                       workspaceImagesKey = "wallpaper.workspaceImages", favouritesKey = "wallpaper.favourites"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        sources = defaults.stringArray(forKey: Self.sourcesKey) ?? [WallpaperCycle.standardFolder.path]
        folders = defaults.string(forKey: Self.foldersKey).flatMap(WallpaperCycle.Folders.init) ?? .shared
        screenSources = (defaults.dictionary(forKey: Self.screenSourcesKey) as? [String: [String]]) ?? [:]
        workspaces = defaults.string(forKey: Self.workspacesKey).flatMap(WallpaperCycle.Workspaces.init) ?? .shared
        workspaceSources = (defaults.dictionary(forKey: Self.workspaceSourcesKey) as? [String: [String]]) ?? [:]
        workspaceImages = (defaults.dictionary(forKey: Self.workspaceImagesKey) as? [String: String]) ?? [:]
        favourites = defaults.stringArray(forKey: Self.favouritesKey) ?? []
        fitShape = defaults.object(forKey: Self.fitShapeKey) as? Bool ?? true
        order = defaults.string(forKey: Self.orderKey).flatMap(WallpaperCycle.Order.init) ?? .name
        seed = defaults.string(forKey: Self.seedKey).flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64.max)
        scope = defaults.string(forKey: Self.scopeKey).flatMap(WallpaperCycle.Scope.init) ?? .focusedScreen
        interval = WallpaperCycle.intervals.contains(defaults.integer(forKey: Self.intervalKey)) ? defaults.integer(forKey: Self.intervalKey) : 0
    }

    /// What a press reads: the picked sources, or ~/Pictures/Wallpapers when none is left.
    var urls: [URL] { sources.isEmpty ? [WallpaperCycle.standardFolder] : sources.map { URL(filePath: $0) } }

    /// What a press on the screen with this display UUID reads: the shown workspace's own sources while each workspace
    /// can have its own and it has some, else the screen's own while each screen has its own and it has some, else the
    /// shared ones.
    func urls(for display: String?) -> [URL] {
        if let workspace = display.flatMap(ownWorkspace) { return workspaceOwn(workspace).map { URL(filePath: $0) } }
        guard folders == .perScreen, let own = display.map(ownSources), !own.isEmpty else { return urls }
        return own.map { URL(filePath: $0) }
    }

    /// The workspace the screen with this display UUID shows, when it cycles that workspace's own sources.
    func ownWorkspace(on display: String) -> String? {
        shownWorkspace(display).flatMap { cyclesOwn($0) ? $0 : nil }
    }

    /// Whether `workspace` shows its own sources: each workspace can have its own and it has some.
    func cyclesOwn(_ workspace: String) -> Bool { workspaces == .perWorkspace && !workspaceOwn(workspace).isEmpty }

    /// The folders of a list of sources, an image picked on its own as its folder, each once, in order: what the gallery
    /// browses (P90).
    nonisolated static func containingFolders(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.map { WallpaperCycle.isImage($0) ? $0.deletingLastPathComponent() : $0 }
            .map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    /// The screen's own folders and images; empty when it takes the shared ones.
    func ownSources(_ display: String) -> [String] { screenSources[display] ?? [] }

    /// The workspace's own folders and images; empty when it takes its screen's.
    func workspaceOwn(_ workspace: String) -> [String] { workspaceSources[workspace] ?? [] }

    /// The list an edit changes: the shared one, the screen's own or the workspace's own; one left with none takes the
    /// shared ones (a workspace, its screen's).
    func sources(for display: String?, workspace: String? = nil) -> [String] {
        workspace.map { workspaceOwn($0) } ?? display.map(ownSources) ?? sources
    }

    private func setSources(_ list: [String], for display: String?, workspace: String?) {
        if let workspace {
            workspaceSources[workspace] = list.isEmpty ? nil : list
            workspaceImages[workspace] = nil
        } else if let display { screenSources[display] = list.isEmpty ? nil : list } else { sources = list }
    }

    /// Keeps the image a workspace with its own sources now shows, for the next time it is switched to.
    func shown(_ url: URL, workspace: String) {
        if workspaceImages[workspace] != url.path { workspaceImages[workspace] = url.path }
    }

    /// Marks the image at `path` a favourite, or unmarks it; true when it is one after.
    @discardableResult func toggleFavourite(_ path: String) -> Bool {
        if let at = favourites.firstIndex(of: path) { favourites.remove(at: at); return false }
        favourites.append(path)
        return true
    }

    /// Drops a workspace's last image once its file is gone, so its cycle starts again.
    func forget(workspace: String) { workspaceImages[workspace] = nil }

    /// Deleting a workspace closes its number (Sven's Q233): each one's folders and last image follow it.
    func renumber(_ r: WorkspaceRenumber) {
        workspaceSources = r.rekeyed(workspaceSources)
        workspaceImages = r.rekeyed(workspaceImages)
    }

    /// Every image of each of `lists`' sources in the cycle's order, a list several screens share listed once; read off
    /// the main thread.
    nonisolated static func imageLists(_ lists: [[URL]], order: WallpaperCycle.Order, seed: UInt64) -> [[URL]: [URL]] {
        Dictionary(Set(lists).map { ($0, WallpaperCycle.ordered(WallpaperCycle.images(in: $0), order: order, seed: seed)) }) { first, _ in first }
    }

    /// Adds picked folders and images, to the shared ones or to the screen's or workspace's own; one already there is
    /// skipped.
    func add(_ urls: [URL], display: String? = nil, workspace: String? = nil) {
        var list = sources(for: display, workspace: workspace)
        for path in urls.map(\.standardizedFileURL.path) where !list.contains(path) { list.append(path) }
        setSources(list, for: display, workspace: workspace)
    }

    func remove(_ path: String, display: String? = nil, workspace: String? = nil) {
        setSources(sources(for: display, workspace: workspace).filter { $0 != path }, for: display, workspace: workspace)
    }

    /// ~/Pictures/Wallpapers alone again; for a screen, the shared ones again; for a workspace, its screen's.
    func reset(display: String? = nil, workspace: String? = nil) {
        setSources(display == nil && workspace == nil ? [WallpaperCycle.standardFolder.path] : [], for: display, workspace: workspace)
    }

    var isStandard: Bool { sources == [WallpaperCycle.standardFolder.path] }

    /// Pack ownership changes only the shared collection. Personal folders, images and cycle controls stay intact.
    func themeSources(_ paths: [String]) { sources = paths }

    func themeState(displays: [ThemeWallpaperState.Display]) -> ThemeWallpaperState {
        func lists(_ values: [String: [String]]) -> JSONValue { .object(values.mapValues { .array($0.map(JSONValue.string)) }) }
        return ThemeWallpaperState(sources: sources, displays: displays, preferences: [
            "folders": .string(folders.rawValue), "screenSources": lists(screenSources),
            "workspaces": .string(workspaces.rawValue), "workspaceSources": lists(workspaceSources),
            "workspaceImages": .object(workspaceImages.mapValues(JSONValue.string)),
            "order": .string(order.rawValue), "seed": .string(String(seed)), "fitShape": .bool(fitShape),
            "scope": .string(scope.rawValue), "interval": .number(Double(interval))])
    }

    func shuffleAgain() { seed = UInt64.random(in: 1...UInt64.max) }

    /// Starts, restarts or stops the timer for the interval; the app calls it once at launch.
    func schedule() {
        timer?.invalidate()
        timer = nil
        guard interval > 0, !paused else { return }
        let every = TimeInterval(interval * 60)
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = every / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var isScheduled: Bool { timer != nil }

    func pause() {
        paused = true
        schedule()
    }

    func resume() {
        paused = false
        schedule()
    }
}
