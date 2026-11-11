import AppKit
import ImageIO
import PilotCore
import SwiftUI

/// The Carousel (spec desktop-controls T8, T9), T2's face (Sven's pick B, slices) in two modes, one bind each.
/// Wallpapers mode browses the current theme's wallpapers, or the folders that cycle when no theme's wallpapers are
/// followed: ←→ browse, Return applies, R random, F favourite, Tab favourites only, / search, Escape closes; a pick changes
/// only the wallpaper, through the scheduler's ledger seam (WallpaperSwitch.pick), with no Allow. Themes mode browses the
/// theme packs the style takes, each drawn as a desktop in its colours with the apps found on this Mac (Q26); Return is
/// a press in Pilot, so it plans and applies the theme in one step as Look's Apply does, with no Allow (theme-system
/// T12); `pilot carousel pick --mode themes` still asks. S switches modes. Browsing plans nothing. Listing and
/// thumbnails run off the main thread; thumbnails exist for the visible window only and go with the panel.
enum WallpaperCarousel {
    typealias Mode = CarouselValues.Mode

    /// What one open lists, read on the main thread: the folders the screen cycles (the theme's images, while its
    /// wallpapers are followed), the theme that owns them, the screen's shape and the image it shows.
    struct Inputs: Sendable {
        struct Theme: Sendable {
            var id: String
            var title: String
            var palette: [String]
        }
        var theme: Theme?
        var folders: [URL]
        var portrait: Bool
        var fit: Bool
        var current: String?
        /// Themes mode: the pack library, the style packs must take, the applied pack and the apps the previews draw.
        var store: ThemePackStore?
        var style = ""
        var applied: String?
        var apps = ThemePreview.Apps()
    }

    /// One theme pack as Themes mode shows it: its name, its colours and its first image for the screen's shape.
    struct Card: Sendable {
        var pack: ThemePack
        var image: String?
        var palette: [String]
        /// The pack's own picture (T14), shown in place of the drawn desktop.
        var preview: String?
    }

    struct Listed: Sendable {
        var mode = Mode.wallpapers
        /// What the row holds, in order: image paths in Wallpapers mode, pack ids in Themes mode.
        var images: [String]
        var source: String
        var palette: [String]
        var theme: String?
        var current: String?
        var cards: [Card] = []
        var style = ""
        var apps = ThemePreview.Apps()
        /// Why the packs could not be listed, said in the empty state's place.
        var failure: String?
    }

    /// The palette dots: the ground, words, the accent and five hues, as the pack names them.
    static let dots = ["background", "foreground", "accent", "red", "yellow", "green", "blue", "magenta"]

    nonisolated static func dots(_ pack: ThemePack) -> [String] { dots.compactMap { pack.palette[$0] } }

    /// The current theme while its wallpapers are followed: its ledger owns the shared collection and the screen still
    /// cycles exactly that, so every image listed is one the ledger takes. Otherwise nil: the screen's own folders.
    @MainActor static func theme(_ owner: ThemeCoordinator?, folders: [URL]) -> Inputs.Theme? {
        guard let owner, let pack = try? owner.selected(),
              case .sources(let images)? = (try? owner.wallpaperClaims())?.first(where: { $0.target == .sources })?.last,
              !images.isEmpty, folders.map(\.path) == images else { return nil }
        return .init(id: pack.id, title: pack.title, palette: dots(pack))
    }

    /// The images in name order, only the screen's shape when any fit (Look › Wallpaper's Each screen its own shape),
    /// each shape from its header as Next reads it. Never on the main thread.
    nonisolated static func list(_ inputs: Inputs) -> Listed {
        let screen: WallpaperCycle.Shape = inputs.portrait ? .portrait : .landscape
        var images = WallpaperCycle.images(in: inputs.folders)
        if inputs.fit {
            let fitting = images.filter { WallpaperSwitch.shapes.shape($0) == screen }
            if !fitting.isEmpty { images = fitting }
        }
        return Listed(images: images.map(\.path), source: inputs.theme.map { "\($0.title)'s wallpapers" } ?? "Your folders",
                      palette: inputs.theme?.palette ?? [], theme: inputs.theme?.id, current: inputs.current)
    }

