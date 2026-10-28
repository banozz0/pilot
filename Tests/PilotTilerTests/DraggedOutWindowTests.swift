import AppKit
@testable import PilotCore
@testable import PilotTiler
import Testing

/// Live bug (Sven, build 49): a Chrome tab dragged from display 2 and dropped on display 1 came back as a window on display
/// 2. Its window appeared while the mouse was down, so the engine waited for the release, then put it on the focused
/// workspace, display 2's. A window first seen during a drag joins the workspace of the display it was dropped on.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct DraggedOutWindowTests {
        /// Where the torn-off tab's window sits after the drop: on display 1.
        private let onDisplayOne = Rect(topLeftX: 600, topLeftY: 300, width: 800, height: 600)

        /// Display 1 shows "one" in main + stack (1 | 2, 3); display 2 shows "two" with Chrome's window 10 focused.
        private func twoDisplays() throws -> (one: Workspace, two: Workspace) {
            unitTestScreen.withLock { $0.monitors = [testMonitorInfo, testSecondMonitorInfo] }
            gcMonitors()
            let one = Workspace.get(byName: "one"), two = Workspace.get(byName: "two")
            #expect(testMonitorInfo.setActiveWorkspace(one) && testSecondMonitorInfo.setActiveWorkspace(two))
            for id in UInt32(1)...3 { try TestWindow.new(id: id, parent: one.rootTilingContainer) }
            try one.arrange(WorkspaceArrangement(.mainStack, auto: false, order: [1, 2, 3]))
            #expect(try TestWindow.new(id: 10, parent: two.rootTilingContainer).focusWindow())
            return (one, two)
        }

        private func open(_ id: UInt32, at rect: Rect) async throws -> Window {
            try await openWindow(id, on: registrationWorkspace(windowId: id, rect: rect).workspace)
        }

        @Test func aWindowTornOffInADragJoinsTheDisplayItWasDroppedOn() async throws {
            let (one, _) = try twoDisplays()
            windowsSeenInDrag.withLock { _ = $0.insert(50) } // the app reported it while the mouse was down
            let opened = try await open(50, at: onDisplayOne)
            #expect(opened.nodeWorkspace == one)
            #expect(try one.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(50)])]))
            #expect(windowsSeenInDrag.withLock { $0.isEmpty }, "used once")
        }

        /// Hyper+N and every other new window: the focused workspace, wherever the app put the frame.
        @Test func aWindowOpenedWithoutADragJoinsTheFocusedWorkspace() async throws {
            let (_, two) = try twoDisplays()
            let opened = try await open(50, at: onDisplayOne)
            #expect(opened.nodeWorkspace == two)
        }
    }
}
