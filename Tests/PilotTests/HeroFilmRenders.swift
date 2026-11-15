#if DEBUG
import AppKit
import AVFoundation
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The parts Pilot's 1.2 hero film (V1, website round 3, Sven 2026-11-15) is composed from, drawn by Pilot's own code from a
/// setup given in the environment (the film copies Sven's, read with `pilot bar`, `pilot dock` and his `bar.items`; nothing
/// of his is in this file):
/// - the top bar from `PILOT_FILM_BAR` (a `bar.items` JSON) as Three islands Attached and as Pills Floating;
/// - the dock Clear and Attached with the apps in `PILOT_FILM_APPS` (bundle ids, in order) and the widgets in
///   `PILOT_FILM_WIDGETS`, those in `PILOT_FILM_LEFT` left of the apps, its bars flat;
/// - both in each theme of `PILOT_STORY_THEMES` over its wallpaper (`PILOT_STORY_WALLS`, "id=path,…");
/// - the visualizer's bars for every frame of the film: the track at `PILOT_FILM_AUDIO`, from `PILOT_FILM_START` seconds for
///   `PILOT_FILM_SECONDS` at `PILOT_FILM_FPS`, through DockSpectrum and DockBarsPath, written as SVG paths in bars.json;
/// - the Line menu's launcher states in each theme: the root, a search for Google Chrome one letter at a time (its commands,
///   Ask AI, Search the web, Search files), the calculator, a translation and an extension's command, and the root as
///   `PILOT_FILM_ROOT_ORDER`, `PILOT_FILM_ROOT_EXTRAS` and `PILOT_FILM_ROOT_HIDDEN` arrange it.
/// Opt-in, in a moved home: `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> PILOT_FILM=1 … swift test --filter HeroFilmRenders`
extension SharedLook {
@MainActor
@Suite("Hero film renders")
struct HeroFilmRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let barWidth: CGFloat = 1880          // the film's 1904-point screen less the bar's 12-point margins
    static let dockSize = DockSize.small

    static func list(_ key: String) -> [String] { (env[key] ?? "").split(separator: ",").map(String.init) }

    @Test("The hero film's bars, dock, visualizer and menu states",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_FILM"] == "1"))
    func render() async throws {
        let dir = try ClockRenders.dir("hero-film")
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let walls = Dictionary(Self.list("PILOT_STORY_WALLS").compactMap { pair -> (String, String)? in
            let p = pair.split(separator: "=", maxSplits: 1)
            return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        }, uniquingKeysWith: { a, _ in a })
        let themes = Self.list("PILOT_STORY_THEMES")
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency)
        defer { (look.style, look.themeID, look.glass, look.transparency) = was }
        (look.style, look.transparency) = (.instrument, 33)

        let dock = Dock(apps: Self.apps(), right: Self.widgets("PILOT_FILM_WIDGETS", except: Self.list("PILOT_FILM_LEFT")),
                        left: Self.widgets("PILOT_FILM_LEFT", except: []))
        for theme in themes {
            look.themeID = theme
            let wall = walls[theme].flatMap(NSImage.init(contentsOfFile:))
            try writeRender(dock.body(wall: wall).styled(.topBar, look: look).pilotTheme(look: look),
                            to: dir.appendingPathComponent("dock-\(theme).png"), wait: 1.5)
            try Self.bar(theme, preset: "threeIslands", attached: true, to: dir.appendingPathComponent("bar-islands-\(theme).png"))
            try Self.bar(theme, preset: "pills", attached: false, to: dir.appendingPathComponent("bar-pills-\(theme).png"))
            try await Self.menus(theme, in: dir)
        }
        try Self.bars(pill: dock.pillWidth, to: dir.appendingPathComponent("bars.json"))
    }

    /// The apps by bundle id, each as Launch Services finds it; ids not installed here are left out.
    static func apps() -> [DockApp] {
        list("PILOT_FILM_APPS").enumerated().compactMap { i, id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return DockApp(bundleID: id, url: url, name: name, pinned: true, pid: i % 3 == 0 ? 1 : nil, windows: i % 3 == 0 ? 1 : 0, front: i == 3)
        }
    }

