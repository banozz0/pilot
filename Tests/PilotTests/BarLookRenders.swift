#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The bar look round's picks as built (Sven, 2026-11-12: Q170 B, Q171 C, Q176, Q177, Q178, and the presets' new
/// sizes), 3440 wide (an ultrawide's whole width), Instrument on Garnet (dark) and Porcelain (light), all drawn by the
/// real strip (TopBarStrip, TopBarRow), parts and pill faces:
/// - each preset's sizes as they were above its new defaults, one picture each (Full bar, Floating strip, Three islands,
///   Pills);
/// - the pill-first bar: the full bar with the pill as its notch on each page and live, then its rail drop open on
///   Media, Stats and Calendar;
/// - Pills with one pill per item and with the readings in the Group's pill.
/// The bar holds a fixture of a working bar: Pilot and the workspaces left; Ask AI, Terminal, the clock, Capture and
/// Power in the centre; the readings as one group, Keep awake, sound, displays and the layout right. Opt-in, in a moved
/// home: `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter BarLookRenders`
extension SharedLook {
@MainActor
@Suite("Bar look renders")
struct BarLookRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let width: CGFloat = 3440
    /// The menu bar strip on a screen without a notch; the Full bar is now taller (TopBarGeometry.fullBar).
    static let strip: Double = 30

    @Test("The presets' sizes before and after, the pill-first notch and rail, and Pills, dark and light, 3440 wide",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch real data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.bar-look-render")
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(true, forKey: BarItemsStore.extensionsApartKey)
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        var settings = store.settings
        let sides = Self.working(&settings)
        store.settings = settings
        // The pill-first bar's sides, as PillFirst draws them.
        let pillSides: [TopBarSide: [BarSlot]] = [.left: [.item(settings.entry(.pilot)), .item(settings.entry(.workspaces))],
                                                  .centre: [.item(settings.entry(.pill))],
                                                  .right: [.item(settings.entry(.modes)), .item(settings.entry(.clock))]]

        let look = Look.shared
        let was = (look.style, look.themeID, look.glass)
        look.glass = false
        look.style = .instrument
        defer { (look.style, look.themeID, look.glass) = was }
        let walls = DesktopControlsRenders.walls()
        StatsRenders.seed(SystemSampler.shared)
        let input = Self.inputs()
        let sources = Self.sources()
        let pill = PillFirstRenders.values(walls)

        for mode in ["dark", "light"] {
            let dark = mode == "dark"
            look.themeID = dark ? "garnet" : "porcelain"
            let tokens = StyleTokens.of(.instrument, theme: look.theme)
            let dir = try ClockRenders.dir("bar-look-\(mode)")
            let draw = Draw(input: input, settings: settings, sources: sources, store: store, look: look, wall: walls[dark ? 0 : min(5, walls.count - 1)], tokens: tokens)

            // Each preset's sizes: as they were, then the new defaults.
            let full = TopBarGeometry.fullBar(Self.strip)
            try shot(draw.compare("Full bar", [("Before · \(Int(Self.strip)) pt", draw.bar(sides, config: nil, height: Self.strip)),
                                              ("Now · \(Int(full)) pt", draw.bar(sides, config: nil, height: full))]), dir, "sizes-full-bar")
            try shot(draw.compare("Floating strip", [("Before · 36 tall, 8 from the top, margins 12", draw.bar(sides, config: BarPresetConfiguration.firstDefaults)),
                                                    ("Now · 30 tall, 6 from the top, margins 10", draw.bar(sides, config: BarPreset.floatingStrip.configuration))]), dir, "sizes-floating-strip")
            try shot(draw.compare("Three islands", [("Unchanged · 36 tall, 8 from the top, margins 12", draw.bar(sides, config: BarPreset.threeIslands.configuration))]), dir, "sizes-three-islands")
            try shot(draw.compare("Pills", [("New · pills 28 tall, 6 apart, 6 from the top", draw.pills(grouped: false)),
                                           ("The readings in the Group's pill", draw.pills(grouped: true))]), dir, "pills")

            // The pill-first bar: the full bar, the pill its notch, on each page's face and live, then open.
            var faces: [(String, PillValues, Bool)] = []
            for (i, tab) in pill.tabs.enumerated() where i < 3 {
                var values = pill
                values.tab = i
                values.page = tab.page
                faces.append((tab.title, values, false))
            }
            var timer = pill
            timer.live = pill.running[1]
            var recording = pill
            recording.live = pill.running[0]
            faces += [("Live · a focus timer", timer, false), ("Live · a recording", recording, false), ("Open", pill, true)]
            try shot(draw.compare("Pill first", faces.map { ($0.0, draw.notchBar(pillSides, values: $0.1, open: $0.2)) }), dir, "pill-first")
            for page in [0, 2, 1] {
                var values = pill
                values.tab = page
                values.page = pill.tabs[page].page
                try shot(draw.opened(pillSides, values: values), dir, "pill-first-open-\(pill.tabs[page].title.lowercased())")
            }
        }

        func shot(_ view: some View, _ dir: URL, _ name: String) throws {
            try writeRender(view, to: dir.appendingPathComponent("\(name).png"), wait: 0.4)
        }
    }

