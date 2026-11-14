#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Attached and Floating (Sven, 2026-11-13, Q224: "how its attatched flush to the the very top of the screen"): Sven's own
/// bar from his exported `bar.*` preferences (PILOT_BAR_PREFS) over his wallpaper (PILOT_BAR_WALL) on his 3440 × 1440
/// display, Three islands and Pills each Floating and Attached, every bar placed where its window goes
/// (BarPresetConfiguration.frame) and drawn by the real strip and slots (TopBarStrip, TopBarSlot); Instrument on Dracula,
/// Glass approximated by BarGlassGround. It also prints each frame on a notched 1512 × 982 display. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_BAR_PREFS=<plist> PILOT_BAR_WALL=<image> swift test --filter BarAttachedRenders`
extension SharedLook {
@MainActor
@Suite("Bar attached renders")
struct BarAttachedRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let screen = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    /// How much of the screen's top each picture keeps.
    static let shown: CGFloat = 64
    static let now = Date(timeIntervalSince1970: 1_794_563_340)   // 2026-11-13 09:49 UTC

    @Test("Three islands and Pills, Floating and Attached, over Sven's wallpaper",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_BAR_PREFS"] != nil && env["PILOT_BAR_WALL"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch real data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }

        // His bar.* keys, copied into the moved home as the fixture's own suite.
        let suite = "dev.banozz.pilot.attached-render"
        let prefs = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        let target = prefs.appendingPathComponent(suite + ".plist")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.env["PILOT_BAR_PREFS"]!), to: target)
        let store = BarItemsStore(defaults: try BarFixtureDefaults(root: home, suite: suite), statsPrefs: { [:] })

        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency)
        (look.style, look.themeID, look.glass, look.transparency) = (.instrument, "dracula", true, 100)
        defer { (look.style, look.themeID, look.glass, look.transparency) = was }

        let wallURL = URL(fileURLWithPath: Self.env["PILOT_BAR_WALL"]!)
        let wall = try #require(NSImage(contentsOf: wallURL))
        let grid = WallpaperStrip.grid(wallURL, screen: Self.screen.size, strip: 30)
        let sources = try await Self.sources(home: home)
        let dir = URL(fileURLWithPath: Self.env["PILOT_RENDER_DIR"]!).appendingPathComponent("bar-attached")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var held: Set<BarKind> = []
        let all = Set(BarKind.allCases)
        sources.readings.hold(all, replacing: &held)
        _ = try await SystemSamplerTests.wait(seconds: 20) { sources.sampler.latestValues != nil && sources.sampler.history.count >= 3 }
        await sources.extensionBar.round()
        sources.extensionBar.stop()
        defer { sources.readings.hold([], replacing: &held) }

        // Attached round 2 (Sven on build 2479, 2026-11-14): the flared edge in each Background, as his own (Glass) and
        // Solid and Clear; Floating once in his own.
        let own = store.background
        defer { store.background = own }
        for preset in [BarPreset.threeIslands, .pills] {
            try store.choosePreset(preset.rawValue)
            for (attached, background) in [(false, own), (true, TopBarBackground.glass), (true, .solid), (true, .clear)] {
                store.background = background
                try store.setAttached(attached)
                let config = try #require(store.topBarConfiguration)
                let name = "\(preset.rawValue)-\(attached ? "attached-\(background.rawValue)" : "floating")"
                // Where the window goes on his display, and on a MacBook's notched one (its menu strip 32 high).
                let frame = config.frame(screen: Self.screen)
                let notched = CGRect(x: 0, y: 0, width: 1512, height: 982), notchFrame = config.frame(screen: notched, notchHeight: 32)
                print("BAR \(name) frame top=\(Int(Self.screen.maxY - frame.maxY)) height=\(Int(frame.height)) x=\(Int(frame.minX)) · notched top=\(Int(notched.maxY - notchFrame.maxY))")
                let sides = store.settings.preview(.topBar).top ?? [:]
                let bar = TopBarStrip(sides: sides, configuration: config, look: look, background: store.background, colour: store.colour,
                                      glassPreview: true, itemColours: store.itemColours, wallpaper: grid) {
                    TopBarSlot(slot: $0, screen: "", sources: sources, store: store)
                }
                .styled(.topBar, look: look)
                .pilotTheme()
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: Self.screen.maxY - frame.maxY)
                try writeRender(Self.desk(wall: wall) { bar }, to: dir.appendingPathComponent("\(name).png"), wait: 1.0)
            }
        }
    }

    /// The top of his screen: the wallpaper filled to the display as macOS fills it, the bar where its window puts it.
    static func desk(wall: NSImage, @ViewBuilder bar: () -> some View) -> some View {
        let shown = WallpaperStrip.rect(image: wall.size, screen: screen.size, placement: .init())
        return ZStack(alignment: .topLeading) {
            Image(nsImage: wall).resizable().interpolation(.high)
                .frame(width: shown.width, height: shown.height).offset(x: shown.minX, y: shown.minY)
            bar()
        }
        .frame(width: screen.width, height: Self.shown, alignment: .topLeading)
        .clipped()
    }

    // MARK: Fixture

    /// His Mac as `pilot` read it on 2026-11-13: workspace 1 in front, 4 holding Vesktop; Ghostex's menus; his menu bar
    /// apps; his top bar's extensions answering as they last did (`pilot dock widgets`), their programs never run.
    static func sources(home: String) async throws -> BarSources {
        let observers = EngineObservers()
        observers.tiler.seed(focused: "1", occupied: [OccupiedWorkspace(name: "1", apps: ["Ghostex", "ZapFast", "Google Chrome"]),
                                                      OccupiedWorkspace(name: "4", apps: ["Vesktop"])])
        let fake = MenuAppsTests.FakeExtras()
        fake.trees = [AppMenusTests.textEdit: AppMenusTests.menuBar(["Apple", "Ghostex", "File", "Edit", "View", "Window", "Help"])]
        let menus = AppMenus(reader: fake, front: { AppMenusTests.textEdit }, center: NotificationCenter())
        await menus.refresh().value
        let apps = TopBarLookTests.svensApps()
        await apps.refresh()
        // The catalogue's manifests in a folder of the moved home; `run` answers for each, so no program runs.
        let folder = URL(fileURLWithPath: home).appendingPathComponent("render-extensions")
        try? FileManager.default.removeItem(at: folder)
        let catalogue = LookThemeTests.fonts.deletingLastPathComponent().deletingLastPathComponent().appending(path: "catalogue/extensions")
        for id in answers.keys {
            try FileManager.default.createDirectory(at: folder.appending(path: id), withIntermediateDirectories: true)
            for file in ["extension.json", "main.py"] {
                try FileManager.default.copyItem(at: catalogue.appending(path: "\(id)/\(file)"), to: folder.appending(path: "\(id)/\(file)"))
            }
        }
        let answers = Self.answers
        let bar = ExtensionBar(folder: folder, run: { _, inputs in
            let id = answers.keys.first { inputs.data.path.contains("/\($0)") }
            return id.flatMap { answers[$0] }.map(SurfaceOutcome.bar) ?? .error("no answer")
        })
        return MenuBarStatusItemsTests.sources(Self.sampler(), timer: ExtensionTimer(now: { Self.now }), observers: observers,
                                               clock: { Self.now }, appMenus: menus, menuApps: apps, extensionBar: bar)
    }

    /// What each of his top bar's extensions last said, as their programs word it.
    nonisolated static let answers: [String: Extension.BarAnswer] = [
        "ai-usage": Extension.BarAnswer(text: "", gauges: [Extension.Gauge(meters: [51], icon: .claude, text: "51%"),
                                                           Extension.Gauge(tone: .warn, icon: .openai, text: "100%")]),
        "ghostex": Extension.BarAnswer(text: "👻 3"),
        "summarise": Extension.BarAnswer(text: "📝"),
        "tailscale": Extension.BarAnswer(text: "🛜 3"),
        "todo": Extension.BarAnswer(text: "☑️ 2"),
        "video-downloader": Extension.BarAnswer(text: "📥"),
        "weather": Extension.BarAnswer(text: "☀️ 17°"),
    ]

    /// CPU 56 %, memory 69 %, heat 89°, storage 95 %, as `pilot dock widgets` read them.
    static func sampler() -> SystemSampler {
        let counter = SystemSamplerTests.Counter()
        return SystemSampler(historyLength: 60, read: { parts in
            let t = Double(counter.bump(slow: false, processes: false))
            var raw = SystemSamplerTests.raw(t, slow: true, processes: false)
            raw.cpu = .init(user: UInt64(t) * 56, system: 0, idle: 44 * UInt64(t), nice: 0)
            raw.memory.active = 560_000
            raw.memory.wired = 163_000
            raw.slow.disk = .init(available: 5, total: 100)
            if parts.contains(.sensors) { raw.sensors = .init(temperatures: ["Tp01": 89], fans: [], power: nil) }
            return raw
        }, fetchPublicIP: { nil }, netTop: { nil })
    }
}
}
#endif