    /// Themes mode's packs: every pack in the library the style takes, by title, each loaded once, with the image Apply
    /// would put on the screen first (the same step). A pack that does not load is left out. Never on the main thread.
    nonisolated static func themes(_ inputs: Inputs) -> Listed {
        var listed = Listed(mode: .themes, images: [], source: "", palette: [], theme: inputs.applied, current: inputs.applied,
                            style: inputs.style, apps: inputs.apps)
        guard let store = inputs.store else { listed.failure = "no theme library"; return listed }
        let screen: WallpaperCycle.Shape = inputs.portrait ? .portrait : .landscape
        let ids = Set(([store.root, store.writableRoot] + [store.factoryRoot].compactMap { $0 }).flatMap {
            ((try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []).filter(ThemePack.validID)
        })
        listed.cards = ids.compactMap { try? store.load($0) }.filter { $0.pack.compatible(with: inputs.style) }.map { loaded in
            let first = WallpaperCycle.step(loaded.images.map { URL(fileURLWithPath: $0) }, shape: { loaded.portraits.contains($0.path) ? .portrait : .landscape },
                                            screen: screen, fit: inputs.fit, current: nil, forward: true)
            return Card(pack: loaded.pack, image: first?.url.path, palette: dots(loaded.pack), preview: loaded.preview)
        }.sorted { $0.pack.title.localizedStandardCompare($1.pack.title) == .orderedAscending }
        listed.images = listed.cards.map(\.pack.id)
        return listed
    }

    nonisolated static func title(_ path: String) -> String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }

    /// Where the Carousel reads and picks: the Mac's screens and Pilot's theme, or a recording fixture's.
    @MainActor struct Source {
        /// The display UUID and inputs for the screen `screen` names (nil: the focused one).
        var inputs: @MainActor (_ screen: String?) throws(ControlError) -> (display: String?, inputs: Inputs)
        /// The listing, run off the main thread.
        var list: @Sendable (Inputs) -> Listed = WallpaperCarousel.list
        /// Sets `image` on the display and says whether the assignment was made (fixture) or queued (the Mac).
        var pick: @MainActor (_ image: URL, _ display: String?) async throws(ControlError) -> JSONValue
        var settings: WallpaperSettings
        /// The theme system that plans and applies Themes mode's pick.
        var owner: @MainActor () -> ThemeCoordinator?
        /// The private recording host's: `pilot carousel fixture-press` stands in for Return there.
        var fixture = false

        static var live: Source {
            Source(inputs: { name throws(ControlError) in liveInputs(try liveScreen(name)) }, pick: { image, display in
                WallpaperSwitch.pick(image, display: display, fallback: Screens.focusedScreen)
                return .object(["assignment": .string("queued"), "image": .string(image.path)])
            }, settings: .shared, owner: { try? ThemeCoordinator.production() })
        }

        /// What `screen` lists: the folders it cycles, its theme while followed, its shape and the image it shows.
        static func liveInputs(_ screen: NSScreen?) -> (display: String?, inputs: Inputs) {
            let settings = WallpaperSettings.shared, display = screen.flatMap(DisplayIdentity.uuid(of:))
            let folders = settings.urls(for: display), owner = try? ThemeCoordinator.production()
            return (display, Inputs(theme: theme(owner, folders: folders), folders: folders,
                                    portrait: screen.map { WallpaperSwitch.shape(of: $0) == .portrait } ?? false,
                                    fit: settings.fitShape, current: screen.flatMap(WallpaperSwitch.current(on:))?.path,
                                    store: owner?.store, style: owner?.style() ?? "", applied: owner.flatMap { try? $0.selected() }?.id))
        }