    // MARK: Fixture

    /// A working bar: Pilot and the workspaces left; Ask AI, Terminal (glyphs, Q176), the clock, Capture and Power in the
    /// centre; the readings as one group, Keep awake, sound, displays and the layout right. No pill: it lives on Pill first.
    static func working(_ s: inout BarSettings) -> [TopBarSide: [BarSlot]] {
        func item(_ kind: BarKind, _ style: BarStyle?) -> BarSlot {
            s.set(kind, on: true)
            if let style { s.set(kind, style: style) }
            return .item(s.entry(kind))
        }
        let readings = [BarKind.cpu, .memory, .heat, .storage].map { kind in
            s.set(kind, on: true); s.set(kind, style: .text); return s.entry(kind)
        }
        return [.left: [item(.pilot, .icon), item(.workspaces, .numbers)],
                .centre: [item(.askAI, nil), item(.terminal, nil), item(.clock, .dateTime), item(.capture, .icon), item(.power, .icon)],
                .right: [.group(readings), item(.keepAwake, .icon), item(.volume, .icon), item(.displays, .icon), item(.keyboardLayout, .code)]]
    }

    /// The bar's readings: workspaces 1, 2 and 4 with 1 in front, Thursday 12 November 15:25, the seeded Stats.
    static func inputs() -> BarInputs {
        var i = BarInputs()
        i.pilotTitle = "1"; i.workspaces = ["1", "2", "4"]; i.focusedWorkspace = "1"
        i.focusedApp = "Ghostty"; i.volume = 0.62; i.muted = false; i.wifiOn = true; i.keyboardLayout = "BR"
        i.now = Date(timeIntervalSince1970: 1_794_497_100)   // 2026-11-12 15:25 UTC
        i.timeZone = TimeZone(secondsFromGMT: 0)!; i.locale = Locale(identifier: "en_US_POSIX")
        i.latest = SystemSampler.shared.latest; i.values = SystemSampler.shared.latestValues; i.history = SystemSampler.shared.history
        return i
    }

