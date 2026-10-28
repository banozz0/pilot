// Pilot's own tests for the pinned pop-out (spec omarchy-ideas T1): a pinned window floats on whichever workspace its
// monitor shows, the layout pass carrying it there before it parks the hidden ones, so it is never parked.
import AppKit
@testable import PilotCore
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct PinnedWindowTests {
        /// A tiled window on workspace "1", focused and pinned.
        private func pinnedWindow() async throws -> Window {
            let window = try TestWindow.new(id: 1, parent: Workspace.get(byName: "1").rootTilingContainer)
            #expect(try window.focusWindow())
            #expect(try await run { try await window.setPinned(true) })
            return window
        }

        /// Pinned windows still on a workspace no monitor shows: the ones layout would park.
        private var pinnedOnHiddenWorkspaces: [UInt32] {
            Workspace.all.filter { !$0.isVisible }.flatMap(\.allLeafWindowsRecursive).filter(\.isPinned).map(\.windowId)
        }

        private func show(_ name: String) throws {
            #expect(Workspace.get(byName: name).focusWorkspace())
        }

        @Test func pinFloatsTheWindow() async throws {
            let window = try await pinnedWindow()
            #expect(window.isPinned)
            #expect(try window.isFloating)
            #expect(try Workspace.get(byName: "1").floatingWindows.map(\.windowId) == [1])
        }

        /// Workspaces 2, 3, then 1: each switch carries it into the shown workspace's floating layer, and it is never
        /// left on a hidden one.
        @Test func followsEveryWorkspaceItsMonitorShows() async throws {
            let window = try await pinnedWindow()
            for name in ["2", "3", "1"] {
                try show(name)
                let carried = try carryPinnedWindows()
                #expect(carried.map(\.windowId) == [1])
                #expect(window.nodeWorkspace?.name == name)
                #expect(try Workspace.get(byName: name).floatingWindows.map(\.windowId) == [1])
                #expect(window.isPinned)
                #expect(pinnedOnHiddenWorkspaces.isEmpty)
            }
        }

        /// Carried onto a workspace, it never becomes its most recent window: the tile you landed on stays it, so
        /// closing that tile focuses the next tile, never the pinned window.
        @Test func carryKeepsTheLandedTileMostRecent() async throws {
            let window = try await pinnedWindow()
            let tile = try TestWindow.new(id: 2, parent: Workspace.get(byName: "2").rootTilingContainer)
            #expect(try tile.focusWindow())
            #expect(try carryPinnedWindows().map(\.windowId) == [1])
            #expect(window.nodeWorkspace?.name == "2")
            #expect(Workspace.get(byName: "2").mostRecentWindowRecursive?.windowId == 2)
        }

        /// Nothing switched, nothing carried: the pass leaves it be, so it is raised only on a switch.
        @Test func staysPutWithoutASwitch() async throws {
            let window = try await pinnedWindow()
            try show("1")
            #expect(try carryPinnedWindows().isEmpty)
            #expect(window.nodeWorkspace?.name == "1")
        }

        /// Another monitor's switch leaves it on its own monitor's workspace; its own monitor's switch carries it there,
        /// never to the other monitor.
        @Test func followsItsOwnMonitorOnly() async throws {
            let rect = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)
            let side = MonitorInfoImpl(monitorAppKitNsScreenScreensId: 2, name: "SIDE", rect: rect, visibleRect: rect, isMain: false, displayId: "S")
            unitTestScreen.withLock { $0.monitors = [testMonitorInfo, side] }
            gcMonitors()
            let window = try await pinnedWindow()
            #expect(testMonitorInfo.setActiveWorkspace(Workspace.get(byName: "1")))
            #expect(side.setActiveWorkspace(Workspace.get(byName: "9")))
            #expect(try carryPinnedWindows().isEmpty)
            #expect(window.nodeWorkspace?.name == "1")
            #expect(testMonitorInfo.setActiveWorkspace(Workspace.get(byName: "2")))
            #expect(try carryPinnedWindows().map(\.windowId) == [1])
            #expect(window.nodeWorkspace?.name == "2")
            #expect(pinnedOnHiddenWorkspaces.isEmpty)
        }

        /// Unpinned, it tiles on the workspace you are on, and switches leave it there.
        @Test func unpinTilesWhereYouAre() async throws {
            let window = try await pinnedWindow()
            try show("2")
            _ = try carryPinnedWindows()
            #expect(try await run { try await window.setPinned(false) })
            #expect(!window.isPinned)
            #expect(try Workspace.get(byName: "2").rootTilingContainer.allLeafWindowsRecursive.map(\.windowId) == [1])
            try show("3")
            #expect(try carryPinnedWindows().isEmpty)
            #expect(window.nodeWorkspace?.name == "2")
        }

        /// Put back in the tiles by another key (float or tile), it loses its pin and stays a tile.
        @Test func retiledWindowLosesItsPin() async throws {
            let window = try await pinnedWindow()
            #expect(try await run { try await window.setLayout(.tiling) })
            try show("2")
            #expect(try carryPinnedWindows().isEmpty)
            #expect(!window.isPinned)
            #expect(window.nodeWorkspace?.name == "1")
        }

        /// Its app hidden, macOS holds it: it keeps its pin and waits.
        @Test func hiddenAppWindowKeepsItsPin() async throws {
            let window = try await pinnedWindow()
            try window.bind(to: Workspace.get(byName: "1").macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            try show("2")
            #expect(try carryPinnedWindows().isEmpty)
            #expect(window.isPinned)
        }

        /// The listing names it pinned, which the snapshots read to skip it.
        @Test func listingNamesItPinned() async throws {
            _ = try await pinnedWindow()
            try Workspace.get(byName: "1").rootTilingContainer.with { _ = try TestWindow.new(id: 2, parent: $0) }
            let windows = try AeroWindow.parse(try await perform(.listWindows(.all)))
            #expect(windows.filter(\.isPinned).map(\.id) == [1])
            #expect(AeroCommand.setPinned(id: 1, true).arguments == ["pin", "--window-id", "1", "on"])
        }
    }
}
