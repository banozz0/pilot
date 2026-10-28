import AppKit
@testable import PilotTiler
import Testing

/// Live bug (Sven, 2026-10-17): a Finder or System Settings window (floating: a floated workspace, or no fullscreen button)
/// dragged from the vertical display to the main one stayed bound to the vertical display's workspace, so each refresh's
/// layout pulled it back there by its centre, mid-drag and after the release; wider than the vertical display, it was
/// pinned to that display's left edge and hung over onto the main one. AeroSpace's moveFloatingWindow rebinds it on each
/// move; Pilot's rewrite of moveWithMouse.swift had dropped it.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct FloatingDragTests {
        /// Sven's vertical 24", left of the main display and taller than it.
        private let vertical = MonitorInfoImpl(
            monitorAppKitNsScreenScreensId: 2,
            name: "Vertical",
            rect: Rect(topLeftX: -1080, topLeftY: -480, width: 1080, height: 1920),
            visibleRect: Rect(topLeftX: -1080, topLeftY: -480, width: 1080, height: 1920),
            isMain: false,
        )
        /// Dragged so its centre (800, 650) is on the main display; 1200 wide, wider than the vertical display.
        private let onMain = Rect(topLeftX: 200, topLeftY: 300, width: 1200, height: 700)

        /// "main" on the main display, "side" on the vertical one with floating window 70, focused, held by the mouse.
        private func dragging() throws -> (main: Workspace, side: Workspace, window: TestWindow) {
            unitTestScreen.withLock { $0.monitors = [testMonitorInfo, vertical]; $0.leftMouseDown = true }
            gcMonitors()
            let main = Workspace.get(byName: "main"), side = Workspace.get(byName: "side")
            #expect(testMonitorInfo.setActiveWorkspace(main) && vertical.setActiveWorkspace(side))
            let window = try TestWindow.new(id: 70, parent: side.floatingWindowsContainer, rect: onMain)
            #expect(try window.focusWindow())
            return (main, side, window)
        }

        private func layOut(_ workspaces: Workspace...) async throws {
            for workspace in workspaces { try await workspace.layoutWorkspace() }
        }

        /// A refresh that runs before the move's rebind (its AX read already sees the new frame) leaves the held window be.
        @Test func layoutNeverPullsBackAWindowTheMouseHolds() async throws {
            defer { unitTestScreen.withLock { $0.leftMouseDown = false } }
            let (main, side, window) = try dragging()
            try await layOut(side, main)
            #expect(window.frameWrites == 0, "pulled back to the vertical display mid-drag")
            #expect(window.axRect == onMain)
        }

        /// The move rebinds it to the workspace under its centre; the refresh after the release keeps it where it was dropped.
        @Test func aFloatingWindowDraggedToAnotherDisplayStaysWhereItWasDropped() async throws {
            defer { unitTestScreen.withLock { $0.leftMouseDown = false } }
            let (main, side, window) = try dragging()
            try await moveFloatingWindow(window)
            #expect(window.nodeWorkspace == main)
            unitTestScreen.withLock { $0.leftMouseDown = false }
            try await layOut(side, main)
            #expect(window.frameWrites == 0, "pulled back after the release")
            #expect(window.axRect == onMain)
        }

        /// Sven's report 2026-10-17 (a fast drag lagged the whole screen): each move of the held window still rebinds it,
        /// but asks for no complete refresh; the release's refresh lays it out once. Not held, a move refreshes as before.
        @Test func aHeldWindowsMovesAskForNoRefresh() async throws {
            defer { unitTestScreen.withLock { $0.leftMouseDown = false } }
            let (main, _, window) = try dragging()
            window.nativeFocus()
            let before = completeRefreshesScheduled
            for _ in 0..<100 {
                windowMoved(70, kAXMovedNotification as String)
                for _ in 0..<50 { await Task.yield() }
            }
            print("[border-drag] tiler: 100 moves of a held floating window, \(completeRefreshesScheduled - before) complete refreshes asked for")
            #expect(completeRefreshesScheduled == before)
            #expect(window.nodeWorkspace == main, "the moves still rebind it")
            unitTestScreen.withLock { $0.leftMouseDown = false }
            windowMoved(70, kAXMovedNotification as String)
            for _ in 0..<50 { await Task.yield() }
            #expect(completeRefreshesScheduled == before + 1)
        }

        /// Its centre still on its own display: it stays on its workspace.
        @Test func aMoveWithinItsDisplayKeepsItsWorkspace() async throws {
            defer { unitTestScreen.withLock { $0.leftMouseDown = false } }
            let (_, side, window) = try dragging()
            window.movedByPilot(to: Rect(topLeftX: -1000, topLeftY: 0, width: 600, height: 400))
            try await moveFloatingWindow(window)
            #expect(window.nodeWorkspace == side)
        }
    }
}
