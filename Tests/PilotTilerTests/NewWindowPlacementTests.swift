@testable import PilotTiler
import PilotCore
import Testing

/// Sven's Q122: a new window lands where its workspace's layout puts it (main + stack: the foot of the stack), with Keep
/// this layout on or off. Keep only decides whether the workspace is built again as windows come and go.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct NewWindowPlacementTests {
        /// The test workspace arranged as `preset` with windows 1...n, window 1 focused, and those windows.
        private func arranged(_ preset: LayoutPreset, _ n: Int, auto: Bool) throws -> (Workspace, [Window]) {
            let workspace = Workspace.get(byName: name)
            let windows = try (0..<UInt32(n)).map { try TestWindow.new(id: $0 + 1, parent: workspace.rootTilingContainer) }
            try workspace.arrange(WorkspaceArrangement(preset, auto: auto, order: windows.map(\.windowId)))
            #expect(try windows.first?.focusWindow() ?? workspace.focusWorkspace())
            return (workspace, windows)
        }

        /// The tree a ready layout builds for windows 1...n, on a workspace of its own.
        private func built(_ preset: LayoutPreset, _ n: Int) throws -> LayoutDescription {
            let other = Workspace.get(byName: "built")
            for id in UInt32(1)...UInt32(n) { try TestWindow.new(id: 100 + id, parent: other.rootTilingContainer) }
            try other.arrange(preset, order: (1...UInt32(n)).map { 100 + $0 })
            let description = try other.rootTilingContainer.layoutDescription
            for window in other.allLeafWindowsRecursive { try window.unbindFromParent() }
            return description.renumbered { $0 - 100 }
        }

        /// One more window lands in the tree the layout builds for one more, from 0 to 4 windows, Keep on and off.
        @Test(arguments: [false, true], [LayoutPreset.mainStack, .columns, .rows, .grid])
        func aNewWindowLandsWhereTheLayoutPutsIt(auto: Bool, preset: LayoutPreset) async throws {
            for n in 0...4 {
                try setUpWorkspacesForTests()
                let (workspace, _) = try arranged(preset, n, auto: auto)
                try await openWindow(UInt32(n + 1), on: workspace)
                #expect(try workspace.rootTilingContainer.layoutDescription == built(preset, n + 1), "\(preset), \(n) windows, keep \(auto)")
            }
        }

        /// Main + stack 1 | 2, 3 with the main widened by hand and Keep off: 4 joins the foot of the stack, the sizes stay.
        @Test func keepOffLeavesTheSizes() async throws {
            let (workspace, windows) = try arranged(.mainStack, 3, auto: false)
            let main = windows[0]
            try main.setWeight(.h, 3)
            try await openWindow(4, on: workspace)
            #expect(try workspace.rootTilingContainer.layoutDescription ==
                .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(4)])]))
            #expect(try main.getWeight(.h) == 3)
        }
    }
}

extension LayoutDescription {
    /// The same tree with each window id mapped.
    func renumbered(_ id: (UInt32) -> UInt32) -> LayoutDescription {
        switch self {
            case .window(let window): .window(id(window))
            case .h_tiles(let children): .h_tiles(children.map { $0.renumbered(id) })
            case .v_tiles(let children): .v_tiles(children.map { $0.renumbered(id) })
            default: self
        }
    }
}
