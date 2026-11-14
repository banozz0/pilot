#if DEBUG
import AppKit
import Foundation
@testable import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Drag to rearrange mid-drag (spec drag-reorder; Sven, 2026-11-14): the dock with an app dragged two places along and
/// the others slid apart, magnification paused; the dock with a right widget dragged across the apps to the left, the
/// apps carried along; the top bar, Full bar and Three islands, with an item dragged from the right into the centre and
/// the gap open there. Each drawn by the real pill and strip (DockStrip, TopBarStrip) from a staged drag (DockDrag.stage,
/// BarDrag(rendering:)), the state a drag's moves set. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter DragRenders`
extension SharedLook {
@MainActor
@Suite("Drag renders")
struct DragRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The dock and the top bar mid-drag", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch real data")
        testApp()
        let dir = try ClockRenders.dir("drag")
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let was = (look.style, look.themeID, look.glass, look.transparency)
        defer { (look.style, look.themeID, look.glass, look.transparency) = was }
        (look.style, look.themeID, look.glass, look.transparency) = (.instrument, "dracula", false, 33)
        try dock(dir, look: look)
        try bar(dir, look: look)
    }

    // MARK: The dock

    private func dock(_ dir: URL, look: Look) throws {
        let screen = DockRenders.laptop, apps = DockRenders.apps(12)
        let tokens = StyleTokens.of(look.style, theme: look.theme)
        let tint = Color(nsColor: TopBarColour.tint(.theme, style: tokens, look: look))
        let desk = DockRenders.Desk(wall: nil, screen: screen, size: CGSize(width: screen.width, height: 150))
        // Four widgets, so their row fits and does not scroll (a scrolling row clips what is dragged out of it).
        let widgets = Array(DockRenders.widgets.prefix(4))
        let right = widgets.map { DockSlot.widget($0.0) }
        let drag = DockDrag()
        func pill() -> some View {
            DockStrip(size: .medium, apps: apps, hasWidgets: true, maxWidth: screen.width - 2 * DockPill.sideMargin, style: .glass,
                      backing: { AnyView($0.modifier(DockRenders.GlassStandIn(desk: desk, tint: tint))) }, drag: drag) {
                ForEach(widgets, id: \.0) { pair in
                    DockWidgetBodyView(widget: pair.0, shown: pair.1).modifier(DockDragged(slot: .widget(pair.0), drag: drag))
                }
            }
            .environment(\.inTopBar, true).environment(\.barItemColours, true)
        }
        // At rest first, so the pill tells the drag where its icons and widgets are.
        try writeRender(desk.scene(pill(), look: look), to: dir.appendingPathComponent("dock-rest.png"), wait: 1.0)
        try #require(drag.row.width > 0 && drag.slot > 0, "the pill reported no row")
        let slot = drag.slot

        // Safari, fourth, dragged two and a half places right: Notes and Calendar slide left into its place.
        drag.stage(.app(key: apps[3].key, from: 3), dx: slot * 2.4)
        try writeRender(desk.scene(pill(), look: look), to: dir.appendingPathComponent("dock-app-mid-drag.png"), wait: 1.0)
        print("DRAG dock app: Safari from 3 lands at \(drag.appLanding.map(String.init) ?? "nil")")

        // The second widget dragged left past the apps' middle: it lands on the left side, the apps carried right.
        let moved = right[1], frame = try #require(drag.frames[moved], "the widget reported no frame")
        drag.stage(.widget(moved), dx: drag.row.minX + 40 - frame.midX, right: right)
        try writeRender(desk.scene(pill(), look: look), to: dir.appendingPathComponent("dock-widget-mid-drag.png"), wait: 1.0)
        print("DRAG dock widget: \(moved.name) lands \(drag.widgetLanding.map { "\($0.side.rawValue) \($0.index)" } ?? "nil")")
    }

    // MARK: The top bar

    private func bar(_ dir: URL, look: Look) throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        let defaults = try BarFixtureDefaults(root: home, suite: "dev.banozz.pilot.drag-render")
        defaults.set(try ThemeDigest.encoded(BarSettings.defaults), forKey: BarItemsStore.key)
        let store = BarItemsStore(defaults: defaults, statsPrefs: { [:] })
        var settings = store.settings
        let sides = BarLookRenders.working(&settings)
        store.settings = settings
        StatsRenders.seed(SystemSampler.shared)
        let tokens = StyleTokens.of(.instrument, theme: look.theme)
        let draw = BarLookRenders.Draw(input: BarLookRenders.inputs(), settings: settings, sources: BarLookRenders.sources(), store: store, look: look,
                                       wall: DesktopControlsRenders.walls()[0], tokens: tokens)
        final class Frames { var all: [TopBarSide: [Int: CGRect]] = [:] }
        for (name, config) in [("full-bar", BarPresetConfiguration?.none), ("three-islands", BarPreset.threeIslands.configuration)] {
            // At rest first, for where each slot is; then Volume, third on the right, dragged into the centre before the
            // clock and held in the gap that opens there, the right closing behind it.
            let frames = Frames()
            var drag = BarDrag()
            func strip() -> some View {
                TopBarStrip(sides: sides, configuration: config, background: .solid,
                            report: { side, index, rect in frames.all[side, default: [:]][index] = rect },
                            moved: { [drag] side, index in (drag.offset(side: side, index: index, on: ""), drag.lifts(side: side, index: index, on: "")) }) {
                    draw.slot($0, settings: settings, pill: { AnyView(EmptyView()) })
                }
            }
            let h = CGFloat(config?.height ?? BarLookRenders.strip), margin = CGFloat(config?.horizontalMargin ?? 0), top = CGFloat(config?.topMargin ?? 0)
            try writeRender(strip().styled(.topBar, look: look).frame(width: BarLookRenders.width - 2 * margin, height: h), to: dir.appendingPathComponent("bar-\(name)-rest.png"), wait: 0.4)
            let volume = try #require(frames.all[.right]?[2]), terminal = try #require(frames.all[.centre]?[1]), clock = try #require(frames.all[.centre]?[2])
            let room = volume.width + max(0, (frames.all[.right]?[3]?.minX ?? volume.maxX) - volume.maxX)
            let piece = BarDrag.Piece(screen: "", items: [.kind(.volume)], side: .right, slot: 2, group: nil, member: nil, frame: volume, room: room)
            drag = BarDrag(rendering: piece, dx: (terminal.maxX + clock.minX) / 2 - volume.midX, target: .side(.centre, 2))
            let view = strip().styled(.topBar, look: look)
                .frame(width: BarLookRenders.width - 2 * margin, height: h)
                .padding(.horizontal, margin).padding(.top, top).padding(.bottom, 10)
                .frame(width: BarLookRenders.width, alignment: .topLeading)
                .background { DesktopControlsRenders.Wallpaper(image: draw.wall) }
                .clipped()
            try writeRender(draw.compare("Drag to rearrange · \(name)", [("Volume dragged from the right into the centre, before the clock", AnyView(view))]),
                            to: dir.appendingPathComponent("bar-\(name)-mid-drag.png"), wait: 0.4)
        }
    }
}
}
#endif
