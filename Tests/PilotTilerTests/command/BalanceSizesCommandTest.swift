// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/BalanceSizesCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct BalanceSizesCommandTest {
        @Test func balanceSizesCommand() async throws {
            let workspace = try Workspace.get(byName: name).with { wsp in
                try wsp.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 1)
                    try TestWindow.new(id: 2, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 2)
                    try TestWindow.new(id: 3, parent: $0).setWeight(wsp.rootTilingContainer.orientation, 3)
                }
            }

            try await run { try workspace.balanceSizes() }

            let root = try workspace.rootTilingContainer
            #expect(root.children.count == 3)
            for window in root.children {
                #expect(try window.getWeight(root.orientation) == 1)
            }
        }
    }
}
