import AppKit
import Observation
import OSLog
import PilotCore
import SwiftUI

private let gridLog = Logger(subsystem: "dev.banozz.pilot", category: "widgets")

/// Snap to grid, on the Widgets page (Sven, 2026-11-15), on by default: desktop widgets keep to whole cells of one
/// grid (Widget.Grid). Turned on, every placement already there is put on it (WidgetDesk.placed packs them).
@MainActor
@Observable
final class WidgetSnap {
    static let shared = WidgetSnap()
    static let key = "widgets.snapToGrid"
    @ObservationIgnored private let defaults: UserDefaults

    var on: Bool {
        didSet {
            guard on != oldValue else { return }
            defaults.set(on, forKey: Self.key)
            // The placements go on the grid now, and the page shows where they went.
            if on { WidgetDesk.shared.snapAll() }
            WidgetsPageModel.shared.reload()
        }
    }

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        on = defaults.object(forKey: Self.key) as? Bool ?? true
    }
}

extension WidgetDesk {
    /// A screen's room for widgets, top-left: its frame less, at each edge, the larger of macOS's inset (menu bar, Dock)
    /// and Pilot's own (the top bar above, the dock below), as the tiler keeps them clear.
    static func room(on screen: NSScreen) -> CGRect {
        let frame = flip(screen.frame), visible = flip(screen.visibleFrame)
        let block = Engine.shared?.pilotBlock.block, name = screen.localizedName
        let bar = Double(block?.topBar.first { $0.monitor == name }?.height ?? 0)
        let dock = Double(block?.dock.first { $0.monitor == name }?.height ?? 0)
        let top = max(visible.minY - frame.minY, bar), bottom = max(frame.maxY - visible.maxY, dock)
        return CGRect(x: visible.minX, y: frame.minY + top, width: visible.width, height: max(0, frame.height - top - bottom))
    }

    static func grid(on screen: NSScreen) -> Widget.Grid { Widget.Grid(area: room(on: screen)) }

    /// What a writer saves: the placements on the grid while Snap to grid is on (snapped), else as given. Every save of
    /// a placement's place goes through here (`pilot add|remove widgets`, the Widgets page), so a new one lands on free
    /// cells and nothing is written twice.
    static func placed(_ all: [Widget.Placement]) -> [Widget.Placement] { WidgetSnap.shared.on ? snapped(all) : all }

    /// Snap to grid turned on, or Pilot's start with it on: the placements file put on the grid, if it is not already,
    /// then read again.
    func snapAll() {
        guard let current = store.readPlacements() else { return }
        let snapped = Self.placed(current)
        if snapped != current {
            do { try store.save(snapped) } catch { return gridLog.error("widgets: grid placement not saved: \(error.localizedDescription, privacy: .public)") }
        }
        reload()
    }

    /// The desktop placements on their screens' grids, each screen's packed together so none overlap while there is
    /// room, the ones already on it kept where they are (Widget.Grid.pack); Home's, a screen not connected now's, and
    /// one on the main screen only by the fallback (its display unknown: the main one's grid saved into it would hold it
    /// there once its display is found), as they were.
    static func snapped(_ all: [Widget.Placement]) -> [Widget.Placement] {
        var out = all
        let live = LiveDisplay.screens
        let desk = all.indices.filter { !all[$0].onHome && !all[$0].onFallback(in: live) && screen(of: all[$0], in: live)?.displayUUID != nil }
        for indices in Dictionary(grouping: desk, by: { screen(of: all[$0], in: live)?.displayUUID ?? "" }).values {
            guard let display = screen(of: all[indices[0]], in: live) else { continue }
            let full = flip(display.frame), grid = grid(on: display)
            for (i, cell) in zip(indices, grid.pack(indices.map { all[$0].frame(on: full) })) { out[i].land(on: grid.rect(cell), screen: full) }
        }
        return out
    }

    /// `pilot status --part widgets`'s grid: whether it is on, and each screen's room, cell, gap and cells across and down.
    func gridStatus() -> JSONValue {
        let screens: [JSONValue] = NSScreen.screens.compactMap { screen in
            guard let uuid = screen.displayUUID else { return nil }
            let grid = Self.grid(on: screen), room = grid.area
            return .object(["screen": .string(uuid), "room": .array([room.minX, room.minY, room.width, room.height].map(JSONValue.number)),
                            "origin": .array([grid.origin.x, grid.origin.y].map(JSONValue.number)),
                            "columns": .number(Double(grid.columns)), "rows": .number(Double(grid.rows))])
        }
        return .object(["snapToGrid": .bool(WidgetSnap.shared.on), "cell": .number(Widget.Grid.cell), "gap": .number(Widget.Grid.gap),
                        "screens": .array(screens)])
    }

