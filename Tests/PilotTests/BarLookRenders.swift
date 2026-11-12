#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The bar look round (a design round on branch bar-look-round, after Sven on test build 2393: "all topbars need to look
/// better", the pill-first bar most): today's bars beside the proposals, 3440 wide (an ultrawide's whole width), in
/// Instrument on Garnet (dark) and Porcelain (light), Toybox on its own two. Today is drawn by the real strip
/// (TopBarStrip, TopBarRow), its real parts and drop items, on a Three islands bar holding a fixture of a working bar:
/// Pilot and the workspaces left; the pill, Ask AI, Terminal, the clock, Capture and Power in the centre; the readings,
/// Keep awake, sound, displays and the layout right. The proposals change only what the kit already exposes (each preset's
/// geometry, the bar's type roles through StyleTokens.retyped, its tokens' quiet text, the items' styles), and draw the
/// pill's faces and drops as this file's own views from the kit's pieces: those are proposals until one is picked and built.
/// Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter BarLookRenders`
extension SharedLook {
@MainActor
@Suite("Bar look renders")
struct BarLookRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let width: CGFloat = 3440
    /// The legacy strip's height on a screen without a notch.
    static let strip: CGFloat = 30

    @Test("Today's bars and the proposals, dark and light, 3440 wide",
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
        let pillSides: [TopBarSide: [BarSlot]] = [.left: [.item(settings.entry(.pilot)), .item(settings.entry(.workspaces))],
                                                  .centre: [.item(settings.entry(.pill))],
                                                  .right: [.item(settings.entry(.modes)), .item(settings.entry(.clock))]]

        let look = Look.shared
        let was = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = was }
        let walls = DesktopControlsRenders.walls()
        StatsRenders.seed(SystemSampler.shared)
        let input = Self.inputs()
        let sources = Self.sources()
        let pill = PillFirstRenders.values(walls)

