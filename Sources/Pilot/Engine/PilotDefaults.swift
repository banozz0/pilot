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

/// Pilot's first launch on this Mac (Sven, 2026-11-18 and 2026-11-19): a new install starts with only the launcher, the
/// key binds, Hyper, its cheat sheet and launch at login on; an install from before keeps every switch as it was.
@MainActor
enum Install {
    static let key = "install.new"

    /// Decided at its first read, early in the first launch: binds.json is written by every launch's first bind load and
    /// onboarding leaves its key, both later than this, so either one means Pilot ran here before. Saved at once, so every
    /// later launch reads the same.
    static let isNew: Bool = {
        // A test or render run is an install from before, the defaults its tests were written for; the sandbox host
        // (PILOT_SANDBOX) is a first launch, or an upgrade with PILOT_SANDBOX_PRIOR's binds.json.
        if isTestRun, ProcessInfo.processInfo.environment["PILOT_SANDBOX"] == nil { return false }
        let defaults = UserDefaults.pilot()
        if let saved = defaults.object(forKey: key) as? Bool { return saved }
        let new = !(Binds.ranBefore || defaults.object(forKey: OnboardingWindow.unfinishedKey) != nil)
        defaults.set(new, forKey: key)
        return new
    }()

    /// A switch that was on for everyone before: off for a new install, on for one from before, until it is set.
    static var startsOn: Bool { !isNew }
}
