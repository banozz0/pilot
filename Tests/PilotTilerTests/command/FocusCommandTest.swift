// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/FocusCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

// `focus <direction>` is Window.focusNeighbor(_:) (boundaries workspace, action stop, floating as tiling);
// `focus dfs-next|dfs-prev --boundaries-action wrap-around-the-workspace` is Workspace.focusRing(from:next:).
extension TilerTreeTests {
    @MainActor
    @Suite
    struct FocusCommandTest {
        @Test func focus() throws {
            #expect(PilotTiler.focus.windowOrNil == nil)
            try Workspace.get(byName: name).rootTilingContainer.with {
                try TestWindow.new(id: 1, parent: $0)
                #expect(try TestWindow.new(id: 2, parent: $0).focusWindow())
                try TestWindow.new(id: 3, parent: $0)
            }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 2)
        }

        @Test func focusOverFloatingWindows() async throws {
            #expect(PilotTiler.focus.windowOrNil == nil)
            try Workspace.get(byName: name).floatingWindowsContainer.with {
                try TestWindow.new(id: 1, parent: $0, rect: Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100))
                #expect(try TestWindow.new(id: 2, parent: $0, rect: Rect(topLeftX: 10, topLeftY: 10, width: 100, height: 100)).focusWindow())
                try TestWindow.new(id: 3, parent: $0, rect: Rect(topLeftX: 20, topLeftY: 20, width: 100, height: 100))
            }

            #expect(PilotTiler.focus.windowOrNil?.windowId == 2)
            try await run { try await focusedWindow().focusNeighbor(.right) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 3)
        }

        @Test func focusAlongTheContainerOrientation() async throws {
            try Workspace.get(byName: name).rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }

            #expect(PilotTiler.focus.windowOrNil?.windowId == 1)
            try await run { try await focusedWindow().focusNeighbor(.right) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 2)
        }

        @Test func focusAcrossTheContainerOrientation() async throws {
            try Workspace.get(byName: name).with {
                try TestWindow.new(id: 1, parent: $0.rootTilingContainer)
                try TestWindow.new(id: 2, parent: $0.rootTilingContainer)
                #expect($0.focusWorkspace())
            }

            #expect(PilotTiler.focus.windowOrNil?.windowId == 2)
            try await run { try await focusedWindow().focusNeighbor(.up) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 2)
            try await run { try await focusedWindow().focusNeighbor(.down) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 2)
        }

        @Test func focusNoWrapping() async throws {
            try Workspace.get(byName: name).rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }

            #expect(PilotTiler.focus.windowOrNil?.windowId == 1)
            try await run { try await focusedWindow().focusNeighbor(.left) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 1)
        }

        @Test func focusFindMruLeaf() async throws {
            let workspace = Workspace.get(byName: name)
            var startWindow: Window!
            var window2: Window!
            var window3: Window!
            var unrelatedWindow: Window!
            try workspace.rootTilingContainer.with {
                startWindow = try TestWindow.new(id: 1, parent: $0)
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    try TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).with {
                        window2 = try TestWindow.new(id: 2, parent: $0)
                        unrelatedWindow = try TestWindow.new(id: 5, parent: $0)
                    }
                    window3 = try TestWindow.new(id: 3, parent: $0)
                }
            }

            #expect(workspace.mostRecentWindowRecursive?.windowId == 3) // The latest bound
            _ = try startWindow.focusWindow()
            try await run { try await focusedWindow().focusNeighbor(.right) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 3)

            window2.markAsMostRecentChild()
            _ = try startWindow.focusWindow()
            try await run { try await focusedWindow().focusNeighbor(.right) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 2)

            window3.markAsMostRecentChild()
            unrelatedWindow.markAsMostRecentChild()
            _ = try startWindow.focusWindow()
            try await run { try await focusedWindow().focusNeighbor(.right) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 2)
        }

        @Test func focusOutsideOfTheContainer() async throws {
            try Workspace.get(byName: name).rootTilingContainer.with {
                try TestWindow.new(id: 1, parent: $0)
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    let focused = try TestWindow.new(id: 2, parent: $0).focusWindow()
                    #expect(focused)
                }
            }

            try await run { try await focusedWindow().focusNeighbor(.left) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 1)
        }

        @Test func focusOutsideOfTheContainer2() async throws {
            try Workspace.get(byName: name).rootTilingContainer.with {
                try TestWindow.new(id: 1, parent: $0)
                try TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).with {
                    let focused = try TestWindow.new(id: 2, parent: $0).focusWindow()
                    #expect(focused)
                }
            }

            try await run { try await focusedWindow().focusNeighbor(.left) }
            #expect(PilotTiler.focus.windowOrNil?.windowId == 1)
        }

        @Test func focusDfsRelative() async throws {
            try Workspace.get(byName: name).rootTilingContainer.with {
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                    try TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).with {
                        try TestWindow.new(id: 2, parent: $0)
                        try TestWindow.new(id: 3, parent: $0)
                    }
                }
                try TestWindow.new(id: 4, parent: $0)
            }

            #expect(PilotTiler.focus.windowOrNil?.windowId == 1)

            for (next, expected) in [(true, 2), (true, 3), (true, 4), (false, 3), (false, 2), (false, 1)] as [(Bool, UInt32)] {
                try await run { try PilotTiler.focus.workspace.focusRing(from: PilotTiler.focus.windowOrNil, next: next) }
                #expect(PilotTiler.focus.windowOrNil?.windowId == expected)
            }
        }

        /// The wrap-around-the-workspace half of AeroSpace's case; `stop` and `fail` are not offered by focusRing.
        @Test func focusDfsRelativeWrapping() async throws {
            try Workspace.get(byName: name).rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }

            #expect(PilotTiler.focus.windowOrNil?.windowId == 1)

            #expect(try await run { try PilotTiler.focus.workspace.focusRing(from: PilotTiler.focus.windowOrNil, next: false) })
            #expect(PilotTiler.focus.windowOrNil?.windowId == 2)

            #expect(try await run { try PilotTiler.focus.workspace.focusRing(from: PilotTiler.focus.windowOrNil, next: true) })
            #expect(PilotTiler.focus.windowOrNil?.windowId == 1)
        }
    }
}