        for mode in ["dark", "light"] {
            let dark = mode == "dark"
            let wall = walls[dark ? 0 : min(5, walls.count - 1)]
            let dir = try ClockRenders.dir("bar-look-\(mode)")

            // Instrument: the four sets on Garnet or Porcelain.
            look.style = .instrument
            look.themeID = dark ? "garnet" : "porcelain"
            let tokens = StyleTokens.of(.instrument, theme: look.theme)
            let tight = Self.tightened(tokens)
            let draw = Draw(input: input, settings: settings, sources: sources, store: store, look: look, wall: wall)
            // The bar's quiet words against its ground, today (text3) and tightened (text2), for the page's checks.
            let ratios: JSONValue = .object(["theme": .string(look.theme.id),
                "text3": .number(Contrast.ratio(tokens.colors.canvas.rgb, tokens.colors.text3.rgb)),
                "text2": .number(Contrast.ratio(tokens.colors.canvas.rgb, tokens.colors.text2.rgb)),
                "text": .number(Contrast.ratio(tokens.colors.canvas.rgb, tokens.colors.text.rgb))])
            try ThemeDigest.encoded(ratios).write(to: dir.appendingPathComponent("contrast.json"))

            // Pill first, collapsed: today on Sven's Three islands, then A, B and C; each on its pages' faces and live.
            var states: [(String, PillValues, Bool)] = []
            for (i, tab) in pill.tabs.enumerated() where [0, 1, 2].contains(i) {
                var values = pill
                values.tab = i
                values.page = tab.page
                states.append((tab.title.lowercased(), values, false))
            }
            var timer = pill
            timer.live = pill.running[1]
            states.append(("live", timer, false))
            states.append(("open", pill, true))
            for variant in PillVariant.allCases {
                for (state, values, open) in states {
                    let view = draw.pillBar(variant, sides: pillSides, values: values, open: open, today: tokens, tight: tight)
                    try writeRender(view, to: dir.appendingPathComponent("pill-\(variant.rawValue)-\(state).png"), wait: 0.4)
                }
                // Opened on Media, Stats and Calendar.
                for page in [0, 2, 1] {
                    var values = pill
                    values.tab = page
                    values.page = pill.tabs[page].page
                    let view = draw.opened(variant, sides: pillSides, values: values, today: tokens, tight: tight)
                    try writeRender(view, to: dir.appendingPathComponent("open-\(variant.rawValue)-\(pill.tabs[page].title.lowercased()).png"), wait: 0.4)
                }
            }

            // The other presets: today, then the tightened pass.
            for preset in Preset.allCases where preset != .toybox {
                for proposed in [false, true] {
                    let view = draw.preset(preset, sides: sides, proposed: proposed, today: tokens, tight: tight)
                    try writeRender(view, to: dir.appendingPathComponent("\(preset.rawValue)-\(proposed ? "proposed" : "today").png"), wait: 0.4)
                }
            }

            // Toybox on its own pair.
            look.style = .toybox
            look.themeID = dark ? "toybox-night" : "toybox"
            let toy = StyleTokens.of(.toybox, theme: look.theme)
            let toyDraw = Draw(input: input, settings: settings, sources: sources, store: store, look: look, wall: wall)
            for proposed in [false, true] {
                let view = toyDraw.preset(.toybox, sides: sides, proposed: proposed, today: toy, tight: toy)
                try writeRender(view, to: dir.appendingPathComponent("toybox-\(proposed ? "proposed" : "today").png"), wait: 0.4)
            }
        }
    }

    // MARK: Fixture

    /// A working bar as Three islands holds it: Pilot and the workspaces left; the pill, Ask AI, Terminal, the clock,
    /// Capture and Power in the centre; the readings as one group, Keep awake, sound, displays and the layout right.
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
                .centre: [item(.pill, nil), item(.askAI, .iconName), item(.terminal, .iconName), item(.clock, .dateTime), item(.capture, .icon), item(.power, .icon)],
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

    /// The tightened pass's tokens: the bar's small capitals a step bigger with less tracking, its glyphs a half step up,
    /// its quiet words in the second text colour (the third measured 3.4 to 4.5:1 on Instrument's grounds, DESIGN.md).
    static func tightened(_ t: StyleTokens) -> StyleTokens {
        var type = t.type
        type.barLabel.size = 10.5; type.barLabel.tracking = 0.03
        type.barIcon.size = 13
        type.barStrong.size = 12.5
        type.barTime.size = 12.5
        var colors = t.colors
        colors.text3 = colors.text2
        var tokens = StyleTokens(kind: t.kind, dark: t.dark, colors: colors, type: type, radii: t.radii, depth: t.depth, density: t.density)
        tokens.scale = t.scale
        return tokens
    }

    // MARK: Sets

    enum PillVariant: String, CaseIterable { case today, a, b, c }
    enum Preset: String, CaseIterable { case strip, floating, islands, toybox }

    @MainActor
    struct Draw {
        let input: BarInputs
        let settings: BarSettings
        let sources: BarSources
        let store: BarItemsStore
        let look: Look
        let wall: NSImage

        /// Three islands as it ships, and the round's tightened islands: one radius, the bar's height less the gaps.
        static let islandsToday = BarPreset.threeIslands.configuration
        static var islandsTight: BarPresetConfiguration {
            var c = BarPreset.threeIslands.configuration
            (c.height, c.horizontalMargin, c.topMargin, c.spacing, c.padding, c.radius, c.border) = (30, 8, 6, 0, 6, 9, 1)
            return c
        }
        static var floatingTight: BarPresetConfiguration {
            var c = BarPreset.floatingStrip.configuration
            (c.height, c.horizontalMargin, c.topMargin, c.spacing, c.padding, c.radius, c.border) = (30, 8, 6, 0, 6, 9, 1)
            return c
        }

        /// Toybox's proposal: neighbours that are only glyphs share one island, led by the first (needs a source change:
        /// ToyIsland wraps each slot alone today).
        var merged: [BarKind: [BarKind]] = [:]

        /// One slot as the bar draws it: the pill by `pill`, a drop's item by its own view, the rest by its parts.
        @ViewBuilder func slot(_ slot: BarSlot, pill: () -> AnyView) -> some View {
            if let members = merged[slot.kind] {
                HStack(spacing: 12) {
                    ForEach(members, id: \.self) { kind in
                        if let parts = BarParts.parts(.item(settings.entry(kind)), input, settings: settings) { BarPartsView(items: parts).fixedSize() }
                    }
                }
                .padding(.horizontal, BarMetrics.inset).frame(maxHeight: .infinity).toyIsland(slot.kind)
            } else if merged.values.contains(where: { $0.dropFirst().contains(slot.kind) }) {
                EmptyView()
            } else if slot.kind == .pill {
                pill().toyIsland(.pill)
            } else if case .item(let entry) = slot, entry.kind.drop != nil {
                TopBarDropItem(entry: entry, sources: sources, store: store, lights: BarDropLights())
            } else if let parts = BarParts.parts(slot, input, settings: settings) {
                BarPartsView(items: parts).fixedSize(horizontal: true, vertical: false).padding(.horizontal, BarMetrics.inset)
                    .frame(maxHeight: .infinity).toyIsland(slot.kind)
            }
        }

        /// A bar on the wallpaper, where its window puts it: a preset's at its margins, the legacy strip edge to edge.
        func onWall(_ strip: some View, config: BarPresetConfiguration?, tokens: StyleTokens, below: CGFloat = 14) -> some View {
            let side = CGFloat(config?.horizontalMargin ?? 0), top = CGFloat(config?.topMargin ?? 0), h = CGFloat(config?.height ?? Double(BarLookRenders.strip))
            return strip.style(tokens).frame(width: BarLookRenders.width - 2 * side, height: h)
                .padding(.horizontal, side).padding(.top, top).padding(.bottom, below)
                .frame(width: BarLookRenders.width, alignment: .topLeading)
                .background { DesktopControlsRenders.Wallpaper(image: wall) }
                .font(.system(size: 13)).foregroundStyle(Color(tokens.colors.text))
        }

        func strip(_ sides: [TopBarSide: [BarSlot]], config: BarPresetConfiguration?, tokens: StyleTokens, itemColours: Bool = false,
                   pill: @escaping () -> AnyView = { AnyView(EmptyView()) }) -> some View {
            // The round's tokens inside the bar's own surface, so they reach every slot.
            TopBarStrip(sides: sides, configuration: config, itemColours: itemColours) { self.slot($0, pill: pill) }
                .style(tokens).styled(.topBar, look: look)
        }

        // MARK: The presets

        func preset(_ preset: Preset, sides: [TopBarSide: [BarSlot]], proposed: Bool, today: StyleTokens, tight: StyleTokens) -> some View {
            let tokens = proposed ? tight : today
            let pillFace = { AnyView(PillCompactFace(values: PillFirstRenders.values([self.wall]))) }
            // Proposed: Ask AI and Terminal as their glyphs, each drop's word gone from a crowded centre.
            var s = settings
            var shown = sides
            if proposed {
                for kind in [BarKind.askAI, .terminal] { s.set(kind, style: .icon) }
                shown = shown.mapValues { $0.map { slot in
                    if case .item(let e) = slot, e.kind == .askAI || e.kind == .terminal { return .item(s.entry(e.kind)) }
                    return slot
                } }
            }
            let config: BarPresetConfiguration? = switch preset {
            case .strip, .toybox: nil
            case .floating: proposed ? Self.floatingTight : BarPreset.floatingStrip.configuration
            case .islands: proposed ? Self.islandsTight : Self.islandsToday
            }
            var draw = Draw(input: input, settings: s, sources: sources, store: store, look: look, wall: wall)
            if proposed, preset == .toybox {
                draw.merged = [.askAI: [.askAI, .terminal], .capture: [.capture, .power], .keepAwake: [.keepAwake, .volume, .displays, .keyboardLayout]]
            }
            return onWall(draw.strip(shown, config: config, tokens: tokens, itemColours: preset == .islands, pill: pillFace), config: config, tokens: tokens)
        }

        // MARK: Pill first

        func pillBar(_ variant: PillVariant, sides: [TopBarSide: [BarSlot]], values: PillValues, open: Bool, today: StyleTokens, tight: StyleTokens) -> some View {
            switch variant {
            case .today:
                return AnyView(onWall(strip(sides, config: Self.islandsToday, tokens: today, itemColours: true) { AnyView(PillCompactFace(values: values, open: open)) },
                                      config: Self.islandsToday, tokens: today))
            case .a:
                return AnyView(onWall(strip(sides, config: Self.islandsTight, tokens: tight) { AnyView(IslandPill(values: values, open: open, padding: Self.islandsTight.padding)) },
                                      config: Self.islandsTight, tokens: tight))
            case .b:
                return AnyView(onWall(strip(sides, config: nil, tokens: tight) { AnyView(NotchPill(values: values, open: open)) },
                                      config: nil, tokens: tight, below: 14))
            case .c:
                return AnyView(onWall(strip(sides, config: Self.floatingTight, tokens: tight) { AnyView(QuietPill(values: values, open: open)) },
                                      config: Self.floatingTight, tokens: tight))
            }
        }

        func opened(_ variant: PillVariant, sides: [TopBarSide: [BarSlot]], values: PillValues, today: StyleTokens, tight: StyleTokens) -> some View {
            let config: BarPresetConfiguration? = switch variant {
            case .today: Self.islandsToday
            case .a: Self.islandsTight
            case .b: nil
            case .c: Self.floatingTight
            }
            let tokens = variant == .today ? today : tight
            let bar = pillBar(variant, sides: sides, values: values, open: true, today: today, tight: tight)
            let drop: AnyView = switch variant {
            case .today: AnyView(PillDropFace(values: values))
            case .a: AnyView(PagedDrop(values: values))
            case .b: AnyView(NotchDrop(values: values))
            case .c: AnyView(RailDrop(values: values))
            }
            // The drop hangs from the bar's foot (A leaves a gap under its island).
            // Over the bar's foot line by a point, as the real drop's gap in it does (BarFootGap).
            let top = CGFloat(config?.topMargin ?? 0) + CGFloat(config?.height ?? Double(BarLookRenders.strip)) + (variant == .a ? 6 : -1)
            return ZStack(alignment: .top) {
                bar
                drop.style(tokens).padding(.top, top)
            }
            .frame(width: BarLookRenders.width, height: top + 380, alignment: .top)
            .background { DesktopControlsRenders.Wallpaper(image: wall) }
            .clipped()
        }
    }
}