    /// A placement's cells on its screen's grid, and whether its frame is exactly them, for status.
    func gridRow(_ placement: Widget.Placement) -> [String: JSONValue] {
        guard !placement.onHome, let screen = Self.screen(of: placement) else { return [:] }
        let grid = Self.grid(on: screen), frame = placement.frame(on: Self.flip(screen.frame))
        return ["cell": .string(grid.cell(nearest: frame).line), "onGrid": .bool(grid.holds(frame))]
    }
}

/// A Hyper+drag on the grid while Snap to grid is on: where it lands, and the faint grid that shows it, one panel over
/// the screen under the widget at the desktop icons' level (below every widget), taking no clicks. The screen's grid and
/// the other widgets' cells are read once per screen the grab crosses, not each frame; the panel is closed at the drop.
@MainActor
final class WidgetGridDrag {
    private var panel: NSPanel?
    private let model = WidgetGridModel()
    private var held: (screen: NSScreen, grid: Widget.Grid, others: [Widget.Grid.Cell])?
    /// Where the grab lands if let go now, top-left: the drop puts the widget there.
    private(set) var landing: CGRect?

    /// The grab's frame now: a move takes the free cells nearest it, clear of the other widgets on the screen under its
    /// middle; a resize the cells its edges are nearest, the corner it does not pull kept, cut back short of a neighbour
    /// (or to where it started, `start`).
    func update(_ frame: CGRect, of id: String, corner: (left: Bool, top: Bool)?, start: CGRect, among placements: [Widget.Placement]) {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        if held.map({ !WidgetDesk.flip($0.screen.frame).contains(middle) }) ?? true {
            guard let screen = NSScreen.screens.first(where: { WidgetDesk.flip($0.frame).contains(middle) }) ?? held?.screen ?? NSScreen.main else { return }
            let grid = WidgetDesk.grid(on: screen), full = WidgetDesk.flip(screen.frame), uuid = screen.displayUUID
            let others = placements.filter { $0.id != id && !$0.onHome && WidgetDesk.screen(of: $0)?.displayUUID == uuid }
                .map { grid.cell(nearest: $0.frame(on: full)) }
            held = (screen, grid, others)
            (model.grid, model.origin) = (grid, full.origin)
        }
        guard let (screen, grid, others) = held else { return }
        let cell = corner.map { grid.clear(grid.cell(pulled: frame, left: $0.left, top: $0.top), left: $0.left, top: $0.top, avoiding: others,
                                           fallback: grid.cell(nearest: start)) } ?? grid.free(grid.cell(nearest: frame), avoiding: others)
        let rect = grid.rect(cell)
        if landing != rect { landing = rect; model.landing = rect.offsetBy(dx: -model.origin.x, dy: -model.origin.y) }
        let panel = panel ?? make()
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// The grab ended: the panel closed (its screen-sized layers freed), nothing kept for the next grab.
    func end() {
        panel?.close()
        (panel, held, landing, model.landing) = (nil, nil, nil, nil)
    }

    private func make() -> NSPanel {
        let made = WindowBorderPanel.overlay()
        made.level = NSWindow.Level(rawValue: DesktopIcons.level)
        made.animationBehavior = .none
        made.contentView = NSHostingView(rootView: WidgetGridView(model: model))
        panel = made
        return made
    }
}

@MainActor
@Observable
final class WidgetGridModel {
    var grid = Widget.Grid(area: .zero)
    /// The screen's top left, which the cells are drawn from.
    var origin = CGPoint.zero
    /// The cells a drop takes now, in the panel's own coordinates.
    var landing: CGRect?
}

/// Every cell as a faint outline, drawn again only when the grid changes, and the cells a drop takes now a little
/// brighter, a shape moved over it.
struct WidgetGridView: View {
    let model: WidgetGridModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Cells(model: model)
            if let landing = model.landing {
                RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .frame(width: landing.width, height: landing.height)
                    .offset(x: landing.minX, y: landing.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private struct Cells: View {
        let model: WidgetGridModel
        var body: some View {
            Canvas { context, _ in
                let grid = model.grid, origin = model.origin
                var cells = Path()
                for y in 0..<grid.rows {
                    for x in 0..<grid.columns {
                        cells.addRoundedRect(in: grid.rect(.init(x: x, y: y, w: 1, h: 1)).offsetBy(dx: -origin.x, dy: -origin.y), cornerSize: CGSize(width: 6, height: 6))
                    }
                }
                context.fill(cells, with: .color(.white.opacity(0.025)))
                context.stroke(cells, with: .color(.white.opacity(0.09)), lineWidth: 1)
            }
        }
    }
}
