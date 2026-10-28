// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/ListWindowsTest.swift (MIT).
@testable import PilotTiler
import Testing

// `list-windows --all|--focused|--workspace <name>` is listWindows(_:), answering TilerWindow values.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct ListWindowsTest {
        /// AeroSpace failed with "No window is focused"; the typed query answers no windows.
        @Test func runFocusedNoWindow() async throws {
            #expect(try await run { try await listWindows(.focused) } == [])
        }

        @Test func runFocusedHappy() async throws {
            try Workspace.get(byName: name).rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }
            let windows = try await run { try await listWindows(.focused) }
            #expect(windows == [TilerWindow(
                id: 1,
                appName: "bobko.AeroSpace.test-app",
                bundleId: "bobko.AeroSpace.test-app",
                pid: 0,
                workspace: name,
                monitorId: 1,
                layout: "h_tiles",
                title: "TestWindow(1)",
            )])
        }

        @Test func runAll() async throws {
            try TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
            try TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
            let windows = try await run { try await listWindows(.all) }
            #expect(windows.map(\.id).sorted() == [1, 2])
            #expect(windows.map(\.workspace).sorted() == ["a", "b"])
        }

        @Test func runCount() async throws {
            let workspace = Workspace.get(byName: "a")
            try TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
            try TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
            try TestWindow.new(id: 3, parent: Workspace.get(byName: "b").rootTilingContainer)
            #expect(try await run { try await listWindows(.all) }.count == 3)
        }

        @Test func runFilterByWorkspaceName() async throws {
            try TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
            try TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
            #expect(try await run { try await listWindows(.workspace("a")) }.map(\.id) == [1])
        }
    }
}