// MARK: - The pill's proposed faces

/// What a collapsed face says on each page, the same words for every variant: a leading mark, a title, a quiet second
/// line and a trailing reading.
@MainActor
private struct PillWords {
    var art: NSImage?
    var symbol: String?
    var live = false
    var title: String
    var detail: String?
    var reading: String?
    var equaliser = false
    /// Several readings at once (Stats, Controls, an extensions page): symbol and value pairs, no title.
    var readings: [(String, String)] = []

    init(_ v: PillValues) {
        if let live = v.live {
            self.live = true; title = live.title; reading = live.reading; return
        }
        switch v.page {
        case .music:
            art = v.music?.art; title = v.music?.title ?? "Nothing playing"; detail = v.music?.artist; equaliser = v.music?.playing == true
        case .calendar:
            symbol = "calendar"
            let next = v.calendar?.events.first
            title = next?.title ?? v.calendar?.short ?? "Calendar"
            live = next?.now == true
            reading = next?.now == true ? "now" : next?.time.components(separatedBy: " ").first
        case .stats:
            title = "Stats"
            readings = v.stats.prefix(3).map { ($0.symbol, $0.unit == "%" ? "\($0.number)%" : "\($0.number) \($0.unit)") }
        case .extensions:
            title = v.title
            readings = v.extensions.prefix(3).map { ($0.symbol, $0.value) }
        case .controls:
            title = "Controls"
            readings = [("speaker.wave.2", "62"), ("sun.max", "78"), ("wifi", "on")]
        case .activity:
            title = v.running.first?.title ?? "Nothing running"; reading = v.running.first?.reading; live = !v.running.isEmpty
        }
    }
}

