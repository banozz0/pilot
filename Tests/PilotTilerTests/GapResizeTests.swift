// Card agent-bo-95423035: dragging the inner gap between two tiles moves the split. The hit test reads the last layout
// only (no AX); the drag shifts weight between the two tiles, so layout moves the split by the mouse's distance.
import AppKit
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct GapResizeTests {
        /// Window 1 beside a stack of 2 over 3, laid out on the 1920 x 1080 test monitor with 10-point inner gaps: 1 is
        /// 0 to 955, the stack 965 to 1920, 2 above 3 with the gap at 534.5 to 544.5.
        @discardableResult
        private func laidOut(outer: Int = 0) async throws -> (workspace: Workspace, stack: TilingContainer) {
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10),
                               outer: .init(left: outer, bottom: outer, top: outer, right: outer))
            var stack: TilingContainer!
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    stack = try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1, index: INDEX_BIND_LAST).with {
                        try TestWindow.new(id: 2, parent: $0)
                        try TestWindow.new(id: 3, parent: $0)
                    }
                }
            }
            #expect(workspace.focusWorkspace())
            try await workspace.layoutWorkspace()
            return (workspace, stack)
        }

        private func window(_ id: UInt32) throws -> TestWindow { try #require(Window.get(byId: id) as? TestWindow) }

        /// Presses at `from`, drags to `to` and lays the result out, as the drag's session does.
        private func drag(from: CGPoint, to: CGPoint, _ workspace: Workspace) async throws {
            unitTestScreen.withLock { $0.mouse = from }
            #expect(pressGap())
            unitTestScreen.withLock { $0.mouse = to }
            try moveGap()
            try await workspace.layoutWorkspace()
        }

        @Test func aPointInAnInnerGapNamesItsTwoTilesAndOrientation() async throws {
            let (workspace, stack) = try await laidOut()
            let between = try #require(innerGap(at: CGPoint(x: 960, y: 500)))
            #expect(try between.container === workspace.rootTilingContainer && between.orientation == .h)
            #expect(try between.tiles.0 === window(1) && between.tiles.1 === stack)
            let stacked = try #require(innerGap(at: CGPoint(x: 1400, y: 540)))
            #expect(stacked.container === stack && stacked.orientation == .v)
            #expect(try stacked.tiles.0 === window(2) && stacked.tiles.1 === window(3))
        }

        @Test func insideATileOrOnAnOuterGapIsNoGap() async throws {
            try await laidOut(outer: 20)
            #expect(innerGap(at: CGPoint(x: 400, y: 500)) == nil) // window 1
            #expect(innerGap(at: CGPoint(x: 1400, y: 300)) == nil) // window 2
            #expect(innerGap(at: CGPoint(x: 10, y: 500)) == nil) // the left outer gap
            #expect(innerGap(at: CGPoint(x: 1910, y: 500)) == nil) // the right outer gap
            #expect(innerGap(at: CGPoint(x: 960, y: 10)) == nil) // the top outer gap, above the inner one
            #expect(innerGap(at: CGPoint(x: 960, y: 500)) != nil)
        }

        @Test func theHitTestReadsTheLastLayoutOnly() async throws {
            try await laidOut()
            let reads = try [1, 2, 3].map { try window($0).axReads }
            for x in stride(from: 0, through: 1920, by: 40) { _ = innerGap(at: CGPoint(x: CGFloat(x), y: 540)) }
            #expect(try [1, 2, 3].map { try window($0).axReads } == reads)
        }

        @Test func draggingTheGapMovesTheSplitByTheDistance() async throws {
            let (workspace, stack) = try await laidOut()
            let root = try workspace.rootTilingContainer
            let total = try window(1).getWeight(.h) + stack.getWeight(.h)
            try await drag(from: CGPoint(x: 960, y: 500), to: CGPoint(x: 1060, y: 520), workspace)
            #expect(try window(1).axRect?.width == 1055)
            #expect(try window(2).axRect?.minX == 1065 && window(3).axRect?.width == 855)
            #expect(try window(1).getWeight(.h) + stack.getWeight(.h) == total)
            // The stack's own split stays where it was: the drag moved along the root's orientation only.
            #expect(try window(2).axRect?.height == 534.5 && root.orientation == .h)
        }

        @Test func aStackedGapMovesUpAndDown() async throws {
            let (workspace, _) = try await laidOut()
            try await drag(from: CGPoint(x: 1400, y: 540), to: CGPoint(x: 1300, y: 440), workspace)
            #expect(try window(2).axRect?.height == 434.5 && window(3).axRect?.minY == 444.5)
            #expect(try window(1).axRect?.width == 955) // the root's split stays
        }

        @Test func neitherTileGoesUnderTheMinimum() async throws {
            let (workspace, _) = try await laidOut()
            try await drag(from: CGPoint(x: 960, y: 500), to: CGPoint(x: 1915, y: 500), workspace)
            let right = try #require(try window(2).axRect)
            #expect(right.width >= GapDrag.minimumTile && right.width < GapDrag.minimumTile + 10)
            try moveGap(to: CGPoint(x: 0, y: 500))
            try await workspace.layoutWorkspace()
            let left = try #require(try window(1).axRect)
            #expect(left.width >= GapDrag.minimumTile && left.width < GapDrag.minimumTile + 10)
        }

        @Test func aPressOffAGapStartsNothingAndTheReleaseEndsIt() async throws {
            let (workspace, _) = try await laidOut()
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 400, y: 500) }
            #expect(!pressGap() && gapDrag == nil)
            try await drag(from: CGPoint(x: 960, y: 500), to: CGPoint(x: 1000, y: 500), workspace)
            #expect(gapDrag != nil)
            releaseGap()
            #expect(gapDrag == nil)
            try moveGap(to: CGPoint(x: 1200, y: 500)) // after the release, a move changes nothing
            try await workspace.layoutWorkspace()
            #expect(try window(1).axRect?.width == 995)
        }

        @Test func theSplitFollowsTheMouseWithoutGliding() async throws {
            let (workspace, _) = try await laidOut()
            try await drag(from: CGPoint(x: 960, y: 500), to: CGPoint(x: 1060, y: 500), workspace)
            #expect(try window(1).lastGlidingFrom == nil && window(2).lastGlidingFrom == nil)
        }

        @Test func aClosedTileEndsTheDrag() async throws {
            let (workspace, _) = try await laidOut()
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 960, y: 500) }
            #expect(pressGap())
            try window(1).closeAxWindow()
            try moveGap(to: CGPoint(x: 1200, y: 500))
            #expect(gapDrag == nil)
            try await workspace.layoutWorkspace()
        }

        @Test func aHeldGapIsNoWindowsDragOrResize() async throws {
            try await laidOut()
            try window(1).nativeFocus()
            unitTestScreen.withLock { $0.leftMouseDown = true }
            #expect(try await isManipulatedWithMouse(window(1))) // the focused tile under a held button, as AeroSpace reads it
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 960, y: 500) }
            #expect(pressGap())
            // The split's own frame writes come back as the focused tile's moved and resized events: no drag, no resize.
            #expect(try await !isManipulatedWithMouse(window(1)))
        }

        @Test func stoppingTilingLetsTheGapGo() async throws {
            try await laidOut()
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 960, y: 500) }
            #expect(pressGap())
            isTilerEnabled = true
            await setTilerEnabled(false)
            #expect(gapDrag == nil)
        }

        @Test func layoutHandsPilotEveryVisibleInnerGapOnce() async throws {
            var shown: [[TilerGap]] = []
            TilerGaps.show = { shown.append($0) }
            isTilerEnabled = true
            defer { TilerGaps.show = { _ in }; isTilerEnabled = false }
            let (workspace, _) = try await laidOut()
            publishGaps()
            publishGaps() // unchanged: not sent again
            #expect(shown.count == 1)
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 960, y: 500) }
            #expect(pressGap())
            try moveGap(to: CGPoint(x: 1060, y: 500))
            try await workspace.layoutWorkspace()
            publishGaps() // a held gap's handles stay put
            #expect(shown.count == 1)
            releaseGap()
            publishGaps()
            #expect(shown.count == 2 && shown.last?.first?.frame.minX == 1055)
            isTilerEnabled = false
            publishGaps() // the engine off: none
            #expect(shown.last == [])
            // AppKit's frames (y up from the main screen's bottom): the root's gap full height, the stack's across it.
            #expect(shown.first == [TilerGap(frame: NSRect(x: 955, y: 1, width: 10, height: 1079), vertical: true),
                                    TilerGap(frame: NSRect(x: 965, y: 535.5, width: 955, height: 10), vertical: false)])
            #expect(innerGaps(of: try #require(Workspace.existing(byName: name))).count == 2)
        }

        @Test func perMoveCost() async throws {
            let (workspace, _) = try await laidOut()
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 960, y: 500) }
            #expect(pressGap())
            let clock = ContinuousClock()
            let moves = 200
            let elapsed = try await clock.measure {
                for i in 0..<moves {
                    try moveGap(to: CGPoint(x: 960 + CGFloat(i % 100), y: 500))
                    try await workspace.layoutWorkspace()
                }
            }
            print("gap resize: \(elapsed / moves) per move (weights + layout of 3 fake windows)")
            #expect(elapsed / moves < .milliseconds(2))
        }
    }
}
