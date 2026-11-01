#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Story 161's surfaces drawn: an extension's page (AI usage's blocks: stats, meters, a list, markdown, buttons) in
/// Instrument and Toybox, one with a failure over its last blocks; the top bar with the Extensions item beside the
/// clock, and its dropdown, in each style. Folders are temporary and the runs fakes. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ExtensionSurfaceRenders`
extension SharedLook {
@MainActor
@Suite("Extension surface renders")
struct ExtensionSurfaceRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let blocks: [Extension.Block] = [
        .stats([.init(label: "Codex 5 h", value: "52%", tone: .warn), .init(label: "Codex week", value: "18%"), .init(label: "Claude block", value: "1.2M")]),
        .meter(.init(label: "Codex 5 h", percent: 52, note: "resets today 14:20 (in 2 h 18 min)", tone: .warn)),
        .meter(.init(label: "Codex week", percent: 18, note: "resets Mon 13 Oct 09:00")),
        .list(title: "Claude Code", items: [
            Extension.Item(title: "This block", subtitle: "1.2M tokens since 11:40 · resets 16:40", icon: "🤖", actions: [.copy("1.2M")]),
            Extension.Item(title: "Last 7 days", subtitle: "38M tokens", icon: "📅",
                           actions: [.copy("38M"), Extension.Item.Action(kind: .open("~/.claude/projects"), title: "Open logs")]),
        ]),
        .markdown("Tokens count input, output and cache. **Claude's share of its limit** is in no local log, so it is unknown."),
        .buttons([Extension.Item.Action(kind: .run(command: "summary", context: nil), title: "Copy summary"),
                  Extension.Item.Action(kind: .open("~/.codex/sessions"), title: "Open Codex logs")]),
    ]

    /// The render folder `name` in a moved home, the app and the faces ready; refuses Sven's own home.
    static func out(_ name: String) throws -> URL {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let out = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"])).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        return out
    }

    @Test("An extension page, the Extensions bar item and its dropdown render in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let out = try Self.out("extension-surfaces")
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }

        let dir = try ExtensionSurfaceTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        try ExtensionSurfaceTests.write("ai-usage", title: "AI usage", in: exts)
        try ExtensionSurfaceTests.write("github", title: "GitHub", in: exts)
        let blocks = Self.blocks
        let page = ExtensionPageModel(id: "ai-usage", folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { _, _ in .blocks(blocks) })
        await page.refresh()
        let stale = ExtensionPageModel(id: "ai-usage", folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { _, _ in .error("did not answer in 5 s") })
        await stale.refresh()
        // pilot-1-1 T8 (Q638): an answer, then a failed ask: the last answer dimmed, why and the next try in the header.
        final class Asks: @unchecked Sendable { var n = 0 }
        let asks = Asks()
        let dimmed = ExtensionPageModel(id: "ai-usage", folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { _, _ in
            asks.n += 1
            return asks.n == 1 ? .blocks(blocks) : .error("did not answer in 5 s")
        })
        await dimmed.refresh()
        await dimmed.refresh(reread: true)

        func shot(_ name: String, _ model: ExtensionPageModel, style: PilotStyle, theme: String) throws {
            (look.themeID, look.style) = (theme, style)
            let view = SurfaceGround { ExtensionSurfacePage(id: model.id, onScreen: false, model: model) { _ in }.frame(width: 900, height: 760) }
                .styled(.page(.extensions), look: look).pilotTheme(look: look)
            try writeRender(view, to: out.appendingPathComponent("page-\(name).png"), wait: 0.6)
        }
        try shot("instrument", page, style: .instrument, theme: "nightwatch")
        try shot("toybox", page, style: .toybox, theme: "toybox")
        try shot("instrument-failed", stale, style: .instrument, theme: "nightwatch")
        try shot("instrument-dimmed", dimmed, style: .instrument, theme: "nightwatch")