/// The page dots: one per page, the one showing in the text colour.
private struct PageDots: View {
    @Environment(\.style) private var style
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                Capsule(style: .circular).fill(style.color(i == current ? \.text : \.line3)).frame(width: i == current ? 8 : 4, height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The readings run: a glyph in the second text colour beside its value in mono, 14 apart.
private struct ReadingsRun: View {
    @Environment(\.style) private var style
    let readings: [(String, String)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(readings.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 5) {
                    Image(systemName: r.0).font(style.font(\.barIcon)).foregroundStyle(style.color(\.text2))
                    Text(r.1).styleText(\.barTime).monospacedDigit().foregroundStyle(style.color(\.text))
                }
            }
        }
    }
}

/// A · the island is the pill (SketchyBar's islands): no capsule of its own, the centre island's ground is its shape; the
/// page dots where the chevron was; the island ringed in the accent while something is live or the drop is open.
private struct IslandPill: View {
    @Environment(\.style) private var style
    let values: PillValues
    let open: Bool
    let padding: Double

    var body: some View {
        let w = PillWords(values)
        HStack(spacing: 8) {
            if w.live { FaceLiveDot(size: 7) }
            if let art = w.art { FaceArt(image: art, size: CGSize(width: 18, height: 18), radius: 4) }
            if let symbol = w.symbol { Image(systemName: symbol).font(style.font(\.barIcon)).foregroundStyle(style.color(\.text2)) }
            if w.readings.isEmpty {
                Text(w.title).styleText(\.barStrong).foregroundStyle(style.color(\.text)).lineLimit(1)
                if let detail = w.detail { Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1) }
                if let reading = w.reading { Text(reading).styleText(\.barTime).monospacedDigit().foregroundStyle(style.color(w.live ? \.accentText : \.text2)) }
                if w.equaliser { Equaliser(playing: true) }
            } else {
                ReadingsRun(readings: w.readings)
            }
            PageDots(count: values.tabs.count, current: values.selected).padding(.leading, 6)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .fixedSize()
        .overlay {
            // The island's own ring, lit: the island is `padding` wider each side.
            if w.live || open {
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(style.color(\.accent), lineWidth: 1.5)
                    .padding(.horizontal, -CGFloat(padding))
            }
        }
    }
}