        /// The screen `--screen` names, as `pilot wallpaper` resolves it, else the focused one.
        static func liveScreen(_ name: String?) throws(ControlError) -> NSScreen? {
            guard let name else { return Screens.focusedScreen ?? NSScreen.main }
            let id = try WallpaperControl().screen(name).id
            return NSScreen.screens.first { WallpaperScreen.number($0) == id }
        }

        /// The private recording host's (spec desktop-controls T8 proof): its wallpaper state file stands in for the
        /// screens, favourites keep in a defaults file in its root, so they outlast a restart, and a pick goes through
        /// the theme ledger with the recording effect, never NSWorkspace. `carousel.hold` in the root holds a listing
        /// (after writing `carousel.ready`) until it is removed.
        static func fixture(_ owner: ThemeCoordinator, root: String) -> Source {
            let settings = WallpaperSettings(defaults: UserDefaults(suiteName: root + "/carousel-defaults")!)
            return Source(inputs: { name throws(ControlError) in
                guard let effect = owner.wallpaper, let state = try? effect.read(),
                      let display = state.displays.first(where: { name == nil || $0.id == name }) else {
                    throw ControlError(.badValue, "no fixture display \(name ?? "")")
                }
                let folders = state.sources.map { URL(fileURLWithPath: $0) }
                return (display.id, Inputs(theme: theme(owner, folders: folders), folders: folders, portrait: display.portrait,
                                           fit: state.preferences["fitShape"] != .bool(false), current: display.image,
                                           store: owner.store, style: owner.style(), applied: (try? owner.selected())?.id))
            }, list: { inputs in
                let hold = root + "/carousel.hold"
                if FileManager.default.fileExists(atPath: hold) {
                    FileManager.default.createFile(atPath: root + "/carousel.ready", contents: Data())
                    for _ in 0..<250 where FileManager.default.fileExists(atPath: hold) { usleep(100_000) }
                }
                return WallpaperCarousel.list(inputs)
            }, pick: { image, display throws(ControlError) in
                guard let display else { throw ControlError(.badValue, "no fixture display") }
                do {
                    let applied = try owner.fixtureCarouselPick(display: display, image: image.path)
                    return .object(["assignment": .string(applied ? "verified" : "unchanged"), "image": .string(image.path)])
                } catch { throw ControlError(.badValue, String(describing: error)) }
            }, settings: settings, owner: { owner }, fixture: true)
        }

        /// Themes mode's Return or click: a press in Pilot, so it plans and applies in one step with no Allow, the same
        /// press as Look's Apply (theme-system T12, Sven 2026-11-10). A plan that fails changes nothing and says why.
        func pressTheme(_ id: String) async throws(ControlError) -> JSONValue {
            guard let owner = owner() else { throw ControlError(.badValue, "the theme system is not available") }
            return try await owner.press(id)
        }

        /// `pilot carousel pick --mode themes`: plans the pack and applies it through the theme's own Allow (`peer` nil,
        /// never a press), so the CLI and links always ask. A plan that fails changes nothing and says why.
        func applyTheme(_ id: String) async throws(ControlError) -> JSONValue {
            guard let owner = owner() else { throw ControlError(.badValue, "the theme system is not available") }
            let planned: ThemePlan
            do { planned = try await owner.plan(id) } catch { throw ControlError(.badValue, "not planned: \(error)") }
            return try await owner.apply(planned.id, peer: nil)
        }
    }