    /// Sources for the drop items' own view (TopBarDropItem): fakes, nothing read from this Mac.
    static func sources() -> BarSources {
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   readBattery: { nil }, readWiFi: { nil }, clock: { Date(timeIntervalSince1970: 1_794_497_100) },
                                   watchStats: { _ in Task {} }, calendar: ClockCalendar { ClockPopoverTests.FakeStore() })
        return BarSources(readings: readings, observers: EngineObservers(), sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                          timer: ExtensionTimer(), pilotTitle: { "1" })
    }

    @MainActor
    struct Draw {
        let input: BarInputs
        let settings: BarSettings
        let sources: BarSources
        let store: BarItemsStore
        let look: Look
        let wall: NSImage
        let tokens: StyleTokens

        /// One slot as the bar draws it: the pill by `pill`, a drop's item by its own view, the rest by its parts.
        @ViewBuilder func slot(_ slot: BarSlot, settings: BarSettings, pill: () -> AnyView) -> some View {
            if slot.kind == .pill {
                pill()
            } else if case .item(let entry) = slot, entry.kind.drop != nil {
                TopBarDropItem(entry: entry, sources: sources, store: store, lights: BarDropLights())
            } else if let parts = BarParts.parts(slot, input, settings: settings) {
                BarPartsView(items: parts).fixedSize(horizontal: true, vertical: false).padding(.horizontal, BarMetrics.inset).frame(maxHeight: .infinity)
            }
        }

        /// A bar on the wallpaper where its window puts it: a preset's at its margins, the full bar edge to edge.
        func bar(_ sides: [TopBarSide: [BarSlot]], config: BarPresetConfiguration?, height: Double = BarLookRenders.strip, settings: BarSettings? = nil,
                 background: TopBarBackground = .solid, pill: @escaping () -> AnyView = { AnyView(EmptyView()) }, below: CGFloat = 10) -> AnyView {
            let s = settings ?? self.settings
            let side = CGFloat(config?.horizontalMargin ?? 0), top = CGFloat(config?.topMargin ?? 0), h = CGFloat(config?.height ?? height)
            let strip = TopBarStrip(sides: sides, configuration: config, background: background) { self.slot($0, settings: s, pill: pill) }
                .styled(.topBar, look: look)
                .frame(width: BarLookRenders.width - 2 * side, height: h)
                .padding(.horizontal, side).padding(.top, top).padding(.bottom, below)
                .frame(width: BarLookRenders.width, alignment: .topLeading)
                .background { DesktopControlsRenders.Wallpaper(image: wall) }
                .clipped()   // the wallpaper fills past the row, over the rows above it
            return AnyView(strip)
        }

        /// Captioned bars, one under another.
        func compare(_ title: String, _ rows: [(String, AnyView)]) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row.0).font(.system(size: 12))
                    row.1
                }
            }
            .padding(14)
            .frame(width: BarLookRenders.width + 28, alignment: .leading)
            .style(tokens).foregroundStyle(Color(tokens.colors.text)).background(Color(tokens.colors.canvas))
        }

        /// Pills: one pill per item, or the readings in the Group's one pill.
        func pills(grouped: Bool) -> AnyView {
            var s = settings
            func item(_ kind: BarKind, _ style: BarStyle) -> BarSlot {
                s.set(kind, on: true); s.set(kind, style: style); return .item(s.entry(kind))
            }
            let readings = [BarKind.cpu, .memory, .heat].map { kind in s.set(kind, style: .text); return s.entry(kind) }
            let right: [BarSlot] = (grouped ? [.group(readings)] : readings.map { .item($0) })
                + [item(.volume, .iconPercent), item(.wifi, .icon), item(.keepAwake, .icon), item(.power, .icon)]
            let sides: [TopBarSide: [BarSlot]] = [.left: [item(.clock, .dateTime), item(.workspaces, .numbers), item(.focusedApp, .iconName)],
                                                  .centre: [item(.askAI, .icon), item(.terminal, .icon), item(.capture, .icon)],
                                                  .right: right]
            return bar(sides, config: BarPreset.pills.configuration, settings: s)
        }

        /// The pill-first bar: the full bar, the pill its notch.
        func notchBar(_ sides: [TopBarSide: [BarSlot]], values: PillValues, open: Bool) -> AnyView {
            bar(sides, config: nil, height: TopBarGeometry.fullBar(BarLookRenders.strip), pill: { AnyView(PillCompactFace(values: values, open: open, notch: true)) })
        }

        /// The pill-first bar open: the notch widened over its rail drop, which hangs from the bar's foot.
        func opened(_ sides: [TopBarSide: [BarSlot]], values: PillValues) -> some View {
            let top = CGFloat(TopBarGeometry.fullBar(BarLookRenders.strip)) - 1
            return ZStack(alignment: .top) {
                notchBar(sides, values: values, open: true)
                PillDropFace(values: values, rail: true).modifier(PillNotched()).styled(.barPopovers, look: look).padding(.top, top)
            }
            .frame(width: BarLookRenders.width, height: top + 320, alignment: .top)
            .background { DesktopControlsRenders.Wallpaper(image: wall) }
            .clipped()
        }
    }
}
}
#endif