/// B · the notch (DynamicNotch): a deep shape flush with the bar's top edge, square at the top and rounded below, the
/// state at its two ends and the title between; open, it is the top of the drop's one shape.
private struct NotchPill: View {
    @Environment(\.style) private var style
    let values: PillValues
    let open: Bool
    static let width: CGFloat = 340

    var body: some View {
        let w = PillWords(values)
        let ink = Notch.tokens(style)
        HStack(spacing: 10) {
            Group {
                if w.live { FaceLiveDot(size: 8) }
                else if let art = w.art { FaceArt(image: art, size: CGSize(width: 20, height: 20), radius: 5) }
                else if let symbol = w.symbol { Image(systemName: symbol).font(ink.font(\.barIcon)).foregroundStyle(ink.color(\.text2)) }
            }
            .frame(width: 22, alignment: .leading)
            if w.readings.isEmpty {
                HStack(spacing: 6) {
                    Text(w.title).styleText(\.barStrong).foregroundStyle(ink.color(\.text)).lineLimit(1)
                    if let detail = w.detail { Text(detail).styleText(\.caption).foregroundStyle(ink.color(\.text2)).lineLimit(1) }
                }
                .frame(maxWidth: .infinity)
            } else {
                ReadingsRun(readings: w.readings).style(ink).frame(maxWidth: .infinity)
            }
            Group {
                if w.equaliser { Equaliser(playing: true) }
                else if let reading = w.reading { Text(reading).styleText(\.barTime).monospacedDigit().foregroundStyle(ink.color(w.live ? \.accentText : \.text2)) }
            }
            .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(width: open ? NotchDrop.width : Self.width)
        .frame(maxHeight: .infinity)
        // Flush with the screen's top edge through the strip's 3 pt inset; open, down through its foot into the drop.
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: open ? 0 : 11, bottomTrailingRadius: open ? 0 : 11, style: .continuous)
                .fill(ink.color(\.canvas)).padding(.top, -3).padding(.bottom, open ? -4 : 0)
        }
    }
}

