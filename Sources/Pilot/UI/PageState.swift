import PilotCore
import SwiftUI

/// A page's state in a word or two, under its name wherever the window lists pages (direction 1's page list):
/// "56 on Hyper · 0 clashes", "Running", "Top bar off". Read from what Pilot already keeps current, never sampled for it;
/// nil for a page with nothing worth saying.
struct PageState: Equatable {
    let text: String
    /// On, running or fine: the dot in the accent; else in the quiet ink.
    let on: Bool

    @MainActor static func of(_ page: AppPage, engine: Engine, look: Look = .shared, clashes: Int) -> PageState? {
        switch page {
        case .binds:
            let hyper = engine.binds.store.binds.keys.filter { $0.hyper && $0.modifiers.isEmpty }.count
            return PageState(text: "\(hyper) on Hyper · \(clashes == 1 ? "1 clash" : "\(clashes) clashes")", on: clashes == 0)
        case .workspaces:
            let tiler = engine.observers.tiler
            guard tiler.isAnswering else { return nil }
            return PageState(text: "\(tiler.occupied.count) in use" + (tiler.focused.map { " · on \($0)" } ?? ""), on: true)
        case .tiling:
            let on = engine.observers.tiler.isAnswering
            return PageState(text: on ? "Running" : "Stopped", on: on)
        case .menuBar:
            let on = engine.topBar.isOn
            return PageState(text: on ? "Top bar on" : "Top bar off", on: on)
        case .look: return PageState(text: "\(look.style.title) · \(look.theme.name)", on: true)
        case .general:
            let on = engine.hyperSwitch.isOn
            return PageState(text: "Hyper \(on ? "on" : "off") · \(engine.settings.layerKeys.label)", on: on)
        default: return nil
        }
    }
}
