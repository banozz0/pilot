import AppKit
import PilotCore
import SwiftUI

/// A display the Widgets page's map draws (Sven, 2026-11-15, Q252 B): its frame and its room for widgets, top-left
/// coordinates as the desk keeps them.
struct WidgetsDisplay: Identifiable, Equatable {
    /// Its display UUID; a placement with none is the main display's.
    let uuid: String?
    let name: String
    let main: Bool
    let frame: CGRect
    /// Its frame less the top bar and the dock (WidgetDesk.room), where the grid sits.
    let room: CGRect
    /// Its EDID identity (LiveDisplay), which a placement matches before its UUID.
    var identity: String? = nil

    var id: String { uuid ?? "main" }

    /// Whether `placement` sits on this display among `displays` (the main one first), as the desk puts it
    /// (Widget.Placement.screenIndex).
    func holds(_ placement: Widget.Placement, among displays: [WidgetsDisplay]) -> Bool {
        guard !placement.onHome else { return false }
        let live = displays.map { LiveDisplay(uuid: $0.uuid, identity: $0.identity) }
        return placement.screenIndex(in: live).map { displays[$0].id == id } ?? false
    }

    /// The Mac's displays now, the main one first, as the desk reads them.
    @MainActor static func live() -> [WidgetsDisplay] {
        NSScreen.screens.enumerated().map { i, screen in
            WidgetsDisplay(uuid: screen.freshDisplayUUID, name: screen.localizedName, main: i == 0,
                           frame: WidgetDesk.flip(screen.frame), room: WidgetDesk.room(on: screen), identity: screen.displayIdentity)
        }
    }

    /// "3,440 × 1,440".
    var size: String { "\(Int(frame.width).formatted()) × \(Int(frame.height).formatted())" }
}

/// The desktop drawn small: the display at its own shape on the theme's wallpaper colours, the top bar and dock's room
/// shaded, the grid's cells while Snap to grid is on, and each widget where it sits; a click picks one.
struct WidgetsMap: View {
    @Environment(\.ink) private var ink
    let display: WidgetsDisplay
    let placements: [Widget.Placement]
    let widget: (String) -> Widget?
    let snap: Bool
    @Binding var selected: String?

    var body: some View {
        let frame = display.frame, room = display.room.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let full = CGRect(origin: .zero, size: frame.size)
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        GeometryReader { box in
            let s = box.size.width / max(frame.width, 1)
            ZStack(alignment: .topLeading) {
                WidgetPreview.ground(Look.shared.theme)
                // The top bar's and the dock's room, which no widget takes.
                Rectangle().fill(ink.surface.opacity(0.75)).frame(height: room.minY * s)
                Rectangle().fill(ink.surface.opacity(0.75)).frame(height: (full.maxY - room.maxY) * s)
                    .offset(y: room.maxY * s)
                if snap { cells(Widget.Grid(area: room), scale: s) }
                ForEach(placements, id: \.id) { placement in
                    let f = placement.frame(on: frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
                    tile(placement, picked: placement.id == selected)
                        .frame(width: max(f.width * s, 14), height: max(f.height * s, 14))
                        .offset(x: f.minX * s, y: f.minY * s)
                }
            }
            .frame(width: box.size.width, height: frame.height * s, alignment: .topLeading)
            .clipShape(shape)
            .overlay { shape.strokeBorder(ink.line2) }
        }
        .aspectRatio(frame.width / max(frame.height, 1), contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map of \(display.name)")
    }

    /// The grid's cells, faint, as the desk shows them while a widget is dragged.
    private func cells(_ grid: Widget.Grid, scale s: CGFloat) -> some View {
        Canvas { context, _ in
            for x in 0..<grid.columns {
                for y in 0..<grid.rows {
                    let r = grid.rect(.init(x: x, y: y, w: 1, h: 1))
                    context.fill(Path(roundedRect: CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s),
                                      cornerRadius: 1.5), with: .color(ink.text.opacity(0.08)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A widget on the map: its icon and name while there is room, its icon alone when small; the picked one ringed in
    /// the accent.
    private func tile(_ placement: Widget.Placement, picked: Bool) -> some View {
        let widget = widget(placement.widget)
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let title = widget?.title ?? placement.widget
        return Button { selected = placement.id } label: {
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(widget?.icon ?? "🧩").font(.system(size: 13))
                    Text(title).font(ink.ui(10.5, .semibold)).foregroundStyle(ink.text).lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text(widget?.icon ?? "🧩").font(.system(size: 11))
                    Text(title).font(ink.ui(10, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                }
                Text(widget?.icon ?? "🧩").font(.system(size: 11))
            }
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ink.raised.opacity(0.92), in: shape)
            .overlay { shape.strokeBorder(picked ? ink.accent : ink.line2, lineWidth: picked ? 2 : 1) }
            .contentShape(shape)
        }
        .buttonStyle(.kitPress)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// Home's widgets as a row of tiles: Home has no screen to draw, only its order (Edit Home sizes them).
struct WidgetsHomeTiles: View {
    @Environment(\.ink) private var ink
    let placements: [Widget.Placement]
    let widget: (String) -> Widget?
    @Binding var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if placements.isEmpty {
                Text("Nothing on Home yet. Add one from the list below.").font(ink.ui(12)).foregroundStyle(ink.text2)
                    .frame(maxWidth: .infinity, minHeight: 90).background(ink.well, in: RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous))
            } else {
                CardGrid(minimum: 200, spacing: 8, stretch: true) {
                    ForEach(placements, id: \.id) { placement in
                        let picked = placement.id == selected, shape = RoundedRectangle(cornerRadius: ink.radius(8), style: .continuous)
                        Button { selected = placement.id } label: {
                            HStack(spacing: 8) {
                                Text(widget(placement.widget)?.icon ?? "🧩").font(.system(size: 15))
                                Text(widget(placement.widget)?.title ?? placement.widget).font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 40)
                            .overlay { shape.strokeBorder(picked ? ink.accent : ink.line2, lineWidth: picked ? 2 : 1) }
                            .contentShape(shape)
                        }
                        .buttonStyle(.kitPress)
                        .accessibilityAddTraits(picked ? .isSelected : [])
                    }
                }
            }
            Text("Home shows them in this order; Edit Home on Home moves and sizes them.").font(ink.ui(11.5)).foregroundStyle(ink.text2)
        }
    }
}
