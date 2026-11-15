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
}
}
#endif
