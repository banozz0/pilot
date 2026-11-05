#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The Menu bar page's strip and bar tray (Sven, Q185): the page's top for each placement in Instrument at 1000, Top bar
/// at 760, and the top bar strip mid-drag (CPU held just right of the focused app: the zones, the LEFT label and
/// the caret, BarDropMarks), and three extensions' items apart on the Top bar strip (spec pilot-1.1 T50). Liquid Glass draws nothing offscreen, so the bar is on Solid here. Opt-in like the other
/// renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-tray PILOT_RENDER_DIR=/tmp/pilot-renders-tray swift test --filter BarTrayRenders`
@MainActor
@Suite("Bar tray renders")
struct BarTrayRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Where the strip drew each slot, as the page keeps it.
    final class Frames {
        var rects: [TopBarSide: [Int: CGRect]] = [:]
    }

    @Test("The page's strip and tray for Menu bar, Top bar and Both in each style, and the strip mid-drag",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let dir = try ClockRenders.dir("bar-tray")
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }
        let engine = Engine()
        StatsRenders.seed(SystemSampler.shared)
        let store = BarItemsStore.shared
        StatsRenders.pickMockup(store)
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass, store.background, store.colour)
        defer { (look.style, look.themeID, look.glass, store.background, store.colour) = saved }
        (look.themeID, look.glass, store.background) = ("lagoon", false, .solid)

        // The page in Instrument at 1000 and 760; the strip mid-drag in both styles.
        look.style = .instrument
        for width in [1000, 760] {
            for placement in BarPlacement.allCases where width == 1000 || placement == .topBar {
                let page = ScrollView { MenuBarPage(onScreen: false, placement: placement).environment(engine) }
                    .frame(width: CGFloat(width), height: 820).background(Theme.background).pilotTheme()
                _ = try ClockRenders.write(page, size: NSSize(width: width, height: 820), settle: 0.8,
                                           to: dir.appendingPathComponent("page-\(placement.rawValue)-\(width).png"))
            }
        }
        // Sven's build 58 bar: Glass on a near-white colour, the void theme. Its items are inked dark for the colour, so
        // the strip draws the glass's tinted ground under them, as the bar does, and they read at full strength.
        (look.themeID, store.background, store.colour) = ("void", .glass, .custom(0xFBFCFF))
        let glass = ScrollView { MenuBarPage(onScreen: false, placement: .topBar).environment(engine) }
            .frame(width: 1000, height: 560).background(Theme.background).pilotTheme()
        _ = try ClockRenders.write(glass, size: NSSize(width: 1000, height: 560), settle: 0.8, to: dir.appendingPathComponent("page-topBar-glass-1000.png"))
        (look.themeID, store.background, store.colour) = ("lagoon", .solid, .theme)
        // The Group on: its readings a piece each inside its outline.
        let kept = store.settings
        store.settings.set(.group, on: true)
        store.settings.set(.group, placement: .both)
        let grouped = ScrollView { MenuBarPage(onScreen: false, placement: .topBar).environment(engine) }
            .frame(width: 1000, height: 560).background(Theme.background).pilotTheme()
        _ = try ClockRenders.write(grouped, size: NSSize(width: 1000, height: 560), settle: 0.8, to: dir.appendingPathComponent("page-topBar-group-1000.png"))
        store.settings = kept
        // Each extension's item its own piece in the order (spec pilot-1.1 T50): Ghostex after the workspaces, Weather
        // before the clock, To-do last on the right; the tray keeps Stocks, never placed.
        let (folder, exts, storage) = try SurfacesV2Tests.fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let faces = ["ghostex": ("Ghostex", "👻 5"), "todo": ("To-do", "☑️ 3"), "weather": ("Weather", "🌤 18°"), "stocks": ("Stocks", "▲ 1.2%")]
        for (id, face) in faces { try ExtensionSurfaceTests.write(id, title: face.0, in: exts) }
        let bar = ExtensionBar(folder: exts, storage: storage, run: { surface, _ in .bar(Extension.BarAnswer(text: faces[surface.command.id.extension]?.1 ?? "")) })
        await bar.round()
        for id in ["ghostex", "todo", "weather"] { store.settings.toggle(extension: id, in: .topBar) }
        _ = store.settings.drop(.extension("ghostex"), on: .top(.left, index: 2), placement: .topBar)
        _ = store.settings.drop(.extension("weather"), on: .top(.centre, index: 3), placement: .topBar)
        let apart = ScrollView { MenuBarPage(onScreen: false, placement: .topBar, extensionBar: bar).environment(engine) }
            .frame(width: 1000, height: 820).background(Theme.background).pilotTheme()
        _ = try ClockRenders.write(apart, size: NSSize(width: 1000, height: 820), settle: 0.8, to: dir.appendingPathComponent("page-topBar-extensions-1000.png"))
        store.settings = kept
        for style in [PilotStyle.instrument, .toybox] {
            look.style = style
            try drag(style, store: store, engine: engine, to: dir)
            try remove(style, store: store, engine: engine, to: dir)
        }
    }

    /// Pieces as the strip draws them, Volume under the pointer with its ×.
    private func remove(_ style: PilotStyle, store: BarItemsStore, engine: Engine, to dir: URL) throws {
        var dragged: BarTrayItem?
        let binding = Binding(get: { dragged }, set: { dragged = $0 })
        let pieces = HStack(spacing: 14) {
            ForEach([BarKind.memory, .volume, .clock], id: \.self) { kind in
                StripPiece(item: .kind(kind), title: kind.title, pinned: false, dragged: binding, remove: {}, step: nil, preview: { EmptyView() },
                           content: { TopBarSlotView(slot: .item(store.settings.entry(kind)), screen: "", sources: engine.barSources, store: store) },
                           hoveredAtStart: kind == .volume)
            }
        }
        // The bar's height, as on the page, with its desk above for the −.
        .frame(height: 30).padding(.top, MenuBarPage.room)
        .environment(\.inTopBar, true)
        .padding(.horizontal, 16).frame(width: 420, height: 64).background(Theme.background).styled(.page(.menuBar)).pilotTheme()
        _ = try ClockRenders.write(pieces, size: NSSize(width: 420, height: 64), settle: 0.6, to: dir.appendingPathComponent("remove-\(style.rawValue).png"))
        // Extensions' own pieces as the strip draws them (Sven on build 55: Ghostex and To-do showed their emoji twice).
        let items = [("ghostex", "Ghostex", "👻", "👻 5"), ("todo", "To-do", "☑️", "☑️ 3"), ("now-playing", "Now Playing", "🎵", "♫")].map {
            ExtensionBar.Item(id: $0.0, title: $0.1, icon: $0.2, hasPage: true, answer: Extension.BarAnswer(text: $0.3))
        }
        let extensions = HStack(spacing: 14) {
            ForEach(items) { item in
                StripPiece(item: .extension(item.id), title: item.title, pinned: false, dragged: binding, remove: {}, step: nil, preview: { EmptyView() },
                           content: { ExtensionStripFace(item: item).fixedSize().padding(.horizontal, 4) })
            }
        }
        .frame(height: 30).padding(.top, MenuBarPage.room)
        .environment(\.inTopBar, true)
        .padding(.horizontal, 16).frame(width: 420, height: 64).background(Theme.background).styled(.page(.menuBar)).pilotTheme()
        _ = try ClockRenders.write(extensions, size: NSSize(width: 420, height: 64), settle: 0.6,
                                   to: dir.appendingPathComponent("extensions-\(style.rawValue).png"))
    }

    /// The top bar strip as the page draws it, then again with CPU held just right of the focused app.
    private func drag(_ style: PilotStyle, store: BarItemsStore, engine: Engine, to dir: URL) throws {
        let sides = store.settings.preview(.topBar).top ?? [:], frames = Frames(), width: CGFloat = 960
        let strip = {
            TopBarStrip(sides: sides, background: .solid, colour: store.colour, report: { side, i, rect in frames.rects[side, default: [:]][i] = rect }) {
                TopBarSlotView(slot: $0, screen: "", sources: engine.barSources, store: store).allowsHitTesting(false)
            }
            .frame(width: width, height: 30)
        }
        _ = try rendered(strip().styled(.page(.menuBar)).pilotTheme(), wait: 0.6)
        let drop = BarDrop(sides: Dictionary(uniqueKeysWithValues: TopBarSide.allCases.map { side in
            (side, (sides[side] ?? []).enumerated().map { i, slot in
                let rect = frames.rects[side]?[i] ?? .zero
                return BarDrop.Slot(kind: slot.kind, minX: rect.minX, maxX: rect.maxX)
            })
        }), width: width, height: 30)
        let lead = try #require(frames.rects[.left]?.values.filter { $0.width > 0 }.map(\.maxX).max())
        let target = drop.target(x: lead + 6, y: 15, dragging: .cpu)
        #expect(target?.side == .left, "\(style)")
        let view = VStack(spacing: 0) {
            strip().overlay { BarDropMarks(drop: drop, target: target) }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: 60).background(Theme.background).styled(.page(.menuBar)).pilotTheme()
        _ = try ClockRenders.write(view, size: NSSize(width: width, height: 60), settle: 0.6,
                                   to: dir.appendingPathComponent("drag-\(style.rawValue).png"))
    }
}
}
#endif
