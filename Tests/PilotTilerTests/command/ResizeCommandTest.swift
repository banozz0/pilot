// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/ResizeCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

// `resize width|height ±n` is Window.resize(_:by:) with .h or .v and a signed step.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct ResizeCommandTest {
        @Test func widthAdd_growsTargetShrinksSiblings() async throws {
            var window1: Window!
            var window2: Window!
            var window3: Window!
            try Workspace.get(byName: name).rootTilingContainer.with {
                window1 = try TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4)
                window2 = try TestWindow.new(id: 2, parent: $0, adaptiveWeight: 4)
                window3 = try TestWindow.new(id: 3, parent: $0, adaptiveWeight: 4)
            }
            _ = try window1.focusWindow()

            try await run { try focusedWindow().resize(.h, by: 2) }
            // diff = +2, childDiff = 2 / (3 - 1) = 1
            #expect(try window1.hWeight == 6)
            #expect(try window2.hWeight == 3)
            #expect(try window3.hWeight == 3)
        }

        @Test func widthSubtract_shrinksTargetGrowsSiblings() async throws {
            var window1: Window!
            var window2: Window!
            var window3: Window!
            try Workspace.get(byName: name).rootTilingContainer.with {
                window1 = try TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4)
                window2 = try TestWindow.new(id: 2, parent: $0, adaptiveWeight: 4)
                window3 = try TestWindow.new(id: 3, parent: $0, adaptiveWeight: 4)
            }
            _ = try window1.focusWindow()

            try await run { try focusedWindow().resize(.h, by: -2) }
            // diff = -2, childDiff = -1
            #expect(try window1.hWeight == 2)
            #expect(try window2.hWeight == 5)
            #expect(try window3.hWeight == 5)
        }

        @Test func height_climbsToVerticalAncestor() async throws {
            // Root is horizontal; height must locate the nested vertical tile container.
            var window1: Window!
            var window2: Window!
            try Workspace.get(byName: name).rootTilingContainer.with {
                try TestWindow.new(id: 0, parent: $0)
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    window1 = try TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4)
                    window2 = try TestWindow.new(id: 2, parent: $0, adaptiveWeight: 4)
                }
            }
            _ = try window1.focusWindow()

            try await run { try focusedWindow().resize(.v, by: 2) }
            // diff = +2, childDiff = 2 / (2 - 1) = 2
            #expect(try window1.vWeight == 6)
            #expect(try window2.vWeight == 2)
        }

        @Test func height_noVerticalAncestor_returnsFail() async throws {
            // Root is horizontal; with no vertical container present, height has nothing to resize.
            try Workspace.get(byName: name).rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }

            #expect(try await run { try focusedWindow().resize(.v, by: 2) } == false)
        }

        @Test func singleChildParent_failsCleanly() async throws {
            // The root has only one tiling child; dividing the diff across 0 siblings must fail.
            try Workspace.get(byName: name).rootTilingContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0, adaptiveWeight: 4).focusWindow()
                #expect(focused)
            }

            #expect(try await run { try focusedWindow().resize(.h, by: 2) } == false)
        }
    }
}
