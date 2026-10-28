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
}
