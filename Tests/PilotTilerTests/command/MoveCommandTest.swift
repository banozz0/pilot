// Ported from AeroSpace 74a1bf17 Sources/AppBundleTests/command/MoveCommandTest.swift (MIT).
@testable import PilotTiler
import Testing

// `move <direction>` is Window.move(_:), which is `move --boundaries-action stop` (what Pilot sends).
extension TilerTreeTests {
    @MainActor
    @Suite
    struct MoveCommandTest {
        @Test func move_swapWindows() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TestWindow.new(id: 2, parent: $0)
            }

            try await run { try focusedWindow().move(.right) }
            #expect(try root.layoutDescription == .h_tiles([.window(2), .window(1)]))
        }

        @Test func moveInto_findTopMostContainerWithRightOrientation() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                try TestWindow.new(id: 0, parent: $0)
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).with {
                    try TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).with {
                        try TestWindow.new(id: 2, parent: $0)
                    }
                }
            }

            try await run { try focusedWindow().move(.right) }
            #expect(try root.layoutDescription == .h_tiles([
                .window(0),
                .h_tiles([
                    .window(1),
                    .h_tiles([
                        .window(2),
                    ]),
                ]),
            ]))
        }

        @Test func move_mru() async throws {
            var window3: Window!
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                try TestWindow.new(id: 0, parent: $0)
                #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    try TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).with {
                        try TestWindow.new(id: 2, parent: $0)
                        window3 = try TestWindow.new(id: 3, parent: $0)
                    }
                    try TestWindow.new(id: 4, parent: $0)
                }
            }
            window3.markAsMostRecentChild()

            try await run { try focusedWindow().move(.right) }
            #expect(try root.layoutDescription == .h_tiles([
                .window(0),
                .v_tiles([
                    .h_tiles([
                        .window(1),
                        .window(2),
                        .window(3),
                    ]),
                    .window(4),
                ]),
            ]))
        }

        @Test func swap_preserveWeight() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer
            let window1 = try TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
            let window2 = try TestWindow.new(id: 2, parent: root, adaptiveWeight: 2)
            _ = try window2.focusWindow()

            try await run { try focusedWindow().move(.left) }
            #expect(try window2.hWeight == 2)
            #expect(try window1.hWeight == 1)
        }

        @Test func moveIn_newWeight() async throws {
            var window1: Window!
            var window2: Window!
            try Workspace.get(byName: name).rootTilingContainer.with {
                try TestWindow.new(id: 0, parent: $0, adaptiveWeight: 1)
                window1 = try TestWindow.new(id: 1, parent: $0, adaptiveWeight: 2)
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    window2 = try TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
                }
            }
            _ = try window1.focusWindow()

            try await run { try focusedWindow().move(.right) }
            #expect(try window2.hWeight == 1)
            #expect(try window2.vWeight == 1)
            #expect(try window1.vWeight == 1)
            #expect(try window1.hWeight == 1)
        }

        @Test func stop_onRootNode() async throws {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                    try TestWindow.new(id: 2, parent: $0)
                    try TestWindow.new(id: 3, parent: $0)
                }
            }

            #expect(try await run { try focusedWindow().move(.left) })
            #expect(try workspace.layoutDescription == .workspace([
                .h_tiles([.window(1), .window(2), .window(3)]),
            ]))
        }

        @Test func stop_onRootNode_withOppositeOrientation() async throws {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    #expect(try TestWindow.new(id: 1, parent: $0).focusWindow())
                    try TestWindow.new(id: 2, parent: $0)
                    try TestWindow.new(id: 3, parent: $0)
                }
            }

            #expect(try await run { try focusedWindow().move(.up) })
            #expect(try workspace.layoutDescription == .workspace([
                .h_tiles([.window(1), .window(2), .window(3)]),
            ]))
        }

        @Test func stop_onRootNode_whenNoBoundary() async throws {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    #expect(try TestWindow.new(id: 2, parent: $0).focusWindow())
                    try TestWindow.new(id: 3, parent: $0)
                }
            }

            #expect(try await run { try focusedWindow().move(.left) })
            #expect(try workspace.layoutDescription == .workspace([
                .h_tiles([.window(2), .window(1), .window(3)]),
            ]))
        }

        @Test func stop_onInnerNode() async throws {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                        #expect(try TestWindow.new(id: 2, parent: $0).focusWindow())
                        try TestWindow.new(id: 3, parent: $0)
                    }
                }
            }

            #expect(try await run { try focusedWindow().move(.right) })
            #expect(try workspace.layoutDescription == .workspace([
                .h_tiles([.window(1), .v_tiles([.window(3)]), .window(2)]),
            ]))
        }

        @Test func moveOut() async throws {
            let root = try Workspace.get(byName: name).rootTilingContainer.with {
                try TestWindow.new(id: 1, parent: $0)
                try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                    #expect(try TestWindow.new(id: 2, parent: $0).focusWindow())
                    try TestWindow.new(id: 3, parent: $0)
                    try TestWindow.new(id: 4, parent: $0)
                }
            }

            try await run { try focusedWindow().move(.left) }
            #expect(try root.layoutDescription == .h_tiles([
                .window(1),
                .window(2),
                .v_tiles([
                    .window(3),
                    .window(4),
                ]),
            ]))
        }
    }
}

extension TreeNode {
    @MainActor
    var layoutDescription: LayoutDescription {
        get throws {
            switch try nodeCases {
                case .window(let window): .window(window.windowId)
                case .workspace(let workspace): .workspace(try workspace.children.map { try $0.layoutDescription })
                case .floatingWindowsContainer(let container): .floatingWindowsContainer(try container.children.map { try $0.layoutDescription })
                case .macosMinimizedWindowsContainer: .macosMinimized
                case .macosFullscreenWindowsContainer: .macosFullscreen
                case .macosHiddenAppsWindowsContainer: .macosHiddeAppWindow
                case .macosPopupWindowsContainer: .macosPopupWindowsContainer
                case .tilingContainer(let container):
                    switch container.layout {
                        case .tiles:
                            container.orientation == .h
                                ? .h_tiles(try container.children.map { try $0.layoutDescription })
                                : .v_tiles(try container.children.map { try $0.layoutDescription })
                        case .scrolling:
                            .h_scrolling(try container.children.map { try $0.layoutDescription })
                        case .stage:
                            .h_stage(try container.children.map { try $0.layoutDescription })
                    }
            }
        }
    }
}

enum LayoutDescription: Equatable {
    case workspace([LayoutDescription])
    case h_tiles([LayoutDescription])
    case v_tiles([LayoutDescription])
    case h_scrolling([LayoutDescription])
    case h_stage([LayoutDescription])
    case floatingWindowsContainer([LayoutDescription])
    case window(UInt32)
    case macosPopupWindowsContainer
    case macosMinimized
    case macosHiddeAppWindow
    case macosFullscreen
}
