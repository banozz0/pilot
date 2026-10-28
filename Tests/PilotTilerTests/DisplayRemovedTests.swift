import AppKit
@testable import PilotCore
@testable import PilotTiler
import Testing

/// Live bug (Sven, 2026-10-15): with the second display turned off, a new Chrome window on the first one did not join that
/// display's main + stack. The display's workspace and the focus went with the display; the new window registered there.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct DisplayRemovedTests {

        /// Workspace "main" on the main display in main + stack (1 | 2, 3), "side" on the second display with window 10
        /// focused, as Sven had them before turning the second display off.
        private func twoDisplays() throws -> (main: Workspace, side: Workspace) {
            unitTestScreen.withLock { $0.monitors = [testMonitorInfo, testSecondMonitorInfo] }
            gcMonitors()
            let main = Workspace.get(byName: "main"), side = Workspace.get(byName: "side")
            #expect(testMonitorInfo.setActiveWorkspace(main) && testSecondMonitorInfo.setActiveWorkspace(side))
            for id in UInt32(1)...3 { try TestWindow.new(id: id, parent: main.rootTilingContainer) }
            try main.arrange(WorkspaceArrangement(.mainStack, auto: false, order: [1, 2, 3]))
            #expect(try TestWindow.new(id: 10, parent: side.rootTilingContainer).focusWindow())
            #expect(focus.workspace == side)
            return (main, side)
        }

        private func unplugSecond() { unitTestScreen.withLock { $0.monitors = [testMonitorInfo] } }

        /// A window that just opened, on the workspace registration picks.
        private func open(_ id: UInt32) async throws -> Window {
            try await openWindow(id, on: registrationWorkspace(windowId: id, rect: nil).workspace)
        }

        /// The window joined the remaining display's workspace at the foot of its stack.
        private func expectJoinsTheStack(_ opened: Window, _ main: Workspace) throws {
            #expect(opened.nodeWorkspace == main, "joins the workspace the remaining display shows")
            #expect(try main.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(50)])]))
        }

        /// No session ran between the display going and the window opening: the engine still had "side" shown, and the
        /// session that sees the window starts by tidying the monitors.
        @Test func aWindowOpenedRightAfterTheDisplayGoesJoinsTheRemainingDisplay() async throws {
            let (main, _) = try twoDisplays()
            unplugSecond()
            let opened = try await runLightSession(.pilotCall("open"), .forceRun) { try await open(50) }
            try expectJoinsTheStack(opened, main)
        }

        /// A session ran in between (macOS moved the second display's windows) and tidied the monitors, the focus with them.
        @Test func aWindowOpenedAfterASessionJoinsTheRemainingDisplay() async throws {
            let (main, _) = try twoDisplays()
            unplugSecond()
            gcMonitors()
            try await refreshModel_nonCancellable()
            #expect(testMonitorInfo.activeWorkspace == main)
            let opened = try await open(50)
            try expectJoinsTheStack(opened, main)
        }
    }
}
