// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/tree/TreeNodeTest.swift (MIT).
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct TreeNodeTest {
        @Test func childParentCyclicReferenceMemoryLeak() throws {
            let workspace = Workspace.get(byName: name) // Don't cache root node
            let window = try TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

            #expect(window.parent != nil)
            try workspace.rootTilingContainer.unbindFromParent()
            #expect(window.parent == nil)
        }

        @Test func isEffectivelyEmpty() throws {
            let workspace = Workspace.get(byName: name)

            #expect(workspace.isEffectivelyEmpty)
            weak let window: TestWindow? = try .new(id: 1, parent: workspace.rootTilingContainer)
            #expect(window != nil)
            #expect(!workspace.isEffectivelyEmpty)
            try window!.unbindFromParent()
            #expect(workspace.isEffectivelyEmpty)

            // Don't save to local variable
            try TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
            #expect(!workspace.isEffectivelyEmpty)
        }

        @Test func normalizeContainers_dontRemoveRoot() throws {
            let workspace = Workspace.get(byName: name)
            weak let root = try workspace.rootTilingContainer
            func test() throws {
                #expect(root != nil)
                #expect(root!.isEffectivelyEmpty)
                try workspace.normalizeContainers()
                #expect(root != nil)
            }
            try test()

            config.enableNormalizationFlattenContainers = true
            try test()
        }

        @Test func normalizeContainers_singleWindowChild() throws {
            config.enableNormalizationFlattenContainers = true
            let workspace = Workspace.get(byName: name)
            try workspace.rootTilingContainer.with {
                try TestWindow.new(id: 0, parent: $0)
                try TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).with {
                    try TestWindow.new(id: 1, parent: $0)
                }
            }
            try workspace.normalizeContainers()
            #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(0), .window(1)]))
        }

        @Test func normalizeContainers_removeEffectivelyEmpty() throws {
            let workspace = Workspace.get(byName: name)
            try workspace.rootTilingContainer.with {
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    _ = try TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1)
                }
            }
            #expect(try workspace.rootTilingContainer.children.count == 1)
            try workspace.normalizeContainers()
            #expect(try workspace.rootTilingContainer.children.count == 0)
        }

        @Test func normalizeContainers_flattenContainers() throws {
            let workspace = Workspace.get(byName: name) // Don't cache root node
            try workspace.rootTilingContainer.with {
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    try TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
                }
            }
            try workspace.normalizeContainers()
            #expect(try workspace.rootTilingContainer.children.singleOrNil() is TilingContainer)

            config.enableNormalizationFlattenContainers = true
            try workspace.normalizeContainers()
            #expect(try workspace.rootTilingContainer.children.singleOrNil() is TestWindow)
        }
    }
}
