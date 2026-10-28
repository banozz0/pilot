// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/FlattenWorkspaceTreeCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct FlattenWorkspaceTreeCommandTest {
        @Test func simple() async throws {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    try TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).with {
                        try TestWindow.new(id: 2, parent: $0)
                    }
                }
                try TestWindow.new(id: 3, parent: $0.floatingWindowsContainer) // floating
            }
            #expect(workspace.focusWorkspace())

            try await run { try focus.workspace.flatten() }
            try workspace.normalizeContainers()
            #expect(try workspace.layoutDescription == .workspace([.h_tiles([.window(1), .window(2)]), .floatingWindowsContainer([.window(3)])]))
        }
    }
}
