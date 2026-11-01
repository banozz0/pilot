import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Strip bar style (card agent-bo-95423013, design JJPiA9o30SA direction A): a raised pill on hover and a tooltip
/// after 500 ms. The Strip's resting look under Current (no boxes, the workspace underline, the time's chip) went with
/// Current on 2026-10-11. Drawn from Sven's bar.items with fake readings; with
/// PILOT_RENDER_DIR set the four bars are also written there as PNGs.
@MainActor
@Suite("Strip bar style", .serialized)
struct StripStyleTests {
    /// Sven's bar on fake readings: the tiler on workspace 2 of 1, 2, 3 and 5, a focus timer running, the clock at
    /// Wed 7 Oct 2026 21:04; `appMenus` reads the front app's menus, `menuApps` other apps' items, over `defaults` when given.
    static func svensBar(appMenus: AppMenus = AppMenus(), menuApps: MenuApps = MenuApps(),
                         defaults: UserDefaults? = nil) throws -> (store: BarItemsStore, sources: BarSources, timer: ExtensionTimer) {
        let store = MenuBarStatusItemsTests.svensBar(try defaults ?? MenuBarStatusItemsTests.defaults())
        let observers = EngineObservers()
        observers.tiler.seed(focused: "2", occupied: ["1", "2", "3", "5"].map { OccupiedWorkspace(name: $0, apps: ["Ghostty"]) })
        let timer = ExtensionTimer(now: { SharedLook.ClockRenders.now })
        timer.startFocus()
        let sources = MenuBarStatusItemsTests.sources(Self.sampler(), timer: timer, observers: observers,
                                                      clock: { SharedLook.ClockRenders.now }, appMenus: appMenus, menuApps: menuApps)
        return (store, sources, timer)
    }

    /// Readings like the mockup's: CPU 9%, memory 56%, the CPU at 52°, a little network traffic.
    static func sampler() -> SystemSampler {
        let counter = SystemSamplerTests.Counter()
        return SystemSampler(historyLength: 60, read: { parts in
            let t = Double(counter.bump(slow: false, processes: false))
            var raw = SystemSamplerTests.raw(t, slow: !parts.isDisjoint(with: .slow), processes: false)
            raw.cpu = .init(user: UInt64(t) * 9, system: 0, idle: 91 * UInt64(t), nice: 0)
            raw.memory.active = 450_000
            raw.memory.wired = 137_000
            raw.network = .init(received: UInt64(t) * 48_000, sent: UInt64(t) * 6_000)
            if parts.contains(.sensors) { raw.sensors = .init(temperatures: ["Tp01": 52], fans: [], power: nil) }
            return raw
        }, fetchPublicIP: { nil }, netTop: { nil })
    }

    /// Each item's frame in the strip, by its name.
    final class Frames { var placed: [String: CGRect] = [:] }

