// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/JoinWithCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct JoinWithCommandTest {
        @Test func moveIn() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                try TestWindow.new(id: 0, parent: $0)
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }

            try await run { try focusedWindow().join(with: .right) }
            #expect(try root.layoutDescription == .h_tiles([
                .window(0),
                .v_tiles([
                    .window(1),
                    .window(2),
                ]),
            ]))
        }
    }
}
