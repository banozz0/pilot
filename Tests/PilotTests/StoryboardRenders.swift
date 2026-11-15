#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The hero film's storyboard and its five candidate themes (website round 3, Sven 2026-11-15): for each theme in
/// `PILOT_STORY_THEMES` (ids, comma-separated), Pilot's own desktop parts over that theme's wallpaper (`PILOT_STORY_WALLS`,
/// "id=path,id=path"): the dock Attached with its widgets and the visualizer playing (DockRiceRenders' scene, on the
/// ultrawide), and the top bar in each preset, Full bar, Floating strip, Three islands and Pills, the island presets
/// Attached (Q256). Drawn by the real dock and strip; nothing reaches the tiler or the system. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_STORY_THEMES=tokyo-night,garnet PILOT_STORY_WALLS=… swift test --filter StoryboardRenders`
extension SharedLook {
@MainActor
@Suite("Storyboard renders")
struct StoryboardRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let barWidth: CGFloat = 1880   // the storyboard's 1904-point screen, less the bar's 12-point margins

    @Test("Each theme's dock and bar presets over its wallpaper",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_STORY_THEMES"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("storyboard")
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let walls = Dictionary((Self.env["PILOT_STORY_WALLS"] ?? "").split(separator: ",").compactMap { pair -> (String, String)? in
            let p = pair.split(separator: "=", maxSplits: 1)
            return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        }, uniquingKeysWith: { a, _ in a })
        let themes = (Self.env["PILOT_STORY_THEMES"] ?? "").split(separator: ",").map(String.init)
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency)
        defer { (look.style, look.themeID, look.glass, look.transparency) = was }
        (look.style, look.transparency) = (.instrument, 33)
        let music = DockSyntheticMusic.frame(at: 3.90)
        for theme in themes {
            look.themeID = theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            let glassTint = Color(nsColor: TopBarColour.tint(.theme, style: tokens, look: look))
            let scene = DockRiceRenders.Scene(wall: walls[theme].flatMap(NSImage.init(contentsOfFile:)), screen: DockRenders.ultrawide,
                                              size: CGSize(width: DockRenders.ultrawide.width, height: 330), glassTint: glassTint,
                                              accent: Color(nsColor: DockRiceRenders.colour(look.theme.accent)), apps: DockRiceRenders.apps(),
                                              widgets: true, placement: .attached, left: music.left.heights, right: music.right.heights)
            try writeRender(scene.body.styled(.topBar, look: look).pilotTheme(look: look), to: dir.appendingPathComponent("dock-\(theme).png"), wait: 1.5)
            for preset in ["floatingStrip", "threeIslands", "pills"] {
                try Self.bar(theme, preset: preset, to: dir.appendingPathComponent("bar-\(preset)-\(theme).png"))
            }
        }
    }

    /// One preset's strip in `theme`, as InstrumentTopBarRenders.renderFloating seeds it, island presets Attached.
    static func bar(_ theme: String, preset: String, to url: URL) throws {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.story-\(preset)-\(theme)")
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(true, forKey: BarItemsStore.extensionsApartKey)
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        try store.choosePreset(preset)
        if preset != "floatingStrip" { try store.setAttached(true) }
        let look = Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), inputSources: BarReadingsTests.Sources(), defaults: defaults)
        look.style = .instrument
        var input = BarInputs()
        input.pilotTitle = "2"; input.workspaces = ["1", "2", "3"]; input.focusedWorkspace = "2"
        input.focusedApp = "Finder"; input.volume = 0.6; input.muted = false; input.wifiOn = true
        input.timerCountdown = "18:42"; input.timerTitle = "Focus"; input.keyboardLayout = "ABC"
        input.now = ClockRenders.now; input.timeZone = TimeZone(secondsFromGMT: 0)!; input.locale = Locale(identifier: "en_US_POSIX")
        for kind in [BarKind.focusedApp, .volume, .wifi, .keyboardLayout] { store.settings.set(kind, on: true) }
        for kind in [BarKind.otherApps, .modes, .group, .cpu, .memory, .network] { store.settings.set(kind, on: false) }
        if preset != "floatingStrip" { store.settings.place(.kind(.clock), on: .centre, at: 0) }
        let sides = store.settings.preview(.topBar).top ?? [:]
        look.preview(theme)
        let tokens = StyleTokens.of(.instrument, theme: look.theme)
        let config = try #require(store.settings.preset)
        try writeRender(TopBarStrip(sides: sides, configuration: config, reportIsland: { _, _ in }) { slot in
            if let parts = BarParts.parts(slot, input, settings: store.settings) {
                BarPartsView(items: parts).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 6)
            }
        }
        .styled(.topBar, look: look).foregroundStyle(Color(tokens.colors.text)).tint(Color(tokens.colors.accent))
        .frame(width: barWidth, height: config.height + (config.isAttached ? 0 : config.topMargin)).clipped()
        .style(tokens).font(.system(size: 13)), to: url, wait: 0.4)
    }
}
}
#endif
