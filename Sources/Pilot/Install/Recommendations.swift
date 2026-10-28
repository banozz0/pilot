import Foundation
import Observation

/// Recommend apps (card agent-bo-95423241, Sven approved 2026-10-08; C5, 2026-10-09: one switch, named so, in Defaults,
/// onboarding's Extras and on Install itself; Sven 2026-10-09: the switch is the whole catalogue of quick installs): on
/// by default; off, Pilot offers nothing to install of its own accord. Gone: Install's catalogue on the page and in the
/// menu (Install is its search alone), and Update's install mas row. Kept, being asked for or needed: Install's search, and Clean's Install Mole,
/// since Clean cannot run without Mole. Its own store, as Look is, so pages that render
/// without an engine read it.
@Observable @MainActor
final class Recommendations {
    static let shared = Recommendations()

    var show: Bool { didSet { defaults.set(show, forKey: Self.key) } }
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "recommendations.show"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        show = defaults.object(forKey: Self.key) as? Bool ?? true
    }
}
