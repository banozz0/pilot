// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/ListWorkspacesTest.swift (MIT).
@testable import PilotTiler
import Testing

// `list-workspaces --monitor all --visible` is visibleWorkspaces(), `--focused` is focusedWorkspace(); both answer
// TilerWorkspace values.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct ListWorkspacesTest {
        @Test func runVisible() async throws {
            try TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
            // Only the focused workspace is visible after setUp on the single test monitor.
            #expect(try await run { try visibleWorkspaces() } == [TilerWorkspace(
                name: "setUpWorkspacesForTests",
                monitorId: 1,
                monitorName: "Test Monitor",
                rootLayout: .h_tiles,
            )])
        }

        @Test func runFocusedAlias() async throws {
            // The initial focused workspace is "setUpWorkspacesForTests" (visible on the focused monitor).
            try TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
            #expect(try await run { try focusedWorkspace() }.name == "setUpWorkspacesForTests")
        }
    }
}
