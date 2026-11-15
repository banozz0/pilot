#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Snap to grid mid-drag (Sven, 2026-11-15): a 1440 × 900 desk under a 32-point top bar, three widgets on whole cells, a
/// fourth dragged off the grid with the cells it would land on lit, drawn by the overlay a Hyper+drag shows
/// (WidgetGridView) and the real tiles. Opt-in, in a moved home:
/// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter WidgetGridRenders`
extension SharedLook {
@MainActor
@Suite("Widget grid renders")
struct WidgetGridRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The desk mid-drag with the grid showing", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let dir = try ClockRenders.dir("widget-grid")
        testApp()
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        (look.themeID, look.glass) = ("tokyo-night", false)

        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900), bar = 32.0
        let grid = Widget.Grid(area: CGRect(x: 0, y: bar, width: screen.width, height: screen.height - bar))
        let ids = [ReadyWidgets.clock, ReadyWidgets.thisMac, ReadyWidgets.note, ReadyWidgets.upkeep]
        let widgets = try ids.map { try #require(ReadyWidgets.widget($0)) }
        // Placed where a free hand left them, then packed as Snap to grid's first pass packs them.
        let loose = [CGRect(x: 30, y: 60, width: 240, height: 160), CGRect(x: 250, y: 70, width: 260, height: 220),
                     CGRect(x: 40, y: 250, width: 240, height: 160)]
        let cells = grid.pack(loose)
        let placed = cells.map(grid.rect)
        for (a, b) in zip(cells, cells.dropFirst()) { #expect(!a.overlaps(b)) }
        // The fourth, mid-drag, half a cell off the grid: the cells it lands on are the free ones nearest.
        let dragged = CGRect(x: 700, y: 330, width: 260, height: 160)
        let landing = grid.free(grid.cell(nearest: dragged), avoiding: cells)
        print("GRID \(grid.columns)x\(grid.rows) at \(grid.origin); placed \(cells.map(\.line)); lands \(landing.line)")

        let model = WidgetGridModel()
        (model.grid, model.origin, model.landing) = (grid, screen.origin, grid.rect(landing))
        func tile(_ widget: Widget, _ frame: CGRect, lifted: Bool = false) -> some View {
            let tile = WidgetTileModel()
            tile.title = widget.title; tile.icon = widget.icon; tile.blocks = WidgetRenders.blocks(widget); tile.buttons = widget.buttons
            return WidgetTile(model: tile, look: look).styled(.hud).pilotTheme(look: look)
                .frame(width: frame.width, height: frame.height)
                .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: 18, y: 8)
                .position(x: frame.midX, y: frame.midY)
        }
        let ground = LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.24), Color(red: 0.30, green: 0.20, blue: 0.42),
                                             Color(red: 0.12, green: 0.30, blue: 0.44)], startPoint: .topLeading, endPoint: .bottomTrailing)
        let desk = ZStack(alignment: .topLeading) {
            ground
            Rectangle().fill(.black.opacity(0.55)).frame(height: bar).frame(maxHeight: .infinity, alignment: .top)
            WidgetGridView(model: model)
            ForEach(Array(zip(widgets.prefix(3), placed).enumerated()), id: \.offset) { _, pair in tile(pair.0, pair.1) }
            tile(widgets[3], dragged, lifted: true)
        }
        .frame(width: screen.width, height: screen.height)
        try writeRender(desk, to: dir.appending(path: "desk-mid-drag.png"), wait: 1.0)
    }
}
}
#endif
