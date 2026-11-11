#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The desktop controls' native faces (spec desktop-controls T2): the tall Dropdown panel, the pill (each view compact and
/// open) and the Carousel in both modes, in Instrument on Tokyo Night (dark) and Porcelain (light), each face fed plain values.
/// The panel and the pill hang under a stand-in solid top bar over a wallpaper, so the attachment shows; Glass is off, as
/// glass draws nothing offscreen (T6 judges the material on Sven's screen). Empty states: nothing playing, no
/// extensions, nothing running, no images. Reduce Motion: the pill's drop halfway open, sliding and fading. Sven's picks
/// (2026-11-10): the panel's cards, the pill's shoulders, the Carousel's slices. Wallpapers come from
/// `PILOT_RENDER_WALLS` (a folder of PNGs) when set, else drawn gradients. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pdh PILOT_RENDER_DIR=/tmp/pdr swift test --filter DesktopControlsRenders`
extension SharedLook {
@MainActor
@Suite("Desktop controls renders")
struct DesktopControlsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let looks: [(name: String, theme: String)] = [("tokyo-night", "tokyo-night"), ("porcelain", "porcelain")]
    static let strip: CGFloat = 32

    @Test("The Dropdown panel, the pill and the Carousel render in Tokyo Night and Porcelain, every state",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        look.style = .instrument
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
        let walls = Self.walls()

        for each in Self.looks {
            look.themeID = each.theme
            let tokens = StyleTokens.of(.instrument, theme: look.theme)
            let dir = out.appendingPathComponent("desktop-controls-\(each.name)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let backdrop = walls[tokens.dark ? 0 : min(5, walls.count - 1)]
            func shot(_ view: some View, _ name: String) throws {
                let rep = try #require(snapshot(drawing: view.style(tokens), scale: 2), "\(name) did not draw")
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
            }

            // The panel.
            let panel = Self.panel(walls)
            try shot(PanelStage(values: panel, backdrop: backdrop), "panel-a-1-default")
            var problem = panel
            problem.problems = [.init(title: "Accessibility is off", detail: "Pilot cannot read keys or move windows until it is back.", button: "Allow")]
            problem.trusted = false
            try shot(PanelStage(values: problem, backdrop: backdrop), "panel-a-2-problem")
            var idle = panel
            idle.running = []
            idle.updateReady = true
            try shot(PanelStage(values: idle, backdrop: backdrop), "panel-a-3-nothing-running")
            var full = panel
            full.sound = .init(device: "Studio Display", level: 0.64)
            full.connections = .init(wifiOn: true, wifiBars: 3, bluetoothOn: true, bluetoothDetail: "On · AirPods Pro")
            full.display = .init(name: "Studio Display", level: 0.78)
            full.media = .init(title: "Weightless", artist: "Marconi Union", art: walls[min(2, walls.count - 1)], playing: true)
            full.stats = .init(cpu: 11, memoryUsed: 14.2, memoryTotal: 24, battery: nil)
            try shot(PanelStage(values: full, backdrop: backdrop), "panel-a-4-optional-blocks")

            // The follow-ups: a saved order, pins above a scroll, nothing pinned, Option held, the tiler stopped, a build
            // with nowhere to check and a download that cannot stop.
            var ordered = full
            ordered.order = [.status, .media, .now, .stats, .workspaces, .quickSwitches, .display, .sound, .rows]
            try shot(PanelStage(values: ordered, backdrop: backdrop), "panel-b-1-saved-order")
            var pinned = ordered
            pinned.pinned = [.media, .now]
            try shot(PanelStage(values: pinned, room: 560, backdrop: backdrop), "panel-b-2-pinned-room-560")
            var unpinned = panel
            unpinned.running = []
            unpinned.pinnedCommands = 0
            try shot(PanelStage(values: unpinned, backdrop: backdrop), "panel-b-3-commands-unpinned")
            var option = unpinned
            option.developer = [.init(symbol: "text.alignleft", title: "Print observers"), .init(symbol: "lifepreserver", title: "Rescue stranded windows")]
            option.presses = ["14:29:52  ⇪ V  Clipboard history", "14:29:40  ⇪ 2  Workspace 2", "14:28:03  ⇪ Space  Pilot menu",
                              "14:27:11  ⇪ ⇧ 4  Move window to workspace 4 and follow it there"]
            try shot(PanelStage(values: option, backdrop: backdrop), "panel-b-4-developer-option-held")
            var stopped = unpinned
            stopped.problems = [.init(title: "The tiler is not running", detail: "Tiling and workspaces are off until it restarts.", button: "Restart")]
            stopped.workspaces = []
            stopped.workspacesStopped = true
            try shot(PanelStage(values: stopped, backdrop: backdrop), "panel-b-5-workspaces-stopped")
            var download = unpinned
            download.canCheckForUpdates = false
            download.running = [.init(symbol: "arrow.down.to.line", title: "Whisper large v3", detail: "Downloading", reading: "62 %", share: 0.62, canStop: false),
                                .init(symbol: "arrow.down.to.line", title: "Terminal pack", detail: "Downloading", reading: "18 %", share: 0.18)]
            try shot(PanelStage(values: download, backdrop: backdrop), "panel-b-6-no-updates-download-cannot-stop")
            // The Extensions card (Q74 A, Sven's pick of the mock-up): after the switches, one extension with a problem.
            var extensions = panel
            extensions.extensions = [
                .init(emoji: "☀️", title: "Weather", text: "14°", detail: "Partly cloudy · Valletta"),
                .init(emoji: "✅", title: "To-do", text: "3 left", detail: "Next: send the invoice"),
                .init(emoji: "📊", title: "AI usage", text: "–", problem: "Needs its API key set first"),
            ]
            try shot(PanelStage(values: extensions, backdrop: backdrop), "panel-b-7-extensions-card")

            // The pill: each view compact, then open; the empty ones; halfway open.
            let pill = Self.pill(walls)
            var empty = pill
            empty.music = nil
            empty.extensions = []
            empty.running = []
            for page in PillValues.Page.allCases {
                var values = pill
                values.page = page
                let slug = page.title.lowercased()
                try shot(BarStage(width: 720) { PillCompactFace(values: values) }, "pill-compact-\(slug)")
                try shot(PillStage(values: values, backdrop: backdrop), "pill-a-open-\(slug)")
                if page != .controls {
                    var none = empty
                    none.page = page
                    try shot(BarStage(width: 720) { PillCompactFace(values: none) }, "pill-compact-\(slug)-empty")
                    try shot(PillStage(values: none, backdrop: backdrop), "pill-a-open-\(slug)-empty")
                }
            }
            try shot(PillStage(values: pill, openness: 0.5, backdrop: backdrop), "pill-motion-half-open")
            try shot(PillStage(values: pill, openness: 0.5, reduceMotion: true, backdrop: backdrop), "pill-motion-half-open-reduce-motion")

            // The Carousel.
            let wallpapers = Self.wallpapers(walls, palette: Self.palette(look.theme), source: "\(look.theme.name)'s wallpapers")
            try shot(CarouselStage(values: wallpapers, backdrop: backdrop), "carousel-a-1-wallpapers")
            try shot(CarouselStage(values: Self.themes(walls), backdrop: backdrop), "carousel-a-2-themes")
            var search = wallpapers
            search.query = "sky"
            search.items = [1, 4, 6].filter { wallpapers.items.indices.contains($0) }.map { wallpapers.items[$0] }
            search.index = 1
            try shot(CarouselStage(values: search, backdrop: backdrop), "carousel-a-3-search")
            var none = wallpapers
            none.items = []
            none.palette = []
            none.source = "Your folders"
            try shot(CarouselStage(values: none, backdrop: backdrop), "carousel-a-4-no-images")
        }
    }

    // MARK: Stages

    /// A solid top bar strip as the real one draws on a solid bar: the theme's ground, its foot's hairline, the Pilot
    /// item and workspaces at the left, the clock at the right, `centre` in the middle.
    struct BarStage<Centre: View>: View {
        @Environment(\.style) private var style
        var width: CGFloat
        var pilotLit = false
        var rule = true
        @ViewBuilder var centre: Centre

        var body: some View {
            ZStack {
                HStack(spacing: 12) {
                    InstrumentMark(size: 13).foregroundStyle(style.color(\.text))
                        .frame(width: 26, height: 22)
                        .background { if pilotLit { Capsule().fill(style.color(\.raised)) } }
                        .overlay { if pilotLit { Capsule().strokeBorder(style.color(\.line2)) } }
                    HStack(spacing: 10) {
                        ForEach(["1", "2", "3", "4"], id: \.self) { n in
                            Text(n).font(style.font(\.key, size: 11)).foregroundStyle(style.color(n == "1" ? \.accentText : \.text3))
                        }
                    }
                    Spacer()
                    Image(systemName: "wifi").font(.system(size: 11, weight: .medium))
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 11, weight: .medium))
                    Text("Tue 10 Nov  14:30").font(style.font(\.key, size: 11.5))
                }
                .foregroundStyle(style.color(\.text2))
                .padding(.horizontal, 10)
                centre
            }
            .frame(width: width, height: DesktopControlsRenders.strip)
            .background(TopBarColour.themeGround(style))
            .overlay(alignment: .bottom) { if rule { InstrumentRule() } }
        }
    }

    /// The panel under Pilot's item on a slice of desktop.
    struct PanelStage: View {
        let values: DropdownPanelValues
        /// BarPanel's room under the item: past it the unpinned blocks scroll.
        var room: CGFloat?
        let backdrop: NSImage

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                BarStage(width: 420, pilotLit: true) { EmptyView() }
                DropdownPanelFace(values: values).environment(\.barPopoverRoom, room).padding(.leading, 6).padding(.bottom, 28)
            }
            .frame(width: 420, alignment: .topLeading)
            .background(alignment: .top) { Wallpaper(image: backdrop) }
        }
    }

    /// The pill in the bar, its drop hung from the bar's foot under it.
    struct PillStage: View {
        let values: PillValues
        var openness: CGFloat = 1
        var reduceMotion = false
        let backdrop: NSImage

        var body: some View {
            VStack(spacing: 0) {
                BarStage(width: 900, rule: true) { PillCompactFace(values: values, open: true) }
                PillDropFace(values: values, openness: openness, reduceMotion: reduceMotion)
                    .padding(.bottom, 36)
            }
            .frame(width: 900)
            .background(alignment: .top) { Wallpaper(image: backdrop) }
        }
    }

    /// The Carousel centred over a dimmed desktop, as T8's KeyPanel shows it.
    struct CarouselStage: View {
        @Environment(\.style) private var style
        let values: CarouselValues
        let backdrop: NSImage

        var body: some View {
            CarouselFace(values: values)
                .padding(.horizontal, 60).padding(.vertical, 70)
                .background { Wallpaper(image: backdrop).overlay { style.color(\.scrim).opacity(0.5) } }
        }
    }

    struct Wallpaper: View {
        let image: NSImage
        var body: some View { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill).clipped() }
    }

    // MARK: Values

    static func icon(_ app: String) -> NSImage {
        let paths = ["/System/Applications/\(app).app", "/Applications/\(app).app", "/System/Library/CoreServices/\(app).app"]
        let path = paths.first { FileManager.default.fileExists(atPath: $0) } ?? "/System/Library/CoreServices/Finder.app"
        return NSWorkspace.shared.icon(forFile: path)
    }

    static func panel(_ walls: [NSImage]) -> DropdownPanelValues {
        var values = DropdownPanelValues()
        values.workspaces = [
            .init(name: "1", apps: [icon("Safari"), icon("Utilities/Terminal")], current: true),
            .init(name: "2", apps: [icon("Notes")]),
            .init(name: "3", apps: [icon("Music"), icon("Podcasts")]),
            .init(name: "4", apps: [icon("Mail"), icon("Calendar"), icon("Messages")]),
            .init(name: "5"),
        ]
        let on: [Dropdown.Switch: Bool] = [.hyper: true, .tiling: true, .topBar: true, .keepAwake: false, .clipboard: true, .dictation: true]
        values.switches = Dropdown.Switch.allCases.map {
            .init(which: $0, on: on[$0] ?? false, state: $0.state(on[$0] ?? false, layerKeys: [.capsLock], tiler: "Tiling"))
        }
        values.running = [
            .init(symbol: "record.circle", title: "Screen recording", detail: "Studio Display · window", reading: "00:42", canPause: true),
            .init(symbol: "timer", title: "Focus", detail: "Write the release notes", reading: "18:20", canPause: true),
        ]
        values.commands = [
            .init(symbol: "magnifyingglass", title: "Pilot menu", keys: ["⇪", "Space"]),
            .init(symbol: "list.clipboard", title: "Clipboard history", keys: ["⇪", "V"]),
            .init(symbol: "sparkles", title: "AI chat", keys: ["⇪", "A"]),
            .init(symbol: "pencil", title: "Quick notes", keys: ["⇪", "N"]),
            .init(symbol: "crop", title: "Capture area", keys: ["⇪", "4"]),
            .init(symbol: "mic", title: "Dictate"),
            .init(symbol: "video", title: "Screen recording", keys: ["⇪", "5"]),
            .init(symbol: "keyboard", title: "Keys map", keys: ["⇪", "K"]),
            .init(symbol: "puzzlepiece.extension", title: "Extensions"),
        ]
        values.pinnedCommands = 5
        return values
    }

    static func pill(_ walls: [NSImage]) -> PillValues {
        var values = PillValues()
        values.music = .init(title: "Weightless", artist: "Marconi Union", album: "Ambient Transmissions", art: walls[min(2, walls.count - 1)],
                             playing: true, elapsed: "1:42", length: "8:09", progress: 0.21, source: "Music")
        values.extensions = [
            .init(symbol: "cloud.sun", name: "Weather", value: "19°", detail: "Valletta · clear later"),
            .init(symbol: "arrow.triangle.branch", name: "Reviews", value: "3", detail: "Pull requests waiting"),
            .init(symbol: "drop", name: "Water", value: "5/8", detail: "Glasses today"),
        ]
        values.running = [
            .init(symbol: "record.circle", title: "Screen recording", detail: "Studio Display · window", reading: "00:42", canPause: true),
            .init(symbol: "timer", title: "Focus", detail: "Write the release notes", reading: "18:20", canPause: true),
            .init(symbol: "arrow.down.to.line", title: "Whisper large v3", detail: "Downloading", reading: "62 %", share: 0.62),
        ]
        values.controls = [
            .init(symbol: "wifi", title: "Wi-Fi", detail: "On · Strong signal", on: true),
            .init(symbol: "antenna.radiowaves.left.and.right", title: "Bluetooth", detail: "On · AirPods Pro", on: true),
            .init(symbol: "moon", title: "Keep awake", detail: "Sleeps as usual", on: false),
            .init(symbol: "rectangle.split.3x1", title: "Tiling", detail: "On", on: true),
            .init(symbol: "doc.on.clipboard", title: "Clipboard", detail: "Recording", on: true),
            .init(symbol: "mic", title: "Dictation key", detail: "A tap dictates", on: true),
        ]
        values.sound = .init(device: "Studio Display speakers", level: 0.64)
        values.display = .init(name: "Studio Display", level: 0.78)
        return values
    }

    /// The current theme's palette dots: its ground, raised and words, then its module colours.
    static func palette(_ theme: PilotTheme) -> [Color] {
        ([theme.ground, theme.raised, theme.text] + theme.modules.prefix(5)).map { Color(Paint($0)) }
    }

    static func wallpapers(_ walls: [NSImage], palette: [Color], source: String) -> CarouselValues {
        let names = ["Lagoon", "Meadow", "Sea cave", "Valley", "Rain city", "Dunes", "Lilac lake", "Orchid"]
        var items = zip(names, walls).map { CarouselValues.Item(title: $0, image: $1) }
        items[0].current = true
        items[2].favourite = true
        return CarouselValues(mode: .wallpapers, items: items, index: 2, palette: palette, source: source)
    }

    static func themes(_ walls: [NSImage]) -> CarouselValues {
        let ids = ["porcelain", "dracula", "tokyo-night", "void", "ayu-dark", "garnet"]
        let items: [CarouselValues.Item] = ids.compactMap { id in
            guard let theme = PilotTheme.named(id) else { return nil }
            let t = StyleTokens.of(.instrument, theme: theme)
            let look = CarouselValues.ThemeLook(dark: t.dark, ground: t.color(\.canvas), window: t.color(\.panel), raised: t.color(\.raised),
                                                line: t.color(\.line2), text: t.color(\.text), muted: t.color(\.text3), accent: t.color(\.accent),
                                                second: Color(Paint(theme.second)), third: Color(Paint(theme.third)))
            let image: NSImage? = id == "tokyo-night" ? walls[0] : id == "dracula" ? walls[walls.count - 1] : nil
            return .init(title: theme.name, image: image, current: id == "tokyo-night", tagline: theme.tagline,
                         palette: palette(theme), look: look,
                         apps: id == "void" ? nil : .init(editor: "Zed", terminal: "Ghostty", notes: "Obsidian"))
        }
        return CarouselValues(mode: .themes, items: items, index: 2)
    }

    /// The round's wallpapers from PILOT_RENDER_WALLS (eight or more PNGs, in name order, the pack's own first), else eight
    /// drawn gradients.
    static func walls() -> [NSImage] {
        if let folder = env["PILOT_RENDER_WALLS"],
           let names = try? FileManager.default.contentsOfDirectory(atPath: folder).filter({ $0.hasSuffix(".png") }).sorted(),
           names.count >= 8 {
            // Lagoon first, the generated six, Orchid last (the Carousel's order).
            let ordered = names.filter { !$0.contains("dracula") } + names.filter { $0.contains("dracula") }
            let images = ordered.compactMap { Self.thumbnail(URL(fileURLWithPath: folder).appendingPathComponent($0)) }
            if images.count >= 8 { return images }
        }
        let pairs: [(UInt32, UInt32)] = [(0x07101A, 0x2BC4F0), (0x9BC8E8, 0x5E9A4A), (0x0B1830, 0x6E8FB8), (0x2E4A4F, 0xA9C2C0),
                                         (0x24102E, 0xE0559B), (0xE3B27A, 0xF3E1C4), (0xC9B8E0, 0xEDEFF5), (0x1A1030, 0xB36BE0)]
        return pairs.map { a, b in
            NSImage(size: NSSize(width: 1600, height: 900), flipped: false) { rect in
                NSGradient(starting: NSColor(Color(Paint(a))), ending: NSColor(Color(Paint(b))))?.draw(in: rect, angle: 35)
                return true
            }
        }
    }

    /// A 1600 pt wide thumbnail through ImageIO, as T8 makes them.
    static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
}
#endif
