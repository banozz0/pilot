#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The top bar's and the dock's ink over the wallpaper (Sven, 2026-11-15, Q288: a light theme's text turns white where the
/// wallpaper under it is dark): Meadow (light) and Tokyo Night (dark) on Clear and Glass, Three islands and the dock, each
/// over the wallpapers PILOT_INK_WALLS names (`name=path`, comma separated), drawn by the real strip and pill. Prints each
/// tone's ink against its median toned ground (`INK …`). Glass is the renders' stand-in: Liquid Glass draws nothing
/// offscreen. PILOT_INK_TAG names the run (before, after). Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_INK_WALLS=dark=<image>,light=<image> PILOT_INK_TAG=after swift test --filter BarInkRenders`
extension SharedLook {
@MainActor
@Suite("Bar ink renders")
struct BarInkRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Meadow and Tokyo Night's bar and dock ink over dark and light wallpapers",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_INK_WALLS"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch real data")
        testApp()
        let dir = try ClockRenders.dir("bar-ink")
        let tag = Self.env["PILOT_INK_TAG"] ?? "now"
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }

        let screen = DockRenders.ultrawide
        let room = Double(DockSize.medium.room(.floating))
        let walls = try Self.env["PILOT_INK_WALLS"]!.split(separator: ",").map { pair in
            let name = String(pair.split(separator: "=")[0]), url = URL(fileURLWithPath: String(pair.split(separator: "=")[1]))
            return (name: name, image: try #require(NSImage(contentsOf: url)),
                    bar: try #require(WallpaperStrip.grid(url, screen: screen, strip: 30)),
                    dock: try #require(WallpaperStrip.grid(url, screen: screen, strip: room, y: Double(screen.height) - room)))
        }

        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency, look.glassBlur)
        (look.style, look.glass, look.transparency, look.glassBlur) = (.instrument, true, 100, .full)
        defer { look.endTrial(keep: false); (look.style, look.themeID, look.glass, look.transparency, look.glassBlur) = was }
        let root = LookThemeTests.fonts.deletingLastPathComponent().deletingLastPathComponent()

        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.bar-ink")
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        var settings = store.settings
        let sides = BarLookRenders.working(&settings)
        store.settings = settings
        StatsRenders.seed(SystemSampler.shared)
        let config = BarPreset.threeIslands.configuration

        for (theme, pack) in [("meadow", true), ("tokyo-night", false)] {
            look.tryOn(id: theme, pack: pack ? try ThemePack.decode(Data(contentsOf: root.appending(path: "catalogue/themes/\(theme)/manifest.json"))) : nil)
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            for wall in walls {
                let draw = BarLookRenders.Draw(input: BarLookRenders.inputs(), settings: settings, sources: BarLookRenders.sources(), store: store,
                                               look: look, wall: wall.image, tokens: tokens)
                for background in [TopBarBackground.clear, .glass] {
                    let name = "\(tag)-\(theme)-\(wall.name)-\(background.rawValue)"
                    for (part, grid) in [("bar", wall.bar), ("dock", wall.dock)] {
                        if let toned = TopBarColour.tone(grid, background: background, colour: .theme, style: tokens, look: look) {
                            print("INK \(name) \(part) ink=\(String(format: "#%06X", toned.tone.ink)) ground=\(String(format: "#%06X", toned.tone.ground)) ratio=\(String(format: "%.2f", Contrast.ratio(toned.tone.ink, toned.tone.ground)))")
                        }
                    }
                    let side = CGFloat(config.horizontalMargin)
                    let bar = TopBarStrip(sides: sides, configuration: config, look: look, background: background, glassPreview: true, wallpaper: wall.bar) {
                        draw.slot($0, settings: settings) { AnyView(EmptyView()) }
                    }
                    .styled(.topBar, look: look)
                    .pilotTheme()
                    .frame(width: screen.width - 2 * side, height: CGFloat(config.height))
                    .padding(.horizontal, side).padding(.top, CGFloat(config.topMargin)).padding(.bottom, 10)
                    .frame(width: screen.width, alignment: .topLeading)
                    .background(alignment: .top) {
                        let shown = WallpaperStrip.rect(image: wall.image.size, screen: screen, placement: .init())
                        Image(nsImage: wall.image).resizable().frame(width: shown.width, height: shown.height).offset(x: shown.minX, y: shown.minY)
                            .frame(width: screen.width, height: 56, alignment: .topLeading).clipped()
                    }
                    .clipped()
                    try writeRender(bar, to: dir.appendingPathComponent("\(name)-bar.png"), wait: 1.2)

                    let desk = DockRenders.Desk(wall: wall.image, screen: screen, size: CGSize(width: 1640, height: 150))
                    var strip = DockStrip(size: .medium, apps: DockRenders.apps(12), hasWidgets: true, maxWidth: screen.width - 2 * DockPill.sideMargin,
                                          style: background) {
                        ForEach(Array(DockRenders.widgets.enumerated()), id: \.offset) { _, pair in DockWidgetBodyView(widget: pair.0, shown: pair.1) }
                    }
                    strip.wallpaper = wall.dock
                    try writeRender(desk.scene(strip.environment(\.inTopBar, true).environment(\.barItemColours, true), look: look),
                                    to: dir.appendingPathComponent("\(name)-dock.png"), wait: 1.2)
                }
            }
        }
    }
}
}
#endif
