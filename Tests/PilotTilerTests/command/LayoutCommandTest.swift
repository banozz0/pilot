// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/LayoutCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

// `layout floating|tiling` is Window.setLayout(_:), `layout horizontal vertical` on the window is Window.flipSplit(),
// `layout --root …` (and `layout --workspace W …` on an empty workspace, which lands on its root) is
// Workspace.setRootLayout(toggling:). setRootLayout answers false where AeroSpace printed "Already in the requested
// mode"; setLayout answers true for its noops, as AeroSpace exited 0.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct LayoutCommandTest {
        @Test func changeOrientation() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }
            #expect(root.orientation == .h)

            #expect(try await run { try focusedWindow().flipSplit() })
            #expect(root.orientation == .v)
            #expect(try root.layoutDescription == .v_tiles([.window(1), .window(2)]))
        }

        @Test func emptyWorkspace_changeOrientation() async throws {
            let workspace = Workspace.get(byName: name)
            #expect(workspace.isEffectivelyEmpty)

            #expect(try await run { try workspace.setRootLayout(toggling: [.v_tiles]) })
            #expect(try workspace.rootTilingContainer.orientation == .v)
            #expect(try workspace.rootTilingContainer.layout == .tiles)
        }

        @Test func emptyWorkspace_changeLayout() async throws {
            let workspace = Workspace.get(byName: name)
            #expect(workspace.isEffectivelyEmpty)

            #expect(try await run { try workspace.setRootLayout(toggling: [.scrolling]) })
            #expect(try workspace.rootTilingContainer.layout == .scrolling)
            #expect(try workspace.rootTilingContainer.orientation == .h)
        }

        @Test func emptyWorkspace_alreadyMatches_fails() async throws {
            let workspace = Workspace.get(byName: name)
            #expect(workspace.isEffectivelyEmpty)

            #expect(try await run { try workspace.setRootLayout(toggling: [.h_tiles]) } == false)
            #expect(try workspace.rootTilingContainer.layout == .tiles)
            #expect(try workspace.rootTilingContainer.orientation == .h)
        }

        @Test func tilingToFloating() async throws {
            let workspace = Workspace.get(byName: name)
            let root = try workspace.rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }

            #expect(try await run { try await focusedWindow().setLayout(.floating) })
            #expect(try root.layoutDescription == .h_tiles([.window(2)]))
            #expect(try workspace.floatingWindows.map(\.windowId) == [1])
            #expect(focus.windowOrNil?.windowId == 1)
        }

        @Test func floatingToTiling() async throws {
            let workspace = Workspace.get(byName: name)
            try workspace.floatingWindowsContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
            }
            #expect(try workspace.floatingWindows.map(\.windowId) == [1])

            #expect(try await run { try await focusedWindow().setLayout(.tiling) })
            #expect(try workspace.floatingWindows == [])
            #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1)]))
        }

        @Test func layoutTilingOnTiledWindow_isNoop() async throws {
            let workspace = Workspace.get(byName: name)
            let root = try workspace.rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }

            #expect(try await run { try await focusedWindow().setLayout(.tiling) })
            #expect(try root.layoutDescription == .h_tiles([.window(1), .window(2)]))
        }

        @Test func layoutFloatingOnFloatingWindow_isNoop() async throws {
            let workspace = Workspace.get(byName: name)
            try workspace.floatingWindowsContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
            }

            #expect(try await run { try await focusedWindow().setLayout(.floating) })
            #expect(try workspace.floatingWindows.map(\.windowId) == [1])
        }

        /// Pilot's own case beside the port: `layout floating` on a floating window leaves it where it is (AeroSpace
        /// answers "Already in the requested mode"), so it neither jumps to the end of the floating windows nor resizes.
        @Test func layoutFloatingOnFloatingWindow_keepsItsPlace() async throws {
            let workspace = Workspace.get(byName: name)
            try workspace.floatingWindowsContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
                try TestWindow.new(id: 2, parent: $0)
            }

            #expect(try await run { try await focusedWindow().setLayout(.floating) })
            #expect(try workspace.floatingWindows.map(\.windowId) == [1, 2])
        }

        /// AeroSpace's `layout v_tiles` on a floating window; the tiling call on the window's parent here is flipSplit.
        @Test func changeTilingLayoutOnFloatingWindow_fails() async throws {
            let workspace = Workspace.get(byName: name)
            try workspace.floatingWindowsContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
            }

            #expect(try await run { try focusedWindow().flipSplit() } == false)
            #expect(try workspace.floatingWindows.map(\.windowId) == [1])
        }

        @Test func root_changesRootInsteadOfNestedParent() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                    #expect(focused)
                }
                try TestWindow.new(id: 2, parent: $0)
            }
            #expect(root.orientation == .h)
            #expect(root.layout == .tiles)

            #expect(try await run { try focus.workspace.setRootLayout(toggling: [.h_scrolling]) })
            #expect(root.layout == .scrolling)
            #expect(root.orientation == .h) // a strip is always horizontal
            #expect(try root.layoutDescription == .h_scrolling([
                .v_tiles([.window(1)]),
                .window(2),
            ]))
        }

        @Test func root_emptyWorkspace_changeLayout() async throws {
            let workspace = Workspace.get(byName: name)
            #expect(workspace.isEffectivelyEmpty)

            #expect(try await run { try workspace.setRootLayout(toggling: [.scrolling]) })
            #expect(try workspace.rootTilingContainer.layout == .scrolling)
            #expect(try workspace.rootTilingContainer.orientation == .h)
        }

        @Test func root_floatingFocusedWindow_changesRootTilingContainer() async throws {
            let workspace = Workspace.get(byName: name)
            try workspace.floatingWindowsContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
            }

            #expect(try await run { try focus.workspace.setRootLayout(toggling: [.h_scrolling]) })
            #expect(try workspace.rootTilingContainer.layout == .scrolling)
            #expect(try workspace.rootTilingContainer.orientation == .h) // a strip is always horizontal
            #expect(try workspace.floatingWindows.map(\.windowId) == [1])
        }

        @Test func root_macosFullscreenFocusedWindow_changesRootTilingContainer() async throws {
            let workspace = Workspace.get(byName: name)
            #expect(try TestWindow.new(id: 1, parent: workspace.macOsNativeFullscreenWindowsContainer).focusWindow())

            // Without --root this would fail with "Can't change layout for macOS minimized, fullscreen…".
            #expect(try await run { try focus.workspace.setRootLayout(toggling: [.h_scrolling]) })
            #expect(try workspace.rootTilingContainer.layout == .scrolling)
            #expect(try workspace.rootTilingContainer.orientation == .h) // a strip is always horizontal
        }

        @Test func root_withWindowIdFlag_targetsThatWindowsWorkspaceRoot() async throws {
            let focusedRoot = try Workspace.get(byName: "a").rootTilingContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
            }
            let otherRoot = try Workspace.get(byName: "b").rootTilingContainer.with {
                try TestWindow.new(id: 2, parent: $0)
            }
            #expect(focusedRoot.layout == .tiles)
            #expect(otherRoot.layout == .tiles)

            #expect(try await run {
                try #require(Window.get(byId: 2)?.nodeWorkspace).setRootLayout(toggling: [.h_scrolling])
            })
            #expect(otherRoot.layout == .scrolling)
            #expect(otherRoot.orientation == .h) // a strip is always horizontal
            #expect(focusedRoot.layout == .tiles) // Focused workspace must be untouched
        }

        @Test func root_withWorkspaceFlag_targetsThatWorkspace() async throws {
            let focusedRoot = try Workspace.get(byName: "a").rootTilingContainer.with {
                let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                #expect(focused)
            }
            let otherRoot = try Workspace.get(byName: "b").rootTilingContainer.with {
                try TestWindow.new(id: 2, parent: $0)
            }
            #expect(focusedRoot.layout == .tiles)
            #expect(otherRoot.layout == .tiles)

            #expect(try await run { try Workspace.get(byName: "b").setRootLayout(toggling: [.h_scrolling]) })
            #expect(otherRoot.layout == .scrolling)
            #expect(otherRoot.orientation == .h) // a strip is always horizontal
            #expect(focusedRoot.layout == .tiles) // Focused workspace must be untouched
        }

        @Test func root_toggleBetween_skipsMatching() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    let focused = try TestWindow.new(id: 1, parent: $0).focusWindow()
                    #expect(focused)
                }
                try TestWindow.new(id: 2, parent: $0)
            }
            #expect(try root.layoutDescription == .h_tiles([
                .v_tiles([.window(1)]),
                .window(2),
            ]))

            #expect(try await run { try focus.workspace.setRootLayout(toggling: [.h_tiles, .h_scrolling]) })
            #expect(root.layout == .scrolling)
            #expect(root.orientation == .h)
            #expect(try root.layoutDescription == .h_scrolling([
                .v_tiles([.window(1)]),
                .window(2),
            ]))
        }

        @Test func root_alreadyMatches_fails() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }
            #expect(try root.layoutDescription == .h_tiles([.window(1), .window(2)]))

            #expect(try await run { try focus.workspace.setRootLayout(toggling: [.h_tiles]) } == false)
            #expect(try root.layoutDescription == .h_tiles([.window(1), .window(2)]))
        }
    }
}