/// C · quiet (macOS's own bar): no box at all, the face reads as bar text; open, it sits on the one capsule the bar shows.
private struct QuietPill: View {
    @Environment(\.style) private var style
    let values: PillValues
    let open: Bool

    var body: some View {
        let w = PillWords(values)
        HStack(spacing: 7) {
            if w.live { FaceLiveDot(size: 7) }
            if let art = w.art { FaceArt(image: art, size: CGSize(width: 16, height: 16), radius: 4) }
            if let symbol = w.symbol { Image(systemName: symbol).font(style.font(\.barIcon)).foregroundStyle(style.color(\.text2)) }
            if w.readings.isEmpty {
                Text(w.title).styleText(\.barStrong).foregroundStyle(style.color(\.text)).lineLimit(1)
                if let detail = w.detail { Text("·  \(detail)").styleText(\.caption).foregroundStyle(style.color(\.text2)).lineLimit(1) }
                if let reading = w.reading { Text(reading).styleText(\.barTime).monospacedDigit().foregroundStyle(style.color(w.live ? \.accentText : \.text2)) }
                if w.equaliser { Equaliser(playing: true).padding(.leading, 2) }
            } else {
                ReadingsRun(readings: w.readings)
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(style.color(\.text2))
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 12).frame(height: 22)
        .background { if open { Capsule(style: .continuous).fill(style.color(\.raised)).overlay { Capsule(style: .continuous).strokeBorder(style.color(\.line)) } } }
        .frame(maxHeight: .infinity)
        .fixedSize()
    }
}

/// The notch's own ink: the bar's ground a deep step down in a dark theme, the theme's inverse in a light one.
private enum Notch {
    static func tokens(_ t: StyleTokens) -> StyleTokens {
        // `b` at `amount` over `a` (Contrast.mix weighs its first).
        func mix(_ a: Paint, _ b: Paint, _ amount: Double) -> Paint { Paint(Contrast.hex(Contrast.mix(Contrast.rgb(b.rgb), Contrast.rgb(a.rgb), amount))) }
        var c = t.colors
        if t.dark {
            let deep = mix(c.canvas, Paint(0x000000), 0.62)
            (c.canvas, c.panel, c.raised, c.sunken) = (deep, deep, mix(deep, c.text, 0.08), mix(deep, Paint(0x000000), 0.3))
            c.line = mix(deep, c.text, 0.12); c.line2 = mix(deep, c.text, 0.18); c.line3 = mix(deep, c.text, 0.26)
        } else {
            let ground = c.inverse, ink = c.onInverse
            (c.canvas, c.panel, c.raised, c.sunken) = (ground, ground, mix(ground, ink, 0.1), mix(ground, Paint(0x000000), 0.25))
            (c.text, c.text2, c.text3) = (ink, mix(ground, ink, 0.72), mix(ground, ink, 0.55))
            c.line = mix(ground, ink, 0.14); c.line2 = mix(ground, ink, 0.2); c.line3 = mix(ground, ink, 0.3)
            (c.inverse, c.onInverse) = (ink, ground)
            // The light theme's accent text is made for a light ground; on the notch the accent itself reads.
            c.accentText = c.accent
        }
        var tokens = StyleTokens(kind: t.kind, dark: true, colors: c, type: t.type, radii: t.radii, depth: t.depth, density: t.density)
        tokens.scale = t.scale
        return tokens
    }
}

// MARK: - The drops' proposed pages

/// The page under any drop's chrome: Media, Stats or Calendar at its content's height, nothing reserved below it.
private struct PageBody: View {
    @Environment(\.style) private var style
    let values: PillValues
    /// C's tiles: each block on a raised tile.
    var tiles = false

