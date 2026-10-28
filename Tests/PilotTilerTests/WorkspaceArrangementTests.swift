@testable import PilotTiler
import PilotCore
import Testing

/// Card agent-bo-95422997, AC3: Pilot's layouts built in the engine's tree in memory, no commands. Each layout for 1 to 5
/// windows, from a scrambled tree; an auto workspace keeps its window order and is rebuilt before layout when a window
/// comes or goes, never while one of its windows is being dragged.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct WorkspaceArrangementTests {
        /// Windows 1...n on the test workspace, every even one nested in a container of its own with an odd weight, plus a
        /// floating window 99 that no layout touches.
        func scrambled(_ n: Int) throws -> Workspace {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with { root in
                    for id in UInt32(1)...UInt32(n) {
                        if id.isMultiple(of: 2) {
                            try TilingContainer.newVTiles(parent: root, adaptiveWeight: 3).with { try TestWindow.new(id: id, parent: $0) }
                        } else {
                            try TestWindow.new(id: id, parent: root, adaptiveWeight: 2)
                        }
                    }
                }
                try TestWindow.new(id: 99, parent: $0.floatingWindowsContainer)
            }
            #expect(workspace.focusWorkspace())
            return workspace
        }

        func windows(_ ids: some Sequence<Int>) -> [LayoutDescription] { ids.map { .window(UInt32($0)) } }

        func expectArranged(_ preset: LayoutPreset, _ n: Int, _ root: LayoutDescription) throws {
            let workspace = try scrambled(n)
            try workspace.arrange(preset, order: (1...n).map(UInt32.init))
            #expect(try workspace.layoutDescription == .workspace([root, .floatingWindowsContainer([.window(99)])]))
            // Equal sizes: every tile and column carries the same weight along its parent.
            for node in try workspace.rootTilingContainer.allLeafWindowsRecursive.flatMap(\.parentsWithSelf) {
                if let parent = node.parent as? TilingContainer, parent.layout == .tiles { #expect(try node.getWeight(parent.orientation) == 1) }
            }
        }

        @Test(arguments: 1...5) func columns(n: Int) throws {
            try expectArranged(.columns, n, .h_tiles(windows(1...n)))
        }

        @Test(arguments: 1...5) func rows(n: Int) throws {
            try expectArranged(.rows, n, .v_tiles(windows(1...n)))
        }

        @Test(arguments: 1...5) func scrolling(n: Int) throws {
            try expectArranged(.scrolling, n, .h_scrolling(windows(1...n)))
        }

        @Test(arguments: 1...5) func mainStack(n: Int) throws {
            let expected: [Int: LayoutDescription] = [
                1: .h_tiles([.window(1)]),
                2: .h_tiles([.window(1), .window(2)]),
                3: .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]),
                4: .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(4)])]),
                5: .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(4), .window(5)])]),
            ]
            try expectArranged(.mainStack, n, try #require(expected[n]))
        }

        @Test(arguments: 1...5) func grid(n: Int) throws {
            let expected: [Int: LayoutDescription] = [
                1: .h_tiles([.window(1)]),
                2: .v_tiles([.window(1), .window(2)]),
                3: .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)]),
                4: .h_tiles([.v_tiles([.window(1), .window(2)]), .v_tiles([.window(3), .window(4)])]),
                5: .h_tiles([.v_tiles([.window(1), .window(2)]), .v_tiles([.window(3), .window(4)]), .window(5)]),
            ]
            try expectArranged(.grid, n, try #require(expected[n]))
        }

        /// The tests above run with AeroSpace's normalizations off; Pilot runs with both on, and they change nothing built.
        @Test(arguments: LayoutPreset.allCases) func normalizationKeepsIt(_ preset: LayoutPreset) throws {
            config.enableNormalizationFlattenContainers = true
            config.enableNormalizationOppositeOrientationForNestedContainers = true
            for n in 1...5 {
                let workspace = try scrambled(n)
                try workspace.arrange(preset, order: (1...n).map(UInt32.init))
                let built = try workspace.layoutDescription
                try workspace.normalizeContainers()
                #expect(try workspace.layoutDescription == built, "\(preset) with \(n)")
                for child in workspace.children { try child.unbindFromParent() }
            }
        }

        @Test func orderIsKept() throws {
            let workspace = try scrambled(3)
            try workspace.arrange(.columns, order: [3, 1, 2])
            #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles(windows([3, 1, 2])))
        }

        @Test func pilotsPresetIsBuiltFocusedFirst() async throws {
            let workspace = try scrambled(3)
            #expect(try #require(Window.get(byId: 2)).focusWindow())
            isTilerEnabled = true
            let tiler = InProcessTiler { _, body in try await run(body) }
            tiler.setLayouts([name: WorkspaceLayout(preset: .mainStack, auto: true), "other": WorkspaceLayout(preset: nil, auto: true)])
            #expect(arrangements.keys.sorted() == [name])
            try await tiler.arrange(name, as: .mainStack)
            #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(2), .v_tiles(windows([1, 3]))]))
            // A later settings change keeps the order that build made.
            tiler.setLayouts([name: WorkspaceLayout(preset: .columns, auto: true)])
            #expect(arrangements[name] == WorkspaceArrangement(.columns, auto: true, order: [2, 1, 3]))
            await #expect(throws: TilerCallRefused.self) { try await tiler.arrange("nowhere", as: .rows) }
        }

        /// The strip is one of Pilot's presets, kept by setLayouts and built by arrange like the rest, the focused window
        /// first; a rebuild keeps each column's width (check 4: no other column resizes).
        @Test(arguments: 1...5) func scrollingThroughThePresetPath(n: Int) async throws {
            let workspace = try scrambled(n)
            #expect(try #require(Window.get(byId: UInt32(n))).focusWindow())
            isTilerEnabled = true
            let tiler = InProcessTiler { _, body in try await run(body) }
            try #require(Window.get(byId: 1)).columnWidth = 2.0 / 3
            tiler.setLayouts([name: WorkspaceLayout(preset: .scrolling, auto: true)])
            #expect(arrangements[name] == WorkspaceArrangement(.scrolling, auto: true, order: []))
            try await tiler.arrange(name, as: .scrolling)
            #expect(try workspace.layoutDescription
                    == .workspace([.h_scrolling(windows([n] + Array(1..<n))), .floatingWindowsContainer([.window(99)])]))
            #expect(Window.get(byId: 1)?.columnWidth == 2.0 / 3)
        }

        @Test func autoRebuildsWhenAWindowComesOrGoes() throws {
            let workspace = try scrambled(3)
            arrangements = [name: WorkspaceArrangement(.mainStack, auto: true, order: [2, 1, 3])]
            try workspace.arrange(.mainStack, order: [2, 1, 3])
            // Nothing came or went: no rebuild, so a size set since stays.
            try #require(Window.get(byId: 2)).setWeight(.h, 5)
            try arrangeAutoWorkspaces()
            #expect(try #require(Window.get(byId: 2)).getWeight(.h) == 5)
            #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(2), .v_tiles(windows([1, 3]))]))
            // A new window joins at the end of the order; nothing else moves.
            try TestWindow.new(id: 4, parent: workspace.rootTilingContainer)
            try arrangeAutoWorkspaces()
            #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(2), .v_tiles(windows([1, 3, 4]))]))
            #expect(arrangements[name]?.order == [2, 1, 3, 4])
            // A closed one leaves the order.
            try #require(Window.get(byId: 2)).unbindFromParent()
            try arrangeAutoWorkspaces()
            #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .v_tiles(windows([3, 4]))]))
        }

        @Test func manualAndDraggedWorkspacesAreLeftAlone() throws {
            let workspace = try scrambled(2)
            let before = try workspace.layoutDescription
            arrangements = [name: WorkspaceArrangement(.columns, auto: false, order: [])]
            try arrangeAutoWorkspaces()
            #expect(try workspace.layoutDescription == before)
            arrangements = [name: WorkspaceArrangement(.columns, auto: true, order: [])]
            currentlyManipulatedWithMouseWindowId = 2
            defer { currentlyManipulatedWithMouseWindowId = nil }
            try arrangeAutoWorkspaces()
            #expect(try workspace.layoutDescription == before)
        }
    }
}
