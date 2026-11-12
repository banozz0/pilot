import Foundation

/// Any test run, a render run that moved the home (CFFIXED_USER_HOME) too.
public let isTestRun = NSClassFromString("XCTestCase") != nil

/// A test run, unless it is a render run that moved the home (CFFIXED_USER_HOME): its stores keep to throwaway places.
public let isIsolatedTestRun = isTestRun && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil

/// Pilot's own folder, where every store keeps its file: `~/Library/Application Support/Pilot`, and in a test run a
/// throwaway folder of the run's own, so no test reads or rewrites Sven's binds, history, token or extensions (Home
/// settles rewrote binds.json on every run, 2026-10-10). A render run keeps the real path: it lives in the moved home.
public enum PilotFolder {
    public static let support = isIsolatedTestRun
        ? FileManager.default.temporaryDirectory.appending(path: "dev.banozz.pilot.test.\(UUID().uuidString)", directoryHint: .isDirectory)
        : URL.applicationSupportDirectory.appending(path: "Pilot", directoryHint: .isDirectory)

    /// The home Pilot reads others' files under: the real one, and in a test run a home inside the run's throwaway
    /// folder, so a sandbox host or a test never reaches Sven's configs or ~/Library.
    public static let home = isIsolatedTestRun ? support.appending(path: "home", directoryHint: .isDirectory)
        : URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
}