    var body: some View {
        switch values.page {
        case .music: if let music = values.music { media(music) }
        case .stats: stats
        case .calendar: if let calendar = values.calendar { day(calendar) }
        default: EmptyView()
        }
    }

    private func media(_ music: PillValues.Music) -> some View {
        HStack(alignment: .center, spacing: 16) {
            FaceArt(image: music.art, size: CGSize(width: 104, height: 104), radius: style.radii.card)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Equaliser(playing: music.playing)
                    Text("\(music.playing ? "Playing" : "Paused") in \(music.source)").styleText(\.small).foregroundStyle(style.color(\.text2))
                }
                Text(music.title).font(style.font(\.title, size: 18)).foregroundStyle(style.color(\.text)).lineLimit(1).padding(.top, 6)
                Text([music.artist, music.album].compactMap { $0 }.joined(separator: " · ")).styleText(\.body).foregroundStyle(style.color(\.text2)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(music.elapsed).font(style.font(\.mono, size: 10.5)).monospacedDigit().foregroundStyle(style.color(\.text2))
                    GeometryReader { space in
                        ZStack(alignment: .leading) {
                            Capsule(style: .circular).fill(style.color(\.line2))
                            Capsule(style: .circular).fill(style.color(\.text)).frame(width: space.size.width * music.progress)
                        }
                    }
                    .frame(height: 4)
                    Text(music.length).font(style.font(\.mono, size: 10.5)).monospacedDigit().foregroundStyle(style.color(\.text2))
                }
                .padding(.top, 12)
                HStack(spacing: 14) {
                    Image(systemName: "backward.fill").font(.system(size: 14))
                    Image(systemName: music.playing ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(style.color(\.onInverse)).frame(width: 34, height: 34).background(style.color(\.inverse), in: Circle())
                    Image(systemName: "forward.fill").font(.system(size: 14))
                    Spacer(minLength: 12)
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(style.color(\.text2))
                    FaceSlider(value: values.sound?.level ?? 0.62, label: "Volume").frame(width: 110)
                }
                .foregroundStyle(style.color(\.text)).padding(.top, 8)
            }
        }
        .padding(tiles ? 12 : 0)
        .background { if tiles { RoundedRectangle(cornerRadius: style.radii.card, style: .continuous).fill(style.color(\.raised)) } }
    }

    private var stats: some View {
        FaceColumns(items: Array(values.stats.indices), columns: min(4, values.stats.count), spacing: 8) { row in
            let stat = values.stats[row]
            FaceReading(symbol: stat.symbol, title: stat.title, number: stat.number, unit: stat.unit, detail: stat.detail, share: stat.share,
                        reservesBar: true, size: 22)
        }
    }

    private func day(_ calendar: PillValues.Calendar) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(calendar.weekday).styleText(\.small).foregroundStyle(style.color(\.accentText))
                Text(calendar.day).font(style.font(\.title, size: 40)).monospacedDigit().foregroundStyle(style.color(\.text))
                Text(calendar.month).styleText(\.small).foregroundStyle(style.color(\.text2))
            }
            .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(calendar.events.prefix(3).enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 10) {
                        Capsule(style: .circular).fill(event.colour ?? style.color(\.accent)).frame(width: 3, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).styleText(\.strong).foregroundStyle(style.color(\.text)).lineLimit(1)
                            Text([event.day, event.time].compactMap { $0 }.joined(separator: " · ")).font(style.font(\.mono, size: 10.5))
                                .monospacedDigit().foregroundStyle(style.color(\.text2))
                        }
                        Spacer(minLength: 6)
                        if event.now { HStack(spacing: 4) { FaceLiveDot(size: 6); Text("Now").styleText(\.small) }.foregroundStyle(style.color(\.text)) }
                    }
                    .padding(.horizontal, 8).frame(minHeight: 38)
                    .background { if event.now { RoundedRectangle(cornerRadius: style.radii.control + 2, style: .continuous).fill(style.color(\.raised)) } }
                }
            }
        }
    }
}

