import Foundation
import PilotCore

extension SettingsSchema {
    /// The Widgets page's Snap to grid: on puts every desktop widget on the grid at once (WidgetSnap).
    func registerWidgets(_ snap: WidgetSnap) {
        register([
            .bool(WidgetSnap.key, "Snap to grid: desktop widgets move and resize a whole cell at a time, so their edges and gaps line up", page: "widgets",
                  standard: true, read: { snap.on }, write: { snap.on = $0 }),
        ])
    }
}