    /// Sven's bar `width` wide, each item's frame recorded in `frames` by its kind's title.
    static func strip(_ store: BarItemsStore, _ sources: BarSources, width: CGFloat, frames: Frames = .init(),
                      wallpaper: WallpaperStrip.Grid? = nil) -> some View {
        TopBarStrip(sides: store.settings.preview(.topBar).top ?? [:], background: store.background, colour: store.colour,
                    itemColours: store.itemColours, wallpaper: wallpaper) { slot in
            TopBarSlotView(slot: slot, screen: "", sources: sources, store: store)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("bar")) } action: { frames.placed[slot.isGroup ? "Group" : slot.kind.title] = $0 }
        }
        .coordinateSpace(.named("bar"))
        .frame(width: width, height: 30)
        .pilotTheme()
    }

    /// Writes `rep` to PILOT_RENDER_DIR/`name`.png when that is set.
    static func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// `rep`'s see-through pixels, and the points of those off the ground in `bands` (pixel rows): where a box drawn
    /// round an item, or a side, would show and no ink does.
    static func resting(_ rep: NSBitmapImageRep, bands: [Range<Int>]) -> (seeThrough: Int, drawn: [Int]) {
        let ground = Self.ground()
        var seeThrough = 0, drawn: [Int] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = Self.pixel(rep, x, y)
                if p[3] < 255 { seeThrough += 1 }
                if bands.contains(where: { $0.contains(y) }), !Self.near(p, ground) { drawn.append(x / 2) }
            }
        }
        return (seeThrough, drawn)
    }

    /// The ground's colour as the renders' device RGB bytes hold it.
    static func ground() -> [UInt8] { bytes(Theme.background) }

    static func bytes(_ colour: Color) -> [UInt8] {
        let c = NSColor(colour).usingColorSpace(.deviceRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent].map { UInt8(($0 * 255).rounded()) }
    }

    /// The pixel at `x`, `y` (top-left origin) as RGBA bytes.
    static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [UInt8] {
        let p = rep.bitmapData! + y * rep.bytesPerRow + x * 4
        return [p[0], p[1], p[2], p[3]]
    }

    /// `view` alone over the ground in the top bar, `width` wide and the bar's height.
    static func alone(_ view: some View, width: CGFloat = 40) throws -> NSBitmapImageRep {
        try rendered(view.environment(\.inTopBar, true).font(BarMetrics.font).frame(width: width, height: 30)
            .pilotTheme().background(Theme.background), wait: 0.2)
    }

    /// How strongly `drawn` draws what `whole` draws at full strength over the ground: the median, over every channel
    /// `whole` sets well off the ground, of how far `drawn`'s goes (blending is not quite linear in the render's bytes, so
    /// one pixel's share says little); with the number of channels counted.
    /// Only `columns` and `rows` (pixels) are read when given.
    static func strength(_ drawn: NSBitmapImageRep, of whole: NSBitmapImageRep, columns: Range<Int>? = nil,
                         rows: Range<Int>? = nil) -> (median: Double, channels: Int) {
        let ground = Self.ground()
        var shares: [Double] = []
        for y in rows ?? 0..<whole.pixelsHigh {
            for x in columns ?? 0..<whole.pixelsWide {
                let d = pixel(drawn, x, y), w = pixel(whole, x, y)
                for c in 0..<3 where abs(Int(w[c]) - Int(ground[c])) > 60 {
                    shares.append((Double(d[c]) - Double(ground[c])) / (Double(w[c]) - Double(ground[c])))
                }
            }
        }
        return (shares.isEmpty ? 0 : shares.sorted()[shares.count / 2], shares.count)
    }

    static func near(_ a: [UInt8], _ b: [UInt8], _ tolerance: Int = 3) -> Bool {
        // Spelled out, not zipped: the strip checks call it for every pixel, and a debug build's zip was most of their time.
        abs(Int(a[0]) - Int(b[0])) <= tolerance && abs(Int(a[1]) - Int(b[1])) <= tolerance && abs(Int(a[2]) - Int(b[2])) <= tolerance
    }

    /// Sleeps only when the test says: a fake clock for the tooltip's 500 ms.
    @MainActor final class FakeSleep {
        var asked: [Duration] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func sleep(_ duration: Duration) async { asked.append(duration); await withCheckedContinuation { waiting.append($0) } }
        func advance() { waiting.forEach { $0.resume() }; waiting = [] }
    }

    @MainActor final class FakeTips: BarTooltipPresenting {
        var shown: [String] = []
        var hidden = 0
        func show(_ text: String, under item: CGRect) { shown.append(text) }
        func hide() { hidden += 1 }
    }

    @Test("A saved bar from the Menu style's days (bar.style = menu) loads and draws the Strip, the clock in the centre; the old key is no setting (Sven, 2026-10-12)")
    func oldMenuStyleLoadsAsStrip() async throws {
        let defaults = try MenuBarStatusItemsTests.defaults()
        defaults.set("menu", forKey: "bar.style")
        let (store, sources, timer) = try Self.svensBar(defaults: defaults)
        defer { timer.stop() }
        let frames = Frames()
        _ = try rendered(Self.strip(store, sources, width: 1440, frames: frames), wait: 0.5)
        let clock = try #require(frames.placed["Clock"])
        #expect(abs(clock.midX - 720) < 120, "the clock at \(clock.midX) is not in the centre")
        #expect(await SettingsSchemaPart2Tests.Rig().ask("get", "bar.style").error?.code == .unknownKey)
    }

    @Test("Hover shows the tooltip after 500 ms on the clock, leaving first shows none; the raised pill draws only while lit (card agent-bo-95423013, AC 4)")
    func hover() async throws {
        let sleep = FakeSleep(), tips = FakeTips()
        let hover = BarHover(presenter: tips) { await sleep.sleep($0) }
        let date = UUID(), time = UUID()
        hover.enter(date, tooltip: "Open Calendar", under: { CGRect(x: 100, y: 0, width: 60, height: 30) })
        #expect(hover.hovered == date && tips.shown.isEmpty)
        #expect(try await SystemSamplerTests.wait { sleep.asked == [.milliseconds(500)] })
        sleep.advance()
        #expect(try await SystemSamplerTests.wait { tips.shown == ["Open Calendar"] })
        hover.leave(date)
        #expect(hover.hovered == nil && tips.hidden == 1)

        // Left before the clock runs out: no tooltip.
        hover.enter(time, tooltip: "Wednesday", under: { CGRect.zero })
        #expect(try await SystemSamplerTests.wait { sleep.asked.count == 2 })
        hover.leave(time)
        sleep.advance()
        for _ in 0..<50 { await Task.yield() }
        #expect(tips.shown == ["Open Calendar"] && hover.hovered == nil)

        // A click before the clock runs out shows none, and one on a shown tooltip takes it off: the popover the click
        // opens hangs where the tooltip would (Moody REJECT duqt_GNBtwY).
        hover.enter(date, tooltip: "Open Calendar", under: { CGRect(x: 100, y: 0, width: 60, height: 30) })
        #expect(try await SystemSamplerTests.wait { sleep.asked.count == 3 })
        hover.pressed()
        sleep.advance()
        for _ in 0..<50 { await Task.yield() }
        #expect(tips.shown == ["Open Calendar"])
        hover.leave(date)
        hover.enter(time, tooltip: "Wednesday", under: { CGRect(x: 200, y: 0, width: 60, height: 30) })
        #expect(try await SystemSamplerTests.wait { sleep.asked.count == 4 })
        sleep.advance()
        #expect(try await SystemSamplerTests.wait { tips.shown.count == 2 })
        let hidden = tips.hidden
        hover.pressed()
        #expect(tips.hidden == hidden + 1)

        // The pill (an open drawer's or menu's) is the raised colour behind the item, drawn the frame it lights.
        let raised = Self.bytes(Theme.selected)
        for lit in [false, true] {
            let rep = try rendered(Text("3").font(Theme.mono(12)).padding(.horizontal, 8).frame(height: 24).barHoverPill(lit)
                .environment(\.inTopBar, true).pilotTheme().background(Theme.background), wait: 0.2)
            let count = (0..<rep.pixelsHigh).reduce(0) { n, y in n + (0..<rep.pixelsWide).count { Self.near(Self.pixel(rep, $0, y), raised, 2) } }
            #expect(lit ? count > 200 : count == 0, "hovered \(lit): \(count) raised pixels")
        }
    }
}
