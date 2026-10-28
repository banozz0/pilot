// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/SwapCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

// `swap <direction>` (no wrap-around, no --swap-focus) is Window.swap(_:).
extension TilerTreeTests {
    @MainActor
    @Suite
    struct SwapCommandTest {
        @Test func swap_swapWindows_Directional() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                    try TestWindow.new(id: 2, parent: $0)
                }
                try TestWindow.new(id: 3, parent: $0)
            }

            try await run { try focusedWindow().swap(.right) }
            #expect(try root.layoutDescription == .h_tiles([.v_tiles([.window(3), .window(2)]), .window(1)]))
            #expect(focus.windowOrNil?.windowId == 1)
            #expect(root.mostRecentWindowRecursive?.windowId == 1)

            try await run { try focusedWindow().swap(.left) }
            #expect(try root.layoutDescription == .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)]))
            #expect(focus.windowOrNil?.windowId == 1)
            #expect(root.mostRecentWindowRecursive?.windowId == 1)

            try await run { try focusedWindow().swap(.down) }
            #expect(try root.layoutDescription == .h_tiles([.v_tiles([.window(2), .window(1)]), .window(3)]))
            #expect(focus.windowOrNil?.windowId == 1)
            #expect(root.mostRecentWindowRecursive?.windowId == 1)

            try await run { try focusedWindow().swap(.up) }
            #expect(try root.layoutDescription == .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)]))
            #expect(focus.windowOrNil?.windowId == 1)
            #expect(root.mostRecentWindowRecursive?.windowId == 1)
        }
    }
}
