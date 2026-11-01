import AppKit
import PilotCore
import SwiftUI

/// A widget on Home, the first page of Pilot's window, drawn as on the desktop at its placement's height and its lane's width: its
/// blocks and buttons, its Trust to run card, or its page. It is fed, and its page runs, only while this tile is drawn in
/// the window on screen (WidgetDesk.drawnOnHome). Its right-click (HomeEdit's block menu) edits it or takes it off Home.
struct HomeWidgetBlock: View {
    let widget: HomeWidget
    let parts: HomeParts

    var body: some View {
        WidgetTile(model: widget.model) { WidgetDesk.shared.askTrust($0) }
            .overlay { if widget.model.page != nil { HomeWidgetPage(id: widget.id) } }
            .frame(maxWidth: .infinity)
            .frame(height: widget.placement.height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(widget.title)
            // Drawn while this tile is on screen, released when it goes or the window hides: one pair per tile, so a copy
            // (Edit Home's carry) ending never stops the tile still shown.
            .task(id: parts.onScreen) {
                guard parts.onScreen else { return }
                parts.sources.drawWidget(widget.id, true)
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                parts.sources.drawWidget(widget.id, false)
            }
    }
}

/// A Home widget's page, the desk's web view placed in Home's tile. Each tile drawing it is a host the desk keeps
/// (WidgetDesk.hostPage): Edit Home's carry draws a copy, which holds the page while it is carried and hands it back to
/// the tile still shown when it goes.
private struct HomeWidgetPage: NSViewRepresentable {
    let id: String

    final class Coordinator { let id: String; init(_ id: String) { self.id = id } }
    func makeCoordinator() -> Coordinator { Coordinator(id) }

    func makeNSView(context: Context) -> NSView {
        let ground = NSView()
        WidgetDesk.shared.hostPage(id, in: ground)
        return ground
    }

    func updateNSView(_ ground: NSView, context: Context) { WidgetDesk.shared.placePage(id) }

    static func dismantleNSView(_ ground: NSView, coordinator: Coordinator) { WidgetDesk.shared.unhostPage(coordinator.id, from: ground) }
}
