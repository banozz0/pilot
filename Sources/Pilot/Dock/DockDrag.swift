import AppKit
import Observation
import PilotCore
import SwiftUI

/// Drag to rearrange in the dock (spec drag-reorder; Sven, 2026-11-14): an app to a new place in its own run (the pins
/// or the running apps, never before Finder), a widget to a place on either side of the apps. The window's left button
/// drives it (TopBarPanel.drag); the others slide apart by offsets alone, so the pill keeps its width and its window
/// never refits mid-drag, and nothing is saved until the drop, through the moves `pilot dock move` makes.
@Observable @MainActor
final class DockDrag: PanelDrag {
    enum Piece: Equatable {
        case app(key: String, from: Int)
        case widget(DockSlot)
    }

    /// The pill as last drawn at rest, in the box's space (DockPill.space, the host's own): the icons' row, one icon's
    /// place (icon and gap), whether the row scrolls, the apps in order, each widget's frame, the widgets' gap. Reported
    /// by the views while nothing is dragged and read at a press, so a report never redraws the pill.
    @ObservationIgnored var row: CGRect = .zero
    @ObservationIgnored var slot: CGFloat = 0
    @ObservationIgnored var scrolls = false
    @ObservationIgnored var apps: [DockApp] = []
    @ObservationIgnored var frames: [DockSlot: CGRect] = [:]
    @ObservationIgnored var widgetGap: CGFloat = 0
    @ObservationIgnored weak var host: NSView?
    @ObservationIgnored weak var dock: DockController?

    /// The piece being dragged and how far along; nil at rest.
    private(set) var piece: Piece?
    private(set) var dx: CGFloat = 0
    /// What a press picked, before it moves far enough to be a drag.
    @ObservationIgnored private var press: (piece: Piece, x: CGFloat)?
    /// The rest geometry as the drag began.
    @ObservationIgnored private var start: (left: [DockSlot], right: [DockSlot])?

    init(dock: DockController? = nil) { self.dock = dock }

    /// A render's mid-drag state (DragRenders): `piece` dragged `dx` along the pill drawn with `apps` and `widgets`.
    init(rendering piece: Piece, dx: CGFloat, apps: [DockApp], row: CGRect, slot: CGFloat, left: [DockSlot] = [], right: [DockSlot] = [],
         frames: [DockSlot: CGRect] = [:], widgetGap: CGFloat = 0) {
        (self.apps, self.row, self.slot, self.frames, self.widgetGap) = (apps, row, slot, frames, widgetGap)
        (self.piece, self.dx, start) = (piece, dx, (left, right))
    }

    var dragging: Bool { piece != nil }

    /// The side the dragged widget began on; nil while no widget is dragged.
    var widgetSide: TopBarSide? {
        guard case .widget(let widget) = piece, let start else { return nil }
        return start.left.contains(widget) ? .left : .right
    }

    // MARK: The window's press

    func pressed(at point: CGPoint) -> Bool {
        press = nil
        if !scrolls, slot > 0, row.contains(point), !apps.isEmpty {
            let i = min(Int((point.x - row.minX) / slot), apps.count - 1)
            if DockSettings.reach(of: apps[i].key, in: apps) != nil { press = (.app(key: apps[i].key, from: i), point.x) }
        } else if let hit = frames.first(where: { $0.value.contains(point) }) {
            press = (.widget(hit.key), point.x)
        }
        return press != nil
    }

    func moved(to point: CGPoint) {
        guard let press else { return }
        if piece == nil {
            guard let settings = dock?.settings else { return }
            start = (settings.widgets(on: .left), settings.widgets(on: .right))
            piece = press.piece
            BarPanel.shared.close()
        }
        dx = point.x - press.x
    }

    /// The move and the gap closing in one animation: each icon and widget, known by its own id, slides from where the
    /// drag drew it to its new place.
    func released(at point: CGPoint) {
        let app = appTarget, widget = widgetTarget
        withAnimation(.spring(duration: 0.25, bounce: 0)) {
            switch piece {
            case .app(let key, _)?: if let app { dock?.settings.moveApp(key, to: app, among: apps) }
            case .widget(let slot)?: if let widget { dock?.settings.place(slot, on: widget.side, at: widget.index) }
            case nil: break
            }
            (piece, dx) = (nil, 0)
        }
        (press, start) = (nil, nil)
    }

    // MARK: Where it lands, and the gap

    /// The dragged app's place now.
    var appTarget: Int? {
        guard case .app(let key, let from) = piece, let reach = DockSettings.reach(of: key, in: apps) else { return nil }
        return DragGap.place(from: from, dx: Double(dx), slot: Double(slot), reach: reach)
    }

    /// The dragged widget's side and place there now: left of the apps' middle the left, else the right, before the
    /// first of that side's others whose middle is right of the pointer.
    var widgetTarget: (side: TopBarSide, index: Int)? {
        guard case .widget(let widget) = piece, let start, let frame = frames[widget] else { return nil }
        let x = frame.midX + dx, side: TopBarSide = x < row.midX ? .left : .right
        let others = (side == .left ? start.left : start.right).filter { $0 != widget }
        return (side, others.filter { (frames[$0]?.midX ?? 0) < x }.count)
    }

    /// The offset of the app at `index` in the row.
    func offset(app index: Int) -> CGFloat {
        guard case .app(_, let from) = piece else { return 0 }
        if index == from { return dx }
        let to = appTarget ?? from
        return CGFloat(DragGap.shift(index < from ? index : index - 1, from: from, to: to, width: Double(slot)))
    }

    /// The offset of a widget, or of the apps with their hairlines (nil): every piece between the dragged widget's old
    /// place and its new one along the pill slides by its width, so one crossing the apps carries them too.
    func offset(widget: DockSlot?) -> CGFloat {
        guard case .widget(let dragged) = piece, let start, let to = widgetTarget, let frame = frames[dragged] else { return 0 }
        if widget == dragged { return dx }
        // The pill's pieces without the dragged one: the left widgets, the apps, the right widgets.
        let left = start.left.filter { $0 != dragged }, right = start.right.filter { $0 != dragged }
        let from = start.left.firstIndex(of: dragged) ?? left.count + 1 + (start.right.firstIndex(of: dragged) ?? 0)
        let target = to.side == .left ? to.index : left.count + 1 + to.index
        var k = left.count
        if let widget {
            guard let at = left.firstIndex(of: widget) ?? right.firstIndex(of: widget).map({ left.count + 1 + $0 }) else { return 0 }
            k = at
        }
        return CGFloat(DragGap.shift(k, from: from, to: target, width: Double(frame.width + widgetGap)))
    }
}