    static func widgets(_ key: String, except: [String]) -> [(DockWidget, DockWidgetBody)] {
        let bodies = DockWidgetRenders.bodies()
        return list(key).filter { !except.contains($0) }.compactMap { id in bodies.first { $0.0.rawValue == id } }
    }

    /// The dock as DockRiceRenders.Scene draws it, with its own apps and widgets on both sides, Clear and Attached, no bars.
    struct Dock {
        let apps: [DockApp]
        let right: [(DockWidget, DockWidgetBody)], left: [(DockWidget, DockWidgetBody)]
        let size = CGSize(width: DockRenders.ultrawide.width, height: 330)

        @MainActor var strip: some View {
            DockStrip(size: dockSize, apps: apps, hasWidgets: !right.isEmpty, maxWidth: size.width - 2 * DockPill.sideMargin, style: .clear,
                      backing: { AnyView($0) }, placement: .attached, tint: .theme,
                      leftWidgets: left.isEmpty ? nil : AnyView(ForEach(Array(left.enumerated()), id: \.offset) { _, pair in
                          DockWidgetBodyView(widget: pair.0, shown: pair.1) })) {
                ForEach(Array(right.enumerated()), id: \.offset) { _, pair in DockWidgetBodyView(widget: pair.0, shown: pair.1) }
            }
            .environment(\.inTopBar, true).environment(\.barItemColours, true)
        }

        @MainActor var pillWidth: CGFloat { (try? rendered(strip, wait: 0.6)).map { CGFloat($0.pixelsWide) / 2 } ?? 600 }