    /// The editor, terminal and notes app Themes mode's previews draw, by the names they show, as the theme system found
    /// and follows them (Q26); nil draws a generic window there.
    @MainActor static func apps(_ owner: ThemeCoordinator?) -> ThemePreview.Apps {
        guard let owner, let found = try? owner.appFollowing() else { return .init() }
        func editor(_ kind: ThemeAppKind) -> Bool {
            switch kind {
            case .vscode, .cursor, .windsurf: true
            case .kitty, .alacritty, .wezterm, .iterm2: false
            }
        }
        let on = found.apps.filter(\.on).compactMap { app in ThemeAppKind(rawValue: app.kind).map { ($0, app.name) } }
        var folder: ObjCBool = false
        let ghostty = FileManager.default.fileExists(atPath: owner.binding.root, isDirectory: &folder) && folder.boolValue
        let terminal = found.ghostexFound && found.ghostexOn ? "Ghostex" : ghostty ? "Ghostty" : on.first { !editor($0.0) }?.1
        return .init(editor: found.zedFound && found.zedOn ? "Zed" : on.first { editor($0.0) }?.1, terminal: terminal,
                     notes: found.obsidianOn && found.vaults.contains(where: \.on) ? "Obsidian" : nil)
    }

    /// A pack's colours as its preview draws them, in the style it would show under.
    @MainActor static func look(_ pack: ThemePack, style: String) -> CarouselValues.ThemeLook {
        let theme = pack.appearance(keeping: .standard), t = StyleTokens.of(PilotStyle(rawValue: style) ?? .instrument, theme: theme)
        return .init(dark: t.dark, ground: t.color(\.canvas), window: t.color(\.panel), raised: t.color(\.raised), line: t.color(\.line2),
                     text: t.color(\.text), muted: t.color(\.text3), accent: t.color(\.accent), second: Color(Paint(theme.second)), third: Color(Paint(theme.third)))
    }

    /// One open's state: the mode, its listing, what search and Tab leave of it, the centre and the visible window's
    /// thumbnails. Shown keys are image paths in Wallpapers mode and pack ids in Themes mode.
    @Observable @MainActor
    final class Model {
        private(set) var mode: Mode
        private(set) var listed: Listed?
        var query: String? { didSet { refilter() } }
        var favouritesOnly = false { didSet { refilter() } }
        private(set) var shown: [String] = []
        var index = 0
        private(set) var thumbnails: [String: NSImage] = [:]
        private(set) var favourites: Set<String>
        @ObservationIgnored private var titles: [String: String] = [:]
        /// Each title lowercased, for search.
        @ObservationIgnored private var keys: [String: String] = [:]
        @ObservationIgnored private var cards: [String: Card] = [:]
        @ObservationIgnored private var looks: [String: CarouselValues.ThemeLook] = [:]
        @ObservationIgnored private var palettes: [String: [Color]] = [:]
        @ObservationIgnored let settings: WallpaperSettings

        init(settings: WallpaperSettings, mode: Mode = .wallpapers) {
            self.settings = settings
            self.mode = mode
            favourites = Set(settings.favourites)
        }

        func load(_ listed: Listed) {
            mode = listed.mode
            cards = Dictionary(listed.cards.map { ($0.pack.id, $0) }) { first, _ in first }
            titles = mode == .themes ? cards.mapValues(\.pack.title)
                : Dictionary(listed.images.map { ($0, WallpaperCarousel.title($0)) }) { first, _ in first }
            keys = titles.mapValues { $0.lowercased() }
            looks = cards.mapValues { WallpaperCarousel.look($0.pack, style: listed.style) }
            palettes = cards.mapValues { $0.palette.map { Color(hex: Contrast.hex($0)) } }
            thumbnails = [:]
            if mode == .themes { favouritesOnly = false }
            self.listed = listed
            refilter()
            index = listed.current.flatMap(shown.firstIndex(of:)) ?? 0
        }

        var centre: String? { shown.indices.contains(index) ? shown[index] : nil }

        func title(_ key: String) -> String { titles[key] ?? key }

        /// The image a key draws: the wallpaper itself, or a theme's own picture, else its first wallpaper under the drawing.
        func image(_ key: String) -> String? { mode == .wallpapers ? key : cards[key].flatMap { $0.preview ?? $0.image } }

        /// Keeps the centre when it is still shown, else the first.
        private func refilter() {
            let keep = centre, words = query?.lowercased().split(separator: " ") ?? []
            shown = (listed?.images ?? []).filter { key in
                (!favouritesOnly || favourites.contains(key)) && words.allSatisfy { keys[key]?.contains($0) == true }
            }
            index = keep.flatMap(shown.firstIndex(of:)) ?? 0
        }

