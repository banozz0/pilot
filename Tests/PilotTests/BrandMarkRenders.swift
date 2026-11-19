#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Pilot's mark on the top bar in five themes (brand round 1, Sven 2026-11-15: "can pilot top left box change with the
/// theme?"): Sven's own bar from his exported `bar.*` preferences (PILOT_BAR_PREFS), drawn by the real strip and slots
/// (TopBarStrip, TopBarSlot) as BarAttachedRenders draws it, on Solid, on Glass (BarGlassGround's stand-in: offscreen
/// Liquid Glass draws nothing) and on Clear, each over the wallpapers PILOT_BAR_WALLS names (`name=path`, comma separated;
/// the first is Solid's). Meadow and Neon Rain are catalogue packs, worn from their manifests as Look › Theme tries one on. Each
/// picture's filled top-left box is found by the theme's accent and measured against the ground beside it; the line is
/// printed (`BRAND …`), nothing is expected, since the round asks what it reads. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_BAR_PREFS=<plist> PILOT_BAR_WALLS=dark=<image>,light=<image> swift test --filter BrandMarkRenders`
extension SharedLook {
@MainActor
@Suite("Brand mark renders")
struct BrandMarkRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let themes: [(id: String, pack: Bool)] = [("meadow", true), ("neon-rain", true), ("tokyo-night", false), ("garnet", false), ("void", false)]

    @Test("The top bar's Pilot mark in five themes on Solid, Glass and Clear, over a dark and a light wallpaper",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_BAR_PREFS"] != nil
                   && env["PILOT_BAR_WALLS"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch real data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }

        let suite = "dev.banozz.pilot.brand-render"
        let prefs = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        let target = prefs.appendingPathComponent(suite + ".plist")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.env["PILOT_BAR_PREFS"]!), to: target)
        let store = BarItemsStore(defaults: try BarFixtureDefaults(root: home, suite: suite), statsPrefs: { [:] })

        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency)
        (look.style, look.glass, look.transparency) = (.instrument, true, 100)
        defer { look.endTrial(); (look.style, look.themeID, look.glass, look.transparency) = was }

        let screen = BarAttachedRenders.screen
        let walls = try Self.env["PILOT_BAR_WALLS"]!.split(separator: ",").map { pair in
            let name = String(pair.split(separator: "=")[0]), url = URL(fileURLWithPath: String(pair.split(separator: "=")[1]))
            return (name: name, image: try #require(NSImage(contentsOf: url)), grid: WallpaperStrip.grid(url, screen: screen.size, strip: 30))
        }
        let sources = try await BarAttachedRenders.sources(home: home)
        var held: Set<BarKind> = []
        sources.readings.hold(Set(BarKind.allCases), replacing: &held)
        _ = try await SystemSamplerTests.wait(seconds: 20) { sources.sampler.latestValues != nil && sources.sampler.history.count >= 3 }
        await sources.extensionBar.round()
        sources.extensionBar.stop()
        defer { sources.readings.hold([], replacing: &held) }

        let dir = URL(fileURLWithPath: Self.env["PILOT_RENDER_DIR"]!).appendingPathComponent("brand-mark")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = LookThemeTests.fonts.deletingLastPathComponent().deletingLastPathComponent()
        let own = store.background
        defer { store.background = own }

        for theme in Self.themes {
            let pack = theme.pack ? try ThemePack.decode(Data(contentsOf: root.appending(path: "catalogue/themes/\(theme.id)/manifest.json"))) : nil
            look.tryOn(id: theme.id, pack: pack)
            let accent = look.theme.accent
            for (background, wall) in [(TopBarBackground.solid, walls[0])] + walls.map({ (TopBarBackground.glass, $0) }) + walls.map({ (TopBarBackground.clear, $0) }) {
                store.background = background
                let config = store.topBarConfiguration
                let frame = config?.frame(screen: screen) ?? CGRect(x: 0, y: screen.maxY - 37, width: screen.width, height: 37)
                let sides = store.settings.preview(.topBar).top ?? [:]
                let bar = TopBarStrip(sides: sides, configuration: config, look: look, background: background, colour: store.colour,
                                      glassPreview: true, itemColours: store.itemColours, wallpaper: wall.grid) {
                    TopBarSlot(slot: $0, screen: "", sources: sources, store: store)
                }
                .styled(.topBar, look: look)
                .pilotTheme()
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: screen.maxY - frame.maxY)
                let rep = try rendered(BarAttachedRenders.desk(wall: wall.image) { bar }, wait: 1.0)
                let name = "\(theme.id)-\(background.rawValue)-\(wall.name)"
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
                print("BRAND \(name) accent=\(Self.hex(accent)) " + Self.measure(rep, accent: accent))
            }
        }
    }

    /// The filled box: the pixels within 6 of `accent` in the bar's first 160 points, then the ground 3 pixels left of the leftmost (the bar beside the mark).
    static func measure(_ rep: NSBitmapImageRep, accent: UInt32) -> String {
        let a = [Int(accent >> 16 & 0xFF), Int(accent >> 8 & 0xFF), Int(accent & 0xFF)]
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<min(rep.pixelsWide, 320) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let p = [Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())]
                if zip(p, a).allSatisfy({ abs($0 - $1) <= 6 }) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= 0, minX >= 3 else { return "box=none" }
        let ground = pixel(rep, minX - 3, (minY + maxY) / 2)
        let ratio = Contrast.ratio(accent, ground)
        return "box=\(minX),\(minY) \(maxX - minX + 1)x\(maxY - minY + 1) ground=\(hex(ground)) ratio=\(String(format: "%.2f", ratio))"
    }

    static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> UInt32 {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        func b(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return b(c.redComponent) << 16 | b(c.greenComponent) << 8 | b(c.blueComponent)
    }

    static func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }
}
}
#endif
