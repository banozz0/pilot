// Story 119 (Sven on build 19, 2026-10-10: Cmd+left-drag of a tiled Ghostex "spazzing", "completely broken"): Pilot's
// modifier move of a tiled window. Pilot's tap swallows the press and focuses the window only after it, so the tiler
// cannot tell the move from any other by the button and the focused window; Pilot says so itself (TilerDrag.begin) and
// ends it once its last frame is written. Simulated with Pilot's own coalescer and AX writes that take 10 ms.
import AppKit
import PilotCore
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct PilotDragTests {
        private func window(_ id: UInt32) throws -> TestWindow { try #require(Window.get(byId: id) as? TestWindow) }

        /// Window 1 (Ghostex) alone in the left column, window 2 (Pilot's app window) the right one, laid out; 1 focused.
        private func laidOut() async throws -> Workspace {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    try TestWindow.new(id: 2, parent: $0)
                }
            }
            #expect(workspace.focusWorkspace())
            try await layOut(workspace)
            try window(1).nativeFocus()
            return workspace
        }

        private func layOut(_ workspace: Workspace) async throws {
            try workspace.normalizeContainers()
            try await workspace.layoutWorkspace()
        }

        /// Lets the tiler's move handlers (each a task) run.
        private func settle() async { for _ in 0..<50 { await Task.yield() } }

        /// The drag in Sven's log, as the tiler meets it: the press never reached it (the left button reads up), the mouse
        /// at 1000 Hz for 800 ms from window 1's middle to window 2's, Pilot's writes through LatestWins at 100 Hz, each
        /// landing 10 ms after it starts and heard as the window's move, and a session laying the workspace out every 50
        /// ms (the activation's refresh, or one a pause in the moves let finish). Then the release over window 2.
        private func simulatedMove(_ workspace: Workspace) async throws -> (tilerWrites: Int, snapBacks: Int, pilotWrites: Int) {
            let dragged = try window(1)
            let tile = try #require(dragged.axRect)
            let start = CGPoint(x: 480, y: 500), end = CGPoint(x: 1440, y: 500)
            var laidIn = false
            scheduleDragPreview = { laidIn = true }
            defer { scheduleDragPreview = previewInASession }
            unitTestScreen.withLock { $0.mouse = start; $0.leftMouseDown = false }
            isTilerEnabled = true // for the call alone: a session here would refresh the Mac's real apps
            #expect(TilerDrag.begin(1))
            isTilerEnabled = false

            var frames = LatestWins<CGPoint>(interval: 0.010)
            var inFlight: (lands: Int, point: CGPoint)?
            var wakes: Int?
            var written = start
            let before = dragged.frameWrites
            var snapBacks = 0, pilotWrites = 0
            func handle(_ step: LatestWins<CGPoint>.Step, at ms: Int) {
                switch step {
                case .write(let point): inFlight = (ms + 10, point)
                case .wait(let delay): wakes = ms + Int((delay * 1000).rounded(.up))
                case .idle: break
                }
            }
            for ms in 0...800 {
                let now = Double(ms) / 1000
                let mouse = CGPoint(x: start.x + (end.x - start.x) * CGFloat(ms) / 800, y: start.y)
                unitTestScreen.withLock { $0.mouse = mouse }
                if let write = inFlight, write.lands == ms {
                    inFlight = nil
                    written = write.point
                    pilotWrites += 1
                    dragged.movedByPilot(to: Rect(topLeftX: tile.minX + written.x - start.x, topLeftY: tile.minY + written.y - start.y, width: tile.width, height: tile.height))
                    windowMoved(1, kAXMovedNotification as String)
                    await settle()
                    handle(frames.written(now: now), at: ms)
                }
                if let wake = wakes, wake <= ms { wakes = nil; handle(frames.woke(now: now), at: ms) }
                handle(frames.offer(mouse, now: now), at: ms)
                if ms % 50 == 25 {
                    if laidIn { laidIn = false; try previewDrop(at: mouseLocation) }
                    try await layOut(workspace)
                    if dragged.axRect == tile && abs(written.x - start.x) > 20 { snapBacks += 1 }
                }
            }
            return (dragged.frameWrites - before, snapBacks, pilotWrites)
        }

        @Test func aTiledMoveIsPilotsAloneAndItsReleaseSwaps() async throws {
            let workspace = try await laidOut()
            let target = try #require(try window(2).axRect)
            let (tilerWrites, snapBacks, pilotWrites) = try await simulatedMove(workspace)
            print("[story119] tiled move, 800 ms: \(pilotWrites) Pilot writes, \(tilerWrites) tiler writes to the dragged window, \(snapBacks) snap-backs to its tile")
            #expect(tilerWrites == 0, "layout leaves the dragged window to Pilot")
            #expect(snapBacks == 0)

            currentlyManipulatedWithMouseWindowId = nil // what TilerDrag.end resets before its drop
            try releaseDrag(at: CGPoint(x: 1440, y: 500))
            try await layOut(workspace)
            #expect(try workspace.rootTilingContainer.layoutDescription == .h_tiles([.window(2), .window(1)]))
            #expect(try window(1).axRect == target, "it lands in window 2's tile")
            #expect(draggedWindowId == nil)
        }

        /// The outline Pilot draws for a right drag: the mouse's frame inside the tiler's reach, as DragSession draws it.
        private func outline(_ id: UInt32, dragging from: CGPoint, to point: CGPoint) throws -> (box: CGRect, reach: EdgeReach) {
            let frame = try #require(try window(id).axRect).cgRect
            let drag = try #require(MouseDrag.begin(.right, flags: KeyEvent.cmdMask, at: from, modifier: .cmd, window: (Int(id), frame)))
            isTilerEnabled = true
            defer { isTilerEnabled = false }
            let reach = try #require(TilerDrag.reach(id))
            return (drag.frame(at: point, within: reach), reach)
        }

        /// Sven on build 19: the box followed the mouse both ways, the release changed only the width.
        @Test func aLoneColumnsBoxGrowsOnlyItsWidthAndTheReleaseIsTheBox() async throws {
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .zero)
            let workspace = try await laidOut()
            let before = try #require(try window(1).axRect).cgRect
            // Bottom-right quadrant, dragged right and down.
            let (box, reach) = try outline(1, dragging: CGPoint(x: 900, y: 900), to: CGPoint(x: 1100, y: 1000))
            #expect(reach.left == nil && reach.top == nil && reach.bottom == nil && reach.right != nil)
            #expect(box == CGRect(x: before.minX, y: before.minY, width: before.width + 200, height: before.height), "no height")
            try window(1).dragResize(to: box)
            try await layOut(workspace)
            #expect(try window(1).axRect?.cgRect == box, "the release lands exactly the box")
            #expect(try window(2).axRect?.minX == box.maxX + 10, "its neighbour gave the width")
        }

        @Test func theBoxStopsWhereTheNeighbourReachesItsMinimum() async throws {
            let workspace = try await laidOut()
            let (box, _) = try outline(1, dragging: CGPoint(x: 900, y: 500), to: CGPoint(x: 5000, y: 500))
            #expect(box.maxX == 1920 - WindowGeometry.minimumSize.width)
            try window(1).dragResize(to: box)
            try await layOut(workspace)
            #expect(try window(1).axRect?.cgRect == box)
            #expect(try window(2).axRect?.width == WindowGeometry.minimumSize.width)
        }

        @Test func aStackedWindowsBoxMovesItsBottomEdgeAndTheReleaseIsTheBox() async throws {
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .zero)
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    try TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).with {
                        try TestWindow.new(id: 2, parent: $0)
                        try TestWindow.new(id: 3, parent: $0)
                    }
                }
            }
            #expect(workspace.focusWorkspace())
            try await layOut(workspace)
            let before = try #require(try window(2).axRect).cgRect
            // Window 2, top right: its bottom-left quadrant dragged left and down.
            let (box, reach) = try outline(2, dragging: CGPoint(x: before.minX + 50, y: before.maxY - 50),
                                           to: CGPoint(x: before.minX - 100, y: before.maxY + 120))
            #expect(reach.right == nil && reach.top == nil && reach.left != nil && reach.bottom != nil)
            #expect(box == CGRect(x: before.minX - 150, y: before.minY, width: before.width + 150, height: before.height + 170))
            try window(2).dragResize(to: box)
            try await layOut(workspace)
            #expect(try window(2).axRect?.cgRect == box)
        }
    }
}
