#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The site's share card, its parts in a theme of your choosing (pilot-og-v2 round, Sven 2026-11-18, Q238 and Q239: the
/// card in three themes to pick from). Each theme gets its own folder under `og-card/`, every part drawn the way its own
/// renders draw it, on a 2560 by 1344 pt screen (a Studio Display's width in the card's shape) so nearly the whole wallpaper shows:
/// - `islands.png` and `islands.json`: the three-islands top bar, full centre, as InstrumentTopBarRenders' islands draw it,
///   with each island's frame;
/// - `dock.png`: the dock attached at the screen's foot with its default widgets and the visualizer playing over the
///   theme's wallpaper (DockRiceRenders.Scene);
/// - `menu-*.png`: Line (LineMenuRenders.render) at the root, searching "notes", converting, asking, and a few words that
///   find Pilot's own actions (capture, clip, dictate, record, music, screen) above Ask or search, over Apple's own
///   apps and made-up notes, so no real name, file or app list shows;
/// - `desk-weather.png`, `desk-system.png`: two desk widgets on DeskWidgetRenders' fixed data, the weather's place a
///   neutral city;
/// - `desk.png`: Look's tiled desk (LookDesk: an editor, a terminal and a notes graph with the tiler's gaps) over nothing,
///   so the card's wallpaper shows between the windows;
/// - `theme.json`: the theme's colours, for the card's text and scrim.
/// A theme Pilot ships wears its pack from `Packaging/ThemePacks`; a catalogue-only one, such as Meadow, is tried on from
/// `catalogue/themes`, as Look tries a catalogue theme on. Opt-in, in a moved home, a theme and its wallpaper each:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_RESOURCES=Packaging PILOT_OG="nord=<wall>,gruvbox=<wall>" swift test --filter OGCardRenders`
extension SharedLook {
@MainActor
@Suite("Share card renders")
struct OGCardRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let screen = CGSize(width: 2560, height: 1344)   // the card's shape (1200 by 630) at a Studio Display's width
    /// The weather's place: a neutral city, never where Sven is.
    static let place = "Lisbon"

