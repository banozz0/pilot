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

    /// The pill as last drawn, in the box's space (DockPill.space, the host's own): each icon's frame by its app's id,
    /// the icons' row, one icon's place at rest (icon and gap), the apps in order, each widget's frame, the widgets' gap.
    /// Reported by the views as laid out (a drag's offsets come after the reports, so they never feed back), and read
    /// at a press and each move, so a report never redraws the pill. The row is reported only at rest.
    @ObservationIgnored var icons: [String: CGRect] = [:]
    @ObservationIgnored var row: CGRect = .zero
    @ObservationIgnored var slot: CGFloat = 0
    @ObservationIgnored var apps: [DockApp] = []
    @ObservationIgnored var frames: [DockSlot: CGRect] = [:]
    @ObservationIgnored var widgetGap: CGFloat = 0
    @ObservationIgnored weak var host: NSView?
    @ObservationIgnored weak var dock: DockController?

    /// Where a widget lands: a side of the apps and its place among that side's others.
    struct Landing: Equatable {
        let side: TopBarSide
        let index: Int
    }

    /// The piece being dragged, how far along, and where it would land now (set only when that changes, so only the
    /// dragged piece follows each move); nil at rest.
    private(set) var piece: Piece?
    private(set) var dx: CGFloat = 0
    private(set) var appLanding: Int?
    private(set) var widgetLanding: Landing?
    /// What a press picked, and where on it: a widget is held where it was grabbed, an icon by its middle.
    @ObservationIgnored private var press: (piece: Piece, grab: CGFloat)?
    /// As the drag began: the widgets on each side, and the places the dragged app may go.
    @ObservationIgnored private var start: (left: [DockSlot], right: [DockSlot])?
    @ObservationIgnored private var reach: ClosedRange<Int>?

    /// A render's mid-drag state (DragRenders): `piece` dragged `dx` along a pill whose widgets are `left` and `right`,
    /// its geometry as the pill last reported it.
    func stage(_ piece: Piece, dx: CGFloat, left: [DockSlot] = [], right: [DockSlot] = []) {
        (self.piece, start) = (piece, (left, right))
        if case .app(let key, _) = piece { reach = DockSettings.reach(of: key, in: apps) }
        follow(dx)
    }

    var dragging: Bool { piece != nil }

    /// The side the dragged widget began on; nil while no widget is dragged.
    var widgetSide: TopBarSide? {
        guard case .widget(let widget) = piece, let start else { return nil }
        return start.left.contains(widget) ? .left : .right
    }

    // MARK: The window's press

    /// An icon under the pointer, by the frame it is drawn at (magnified or not), else a widget.
    func pressed(at point: CGPoint) -> Bool {
        press = nil
        if let i = apps.firstIndex(where: { icons[$0.dragID]?.contains(point) == true }) {
            if DockSettings.reach(of: apps[i].key, in: apps) != nil { press = (.app(key: apps[i].key, from: i), 0) }
        } else if let hit = frames.first(where: { $0.value.contains(point) }) {
            press = (.widget(hit.key), point.x - hit.value.midX)
        }
        return press != nil
    }

    func moved(to point: CGPoint) {
        guard let press else { return }
        if piece == nil {
            guard let settings = dock?.settings else { return }
            start = (settings.widgets(on: .left), settings.widgets(on: .right))
            if case .app(let key, _) = press.piece { reach = DockSettings.reach(of: key, in: apps) }
            piece = press.piece
            BarPanel.shared.close()
        }
        // From the piece's middle as laid out now: once magnification pauses the icons shrink back to rest, and the
        // piece stays under the pointer.
        let middle: CGFloat? = switch press.piece {
        case .app(_, let from): apps.indices.contains(from) ? icons[apps[from].dragID]?.midX : nil
        case .widget(let widget): frames[widget]?.midX
        }
        if let middle { follow(point.x - press.grab - middle) }
    }

    /// The move and the gap closing in one animation: each icon and widget, known by its own id, slides from where the
    /// drag drew it to its new place.
    func released(at point: CGPoint) {
        withAnimation(DockDrag.settle) {
            switch piece {
            case .app(let key, _)?: if let appLanding { dock?.settings.moveApp(key, to: appLanding, among: apps) }
            case .widget(let slot)?: if let widgetLanding { dock?.settings.place(slot, on: widgetLanding.side, at: widgetLanding.index) }
            case nil: break
            }
            (piece, dx, appLanding, widgetLanding) = (nil, 0, nil, nil)
        }
        (press, start, reach) = (nil, nil, nil)
    }

    /// How a drop settles, the dock's and the bar's.
    static let settle = Animation.spring(duration: 0.25, bounce: 0)

    // MARK: Where it lands, and the gap

    /// `dx` along, and where the piece lands there: an app `dx` along places `slot` wide, held to its run; a widget left
    /// of the apps' middle on the left, else the right, before the first of that side's others whose middle is right of it.
    private func follow(_ dx: CGFloat) {
        self.dx = dx
        switch piece {
        case .app(_, let from)?:
            let to = reach.map { DragGap.place(from: from, dx: Double(dx), slot: Double(slot), reach: $0) }
            if to != appLanding { appLanding = to }
        case .widget(let widget)?:
            guard let start, let frame = frames[widget] else { break }
            let x = frame.midX + dx, side: TopBarSide = x < row.midX ? .left : .right
            let others = (side == .left ? start.left : start.right).filter { $0 != widget }
            let to = Landing(side: side, index: others.filter { (frames[$0]?.midX ?? 0) < x }.count)
            if to != widgetLanding { widgetLanding = to }
        case nil: break
        }
    }

    /// Whether the app at `index` is the one dragged, drawn over the rest.
    func lifts(app index: Int) -> Bool {
        if case .app(_, let from)? = piece { return from == index }
        return false
    }

    /// The offset of the app at `index` in a row of places `slot` wide, as the pill draws it now.
    func offset(app index: Int, slot: CGFloat) -> CGFloat {
        guard case .app(_, let from) = piece else { return 0 }
        if index == from { return dx }
        return CGFloat(DragGap.shift(.left, j: index, leaving: from, entering: appLanding ?? from, width: Double(slot)))
    }

    /// The offset of a widget, or of the apps with their hairlines (nil): every piece between the dragged widget's old
    /// place and its new one along the pill (the left widgets, the apps, the right widgets) slides by its width, so one
    /// crossing the apps carries them too.
    func offset(widget: DockSlot?) -> CGFloat {
        guard case .widget(let dragged) = piece, let start, let to = widgetLanding, let frame = frames[dragged] else { return 0 }
        if widget == dragged { return dx }
        let pill: [DockSlot?] = start.left + [nil] + start.right
        guard let j = pill.firstIndex(of: widget), let from = pill.firstIndex(of: dragged) else { return 0 }
        let target = to.side == .left ? to.index : start.left.filter { $0 != dragged }.count + 1 + to.index
        return CGFloat(DragGap.shift(.left, j: j, leaving: from, entering: target, width: Double(frame.width + widgetGap)))
    }
}
