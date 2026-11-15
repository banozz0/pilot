#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Liquid Glass, round 2 (Sven, 2026-11-15, on build 2527: "look at the dock"): the dock and a Three islands top bar on
/// Glass, Dracula, Transparency 100 and Blur Full as Sven runs them, over two of his wallpapers. Liquid Glass's rim and
/// refraction are drawn by the window server over what lies under the window, so nothing offscreen shows them
/// (Memory/Mac liquid-glass-no-offscreen-check). Each is drawn as `live`, the app's own path (what is left offscreen: the
/// fills and edges laid over or under the glass), and the dock as `standin` too, the wallpaper blurred under the glass's
/// tint as the live sites take it. PILOT_GLASS_WALLS lists the wallpapers, PILOT_GLASS_TAG names the run:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_GLASS_WALLS=<a>:<b> PILOT_GLASS_TAG=after swift test --filter LiquidGlassRenders`
@MainActor
@Suite("Liquid Glass renders")
struct LiquidGlassRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The dock and the top bar's islands on Glass over Sven's wallpapers",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_GLASS_WALLS"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch real data")
        testApp()
        let dir = try ClockRenders.dir("liquid-glass")
        let tag = Self.env["PILOT_GLASS_TAG"] ?? "now"
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        let walls = try (Self.env["PILOT_GLASS_WALLS"] ?? "").split(separator: ":").map { try #require(NSImage(contentsOfFile: String($0))) }

        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency, look.glassBlur)
        defer { (look.style, look.themeID, look.glass, look.transparency, look.glassBlur) = was }
        (look.style, look.themeID, look.glass, look.transparency, look.glassBlur) = (.instrument, "dracula", true, 100, .full)
        let tokens = StyleTokens.of(look.style, theme: look.theme)
        // The glass's tint as the dock's live ground takes it (DockBacking), clear where it takes none.
        let tint = TopBarColour.glassTint(.theme, style: tokens, look: look) ?? .clear

        // The bar: Three islands on Glass, the bar's own items, Look passed so each island draws its own glass.
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.liquid-glass-render")
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        var settings = store.settings
        let sides = BarLookRenders.working(&settings)
        store.settings = settings
        StatsRenders.seed(SystemSampler.shared)

        for (index, wall) in walls.enumerated() {
            let name = "wall\(index + 1)"
            let draw = BarLookRenders.Draw(input: BarLookRenders.inputs(), settings: settings, sources: BarLookRenders.sources(), store: store,
                                           look: look, wall: wall, tokens: tokens)
            let bar = draw.bar(sides, config: BarPreset.threeIslands.configuration, background: .glass, live: true)
            try writeRender(bar.frame(width: 1720, alignment: .leading).clipped(), to: dir.appendingPathComponent("\(tag)-bar-\(name)-live.png"), wait: 1.2)

            let desk = DockRenders.Desk(wall: wall, screen: DockRenders.ultrawide, size: CGSize(width: 1640, height: 150))
            for (kind, backing) in [("live", nil), ("standin", { (row: AnyView) in AnyView(row.modifier(DockRenders.GlassStandIn(desk: desk, tint: tint))) })]
                as [(String, ((AnyView) -> AnyView)?)] {
                let strip = DockStrip(size: .medium, apps: DockRenders.apps(16), hasWidgets: true, maxWidth: DockRenders.ultrawide.width - 2 * DockPill.sideMargin,
                                      style: .glass, backing: backing) {
                    ForEach(Array(DockRenders.widgets.enumerated()), id: \.offset) { _, pair in DockWidgetBodyView(widget: pair.0, shown: pair.1) }
                }
                try writeRender(desk.scene(strip.environment(\.inTopBar, true).environment(\.barItemColours, true), look: look),
                                to: dir.appendingPathComponent("\(tag)-dock-\(name)-\(kind).png"), wait: 1.2)
            }
        }
    }

    /// Liquid Glass, round 3 (Sven, 2026-11-15, on build 2550): the wallpaper's tone under a Three islands bar and under
    /// the dock, over a made-up near-black desktop with two bright blocks at known points from the screen's left. The tone
    /// is a plain image, so it draws offscreen where the glass does not: each island and the dock must darken the bright
    /// blocks where they stand, and nothing else of the screen's tone may show inside them (before, each island drew the
    /// whole screen's tone squeezed to its own width: "what is this on light wallpaper"). `predicted.txt` lists the tone
    /// over plain greys, BarTone's clear-glass model, against the macOS Dock's own readings.
    /// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter LiquidGlassRenders`
    @Test("The tone under islands and the dock lines up with the wallpaper",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func tone() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch real data")
        testApp()
        let dir = try ClockRenders.dir("liquid-glass")
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency, look.glassBlur)
        defer { (look.style, look.themeID, look.glass, look.transparency, look.glassBlur) = was }
        (look.style, look.themeID, look.glass, look.transparency, look.glassBlur) = (.instrument, "dracula", true, 100, .full)
        let tokens = StyleTokens.of(look.style, theme: look.theme)

        // The bar: bright blocks at 60 to 140 pt (under the left island) and 1640 to 1800 pt (the centre island's middle).
        let screen = DockRenders.ultrawide, cell = WallpaperStrip.cell
        let barGrid = Self.grid(width: screen.width, rows: 24, bright: [60...140, 1640...1800])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.liquid-glass-tone")
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        var settings = store.settings
        let sides = BarLookRenders.working(&settings)
        let config = BarPreset.threeIslands.configuration
        let draw = BarLookRenders.Draw(input: BarLookRenders.inputs(), settings: settings, sources: BarLookRenders.sources(), store: store,
                                       look: look, wall: Self.image(barGrid), tokens: tokens)
        let side = CGFloat(config.horizontalMargin)
        let bar = TopBarStrip(sides: sides, configuration: config, look: look, background: .glass, wallpaper: barGrid) { draw.slot($0, settings: settings) { AnyView(EmptyView()) } }
            .styled(.topBar, look: look)
            .frame(width: screen.width - 2 * side, height: CGFloat(config.height))
            .padding(.horizontal, side).padding(.top, CGFloat(config.topMargin)).padding(.bottom, 10)
            .frame(width: screen.width, alignment: .topLeading)
            .background(alignment: .topLeading) {
                Image(decorative: Self.cgImage(barGrid), scale: 1)
                    .resizable().interpolation(.none).frame(width: screen.width, height: CGFloat(barGrid.height) * cell)
            }
            .clipped()
        try writeRender(bar, to: dir.appendingPathComponent("tone-bar.png"), wait: 1.2)

        // The dock: a bright block at 1540 to 1660 pt, left of the screen's middle, along the foot.
        let room = Double(DockSize.medium.room(.floating))
        let dockGrid = Self.grid(width: screen.width, rows: Int((room / cell).rounded()), bright: [1540...1660])
        let deskWall = Self.screenImage(dockGrid, screen: screen)
        let desk = DockRenders.Desk(wall: deskWall, screen: screen, size: CGSize(width: 1640, height: 150))
        var strip = DockStrip(size: .medium, apps: DockRenders.apps(16), hasWidgets: true, maxWidth: screen.width - 2 * DockPill.sideMargin, style: .glass) {
            ForEach(Array(DockRenders.widgets.enumerated()), id: \.offset) { _, pair in DockWidgetBodyView(widget: pair.0, shown: pair.1) }
        }
        strip.wallpaper = dockGrid
        try writeRender(desk.scene(strip.environment(\.inTopBar, true).environment(\.barItemColours, true), look: look),
                        to: dir.appendingPathComponent("tone-dock.png"), wait: 1.2)

        // The widgets over a light wallpaper, Sven's amber (read above the dock on build 2550) under the left half of the
        // widgets and near-white under the rest, untoned (as before) and toned: their words must be inked for the ground.
        let light = Self.grid(width: screen.width, rows: Int((room / cell).rounded()), bright: [], fill: { x in
            x < 1500 ? [14, 12, 16] : x < 2000 ? [130, 89, 19] : [236, 236, 232]
        })
        let lightDesk = DockRenders.Desk(wall: Self.screenImage(light, screen: screen, fill: [236, 236, 232]), screen: screen, size: CGSize(width: 1640, height: 150))
        for (name, grid) in [("untoned", nil), ("toned", light)] as [(String, WallpaperStrip.Grid?)] {
            strip.wallpaper = grid
            try writeRender(lightDesk.scene(strip.environment(\.inTopBar, true).environment(\.barItemColours, true), look: look),
                            to: dir.appendingPathComponent("tone-dock-light-\(name).png"), wait: 1.2)
        }

        // The model over plain greys: what clear glass shows (glassVeil) and what the tone leaves (the cap at the Dock's
        // veil, the menu bar's curve past it), against the macOS Dock over Sven's near-black (6 to 18).
        var lines = ["grey  glass-shows  tone-alpha  left  white-on-it  (macOS Dock 6 -> 18)"]
        for grey in [6, 24, 37, 64, 128, 180, 230, 255] {
            let g = WallpaperStrip.Grid(width: 1, height: 1, rgb: [UInt8(grey), UInt8(grey), UInt8(grey)])
            let tone = try #require(BarTone.make(g, prefersWhite: true, glass: true))
            let shows = Double(grey) + BarTone.glassVeil * (255 - Double(grey)), a = Double(tone.alpha[0]) / 255
            let left = shows * (1 - a), ratio = Contrast.ratio([255, 255, 255], [left, left, left])
            lines.append(String(format: "%4d  %11.1f  %10.2f  %5.1f  %6.2f : 1", grey, shows, a, left, ratio))
        }
        // The jade horse's foot, where the macOS Dock shows the desk as it is (36, 53, 40; Sven on build 2564).
        let jade: [Double] = [35, 50, 38]
        let jadeTone = try #require(BarTone.make(WallpaperStrip.Grid(width: 1, height: 1, rgb: jade.map { UInt8($0) }), prefersWhite: true, glass: true))
        let ja = Double(jadeTone.alpha[0]) / 255
        let jadeLeft = jade.map { ($0 + BarTone.glassVeil * (255 - $0)) * (1 - ja) }
        lines.append(String(format: "jade (35 50 38): tone-alpha %.2f, left %.0f %.0f %.0f  (macOS Dock 36 53 40)", ja, jadeLeft[0], jadeLeft[1], jadeLeft[2]))
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("predicted.txt"), atomically: true, encoding: .utf8)
    }

    /// Pills on Glass and Clear over a bright sky (Sven on build 2577: "pills glass look how they look", washed out over
    /// a blue sky with a cloud in the middle): each pill tones the sky under it as the islands do, Floating and Attached.
    /// The tone is a plain image and draws offscreen; the glass does not, so the pictures show the tone, the ink and the
    /// rings, never the glass's blur or rim.
    /// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter LiquidGlassRenders/pills`
    @Test("Pills tone a bright sky under them on Glass and Clear",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func pills() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch real data")
        testApp()
        let dir = try ClockRenders.dir("liquid-glass")
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency, look.glassBlur)
        defer { (look.style, look.themeID, look.glass, look.transparency, look.glassBlur) = was }
        (look.style, look.themeID, look.glass, look.transparency, look.glassBlur) = (.instrument, "dracula", true, 100, .full)
        let tokens = StyleTokens.of(look.style, theme: look.theme)
        let screen = DockRenders.ultrawide, cell = WallpaperStrip.cell
        // His sky (read off the build 2577 screenshot) with a white cloud across the bar's middle.
        let sky = Self.grid(width: screen.width, rows: 24, bright: [], fill: { x in (1500...2000).contains(x) ? [236, 238, 242] : [74, 142, 222] })
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.liquid-glass-pills")
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        var settings = store.settings
        let sides = BarLookRenders.working(&settings)
        let draw = BarLookRenders.Draw(input: BarLookRenders.inputs(), settings: settings, sources: BarLookRenders.sources(), store: store,
                                       look: look, wall: Self.image(sky), tokens: tokens)
        for attached in [false, true] {
            var config = BarPreset.pills.configuration
            config.attached = attached ? true : nil
            let frame = config.frame(screen: CGRect(origin: .zero, size: screen))
            for background in [TopBarBackground.glass, .clear] {
                let bar = TopBarStrip(sides: sides, configuration: config, look: look, background: background, wallpaper: sky) { draw.slot($0, settings: settings) { AnyView(EmptyView()) } }
                    .styled(.topBar, look: look)
                    .frame(width: frame.width, height: frame.height)
                    .padding(.horizontal, frame.minX).padding(.top, screen.height - frame.maxY).padding(.bottom, 10)
                    .frame(width: screen.width, alignment: .topLeading)
                    .background(alignment: .topLeading) {
                        Image(decorative: Self.cgImage(sky), scale: 1)
                            .resizable().interpolation(.none).frame(width: screen.width, height: CGFloat(sky.height) * cell)
                    }
                    .clipped()
                try writeRender(bar, to: dir.appendingPathComponent("pills-sky-\(background.rawValue)-\(attached ? "attached" : "floating").png"), wait: 1.2)
            }
        }
    }

    /// A made-up wallpaper strip `width` points wide: near-black, bright where `bright` says, in points from the left.
    static func grid(width: CGFloat, rows: Int, bright: [ClosedRange<CGFloat>], fill: ((CGFloat) -> [UInt8])? = nil) -> WallpaperStrip.Grid {
        let cols = Int(width / WallpaperStrip.cell)
        var rgb = [UInt8]()
        for _ in 0..<rows {
            for c in 0..<cols {
                let x = CGFloat(c) * WallpaperStrip.cell
                rgb += fill?(x) ?? (bright.contains { $0.contains(x) } ? [235, 230, 220] : [14, 12, 16])
            }
        }
        return WallpaperStrip.Grid(width: cols, height: rows, rgb: rgb)
    }

    /// The strip as a picture, a pixel a cell.
    static func cgImage(_ grid: WallpaperStrip.Grid) -> CGImage {
        var rgba = [UInt8](repeating: 255, count: grid.width * grid.height * 4)
        for i in 0..<grid.width * grid.height { (rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]) = (grid.rgb[i * 3], grid.rgb[i * 3 + 1], grid.rgb[i * 3 + 2]) }
        return CGImage(width: grid.width, height: grid.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: grid.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func image(_ grid: WallpaperStrip.Grid) -> NSImage {
        NSImage(cgImage: cgImage(grid), size: NSSize(width: grid.width, height: grid.height))
    }

    /// A whole screen's picture, a pixel a point, with `grid` along its foot over the same near-black, as Desk fills a screen.
    static func screenImage(_ grid: WallpaperStrip.Grid, screen: CGSize, fill: [CGFloat] = [14, 12, 16]) -> NSImage {
        let (w, h) = (Int(screen.width), Int(screen.height))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: fill[0] / 255, green: fill[1] / 255, blue: fill[2] / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .none
        ctx.draw(cgImage(grid), in: CGRect(x: 0, y: 0, width: screen.width, height: CGFloat(grid.height) * WallpaperStrip.cell))
        return NSImage(cgImage: ctx.makeImage()!, size: screen)
    }
}
}
#endif