    /// `PILOT_OG`'s themes and wallpapers, `id=path` comma separated.
    static func cases() -> [(id: String, wall: String)] {
        (env["PILOT_OG"] ?? "").split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    @Test("The share card's parts in each theme asked for",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_OG"] != nil && env["PILOT_RESOURCES"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency)
        defer { (look.style, look.themeID, look.glass, look.transparency) = was; look.packChanged(nil); LookRenders.resetShared() }
        let thumbnails = FileThumbnails.shared
        thumbnails.make = FileThumbnailRenders.fake
        defer { thumbnails.make = FileThumbnails.quickLook }
        let store = try DeskWidgetRenders.store()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cases = Self.cases()
        try #require(!cases.isEmpty, "PILOT_OG names no theme")
        for (id, wallPath) in cases {
            let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appending(path: "og-card/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let wall = try #require(NSImage(contentsOfFile: wallPath), "no wallpaper at \(wallPath)")
            (look.style, look.transparency, look.glass) = (.instrument, 33, false)
            // A designed theme wears its shipped pack; a catalogue-only one (Meadow) is tried on from its catalogue pack.
            let catalogue: ThemePack?
            if PilotTheme.named(id) != nil {
                catalogue = nil
                look.endTrial()
                look.themeID = id
                look.packChanged(try ThemePack.decode(Data(contentsOf: root.appending(path: "Packaging/ThemePacks/\(id)/manifest.json"))))
            } else {
                catalogue = try ThemePack.decode(Data(contentsOf: root.appending(path: "catalogue/themes/\(id)/manifest.json")))
                look.tryOn(id: id, pack: catalogue)
            }
            try #require(look.theme.id == id, "\(id) did not resolve")
            try Self.topBar(id, pack: catalogue, to: dir)
            try Self.dock(look, wall: wall, to: dir)
            try Self.desk(look, to: dir)
            for (name, model) in try Self.states() {
                try await LineMenuRenders.render(model, name, in: dir, wait: 0.4)
            }
            try await Self.widgets(store, theme: look.theme, to: dir)
            try ThemeDigest.encoded(DeskWidgetRenders.theme(look.theme)).write(to: dir.appending(path: "theme.json"))
            look.endTrial()
        }
    }

    /// The three-islands top bar across the screen, less 12 pt each side, on the theme's canvas, as
    /// InstrumentTopBarRenders.renderFloating draws its "Full centre" row; each island's frame beside it.
    static func topBar(_ id: String, pack: ThemePack?, to dir: URL) throws {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.og-render-" + id)
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(true, forKey: BarItemsStore.extensionsApartKey)
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        try store.choosePreset("threeIslands")
        let look = Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), inputSources: BarReadingsTests.Sources(), defaults: defaults)
        look.style = .instrument
        if let pack { look.tryOn(id: id, pack: pack) } else { look.preview(id) }
        try #require(look.theme.id == id)
        var input = BarInputs()
        input.pilotTitle = "2"; input.workspaces = ["1", "2", "3"]; input.focusedWorkspace = "2"
        input.focusedApp = "Finder"; input.volume = 0.6; input.muted = false; input.wifiOn = true
        input.timerCountdown = "18:42"; input.timerTitle = "Focus"; input.keyboardLayout = "ABC"
        input.now = ClockRenders.now; input.timeZone = TimeZone(secondsFromGMT: 0)!; input.locale = Locale(identifier: "en_US_POSIX")
        for kind in [BarKind.focusedApp, .volume, .wifi, .keyboardLayout] { store.settings.set(kind, on: true) }
        for kind in [BarKind.otherApps, .modes, .group, .cpu, .memory, .network] { store.settings.set(kind, on: false) }
        store.settings.place(.kind(.clock), on: .centre, at: 0)
        let sides = store.settings.preview(.topBar).top ?? [:]
        let tokens = StyleTokens.of(.instrument, theme: look.theme)
        let config = try #require(store.settings.preset)
        let width = screen.width - 24
        var frames: [TopBarSide: CGRect] = [:]
        try writeRender(
            TopBarStrip(sides: sides, configuration: config, reportIsland: { side, rect in frames[side] = rect }) { slot in
                if let parts = BarParts.parts(slot, input, settings: store.settings) {
                    BarPartsView(items: parts).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 6)
                }
            }
            .styled(.topBar, look: look).foregroundStyle(Color(tokens.colors.text)).tint(Color(tokens.colors.accent))
            .frame(width: width, height: config.height).clipped()
            .style(tokens).font(.system(size: 13)).background(Color(tokens.colors.canvas)),
            to: dir.appending(path: "islands.png"), wait: 0.4)
        try #require(frames.count == 3 && frames.values.allSatisfy { $0.width > 0 }, "an island did not draw: \(frames)")
        let record: JSONValue = .object(["width": .number(Double(width)), "height": .number(Double(config.height)),
            "islands": .object(Dictionary(uniqueKeysWithValues: frames.map { ($0.key.rawValue, .array([$0.value.minX, $0.value.minY, $0.value.width, $0.value.height].map { .number(Double($0)) })) }))])
        try ThemeDigest.encoded(record).write(to: dir.appending(path: "islands.json"))
    }

    /// The dock at the screen's foot with its default widgets, the visualizer playing over the wallpaper.
    static func dock(_ look: Look, wall: NSImage, to dir: URL) throws {
        let tokens = StyleTokens.of(look.style, theme: look.theme)
        let tint = TopBarColour.glassTint(.theme, style: tokens, look: look) ?? .clear
        let frame = DockSyntheticMusic.frame(at: 3.90)
        let scene = DockRiceRenders.Scene(wall: wall, screen: screen, size: CGSize(width: screen.width, height: 330), glassTint: tint,
                                          accent: Color(nsColor: DockRiceRenders.colour(look.theme.accent)), apps: DockRiceRenders.apps(),
                                          widgets: true, placement: .attached, left: frame.left.heights, right: frame.right.heights)
        try writeRender(scene.body.styled(.topBar, look: look).pilotTheme(look: look), to: dir.appending(path: "dock.png"), wait: 1.5)
    }

    /// Look's tiled desk at a screen's scale, nothing behind its windows.
    static func desk(_ look: Look, to dir: URL) throws {
        let clear = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in true }
        try writeRender(LookDesk(colors: look.colors, picture: Image(nsImage: clear)).frame(width: 1480, height: 1150)
                            .styled(.page(.look), look: look).pilotTheme(look: look),
                        to: dir.appending(path: "desk.png"), wait: 0.5)
    }

    /// Two desk widgets on fixed data in the theme, the weather's place swapped for a neutral city.
    static func widgets(_ store: WidgetStore, theme: PilotTheme, to dir: URL) async throws {
        for id in ["desk-weather", "desk-system"] {
            let widget = try #require(store.widget(id))
            var data = try DeskWidgetRenders.fixture(id)
            if id == "desk-weather", case .object(var fields) = data {
                fields["place"] = .string(Self.place)
                data = .object(fields)
            }
            let image = try await DeskWidgetRenders.shot(widget, store: store, data: data, theme: DeskWidgetRenders.theme(theme))
            let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: dir.appending(path: "\(id).png"))
        }
    }

    /// Line's rows over Apple's own apps only, so no real app list shows.
    static func built() -> [MenuEntry] {
        let engine = Engine()
        return MenuEntries.build(
            apps: [("Safari", "com.apple.Safari"), ("Finder", "com.apple.finder"), ("Notes", "com.apple.Notes"), ("Calendar", "com.apple.iCal"),
                   ("Music", "com.apple.Music"), ("Terminal", "com.apple.Terminal"), ("Photos", "com.apple.Photos")],
            actions: engine.bindActions,
            store: BindStore(defaults: ["apps.terminal": Key("return"), "system.lock": Key("escape"), "system.darkMode": Key("d", shift: true),
                                        "captures.menu": Key("c", .ctrl), "apps.emoji": Key("e", .ctrl)]),
            roleApps: ["apps.terminal": "com.apple.Terminal"], menu: AppsModule.menuID, openID: AppsModule.openID(bundle:),
            running: ["com.apple.finder", "com.apple.Notes", "com.apple.Safari"],
            switches: ["system.darkMode": true, "system.keepAwake": false, "system.idleLock": true, "system.nightShift": false, "system.wifi": true])
    }

    /// Made-up windows, none of them Sven's.
    static let windows = """
    [{"window-id": 21, "app-name": "Notes", "app-bundle-id": "com.apple.Notes", "app-pid": 2, "workspace": "2", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "Trip notes"},
     {"window-id": 22, "app-name": "Safari", "app-bundle-id": "com.apple.Safari", "app-pid": 3, "workspace": "1", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "Field notes — a reading list"},
     {"window-id": 23, "app-name": "Terminal", "app-bundle-id": "com.apple.Terminal", "app-pid": 4, "workspace": "3", "monitor-id": 1,
      "window-layout": "h_tiles", "window-title": "~ — zsh"}]
    """

    /// Line at the root, searching "notes" (apps, windows, made-up files and settings), converting and asking.
    static func states() throws -> [(String, MenuModel)] {
        let windows = try AeroWindow.parse(Self.windows)
        let built = built()
        let day = Date(timeIntervalSince1970: 1_791_028_800), home = NSHomeDirectory()
        func model(_ nav: MenuNavigator) -> MenuModel {
            let m = MenuModel(nav: nav)
            m.layout = .line
            m.windows = windows
            m.ownKey = "Hyper+Space"
            m.waiting = MenuModel.waiting(updates: 3, clean: "2.1 GB")
            return m
        }
        func answer(_ query: String) -> MenuModel {
            var nav = MenuNavigator(entries: built)
            nav.query = query
            nav.provide(.answer, RootAnswers.entries(for: query, now: day))
            return model(nav)
        }
        var notes = MenuNavigator(entries: built)
        notes.query = "notes"
        notes.provide(.window, MenuEntries.windows(windows, excluding: nil))
        notes.provide(.file, MenuEntries.files([(home + "/Documents/Trip notes.md", day),
                                                (home + "/Documents/Recipes/Bread notes.md", day.addingTimeInterval(-172_800))], home: home))
        notes.provideSettings("notes")
        return [("menu-root", model(MenuNavigator(entries: built))), ("menu-notes", model(notes)),
                ("menu-convert", answer("22 km to mi")), ("menu-sum", answer("1280 * 0.85")),
                ("menu-ask", answer("ask regex to match a hex colour"))]
            + ["capture", "clip", "dictat", "record", "music", "screen"].map { ("menu-q-\($0)", answer($0)) }
    }
}
}
#endif