        @MainActor func body(wall: NSImage?) -> some View {
            ZStack(alignment: .bottom) {
                Group {
                    if let wall { Image(nsImage: wall).resizable().interpolation(.high).aspectRatio(contentMode: .fill) } else { Color.black }
                }
                .frame(width: DockRenders.ultrawide.width, height: DockRenders.ultrawide.height)
                .frame(width: size.width, height: size.height, alignment: .bottom).clipped()
                strip.padding(.bottom, CGFloat(DockSize.margin(.attached)))
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// The visualizer's bars for each frame: the track's samples through Pilot's spectrum, as the dock's audio tap feeds it,
    /// shaped by the dock's own path; each frame's path in SVG, y up from the screen's foot.
    static func bars(pill: CGFloat, to url: URL) throws {
        let audio = try #require(env["PILOT_FILM_AUDIO"])
        let start = Double(env["PILOT_FILM_START"] ?? "0") ?? 0, seconds = Double(env["PILOT_FILM_SECONDS"] ?? "60") ?? 60
        let fps = Double(env["PILOT_FILM_FPS"] ?? "30") ?? 30
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audio))
        let format = file.processingFormat, rate = format.sampleRate
        file.framePosition = AVAudioFramePosition(start * rate)
        let count = AVAudioFrameCount((seconds + 0.2) * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        try file.read(into: buffer, frameCount: count)
        let n = Int(buffer.frameLength), channels = try #require(buffer.floatChannelData)
        let left = Array(UnsafeBufferPointer(start: channels[0], count: n))
        let right = format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: n)) : left
        let l = DockSpectrum(bands: 96, sampleRate: Float(rate)), r = DockSpectrum(bands: 96, sampleRate: Float(rate))
        let width = DockRenders.ultrawide.width, tallest = CGFloat(dockSize.tallestBar)
        var frames: [String] = []
        for i in 0..<Int(seconds * fps) {
            let end = min(n, Int(Double(i) / fps * rate))
            _ = l.step(left[0..<end], dt: Float(1 / fps))
            _ = r.step(right[0..<end], dt: Float(1 / fps))
            frames.append(svg(DockBarsPath.path(width: width, pill: pill, tallest: tallest, left: l.heights, right: r.heights)))
        }
        let json: [String: Any] = ["width": width, "tallest": tallest, "pill": pill, "fps": fps, "start": start, "frames": frames]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    static func svg(_ path: CGPath) -> String {
        var d = ""
        func p(_ q: CGPoint) -> String { String(format: "%.1f %.1f", q.x, q.y) }
        path.applyWithBlock { element in
            let pts = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: d += "M" + p(pts[0])
            case .addLineToPoint: d += "L" + p(pts[0])
            case .addQuadCurveToPoint: d += "Q" + p(pts[0]) + " " + p(pts[1])
            case .addCurveToPoint: d += "C" + p(pts[0]) + " " + p(pts[1]) + " " + p(pts[2])
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }

    /// The top bar from the given `bar.items` in `theme`, as StoryboardRenders.bar seeds it.
    static func bar(_ theme: String, preset: String, attached: Bool, to url: URL) throws {
        let home = try #require(env["CFFIXED_USER_HOME"]), source = try #require(env["PILOT_FILM_BAR"])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.film-\(preset)-\(theme)")
        defaults.set(true, forKey: BarItemsStore.markAloneKey)
        defaults.set(true, forKey: BarItemsStore.extensionsApartKey)
        defaults.set(try Data(contentsOf: URL(fileURLWithPath: source)), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        try store.choosePreset(preset)
        try store.setAttached(attached)
        let look = Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), inputSources: BarReadingsTests.Sources(), defaults: defaults)
        look.style = .instrument
        var input = BarInputs()
        input.pilotTitle = "2"; input.workspaces = ["1", "2", "3", "4"]; input.focusedWorkspace = "2"
        input.focusedApp = "Zed"; input.volume = 0.6; input.muted = false; input.wifiOn = true; input.wifiSignal = -55
        input.keyboardLayout = "ABC"
        input.values = SystemStats.Values(cpu: 0.23, ram: 0.61, gpu: nil, down: 1_240_000, up: 42_000, cores: nil, diskRead: nil, diskWrite: nil)
        input.now = ClockRenders.now; input.timeZone = TimeZone(secondsFromGMT: 0)!; input.locale = Locale(identifier: "en_US_POSIX")
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

    /// The launcher beats' menu states in `theme`: LineMenuRenders' root, calculator, translation and extension command, and a
    /// search for Google Chrome one letter at a time, its commands from Pilot's drive catalogue.
    static func menus(_ theme: String, in dir: URL) async throws {
        Look.shared.themeID = theme
        let wanted = ["L1-root", "L3-calculator", "L16-translate", "L32-gx-new-terminal"]
        for (name, model) in try LineMenuRenders.states() where wanted.contains(name) {
            try await LineMenuRenders.render(model, "\(name)-\(theme)", in: dir, wait: 0.3)
        }
        // The root as `PILOT_FILM_ROOT_ORDER`, `_EXTRAS` and `_HIDDEN` arrange it (Menu › Hyper+Space's own order and hiding).
        let root = MenuRoot(order: list("PILOT_FILM_ROOT_ORDER"), hidden: Set(list("PILOT_FILM_ROOT_HIDDEN")), extras: Set(list("PILOT_FILM_ROOT_EXTRAS")))
        let arranged = MenuModel(nav: MenuNavigator(entries: try LineMenuRenders.built(), root: root))
        arranged.layout = .line
        arranged.ownKey = "Hyper+Space"
        arranged.waiting = MenuModel.waiting(updates: 3, clean: "2.1 GB")
        try await LineMenuRenders.render(arranged, "root-\(theme)", in: dir, wait: 0.3)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/drive-catalogue.json")
        let chrome = ("Google Chrome", "com.google.Chrome")
        let entries = MenuEntries.commands(try LineMenuRenders.built() + [MenuEntry(title: chrome.0, target: .app(chrome.1), home: .apps)],
                                           catalogue: try DriveCatalogue(json: Data(contentsOf: file)), installed: [chrome.1])
        for k in 1...6 {
            var nav = MenuNavigator(entries: entries)
            nav.query = String("chrome".prefix(k))
            let m = MenuModel(nav: nav)
            m.layout = .line
            m.ownKey = "Hyper+Space"
            m.waiting = MenuModel.waiting(updates: 3, clean: "2.1 GB")
            try await LineMenuRenders.render(m, "chrome-\(k)-\(theme)", in: dir, wait: 0.3)
        }
    }
}
}
#endif
