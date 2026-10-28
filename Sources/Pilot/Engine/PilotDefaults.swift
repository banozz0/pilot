import Foundation
import PilotCore

extension UserDefaults {
    /// Where a Pilot store saves its settings: the app's defaults, and in a test run a fresh throwaway suite per store, so a
    /// test never leaves a setting in the runner's shared defaults for the next run (cards agent-bo-95423261 and
    /// agent-bo-95423301). A render run that moved the home (CFFIXED_USER_HOME) keeps .standard: it lives in that home, and
    /// the renders seed it on purpose. Take it once per store.
    static func pilot(testRun: Bool = isIsolatedTestRun) -> UserDefaults {
        testRun ? UserDefaults(suiteName: NSTemporaryDirectory() + "dev.banozz.pilot.test.\(UUID().uuidString)")! : .standard
    }

    /// The app's own defaults, not a test run's throwaway suite.
    var isApp: Bool { self === Self.standard }
}
