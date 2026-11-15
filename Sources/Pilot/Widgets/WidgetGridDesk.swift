import AppKit
import Observation
import PilotCore
import SwiftUI

/// Snap to grid, on the Widgets page (Sven, 2026-11-15), on by default: desktop widgets keep to whole cells of one
/// grid (Widget.Grid). Turned on, every placement already there is put on it (WidgetDesk.reload packs them).
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
            WidgetDesk.shared.reload()
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

    /// The desktop placements on their screens' grids, each screen's packed together so none overlap while there is
    /// room, the ones already on it kept where they are (Widget.Grid.pack); Home's, and a screen not connected now's,
    /// as they were.
    static func snapped(_ all: [Widget.Placement]) -> [Widget.Placement] {
        var out = all
        let desk = all.indices.filter { !all[$0].onHome && screen(all[$0].screen)?.displayUUID != nil }
        for indices in Dictionary(grouping: desk, by: { screen(all[$0].screen)?.displayUUID ?? "" }).values {
            guard let display = screen(all[indices[0]].screen) else { continue }
            let full = flip(display.frame), grid = grid(on: display)
            for (i, cell) in zip(indices, grid.pack(indices.map { all[$0].frame(on: full) })) { out[i].land(on: grid.rect(cell), screen: full) }
        }
        return out
    }

    /// Where a grab lands if let go now: the grid of the screen under its middle, and the cells there. A move takes the
    /// free cells nearest its frame, clear of the other widgets on that screen; a resize the cells its edges are nearest,
    /// the corner it does not pull kept.
    func landing(_ frame: CGRect, of id: String, corner: (left: Bool, top: Bool)?) -> (screen: NSScreen, grid: Widget.Grid, cell: Widget.Grid.Cell)? {
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { Self.flip($0.frame).contains(middle) }) ?? panels[id]?.screen ?? NSScreen.main else { return nil }
        let grid = Self.grid(on: screen)
        if let corner { return (screen, grid, grid.cell(pulled: frame, left: corner.left, top: corner.top)) }
        let full = Self.flip(screen.frame), uuid = screen.displayUUID
        let others = placements.filter { $0.id != id && !$0.onHome && Self.screen($0.screen)?.displayUUID == uuid }
            .map { grid.cell(nearest: $0.frame(on: full)) }
        return (screen, grid, grid.free(grid.cell(nearest: frame), avoiding: others))
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
        guard !placement.onHome, let screen = Self.screen(placement.screen) else { return [:] }
        let grid = Self.grid(on: screen), frame = placement.frame(on: Self.flip(screen.frame))
        return ["cell": .string(grid.cell(nearest: frame).line), "onGrid": .bool(grid.holds(frame))]
    }
}

extension Widget.Placement {
    /// On `rect` of a screen whose frame is `screen`, its size too.
    mutating func land(on rect: CGRect, screen: CGRect) {
        move(to: rect, on: screen)
        (width, height) = (rect.width, rect.height)
    }
}

/// The faint grid a Hyper+drag shows while Snap to grid is on: one panel over the screen under the widget, below the
/// widgets, taking no clicks, made at the first grab and only ordered out after.
@MainActor
final class WidgetGridOverlay {
    private var panel: NSPanel?
    private let model = WidgetGridModel()

    /// Shown, or moved to `screen`, with `landing` lit.
    func show(_ grid: Widget.Grid, on screen: NSScreen, landing: CGRect, below widget: NSWindow?) {
        let full = WidgetDesk.flip(screen.frame)
        (model.grid, model.screen, model.landing) = (grid, full, landing)
        let panel = panel ?? make()
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        guard !panel.isVisible else { return }
        if let widget { panel.order(.below, relativeTo: widget.windowNumber) } else { panel.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let made = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        made.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        made.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        (made.isOpaque, made.backgroundColor, made.hasShadow, made.ignoresMouseEvents) = (false, .clear, false, true)
        (made.isReleasedWhenClosed, made.hidesOnDeactivate, made.animationBehavior) = (false, false, .none)
        made.contentView = NSHostingView(rootView: WidgetGridView(model: model))
        panel = made
        return made
    }
}

@MainActor
@Observable
final class WidgetGridModel {
    var grid = Widget.Grid(area: .zero)
    /// The screen's frame, top-left, which the view draws from.
    var screen = CGRect.zero
    var landing: CGRect?
}

/// Every cell as a faint outline, and the cells a drop takes now a little brighter.
struct WidgetGridView: View {
    let model: WidgetGridModel

    var body: some View {
        Canvas { context, _ in
            let grid = model.grid, origin = model.screen.origin
            let local = { (rect: CGRect) in rect.offsetBy(dx: -origin.x, dy: -origin.y) }
            for y in 0..<grid.rows {
                for x in 0..<grid.columns {
                    let cell = Path(roundedRect: local(grid.rect(.init(x: x, y: y, w: 1, h: 1))), cornerRadius: 6)
                    context.fill(cell, with: .color(.white.opacity(0.025)))
                    context.stroke(cell, with: .color(.white.opacity(0.09)), lineWidth: 1)
                }
            }
            if let landing = model.landing {
                let lit = Path(roundedRect: local(landing), cornerRadius: 18)
                context.fill(lit, with: .color(.white.opacity(0.14)))
                context.stroke(lit, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
        .allowsHitTesting(false)
    }
}
