import Foundation
import Observation
import WebApps

/// Install › Web apps' Window top (Sven, Q355): what sits at the top of every web app's window. Kept in Pilot's defaults,
/// where each web app reads it at launch, and announced on a change, so open web apps change at once. A web app made
/// before this reads nothing until it is rebuilt.
@Observable @MainActor
final class WebAppWindow {
    static let shared = WebAppWindow()

    var top: WindowTop {
        didSet {
            guard top != oldValue else { return }
            defaults.set(top.rawValue, forKey: WindowTop.key)
            // Only the app's own change reaches Sven's web apps, never a test run's throwaway suite.
            if defaults.isApp { top.announce() }
        }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        top = defaults.string(forKey: WindowTop.key).flatMap(WindowTop.init) ?? .initial
    }
}
