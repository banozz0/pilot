// Pilot's own tests for the monitor calls, which AeroSpace 74a1bf17 only tested for parsing: a second display through
// UnitTestScreen, the test seam beside AeroSpace's single test monitor.
import AppKit
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct MonitorCallsTest {
        /// The test monitor's twin, to its right.
        private let second = MonitorInfoImpl(
            monitorAppKitNsScreenScreensId: 2,
            name: "Second Monitor",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            isMain: false,
        )

        private func addSecondMonitor() -> Workspace {
            unitTestScreen.withLock { $0.monitors.append(second) }
            gcMonitors()
            return second.activeWorkspace
        }

        /// `focus-monitor --wrap-around right`, there and back.
        @Test func focusMonitor_rightWrapsAround() async throws {
            let first = focus.workspace
            let other = addSecondMonitor()
            #expect(other != first)

            #expect(try await run { focusMonitor(.right) })
            #expect(focus.workspace == other)
            #expect(focus.workspace.workspaceMonitor.monitorId_oneBased == 2)

            #expect(try await run { focusMonitor(.right) })
            #expect(focus.workspace == first)
            #expect(focus.workspace.workspaceMonitor.monitorId_oneBased == 1)
        }

        /// On one display every direction wraps onto the display itself.
        @Test func focusMonitor_singleMonitor_staysPut() async throws {
            let first = focus.workspace
            #expect(try await run { focusMonitor(.left) })
            #expect(focus.workspace == first)
        }

        /// `move-node-to-monitor --window-id N --focus-follows-window --wrap-around right`: first in a horizontal root,
        /// and the focus goes with it.
        @Test func moveToMonitor_right() async throws {
            try Workspace.get(byName: name).rootTilingContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
                try TestWindow.new(id: 3, parent: $0)
            }
            let other = addSecondMonitor()
            try TestWindow.new(id: 2, parent: other.rootTilingContainer)

            #expect(try await run { try #require(Window.get(byId: 1)).moveToMonitor(.right) })
            #expect(try other.layoutDescription == .workspace([.h_tiles([.window(1), .window(2)])]))
            #expect(try Workspace.get(byName: name).layoutDescription == .workspace([.h_tiles([.window(3)])]))
            #expect(focus.windowOrNil?.windowId == 1)
            #expect(focus.workspace == other)
        }

        /// Left from the leftmost display wraps to the rightmost; a negative direction binds last.
        @Test func moveToMonitor_leftWrapsAround() async throws {
            try Workspace.get(byName: name).rootTilingContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
            }
            let other = addSecondMonitor()
            try TestWindow.new(id: 2, parent: other.rootTilingContainer)

            #expect(try await run { try #require(Window.get(byId: 1)).moveToMonitor(.left) })
            #expect(try other.layoutDescription == .workspace([.h_tiles([.window(2), .window(1)])]))
            #expect(focus.windowOrNil?.windowId == 1)
        }

        /// `list-workspaces --monitor mouse --visible`: the workspace on the display under the mouse.
        @Test func mouseWorkspace_followsTheMouse() async throws {
            let first = focus.workspace
            let other = addSecondMonitor()

            unitTestScreen.withLock { $0.mouse = CGPoint(x: 2500, y: 500) }
            #expect(try await run { try mouseWorkspace() } == TilerWorkspace(
                name: other.name,
                monitorId: 2,
                monitorName: "Second Monitor",
                rootLayout: .h_tiles,
            ))

            unitTestScreen.withLock { $0.mouse = CGPoint(x: 100, y: 100) }
            #expect(try await run { try mouseWorkspace() }.name == first.name)
        }

        /// `list-workspaces --monitor all --visible`: one per display, in display order.
        @Test func visibleWorkspaces_onTwoMonitors() async throws {
            let first = focus.workspace
            let other = addSecondMonitor()

            let visible = try await run { try visibleWorkspaces() }
            #expect(visible.map(\.name) == [first.name, other.name])
            #expect(visible.map(\.monitorId) == [1, 2])
            #expect(visible.map(\.monitorName) == ["Test Monitor", "Second Monitor"])
        }

        /// `subscribe focused-monitor-changed`: a monitor change reaches tilerEvents() after the call's refresh.
        @Test func focusMonitor_sendsFocusedMonitorChanged() async throws {
            let other = addSecondMonitor()
            try await refreshModel_nonCancellable() // settle the last known focus before listening
            let events = tilerEvents(sendInitial: false)
            var iterator = events.makeAsyncIterator()

            try await run { focusMonitor(.right) }
            #expect(await iterator.next() == .focusChanged(windowId: nil, workspace: other.name))
            #expect(await iterator.next() == .workspaceChanged(workspace: other.name, prevWorkspace: "setUpWorkspacesForTests"))
            #expect(await iterator.next() == .focusedMonitorChanged(workspace: other.name, monitorId: 2))
        }
    }
}