        // The bar: the timer, the Extensions item (AI usage warns, GitHub alerts), the clock.
        let bar = ExtensionBar(folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { surface, _ in
            surface.command.id.extension == "github" ? .bar(Extension.BarAnswer(text: "CI 2 red", tone: .alert))
                : .bar(Extension.BarAnswer(text: "AI 52%", tone: .warn, blocks: Array(blocks.prefix(3))))
        })
        await bar.round()
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   readBattery: { nil }, readWiFi: { nil }, clock: { ClockRenders.now }, watchStats: { _ in Task {} },
                                   calendar: ClockCalendar { ClockPopoverTests.FakeStore() }, extensionBar: bar)
        let sources = BarSources(readings: readings, observers: EngineObservers(), sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: ExtensionTimer(), extensionBar: bar, pilotTitle: { "2" })
        var s = BarSettings.defaults
        s.set(.clock, style: .time)
        let sides: [TopBarSide: [BarSlot]] = [.left: [.item(s.entry(.pilot))], .right: [.item(s.entry(.extensions)), .item(s.entry(.clock))]]
        for (style, theme) in [(PilotStyle.instrument, "nightwatch"), (.toybox, "toybox")] {
            (look.themeID, look.style) = (theme, style)
            let strip = TopBarStrip(sides: sides) { TopBarSlotView(slot: $0, screen: "Studio", sources: sources, store: .shared) }
                .styled(.topBar, look: look).pilotTheme(look: look).frame(width: 700, height: 32)
            try writeRender(strip, to: out.appendingPathComponent("bar-\(style.rawValue).png"), wait: 0.6)
            let tokens = StyleTokens.of(style, theme: look.theme)
            try writeRender(ExtensionBarPopover(bar: bar).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                .background(Color(tokens.colors.canvas)), to: out.appendingPathComponent("dropdown-\(style.rawValue).png"), wait: 0.5)
        }
    }

    /// Weather's popover (omarchy-ideas T4): a hero over a five-day strip, then today's rain as a meter.
    static let weather: [Extension.Block] = [
        .hero(.init(glyph: "☀️", value: "24", unit: "°C", place: "Valletta",
                    stats: [.init(label: "Feels", value: "26°"), .init(label: "Wind", value: "12 km/h"), .init(label: "Humidity", value: "61%")])),
        .strip([.init(label: "Thu", glyph: "☀️", high: "25°", low: "18°"), .init(label: "Fri", glyph: "⛅️", high: "23°", low: "17°"),
                .init(label: "Sat", glyph: "🌧️", high: "19°", low: "15°"), .init(label: "Sun", glyph: "🌦️", high: "21°", low: "16°"),
                .init(label: "Mon", glyph: "☀️", high: "26°", low: "19°")]),
        .meter(.init(label: "Rain today", percent: 10, value: "10%")),
    ]

    @Test("omarchy-ideas T4: Weather's hero and strip in its 380-wide popover in Instrument and Toybox, dark and light, and on its page",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func heroAndStrip() async throws {
        let out = try Self.out("extension-hero")
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        look.glass = false
        defer { (look.themeID, look.style, look.glass) = saved }
        let dir = try ExtensionSurfaceTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions"), storage = ExtensionSurfaceTests.storage(dir)
        try ExtensionSurfaceTests.write("weather", title: "Weather", in: exts)
        let blocks = Self.weather
        let item = ExtensionBar.Item(id: "weather", title: "Weather", icon: "🌤️", hasPage: true, answer: nil, problem: nil)
        for (style, theme, shade) in ClockRenders.looks {
            (look.themeID, look.style) = (theme, style)
            let model = ExtensionPopoverModel(id: "weather", folder: exts, storage: storage, run: { _, _, _ in .blocks(blocks) })
            await model.open()
            #expect(model.top.blocks == blocks)
            let tokens = StyleTokens.of(style, theme: look.theme)
            try writeRender(ExtensionPopoverView(item: item, model: model).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                .background(Color(tokens.colors.canvas)), to: out.appendingPathComponent("popover-\(style.rawValue)-\(shade).png"), wait: 0.6)
        }
        // The page draws them larger, beside AI usage's blocks as an older extension sends them.
        (look.themeID, look.style) = ("nightwatch", .instrument)
        let mixed = blocks + Array(Self.blocks.prefix(2))
        let page = ExtensionPageModel(id: "weather", folder: exts, storage: storage, run: { _, _ in .blocks(mixed) })
        await page.refresh()
        let view = SurfaceGround { ExtensionSurfacePage(id: "weather", onScreen: false, model: page) { _ in }.frame(width: 900, height: 760) }
            .styled(.page(.extensions), look: look).pilotTheme(look: look)
        try writeRender(view, to: out.appendingPathComponent("page-instrument.png"), wait: 0.6)
    }

    /// Weather as the mockup draws it (Q475): line glyphs by name, a hero over today's hours.
    static let lineWeather: [Extension.Block] = [
        .hero(.init(glyph: "cloud.sun", value: "27", unit: "°C", place: "Valletta",
                    stats: [.init(label: "Feels", value: "29°"), .init(label: "Wind", value: "14 km/h"), .init(label: "Humid", value: "68%")])),
        .strip([.init(label: "13:00", glyph: "cloud.sun", high: "27°"), .init(label: "14:00", glyph: "cloud.sun", high: "28°"),
                .init(label: "15:00", glyph: "sun", high: "28°"), .init(label: "16:00", glyph: "sun", high: "27°"),
                .init(label: "17:00", glyph: "cloud", high: "26°"), .init(label: "18:00", glyph: "cloud", high: "25°"),
                .init(label: "19:00", glyph: "moon", high: "24°")]),
        .stats([.init(label: "Rain", value: "4%"), .init(label: "UV", value: "6"), .init(label: "Sunset", value: "18:21")]),
        .meter(.init(label: "Rain today", percent: 4, value: "4%")),
    ]

    @Test("Q474, Q475: the Omarchy weather look on an extension's popover, page and detail, in Instrument light and dark",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func omarchyLook() async throws {
        let out = try Self.out("extension-omarchy")
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass, look.transparency)
        // Offscreen the glass draws a flat grey (GlassEverywhereRenders' probe): these are the layout on Solid, and the
        // glass-* ones its face on Glass (no fill, no ring, see-through fills), the material itself Sven's screen.
        look.glass = false
        defer { (look.themeID, look.style, look.glass, look.transparency) = saved }
        let dir = try ExtensionSurfaceTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions"), storage = ExtensionSurfaceTests.storage(dir)
        try ExtensionSurfaceTests.write("weather", title: "Weather", in: exts)
        let blocks = Self.lineWeather
        let item = ExtensionBar.Item(id: "weather", title: "Weather", icon: "🌤️", hasPage: true, answer: nil, problem: nil)
        let detail = Extension.Detail(markdown: "# Valletta\n\n27 °C and partly cloudy. Feels like 29 °C. Wind 14 km/h from the north-west; 4 % chance of rain this afternoon.\n\nTomorrow: 26 °C, sunny.",
                                      metadata: [.init(label: "Feels", text: "29 °C"), .init(label: "Wind", text: "14 km/h NW"), .init(label: "Humidity", text: "68 %")],
                                      actions: [])
        for (theme, shade) in [("lagoon", "dark"), ("porcelain", "light")] {
            (look.themeID, look.style) = (theme, .instrument)
            let tokens = StyleTokens.of(.instrument, theme: look.theme)
            let model = ExtensionPopoverModel(id: "weather", folder: exts, storage: storage, run: { _, _, _ in .blocks(blocks) })
            await model.open()
            try writeRender(ExtensionPopoverView(item: item, model: model).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                .background(Color(tokens.colors.canvas)), to: out.appendingPathComponent("popover-\(shade).png"), wait: 0.6)
            let page = ExtensionPageModel(id: "weather", folder: exts, storage: storage, run: { _, _ in .blocks(blocks) })
            await page.refresh()
            try writeRender(SurfaceGround { ExtensionSurfacePage(id: "weather", onScreen: false, model: page) { _ in }.frame(width: 900, height: 620) }
                .styled(.page(.extensions), look: look).pilotTheme(look: look), to: out.appendingPathComponent("page-\(shade).png"), wait: 0.6)
            try writeRender(ExtensionDetailView(detail: detail).frame(width: 640, height: 300).background(Color(tokens.colors.panel))
                .pilotTheme(look: look), to: out.appendingPathComponent("detail-\(shade).png"), wait: 0.5)
            // AI usage's popover: a provider's section with its stats and meters, on hairlines.
            let usage: [Extension.Block] = [.section(title: "Codex", subtitle: nil, aside: "sven@", asideNote: "Pro", blocks: Array(Self.blocks.prefix(3)))]
            let sectioned = ExtensionPopoverModel(id: "weather", folder: exts, storage: storage, run: { _, _, _ in .blocks(usage) })
            await sectioned.open()
            try writeRender(ExtensionPopoverView(item: item, model: sectioned).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                .background(Color(tokens.colors.canvas)), to: out.appendingPathComponent("section-\(shade).png"), wait: 0.6)
            (look.glass, look.transparency) = (true, 100)
            try writeRender(ExtensionPopoverView(item: item, model: model).styled(.barPopovers, look: look).pilotTheme(look: look).padding(24)
                .background(Color(tokens.colors.canvas)), to: out.appendingPathComponent("glass-popover-\(shade).png"), wait: 0.6)
            try writeRender(ExtensionDetailView(detail: detail).frame(width: 640, height: 300).background(Color(tokens.colors.panel))
                .pilotTheme(look: look), to: out.appendingPathComponent("glass-detail-\(shade).png"), wait: 0.5)
            look.glass = false
        }
    }
}

struct SurfaceGround<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}
#endif