        func move(_ by: Int) {
            guard !shown.isEmpty else { return }
            index = (index + by + shown.count) % shown.count
        }

        func random() {
            guard mode == .wallpapers, shown.count > 1 else { return }
            index = (index + Int.random(in: 1..<shown.count)) % shown.count
        }

        func toggleFavourite() {
            guard mode == .wallpapers, let centre else { return }
            settings.toggleFavourite(centre)
            favourites = Set(settings.favourites)
            if favouritesOnly { refilter() }
        }

        func toggleFavouritesOnly() { if mode == .wallpapers { favouritesOnly.toggle() } }

        /// The keys the face draws: the centre and three each side.
        var window: ArraySlice<String> {
            shown.isEmpty ? [] : shown[max(0, index - 3)...min(shown.count - 1, index + 3)]
        }

        /// Drops thumbnails outside `wanted` (image paths); nothing changes when none is.
        func prune(keeping wanted: Set<String>) {
            if thumbnails.keys.contains(where: { !wanted.contains($0) }) { thumbnails = thumbnails.filter { wanted.contains($0.key) } }
        }

        func insert(_ made: [(String, NSImage)]) {
            guard !made.isEmpty else { return }
            thumbnails.merge(made) { _, new in new }
        }

        var values: CarouselValues {
            let items = shown.map { key -> CarouselValues.Item in
                let picture = image(key).flatMap { thumbnails[$0] }
                guard mode == .themes, let pack = cards[key]?.pack else {
                    return .init(title: titles[key] ?? key, image: picture, current: key == listed?.current, favourite: favourites.contains(key))
                }
                // A pack's own picture stands alone (no look): the face draws it in place of the desktop.
                let own = cards[key]?.preview != nil
                return .init(title: pack.title, image: picture, current: key == listed?.current, tagline: PilotTheme.named(pack.id)?.tagline,
                             palette: palettes[key] ?? [], look: own ? nil : looks[key], apps: listed?.apps)
            }
            return CarouselValues(mode: mode, items: items, index: index, query: query, favouritesOnly: favouritesOnly,
                                  palette: (listed?.palette ?? []).map { Color(hex: Contrast.hex($0)) }, source: listed?.source ?? "")
        }

        /// What `pilot carousel` answers: what the face would show.
        var answer: JSONValue {
            var fields: [String: JSONValue] = [
                "mode": .string(mode == .themes ? "themes" : "wallpapers"), "source": .string(listed?.source ?? ""),
                "theme": listed?.theme.map(JSONValue.string) ?? .null,
                "total": .number(Double(listed?.images.count ?? 0)), "count": .number(Double(shown.count)),
                "index": .number(Double(index)), "centre": centre.map(JSONValue.string) ?? .null,
                "current": listed?.current.map(JSONValue.string) ?? .null, "images": .array(shown.map(JSONValue.string)),
                "favourites": .array(settings.favourites.map(JSONValue.string)), "query": query.map(JSONValue.string) ?? .null,
                "favouritesOnly": .bool(favouritesOnly), "palette": .array((listed?.palette ?? []).map(JSONValue.string)),
                "empty": .bool(shown.isEmpty)]
            if mode == .themes {
                func name(_ app: String?) -> JSONValue { app.map(JSONValue.string) ?? .null }
                let apps = listed?.apps ?? .init()
                fields["apps"] = .object(["editor": name(apps.editor), "terminal": name(apps.terminal), "notes": name(apps.notes)])
                fields["themes"] = .array(shown.compactMap { cards[$0] }.map { card in
                    .object(["id": .string(card.pack.id), "title": .string(card.pack.title), "current": .bool(card.pack.id == listed?.current),
                             "image": card.image.map(JSONValue.string) ?? .null, "dark": .bool(card.pack.dark),
                             "preview": card.preview.map(JSONValue.string) ?? .null, "drawn": .bool(card.preview == nil),
                             "palette": .array(card.palette.map(JSONValue.string))])
                })
                fields["failure"] = listed?.failure.map(JSONValue.string) ?? .null
            }
            return .object(fields)
        }
    }

