import AppKit
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422949: the three notification keys are registered System actions with no default key (Hyper+comma
/// is My binds' focus display left); the Omarchy preset binds them. No action is run: that would press the real
/// Notification Center.
@MainActor
@Suite("Notification key actions")
struct NotificationKeysTests {
    @Test("Clear latest, clear all and open latest are registered, unbound by default")
    func registered() throws {
        var registry = ActionRegistry()
        SystemModule.register(into: &registry)
        for (id, label) in [("system.clearNotification", "Clear latest notification"),
                            ("system.clearAllNotifications", "Clear all notifications"),
                            ("system.openNotification", "Open latest notification")] {
            let action = try #require(registry.actions[id])
            #expect(action.label == label)
            #expect(action.defaultKey == nil)
        }
    }
}
