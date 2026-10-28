// Pilot's own tests for workspace pins (N7): AeroSpace's force-assignment fed from Pilot's MonitorPin, with a display
// matched by its id and main as the fallback while it is unplugged.
import AppKit
@testable import PilotCore
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct WorkspacePinTests {
        private static func display(_ name: String, id: String, x: Double) -> MonitorInfoImpl {
            let rect = Rect(topLeftX: x, topLeftY: 0, width: 1920, height: 1080)
            return MonitorInfoImpl(monitorAppKitNsScreenScreensId: 2, name: name, rect: rect, visibleRect: rect, isMain: false, displayId: id)
        }

        private let lg = display("LG ULTRAFINE", id: "B", x: 1920)
        /// The same model on the left: same name, another id.
        private let twin = display("LG ULTRAFINE", id: "C", x: -1920)

        private func plug(_ monitors: MonitorInfoImpl...) {
            unitTestScreen.withLock { $0.monitors = [testMonitorInfo] + monitors }
            gcMonitors()
        }

        private func pin(_ pins: [String: MonitorPin]) {
            config.workspaceToMonitorForceAssignment = TilerSettings(block: PilotBlock(), pins: pins).workspaceToMonitorForceAssignment
        }

        @Test func pinnedWorkspaceOpensOnItsDisplayById() {
            plug(twin, lg)
            pin(["3": .display(name: "LG ULTRAFINE", id: "B"), "1": .main])
            #expect(Workspace.get(byName: "3").workspaceMonitor.rect.topLeftCorner == lg.rect.topLeftCorner)
            #expect(Workspace.get(byName: "1").workspaceMonitor.isMain)
            #expect(Workspace.get(byName: "2").forceAssignedMonitor == nil)
        }

        /// Unplugged, the workspace opens on main; plugged back in, it goes back to its display.
        @Test func fallsBackToMainAndReturns() {
            plug(lg)
            pin(["3": .display(name: "LG ULTRAFINE", id: "B")])
            plug()
            #expect(Workspace.get(byName: "3").workspaceMonitor.isMain)
            #expect(Workspace.get(byName: "3").focusWorkspace())
            #expect(testMonitorInfo.activeWorkspace.name == "3")
            plug(lg)
            #expect(Workspace.get(byName: "3").workspaceMonitor.rect.topLeftCorner == lg.rect.topLeftCorner)
            #expect(testMonitorInfo.activeWorkspace.name != "3")
        }

        /// A pin set while its workspace shows on another monitor moves it there, and the monitor it left shows another.
        @Test func newPinMovesAShownWorkspace() {
            plug(lg)
            #expect(Workspace.get(byName: "3").focusWorkspace())
            #expect(testMonitorInfo.activeWorkspace.name == "3")
            pin(["3": .display(name: "LG ULTRAFINE", id: "B")])
            showPinnedWorkspacesOnTheirMonitors()
            #expect(lg.activeWorkspace.name == "3")
            #expect(testMonitorInfo.activeWorkspace.name != "3")
        }

        /// A pin carried over from AeroSpace's table is its monitor description, read as AeroSpace did, then main.
        @Test func pinsAsMonitorDescriptions() {
            #expect(TilerSettings.monitors(.main) == [.main])
            #expect(TilerSettings.monitors(.display(name: "LG ULTRAFINE", id: "B")) == [.displayId("B"), .main])
            #expect(TilerSettings.monitors(.display(name: "CU34G4Z", id: nil)) == [.pattern("CU34G4Z")!, .main])
        }
    }
}