    /// A thumbnail from the image's own data (ImageIO), at most `pixels` on its long side; read off the main thread.
    nonisolated static func thumbnail(_ path: String, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// The Carousel's window: T2's face centred on the screen in a KeyPanel, Pilot left inactive, its keys through the search
/// panel's monitor. Made on open and dropped on close, thumbnails with it.
@MainActor
final class WallpaperCarouselPanel {
    static let shared = WallpaperCarouselPanel()

    private var panel: KeyPanel?
    private var monitor: Any?
    private var resign: NSObjectProtocol?
    private var model: WallpaperCarousel.Model?
    private var screen: NSScreen?
    private var loading: Task<Void, Never>?
    /// Thumbnails being made, so a key press asks for none twice.
    private var making: Set<String> = []
    /// The mode last asked for, set before its listing arrives, so a quick second bind compares against it.
    private var mode: WallpaperCarousel.Mode?
    /// The apps Themes mode's previews draw, found once per open.
    private var apps: ThemePreview.Apps?

    /// A mode's bind: opens the Carousel in `mode` on `screen` (nil: the focused one); while it is open, the same bind
    /// closes it and the other mode's bind switches to its mode.
    func toggle(_ mode: WallpaperCarousel.Mode, on screen: NSScreen?) {
        guard panel != nil, let shown = self.mode else { return open(mode, on: screen) }
        if shown == mode { close() } else { show(mode) }
    }

    func open(_ mode: WallpaperCarousel.Mode = .wallpapers, on screen: NSScreen?) {
        close()
        guard let target = screen ?? Screens.focusedScreen ?? NSScreen.main else { return }
        let model = WallpaperCarousel.Model(settings: WallpaperCarousel.Source.live.settings, mode: mode)
        (self.model, self.screen) = (model, target)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let face = CarouselHost(model: model, reduceMotion: reduce) { [weak self] in self?.act($0) }
        let frame = target.visibleFrame
        let panel = BarPanelWindow.keyPanel(face, surface: .barPopovers, level: .popUpMenu) { size in
            NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        }
        self.panel = panel
        monitor = HUD.showSearchPanel(panel, handle: { [weak self] code, flags, characters in
            self?.key(code, flags, characters) ?? false
        }, keepsSearch: { false }, onlyPanel: true, log: { _ in })
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        show(mode)
    }

    /// Lists `mode` for the panel's screen off the main thread and shows it; browsing plans nothing.
    private func show(_ mode: WallpaperCarousel.Mode) {
        guard let model, let screen else { return }
        self.mode = mode
        let source = WallpaperCarousel.Source.live
        var inputs = WallpaperCarousel.Source.liveInputs(screen).inputs
        if mode == .themes {
            if apps == nil { apps = WallpaperCarousel.apps(source.owner()) }
            inputs.apps = apps ?? .init()
        }
        let list = mode == .themes ? WallpaperCarousel.themes : source.list, frozen = inputs
        loading?.cancel()
        loading = Task { [weak self] in
            let listed = await Task.detached(priority: .userInitiated) { list(frozen) }.value
            guard let self, !Task.isCancelled, self.model === model else { return }
            model.query = nil
            model.load(listed)
            self.draw()
        }
    }

    func close() {
        loading?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resign { NotificationCenter.default.removeObserver(resign) }
        panel?.contentView = nil
        panel?.orderOut(nil)
        (panel, monitor, resign, model, screen, loading, making, apps, mode) = (nil, nil, nil, nil, nil, nil, [], nil, nil)
    }

    /// The panel's keys; true when taken. While searching, letters type and Delete takes the last one back; otherwise S
    /// switches between Wallpapers and Themes (Sven, build 2276).
    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String?) -> Bool {
        guard let model else { return false }
        let plain = flags.intersection([.command, .control, .option]).isEmpty
        switch Int64(code) {
        case KeyCode.leftArrow: model.move(-1)
        case KeyCode.rightArrow: model.move(1)
        case KeyCode.returnKey, KeyCode.keypadEnter: apply()
        case KeyCode.escape:
            if model.query != nil { model.query = nil } else { close(); return true }
        case KeyCode.tab: model.toggleFavouritesOnly()
        case KeyCode.delete:
            guard let query = model.query else { return true }
            model.query = query.isEmpty ? nil : String(query.dropLast())
        default:
            guard plain, let typed = characters, !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
            if let query = model.query { model.query = query + typed }  // Searching, S types too.
            else if typed == "/" { model.query = "" }
            else if typed.lowercased() == "s" { show(mode == .themes ? .wallpapers : .themes); return true }
            else if typed.lowercased() == "r" { model.random() }
            else if typed.lowercased() == "f" { model.toggleFavourite() }
            else { return true }
        }
        draw()
        return true
    }

    private func act(_ action: CarouselFace.Action) {
        guard let model else { return }
        switch action {
        case .select(let i): model.index = i; draw()
        case .apply: apply()
        case .mode(let mode): if mode != self.mode { show(mode) }
        case .openLook:
            let display = screen.flatMap(DisplayIdentity.uuid(of:))
            let mode = model.mode
            close()
            if mode == .themes { AppWindowController.shared.open(.look) }
            else { AppWindowController.shared.openWallpaper(.init(display: display, workspace: display.flatMap(WallpaperSettings.shared.shownWorkspace))) }
        }
    }

    /// Return: Wallpapers mode sets the image; Themes mode presses the theme, as Look's Apply does, saying in a tip
    /// what came of it.
    private func apply() {
        guard let model, let centre = model.centre, let screen else { return }
        let mode = model.mode, title = model.title(centre)
        close()
        guard mode == .themes else {
            return WallpaperSwitch.pick(URL(fileURLWithPath: centre), display: DisplayIdentity.uuid(of: screen), fallback: screen)
        }
        Task {
            do {
                guard case .object(let result) = try await WallpaperCarousel.Source.live.pressTheme(centre) else { return }
                let status = result["status"]?.string ?? "not applied"
                HUD.tip(status == "applied" ? "\(title) applied" : "\(title): \(status)")
            } catch { HUD.tip("\(title) was not applied: \((error as? ControlError)?.message ?? String(describing: error))") }
        }
    }

    /// Makes the visible window's thumbnails off the main thread, each once, and drops the rest.
    private func draw() {
        guard let model else { return }
        let wanted = Set(model.window.compactMap(model.image))
        model.prune(keeping: wanted)
        let missing = wanted.subtracting(model.thumbnails.keys).subtracting(making)
        guard !missing.isEmpty else { return }
        making.formUnion(missing)
        let pixels = Int(CarouselFace.centre.width * (panel?.backingScaleFactor ?? 2))
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) {
                missing.compactMap { path in WallpaperCarousel.thumbnail(path, pixels: pixels).map { (path, $0) } }
            }.value
            guard let self, self.model === model else { return }
            self.making.subtract(missing)
            let now = Set(model.window.compactMap(model.image))
            model.insert(made.filter { now.contains($0.0) }.map { ($0.0, NSImage(cgImage: $0.1, size: NSSize(width: $0.1.width, height: $0.1.height))) })
        }
    }
}

/// The face, fed from the model as it changes.
private struct CarouselHost: View {
    let model: WallpaperCarousel.Model
    let reduceMotion: Bool
    let act: (CarouselFace.Action) -> Void

    var body: some View {
        CarouselFace(values: model.values, reduceMotion: reduceMotion, act: act)
            .animation(DesktopMotion.step(reduceMotion), value: model.index)
    }
}
