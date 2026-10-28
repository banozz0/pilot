// Card agent-bo-95423034: while a tiled window is dragged, the drop under the mouse is laid into the tree and laid out, so
// the other windows glide aside; the release keeps it, Esc or the window's own tile puts the committed tree back. The
// two-monitor tree of DropWithMouseTests, laid out for real (TestWindow keeps the frames layout writes).
import AppKit
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct LiveSwapTests {
        private let second = MonitorInfoImpl(
            monitorAppKitNsScreenScreensId: 2,
            name: "Second Monitor",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            isMain: false,
        )

        /// Window 1 beside a stack of 2 over 5 on the first monitor, 3 and 4 side by side on the second, laid out; 1 and 3
        /// most recent, against their order. Containers flatten, so taking window 1 out leaves the stack as the left root.
        private func twoMonitors() async throws -> (left: Workspace, right: Workspace) {
            config.enableNormalizationFlattenContainers = true
            let left = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1, index: INDEX_BIND_LAST).with {
                        try TestWindow.new(id: 2, parent: $0)
                        try TestWindow.new(id: 5, parent: $0)
                    }
                }
            }
            #expect(left.focusWorkspace())
            unitTestScreen.withLock { $0.monitors.append(second) }
            gcMonitors()
            let right = try second.activeWorkspace.with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 3, parent: $0)
                    try TestWindow.new(id: 4, parent: $0)
                }
            }
            try window(1).markAsMostRecentChild()
            try window(3).markAsMostRecentChild()
            try await layOut(left, right)
            return (left, right)
        }

        /// A session's model refresh and layout, as runLightSession runs them round a preview.
        private func layOut(_ workspaces: Workspace...) async throws { try await layOut(workspaces) }

        private func layOut(_ workspaces: [Workspace]) async throws {
            for workspace in workspaces { try workspace.normalizeContainers() }
            try arrangeAutoWorkspaces()
            for workspace in workspaces { try await workspace.layoutWorkspace() }
        }

        /// Moves the mouse to `point` as the dragged window's move event does, and lays the preview out when it asks.
        private func move(to point: CGPoint, _ workspaces: Workspace...) async throws {
            unitTestScreen.withLock { $0.mouse = point }
            var asked = false
            let previous = scheduleDragPreview
            scheduleDragPreview = { asked = true }
            defer { scheduleDragPreview = previous }
            dragMoved()
            guard asked else { return }
            try previewDrop(at: mouseLocation)
            try await layOut(workspaces)
        }

        private func window(_ id: UInt32) throws -> TestWindow { try #require(Window.get(byId: id) as? TestWindow) }

        private func frames(_ ids: [UInt32]) throws -> [UInt32: Rect?] {
            try Dictionary(uniqueKeysWithValues: ids.map { ($0, try window($0).axRect) })
        }

        @Test func hoverThenEscPutsTheCommittedTreeBack() async throws {
            let (left, right) = try await twoMonitors()
            let others: [UInt32] = [2, 3, 4, 5]
            let laidOut = try frames(others)
            startDrag(try window(1))
            let committed = try TreeState(left, right)

            // Right half of window 3: window 1 after it, as the drop would leave it; the left stack is the left root now.
            try await move(to: CGPoint(x: 2600, y: 500), left, right)
            #expect(try right.rootTilingContainer.layoutDescription == .h_tiles([.window(3), .window(1), .window(4)]))
            #expect(try left.rootTilingContainer.layoutDescription == .v_tiles([.window(2), .window(5)]))
            let previewed = try frames(others)
            #expect(previewed[3] != laidOut[3] && previewed[2] != laidOut[2], "the others moved aside")

            try cancelDrag()
            try await layOut(left, right)
            #expect(try TreeState(left, right) == committed, "the same containers, order, weights, MRU and frames")
            #expect(try frames(others) == laidOut)
            #expect(try window(3).lastGlidingFrom == previewed[3], "it glides back from where the preview put it")
            #expect(draggedWindowId == nil && dragPreview == nil)
        }

        @Test func hoveringBackOverItsOwnTilePutsTheOthersBack() async throws {
            let (left, right) = try await twoMonitors()
            let laidOut = try frames([2, 3, 4, 5])
            startDrag(try window(1))
            let committed = try TreeState(left, right)
            try await move(to: CGPoint(x: 2600, y: 500), left, right)
            try await move(to: CGPoint(x: 400, y: 500), left, right) // its own tile: a release there leaves it
            #expect(dragPreview == nil)
            #expect(try TreeState(left, right) == committed)
            #expect(try frames([2, 3, 4, 5]) == laidOut)
        }

        @Test func theReleaseKeepsExactlyThePreview() async throws {
            let (left, right) = try await twoMonitors()
            startDrag(try window(1))
            let landing = try #require(try dropLanding(at: CGPoint(x: 2600, y: 500)))
            try await move(to: CGPoint(x: 2600, y: 500), left, right)
            #expect(dragPreview?.landing == landing)
            let previewed = try frames([2, 3, 4, 5])
            let tree = try (left.rootTilingContainer.layoutDescription, right.rootTilingContainer.layoutDescription)

            currentlyManipulatedWithMouseWindowId = nil // the mouse-up's reset, before the drop
            try dropDraggedWindow(at: CGPoint(x: 2610, y: 520)) // still the right half of window 3
            try await layOut(left, right)
            #expect(try (left.rootTilingContainer.layoutDescription, right.rootTilingContainer.layoutDescription) == tree)
            #expect(try frames([2, 3, 4, 5]) == previewed)
            #expect(try window(1).axRect == landing, "it lands where the drop zone showed")
        }

        @Test func aReleaseElsewhereDropsThereInstead() async throws {
            let (left, right) = try await twoMonitors()
            startDrag(try window(1))
            try await move(to: CGPoint(x: 2600, y: 500), left, right)
            try dropDraggedWindow(at: CGPoint(x: 2000, y: 500)) // left half of window 3, no move event first
            #expect(try right.rootTilingContainer.layoutDescription == .h_tiles([.window(1), .window(3), .window(4)]))
            #expect(dragPreview == nil)
        }

        @Test func movesInsideTheSameTargetLayNothingOut() async throws {
            let (left, right) = try await twoMonitors()
            var asked = 0
            scheduleDragPreview = { asked += 1 }
            startDrag(try window(1))
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 400, y: 500) }
            dragMoved() // its own tile, nothing previewed: nothing to lay out
            #expect(asked == 0)

            try await move(to: CGPoint(x: 2600, y: 500), left, right)
            let ids: [UInt32] = [1, 2, 3, 4, 5]
            for id in ids { try window(id).frameWrites = 0 }
            for point in [CGPoint(x: 2500, y: 100), CGPoint(x: 2870, y: 1000), CGPoint(x: 2440, y: 540)] {
                try await move(to: point, left, right) // still the right half of window 3
            }
            #expect(try ids.map { try window($0).frameWrites } == [0, 0, 0, 0, 0], "no frame writes while the target holds")

            unitTestScreen.withLock { $0.mouse = CGPoint(x: 2000, y: 500) }
            dragMoved() // the left half of window 3: another drop
            #expect(asked == 1)

            let clock = ContinuousClock()
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 2600, y: 500) }
            let elapsed = clock.measure { for _ in 0..<10_000 { dragMoved() } }
            print("live swap, a move inside the previewed target: \(elapsed / 10_000) per move")
            #expect(elapsed / 10_000 < .microseconds(20))
        }

        @Test func aSwapGlidesTheOtherWindowIntoTheDraggedOnesTile() async throws {
            let (left, right) = try await twoMonitors()
            let laidOut = try frames([2])
            startDrag(try window(1))
            try await move(to: CGPoint(x: 1500, y: 200), left, right) // over window 2, its own workspace
            #expect(try left.rootTilingContainer.layoutDescription == .h_tiles([.window(2), .v_tiles([.window(1), .window(5)])]))
            #expect(try window(2).lastGlidingFrom == laidOut[2] ?? nil, "it glides from its tile")
            #expect(try window(2).axRect?.minX == 0)
        }

        @Test func anAutoWorkspaceGetsItsArrangementBack() async throws {
            let (left, right) = try await twoMonitors()
            try TestWindow.new(id: 6, parent: right.rootTilingContainer)
            try right.arrange(WorkspaceArrangement(.mainStack, auto: true, order: [3, 4, 6]))
            try await layOut(left, right) // main 3, stack of 4 over 6
            startDrag(try window(1))
            let committed = try TreeState(left, right)
            try await move(to: CGPoint(x: 1930, y: 500), left, right) // the main tile's left edge: window 1 is main
            #expect(arrangements[right.name]?.order == [1, 3, 4, 6])
            try cancelDrag()
            try await layOut(left, right)
            #expect(arrangements[right.name]?.order == [3, 4, 6])
            #expect(try TreeState(left, right) == committed)
        }

        /// Moody REJECT lqjktf2-UEU: a session that left no preview (the mouse back on its own tile) dropped the move that
        /// came while it ran, onto a target, so the others stayed put until the mouse moved again.
        @Test func aMoveDuringASessionIsLaidInAfterIt() async throws {
            let (left, right) = try await twoMonitors()
            startDrag(try window(1))
            try await move(to: CGPoint(x: 2600, y: 500), left, right)
            isTilerEnabled = true
            defer { isTilerEnabled = false }
            var sessions = 0
            var gate: CheckedContinuation<Void, Never>?
            runDragPreviewSession = { body in
                try body()
                sessions += 1
                await withCheckedContinuation { gate = $0 }
            }
            defer { runDragPreviewSession = { body in try await runLightSession(.dragPreview, .forceRun, body: body) } }
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 400, y: 500) } // its own tile: the session puts the tree back
            dragMoved()
            for _ in 0..<1000 where gate == nil { await Task.yield() }
            #expect(sessions == 1 && dragPreview == nil)
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 2000, y: 500) } // a target, while that session still runs
            dragMoved()
            gate?.resume()
            gate = nil
            for _ in 0..<1000 where gate == nil { await Task.yield() }
            #expect(sessions == 2 && dragPreview != nil, "the missed move is laid in once the session ends")
            gate?.resume()
        }

        @Test func escEndsTheDragForGood() async throws {
            let (left, right) = try await twoMonitors()
            var shown: [NSRect?] = []
            TilerDropZone.show = { frame, _ in shown.append(frame) }
            defer { TilerDropZone.show = { _, _ in } }
            startDrag(try window(1))
            try await move(to: CGPoint(x: 2600, y: 500), left, right)
            #expect(shown.last.flatMap { $0 } == dragPreview?.landing.appKitFrame)
            try cancelDrag()
            #expect(shown.last == .some(nil), "the drop zone goes")
            let tree = try (left.rootTilingContainer.layoutDescription, right.rootTilingContainer.layoutDescription)
            var asked = false
            scheduleDragPreview = { asked = true }
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 2000, y: 500) }
            dragMoved()
            try dropDraggedWindow(at: mouseLocation)
            #expect(!asked && cancelledDragWindowId == 1)
            #expect(try (left.rootTilingContainer.layoutDescription, right.rootTilingContainer.layoutDescription) == tree)
        }
    }
}

/// Every tiled node of some workspaces as the tree holds it: which object, its children, weights, MRU, frames and shape.
@MainActor
private struct TreeState: Equatable {
    struct Node: Equatable {
        let id: ObjectIdentifier
        let weight: CGFloat?
        let physical: Rect?
        let virtual: Rect?
        let shape: String?
        let children: [ObjectIdentifier]
        let mru: [ObjectIdentifier]
    }

    let nodes: [Node]

    init(_ workspaces: Workspace...) throws {
        var nodes: [Node] = []
        func add(_ node: TreeNode) throws {
            let container = node as? TilingContainer
            nodes.append(Node(
                id: ObjectIdentifier(node),
                weight: (node.parent as? TilingContainer).map { try? node.getWeight($0.orientation) } ?? nil,
                physical: node.lastAppliedLayoutPhysicalRect,
                virtual: node.lastAppliedLayoutVirtualRect,
                shape: container.map { "\($0.orientation) \($0.layout)" },
                children: node.children.map(ObjectIdentifier.init),
                mru: node.mruChildren.map(ObjectIdentifier.init),
            ))
            for child in node.children { try add(child) }
        }
        for workspace in workspaces { try add(workspace.rootTilingContainer) }
        self.nodes = nodes
    }
}
