import Foundation

/// Launch at login (story 40, card agent-bo-95422770): what the setting asks of the login item, given its status.
/// SMAppService's statuses, mirrored so the decision is testable without touching the real login items.
public enum LaunchAtLogin {
    public enum Status: Sendable { case notRegistered, enabled, requiresApproval, notFound }
    public enum Step: Sendable { case register, unregister }

    /// Nil when the login item already does what the setting says; registered but waiting for approval in System
    /// Settings counts as on.
    public static func step(wanted: Bool, status: Status) -> Step? {
        switch (wanted, status) {
        case (true, .notRegistered), (true, .notFound): .register
        case (false, .enabled), (false, .requiresApproval): .unregister
        default: nil
        }
    }

    /// Whether this Pilot may register or unregister the login item at all. SMAppService.mainApp registers whatever is
    /// running, and a debug run from a worktree slot (a thread's E2E or sandbox run, its home moved with
    /// CFFIXED_USER_HOME, so the setting reads its default, on) registered its bare binary: macOS opened each in Terminal
    /// at the next login (2026-11-16). Only a release Pilot.app bundle, run in the real home and outside a test, may.
    public static func owns(bundlePath: String, debugBuild: Bool, environment: [String: String],
                            testRun: Bool = isTestRun) -> Bool {
        bundlePath.hasSuffix(".app") && !debugBuild && environment["CFFIXED_USER_HOME"] == nil && !testRun
    }
}
