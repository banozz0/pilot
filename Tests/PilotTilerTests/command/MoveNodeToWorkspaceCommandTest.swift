// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/MoveNodeToWorkspaceCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

// `move-node-to-workspace [--window-id N] [--focus-follows-window] <name>` is Window.moveToWorkspace(_:focusFollowsWindow:).
extension TilerTreeTests {
    @MainActor
    @Suite
    struct MoveNodeToWorkspaceCommandTest {
        @Test func simple() async throws {
            let workspaceA = Workspace.get(byName: "a")
            try workspaceA.rootTilingContainer.with {
                _ = try TestWindow.new(id: 1, parent: $0).focusWindow()
            }

            try await run { try focusedWindow().moveToWorkspace(Workspace.get(byName: "b")) }
            #expect(workspaceA.isEffectivelyEmpty)
            #expect(try (Workspace.get(byName: "b").rootTilingContainer.children.singleOrNil() as? Window)?.windowId == 1)
        }

        @Test func emptyWorkspaceSubject() async throws {
            let workspaceA = Workspace.get(byName: "a")
            try workspaceA.rootTilingContainer.with {
                _ = try TestWindow.new(id: 1, parent: $0).focusWindow()
            }

            try await run { try focusedWindow().moveToWorkspace(Workspace.get(byName: "b")) }
            #expect(focus.workspace.name == "a")
        }

        @Test func anotherWindowSubject() async throws {
            try Workspace.get(byName: "a").rootTilingContainer.with {
                try TestWindow.new(id: 1, parent: $0)
                _ = try TestWindow.new(id: 2, parent: $0).focusWindow()
            }

            try await run { try focusedWindow().moveToWorkspace(Workspace.get(byName: "b")) }
            #expect(focus.windowOrNil?.windowId == 1)
        }

        @Test func preserveFloatingLayout() async throws {
            let workspaceA = try Workspace.get(byName: "a").with {
                let focused = try TestWindow.new(id: 1, parent: $0.floatingWindowsContainer).focusWindow()
                #expect(focused)
            }

            try await run { try focusedWindow().moveToWorkspace(Workspace.get(byName: "b")) }
            #expect(workspaceA.isEffectivelyEmpty)
            #expect(try (Workspace.get(byName: "b").floatingWindowsContainer.children.singleOrNil() as? Window)?.windowId == 1)
        }

        @Test func summonWindow() async throws {
            let workspaceA = try Workspace.get(byName: "a").with {
                try $0.rootTilingContainer.with {
                    _ = try TestWindow.new(id: 1, parent: $0).focusWindow()
                }
            }
            try Workspace.get(byName: "b").rootTilingContainer.with {
                try TestWindow.new(id: 2, parent: $0)
            }

            #expect(focus.workspace == workspaceA)

            try await run { try #require(Window.get(byId: 2)).moveToWorkspace(Workspace.get(byName: "a")) }

            #expect(focus.workspace == workspaceA)
            #expect(focus.windowOrNil?.windowId == 1)
            #expect(try Workspace.get(byName: "b").rootTilingContainer.children.count == 0)
            #expect(try workspaceA.rootTilingContainer.children.count == 2)
        }

        /// AeroSpace answered 0 with "already belongs to workspace 'a'" on stderr; the typed call answers false.
        @Test func alreadyOnTheWorkspace_isNoop() async throws {
            try Workspace.get(byName: "a").rootTilingContainer.with {
                _ = try TestWindow.new(id: 1, parent: $0).focusWindow()
            }

            #expect(try await run { try focusedWindow().moveToWorkspace(Workspace.get(byName: "a")) } == false)
            #expect(try Workspace.get(byName: "a").rootTilingContainer.children.count == 1)
        }

        @Test func focusFollowsWindow() async throws {
            let workspaceA = Workspace.get(byName: "a")
            try workspaceA.rootTilingContainer.with {
                _ = try TestWindow.new(id: 1, parent: $0).focusWindow()
            }
            #expect(focus.workspace.name == "a")

            try await run { try focusedWindow().moveToWorkspace(Workspace.get(byName: "b"), focusFollowsWindow: true) }
            #expect(focus.workspace.name == "b")
            #expect(focus.windowOrNil?.windowId == 1)
            #expect(workspaceA.isEffectivelyEmpty)
        }
    }
}