/// A's drop: its own panel 6 under the island, the island's corner family; the pages as words with the one showing
/// underlined (the Strip's workspace mark), one quiet line of keys at the foot.
private struct PagedDrop: View {
    @Environment(\.style) private var style
    let values: PillValues
    static let width: CGFloat = 560

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ForEach(Array(values.tabs.enumerated()), id: \.offset) { i, tab in
                    let on = i == values.selected
                    Text(tab.title).styleText(on ? \.strong : \.caption).foregroundStyle(style.color(on ? \.text : \.text2))
                        .padding(.bottom, 6)
                        .overlay(alignment: .bottom) { if on { Capsule(style: .circular).fill(style.color(\.accent)).frame(height: 2) } }
                }
                Spacer(minLength: 0)
                Image(systemName: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(style.color(\.text2))
            }
            PageBody(values: values)
            Text("←  →  pages     ↵  open     esc  close").font(style.font(\.mono, size: 10.5)).foregroundStyle(style.color(\.text2))
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .background(style.color(\.canvas), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line)) }
    }
}

/// B's drop: the notch grown down, one deep shape from the bar's top edge, flaring into the bar at its shoulders (Sven's
/// pick A, 2026-11-10); the pages as words across its top, no key line.
private struct NotchDrop: View {
    @Environment(\.style) private var style
    let values: PillValues
    static let width: CGFloat = 600
    static let shoulder: CGFloat = 12

    var body: some View {
        let ink = Notch.tokens(style)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(values.tabs.enumerated()), id: \.offset) { i, tab in
                    let on = i == values.selected
                    Text(tab.title).styleText(on ? \.strong : \.caption).foregroundStyle(ink.color(on ? \.text : \.text2))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background { if on { Capsule(style: .circular).fill(ink.color(\.raised)) } }
                }
                Spacer(minLength: 0)
            }
            PageBody(values: values)
        }
        .style(ink)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        .frame(width: Self.width, alignment: .leading)
        .padding(.horizontal, Self.shoulder)
        .background { ShoulderShape(shoulder: Self.shoulder, corner: 16).fill(ink.color(\.canvas)) }
    }
}

/// C's drop: macOS's Control Center under a quiet bar: the pages a rail on the left, the page on raised tiles beside it;
/// it flares into the floating strip's foot as today's drop does.
private struct RailDrop: View {
    @Environment(\.style) private var style
    let values: PillValues
    static let width: CGFloat = 640
    static let shoulder: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(values.tabs.enumerated()), id: \.offset) { i, tab in
                    let on = i == values.selected
                    HStack(spacing: 8) {
                        Image(systemName: tab.page.symbol).font(.system(size: 12)).frame(width: 16)
                        Text(tab.title).styleText(on ? \.strong : \.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(style.color(on ? \.text : \.text2))
                    .padding(.horizontal, 8).frame(height: 28)
                    .background { if on { RoundedRectangle(cornerRadius: style.radii.control + 1, style: .continuous).fill(style.color(\.raised)) } }
                }
            }
            .frame(width: 128)
            PageBody(values: values, tiles: true).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .padding(.horizontal, Self.shoulder)
        .background { ShoulderShape(shoulder: Self.shoulder, corner: style.radii.pop).fill(style.color(\.canvas)) }
        .overlay { ShoulderShape(shoulder: Self.shoulder, corner: style.radii.pop, open: true).stroke(style.color(\.line2), lineWidth: 1) }
    }
}
}
#endif
