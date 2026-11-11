#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Instrument's top bar (card agent-bo-95423181) beside mockup A's (pilot-redesign-A/topbar-dark.png, topbar-light.png
/// and the 4x crops): the strip at the mockup's 1600 by 32 and at Sven's 1440 by 30, dark and light; a break and the
/// workspaces' icons style; the tooltip. Seeded with
/// fakes in a moved home: workspaces 1 to 3 on this display and 4 on another, Finder in front with its window's title,
/// Stats' readings, a focus timer at 18:42, Wi-Fi (nothing reaches the tiler, the timer or Wi-Fi):
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-ib PILOT_RENDER_DIR=/tmp/pilot-renders-ib swift test --filter InstrumentTopBarRenders`
extension SharedLook {
@MainActor
@Suite("Instrument top bar renders")
struct InstrumentTopBarRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let screen = "Studio"

    /// T7 uses the actual strip/parts/editor with isolated local stores; no global readers, live sources or windows.
    static func renderFloating(style: PilotStyle, islands: Bool = false) throws {
        let dir = try ClockRenders.dir(islands ? "three-islands" : "floating-strip")
        testApp()
        let oldFonts = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = oldFonts }
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.strip-render-" + style.rawValue)
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(true, forKey: BarItemsStore.extensionsApartKey)
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        try store.choosePreset(islands ? "threeIslands" : "floatingStrip")
        let look = Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), inputSources: BarReadingsTests.Sources(), defaults: defaults)
        look.style = style
        var input = BarInputs()
        input.pilotTitle = "2"; input.workspaces = ["1", "2", "3"]; input.focusedWorkspace = "2"
        input.focusedApp = "Finder"; input.volume = 0.6; input.muted = false; input.wifiOn = true
        input.timerCountdown = "18:42"; input.timerTitle = "Focus"; input.keyboardLayout = "ABC"
        input.now = ClockRenders.now; input.timeZone = TimeZone(secondsFromGMT: 0)!; input.locale = Locale(identifier: "en_US_POSIX")
        for kind in [BarKind.focusedApp, .volume, .wifi, .keyboardLayout] { store.settings.set(kind, on: true) }
        for kind in [BarKind.otherApps, .modes, .group, .cpu, .memory, .network] { store.settings.set(kind, on: false) }
        if islands { store.settings.place(.kind(.clock), on: .centre, at: 0) }
        let sides = store.settings.preview(.topBar).top ?? [:]
        for (mode, id) in [("dark", style == .toybox ? "toybox-night" : "lagoon"), ("light", style == .toybox ? "toybox" : "porcelain")] {
            look.preview(id)
            let tokens = StyleTokens.of(style, theme: look.theme)
            let config = try #require(store.settings.preset)
            var effective: StyleTokens?
            var effectiveDark: Bool?
            var groupFrames: [String: [TopBarSide: CGRect]] = [:]
            let image = dir.appendingPathComponent("\(islands ? "islands" : "strip")-\(style.rawValue)-\(mode).png")
            let variants: [(String, [TopBarSide: [BarSlot]])] = islands ? [
                ("Full centre", sides), ("Empty centre", sides.filter { $0.key != .centre }), ("All empty", [:])
            ] : [("Floating strip", sides)]
            try writeRender(VStack(alignment: .leading, spacing: 12) {
                Text("\(style.rawValue) · \(mode) · \(config.preset.title)").font(.headline)
                ForEach(variants, id: \.0) { title, items in
                    Text(title).font(.caption)
                    ForEach([1416, 336], id: \.self) { width in
                        TopBarStrip(sides: items, configuration: config, reportIsland: { side, rect in
                            groupFrames[title + String(width), default: [:]][side] = rect
                        }) { slot in
                            if let parts = BarParts.parts(slot, input, settings: store.settings) {
                                BarPartsView(items: parts).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 6)
                            }
                        }
                        .overlay { EffectiveTokens { effective = $0; effectiveDark = $1 == .dark } }.styled(.topBar, look: look)
                        .foregroundStyle(Color(tokens.colors.text)).tint(Color(tokens.colors.accent))
                        .frame(width: CGFloat(width), height: config.height).clipped()
                    }
                }
                BarPresetControls(store: store).frame(width: 620)
            }.padding(12).frame(width: 1440, height: islands ? 950 : 650, alignment: .topLeading)
                .style(tokens).font(.system(size: 13)).foregroundStyle(Color(tokens.colors.text)).tint(Color(tokens.colors.accent))
                .background(Color(tokens.colors.canvas)), to: image, wait: 0.4)
            let hosted = try #require(effective)
            try #require(look.theme.dark == (mode == "dark")); try #require(hosted.kind == style && hosted.dark == (mode == "dark") && effectiveDark == (mode == "dark"))
            if islands {
                for width in [1416, 336] {
                    let empty = try #require(groupFrames["All empty" + String(width)])
                    try #require(empty.count == 3 && empty.values.allSatisfy { $0.width == 0 && $0.height == 0 })
                    let two = try #require(groupFrames["Empty centre" + String(width)])
                    try #require(two[.centre]?.width == 0)
                    try #require(groupFrames["Full centre" + String(width)]?[.centre]?.width ?? 0 > 0)
                }
            }
            let record: JSONValue = .object(["style": .string(hosted.kind.rawValue), "theme": .string(look.theme.id), "dark": .bool(hosted.dark),
                "geometry": try JSONDecoder().decode(JSONValue.self, from: ThemeDigest.encoded(config)), "ground": .string(ColourAnswer.hex(hosted.colors.canvas.rgb)),
                "foreground": .string(ColourAnswer.hex(hosted.colors.text.rgb)), "widths": .array([.number(1416), .number(336)]),
                "variants": .array(variants.map { .string($0.0) }), "hostedEnvironmentRead": .bool(true), "effectiveColorSchemeDark": .bool(effectiveDark == true),
                "drawnGroups": .object(groupFrames.mapValues { .object(Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, .array([$0.value.minX,$0.value.minY,$0.value.width,$0.value.height].map { .number(Double($0)) })) })) })])
            try ThemeDigest.encoded(record).write(to: image.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    private struct EffectiveTokens: View {
        @Environment(\.style) private var style
        @Environment(\.colorScheme) private var scheme
        let record: (StyleTokens, ColorScheme) -> Void
        var body: some View { Color.clear.allowsHitTesting(false).onAppear { record(style, scheme) } }
    }

    /// The mockup's bar: Pilot's mark, the workspaces and the app in front on the left, the timer in the centre, the
    /// readings' group, sound, Wi-Fi, the layout and the clock on the right.
    static func sides(workspaces: BarStyle = .numbers) -> [TopBarSide: [BarSlot]] {
        var s = BarSettings.defaults
        func item(_ kind: BarKind, _ style: BarStyle) -> BarSlot {
            s.set(kind, style: style)
            return .item(s.entry(kind))
        }
        let readings = [BarKind.cpu, .memory, .network].map { kind in s.set(kind, style: .text); return s.entry(kind) }
        return [.left: [item(.pilot, .icon), item(.workspaces, workspaces), item(.focusedApp, .iconName)],
                .centre: [item(.timer, .countdown), item(.terminal, .iconName), item(.askAI, .iconName)],
                .right: [.group(readings), item(.volume, .iconPercent), item(.wifi, .icon), item(.keyboardLayout, .code), item(.clock, .dateTime)]]
    }

    /// Workspaces 1 to 3 on the studio display (monitor 1), 4 on the portrait one (monitor 2).
    static let windows = HomeRenders.windows.replacingOccurrences(of: "\"workspace\": \"4\", \"monitor-id\": 1", with: "\"workspace\": \"4\", \"monitor-id\": 2")
    static let monitors = """
    [{"monitor-id": 1, "monitor-name": "Studio", "workspace": "2"}, {"monitor-id": 2, "monitor-name": "Portrait", "workspace": "4"}]
    """

    struct Bar: View {
        let sides: [TopBarSide: [BarSlot]]
        let sources: BarSources
        let look: Look
        /// The bar drops' items unlit, or lit as their drops hang open (spec Bar drops T4).
        var lights = BarDropLights()
        /// A dictation take in the bar, at its position.
        var take: DictationOverlay? = nil
        /// What the bar adds at its right end, as a recording's control (TopBarView's `trailing`).
        var trailing: AnyView? = nil

        var body: some View {
            TopBarStrip(sides: sides, trailing: trailing, live: take.map { AnyView(DictationBarItem(overlay: $0)) }, liveSide: take?.setup.barSide ?? .left) { TopBarSlot(slot: $0, screen: InstrumentTopBarRenders.screen, sources: sources, store: .shared, lights: lights) }
                .styled(.topBar, look: look).pilotTheme(look: look)
        }
    }

    @Test("The strip, its tooltip and edit mode in Instrument dark and light", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        if Self.env["PILOT_ISLANDS_RENDER"] == "1" { try Self.renderFloating(style: .instrument, islands: true); return }
        if Self.env["PILOT_STRIP_RENDER"] == "1" { try Self.renderFloating(style: .instrument); return }
        let dir = try ClockRenders.dir("topbar-instrument")
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        let look = Look.shared
        let (style, glass) = (look.style, look.glass)
        look.glass = false
        defer { (look.style, look.glass) = (style, glass) }

        StatsRenders.seed(SystemSampler.shared)
        let clock = HomeRenders.Clock(), start = clock.now
        let timer = ExtensionTimer(now: { clock.now })
        timer.startFocus()
        clock.now = start.addingTimeInterval(25 * 60 - (18 * 60 + 42))
        timer.tick()
        defer { timer.stop() }
        let observers = EngineObservers()
        let windows = try AeroWindow.parse(Self.windows)
        observers.tiler.seed(focused: "2", occupied: OccupiedWorkspace.list(windows), windows: windows, perMonitor: try AeroMonitorWorkspace.parse(Self.monitors))
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            observers.seed(focusedApp: finder, windowTitle: "Downloads")
        }
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: BarReadingsTests.Sources()),
                                   readBattery: { nil }, readWiFi: { WiFiStatus(on: true, network: nil, signal: -55, rate: 573) }, clock: { ClockRenders.now },
                                   watchStats: { _ in Task {} }, calendar: ClockCalendar { ClockPopoverTests.FakeStore() })
        let sources = BarSources(readings: readings, observers: observers, sampler: .shared, keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: timer, pilotTitle: { "2" })
        let sides = Self.sides()
        var held: Set<BarKind> = []
        readings.hold(Set(sides.values.joined().flatMap(\.kinds)), replacing: &held)
        defer { readings.hold([], replacing: &held) }

        let variants = [("dark", true), ("light", false)]
        for (name, isDark) in variants {
            look.style = .instrument
            try writeRender(Bar(sides: sides, sources: sources, look: look).frame(width: 1600, height: 32), to: dir.appendingPathComponent("bar-\(name)-1600.png"), wait: 0.8)
            try writeRender(Bar(sides: sides, sources: sources, look: look).frame(width: 1440, height: 30), to: dir.appendingPathComponent("bar-\(name)-1440.png"), wait: 0.8)
            // The terminal's drop open: its item lit, Ask AI's not.
            try writeRender(Bar(sides: sides, sources: sources, look: look, lights: BarDropLights(open: [.terminal])).frame(width: 1440, height: 30),
                            to: dir.appendingPathComponent("bar-\(name)-1440-terminal-lit.png"), wait: 0.8)
            try writeRender(BarTooltipView(text: "Workspace 2: Telegram, Zen").styled(.topBar, look: look).pilotTheme(look: look).padding(24)
                .background(Color(StyleTokens.of(.instrument, theme: look.theme).colors.canvas)),
                            to: dir.appendingPathComponent("tooltip-\(name).png"), wait: 0.5)
        }
        // Dictation's take at each position in the top bar, the words at the centre; at 1100 the words fold away.
        look.style = .instrument
        for side in TopBarSide.allCases {
            try writeRender(Bar(sides: sides, sources: sources, look: look, take: DictationOverlayRenders.barTake(side)).frame(width: 1440, height: 30),
                            to: dir.appendingPathComponent("bar-dark-1440-dictation-\(side.rawValue).png"), wait: 0.8)
        }
        let words = DictationOverlayRenders.barTake(.centre, words: DictationOverlayTests.long)
        try writeRender(Bar(sides: sides, sources: sources, look: look, take: words).frame(width: 1440, height: 30),
                        to: dir.appendingPathComponent("bar-dark-1440-dictation-centre-words.png"), wait: 0.8)
        try writeRender(Bar(sides: sides, sources: sources, look: look, take: words).frame(width: 1100, height: 30),
                        to: dir.appendingPathComponent("bar-dark-1100-dictation-centre-words.png"), wait: 0.8)
        // A paused timer, and the workspaces' icons style.
        timer.startFocus(paused: true)
        look.style = .instrument
        try writeRender(Bar(sides: Self.sides(workspaces: .icons), sources: sources, look: look).frame(width: 1600, height: 32),
                        to: dir.appendingPathComponent("bar-dark-1600-paused-icons.png"), wait: 0.8)
        timer.startFocus()

    }
}
}
#endif
