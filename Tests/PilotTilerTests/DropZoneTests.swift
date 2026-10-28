// Card agent-bo-95423032: while a tiled window is dragged, the engine names the frame it would land in from its last
// layout (no AX), and Pilot's overlay shows it until the release. The two-monitor tree of DropWithMouseTests.
import AppKit
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct DropZoneTests {
        private let second = MonitorInfoImpl(
            monitorAppKitNsScreenScreensId: 2,
            name: "Second Monitor",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            isMain: false,
        )

        /// Windows 1 and 2 side by side on the first monitor, 3 and 4 on the second (none with `rightEmpty`), laid out
        /// as halves of their screens.
        @discardableResult
        private func twoMonitors(rightEmpty: Bool = false) throws -> (left: Workspace, right: Workspace) {
            let left = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    try TestWindow.new(id: 2, parent: $0)
                }
            }
            #expect(left.focusWorkspace())
            unitTestScreen.withLock { $0.monitors.append(second) }
            gcMonitors()
            let right = second.activeWorkspace
            if !rightEmpty {
                try right.rootTilingContainer.with {
                    try TestWindow.new(id: 3, parent: $0)
                    try TestWindow.new(id: 4, parent: $0)
                }
            }
            for id in UInt32(1)...(rightEmpty ? 2 : 4) {
                try #require(Window.get(byId: id)).lastAppliedLayoutPhysicalRect = Rect(topLeftX: CGFloat(id - 1) * 960, topLeftY: 0, width: 960, height: 1080)
            }
            try left.rootTilingContainer.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
            try right.rootTilingContainer.lastAppliedLayoutPhysicalRect = second.visibleRect
            return (left, right)
        }

        private func landing(dragging id: UInt32, at point: CGPoint) throws -> Rect? {
            startDrag(try #require(Window.get(byId: id)))
            return try dropLanding(at: point)
        }

        @Test func sameWorkspaceShowsTheTileItSwapsWith() throws {
            try twoMonitors()
            #expect(try landing(dragging: 1, at: CGPoint(x: 1500, y: 500)) == Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 1080))
        }

        @Test func itsOwnTileShowsNothing() throws {
            try twoMonitors()
            startDrag(try #require(Window.get(byId: 1)))
            // At the drag's start (draggedWindowId's didSet) its own frame is still in place: under the point, it is no swap.
            try #require(Window.get(byId: 1)).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080)
            #expect(try dropLanding(at: CGPoint(x: 400, y: 500)) == nil)
        }

        @Test func aGapOnItsOwnWorkspaceShowsNothing() throws {
            try twoMonitors()
            try #require(Window.get(byId: 1)).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 955, height: 1080)
            try #require(Window.get(byId: 2)).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 965, topLeftY: 0, width: 955, height: 1080)
            #expect(try landing(dragging: 1, at: CGPoint(x: 960, y: 500)) == nil)
        }

        @Test func unequalTilesShowWhereLayoutPutsTheInsertedWindow() throws {
            let (_, right) = try twoMonitors()
            // Window 3 is 1200 wide, window 4 720; dropped after 3, the new window's average weight 960 and layout's
            // shared delta (1920 - 2880) / 3 put it at 880 to 1520 of the screen.
            let root = try right.rootTilingContainer
            try #require(Window.get(byId: 3)).setWeight(root.orientation, 1200)
            try #require(Window.get(byId: 4)).setWeight(root.orientation, 720)
            try #require(Window.get(byId: 3)).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 1920, topLeftY: 0, width: 1200, height: 1080)
            try #require(Window.get(byId: 4)).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 3120, topLeftY: 0, width: 720, height: 1080)
            #expect(try landing(dragging: 1, at: CGPoint(x: 2720, y: 500)) == Rect(topLeftX: 2800, topLeftY: 0, width: 640, height: 1080))
        }

        @Test func otherWorkspaceShowsTheSideOfTheTileUnderIt() throws {
            try twoMonitors()
            // Right half of window 3: a third column after it, as the drop's bind with an average weight leaves it.
            #expect(try landing(dragging: 1, at: CGPoint(x: 2600, y: 500)) == Rect(topLeftX: 2560, topLeftY: 0, width: 640, height: 1080))
            // Left half of window 3: the first third.
            #expect(try dropLanding(at: CGPoint(x: 2000, y: 500)) == Rect(topLeftX: 1920, topLeftY: 0, width: 640, height: 1080))
        }

        @Test func innerGapsAreLeftBetweenTiles() throws {
            try twoMonitors()
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .zero)
            #expect(try landing(dragging: 1, at: CGPoint(x: 2600, y: 500)) == Rect(topLeftX: 2565, topLeftY: 0, width: 630, height: 1080))
            #expect(try dropLanding(at: CGPoint(x: 2000, y: 500)) == Rect(topLeftX: 1920, topLeftY: 0, width: 635, height: 1080))
        }

        @Test func anEmptyWorkspaceShowsAllOfIt() throws {
            try twoMonitors(rightEmpty: true)
            #expect(try landing(dragging: 1, at: CGPoint(x: 2600, y: 500)) == second.visibleRect)
        }

        @Test func autoWorkspaceShowsThePresetSlot() throws {
            let (_, right) = try twoMonitors()
            arrangements = [right.name: WorkspaceArrangement(.mainStack, auto: true, order: [3, 4])]
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .zero)
            // Bottom half of the stack's only tile (window 4): after it, the lower half of the stack.
            #expect(try landing(dragging: 1, at: CGPoint(x: 3500, y: 1000)) == Rect(topLeftX: 2885, topLeftY: 545, width: 955, height: 535))
            // Left edge of the main tile: the main window.
            #expect(try dropLanding(at: CGPoint(x: 1930, y: 500)) == Rect(topLeftX: 1920, topLeftY: 0, width: 955, height: 1080))
        }

        /// Scrolling layout spec: a drop on a strip shows the column it gets, at a new column's width and in its place on
        /// the strip as the next layout scrolls it into view, auto or not.
        @Test func aStripShowsTheColumnTheDropGets() throws {
            let (_, right) = try twoMonitors()
            try right.rootTilingContainer.layout = .scrolling
            config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .zero)
            let third = (1920 + 10) * config.scrollingNewWidth - 10
            func column(_ slot: CGFloat) -> Rect { Rect(topLeftX: 1920 + slot * (third + 10), topLeftY: 0, width: third, height: 1080) }
            func close(_ a: Rect?, _ b: Rect) -> Bool { a.map { abs($0.minX - b.minX) < 0.01 && abs($0.width - b.width) < 0.01 && $0.height == b.height } == true }
            // Right half of window 3: the second column.
            #expect(close(try landing(dragging: 1, at: CGPoint(x: 2600, y: 500)), column(1)))
            arrangements = [right.name: WorkspaceArrangement(.scrolling, auto: true, order: [3, 4])]
            // Right half of window 4: the third column.
            #expect(close(try dropLanding(at: CGPoint(x: 3500, y: 500)), column(2)))
        }

        /// The live swap's preview on a strip scrolls it; Esc puts the scroll back with the tree.
        @Test func escOnAStripPutsItsScrollBack() throws {
            let (_, right) = try twoMonitors()
            let root = try right.rootTilingContainer
            root.layout = .scrolling
            root.stripOffset = 120
            startDrag(try #require(Window.get(byId: 1)))
            try previewDrop(at: CGPoint(x: 2600, y: 500))
            #expect(dragPreview != nil)
            root.stripOffset = 400 // the preview's layout scrolled the strip
            try cancelDrag()
            #expect(root.stripOffset == 120)
        }

        @Test func autoWorkspaceInTheSameOrderShowsNothing() throws {
            let (left, _) = try twoMonitors()
            arrangements = [left.name: WorkspaceArrangement(.columns, auto: true, order: [1, 2])]
            #expect(try landing(dragging: 1, at: CGPoint(x: 100, y: 500)) == nil)
            #expect(try dropLanding(at: CGPoint(x: 1800, y: 500)) == Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 1080))
        }

        @Test func theOverlayFollowsTheDragAndGoesAtTheRelease() throws {
            try twoMonitors()
            var shown: [(NSRect?, UInt32?)] = []
            TilerDropZone.show = { shown.append(($0, $1)) }
            defer { TilerDropZone.show = { _, _ in } }
            startDrag(try #require(Window.get(byId: 1)))
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 1500, y: 500) }
            updateDropZone()
            updateDropZone() // the same frame again: not redrawn
            #expect(shown.count == 1)
            // Window 2's tile, in AppKit's coordinates (y up from the main screen's bottom), below window 1.
            #expect(shown.first?.0 == NSRect(x: 960, y: 0, width: 960, height: 1080) && shown.first?.1 == 1)
            try dropDraggedWindow(at: mouseLocation)
            #expect(shown.count == 2 && shown.last?.0 == nil)
        }

        @Test func stoppingTheEngineMidDragHidesIt() throws {
            try twoMonitors()
            var shown: [NSRect?] = []
            TilerDropZone.show = { frame, _ in shown.append(frame) }
            defer { TilerDropZone.show = { _, _ in } }
            isTilerEnabled = true
            startDrag(try #require(Window.get(byId: 1)))
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 1500, y: 500) }
            updateDropZone()
            InProcessTiler(session: { _, body in try await body() }, otherTilerRunning: { false }).stop()
            #expect(shown.count == 2 && shown.last == .some(nil) && draggedWindowId == nil)
        }

        @Test func landingCostsUnderAFifthOfAMillisecond() throws {
            let workspace = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with { root in
                    for column in 0..<4 {
                        let stack = try TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                        for row in 0..<3 { try TestWindow.new(id: UInt32(column * 3 + row + 1), parent: stack) }
                    }
                }
            }
            #expect(workspace.focusWorkspace())
            for (column, stack) in try workspace.rootTilingContainer.children.enumerated() {
                stack.lastAppliedLayoutPhysicalRect = Rect(topLeftX: CGFloat(column) * 480, topLeftY: 0, width: 480, height: 1080)
            }
            for window in try workspace.rootTilingContainer.allLeafWindowsRecursive {
                let i = CGFloat(window.windowId - 1)
                window.lastAppliedLayoutPhysicalRect = Rect(topLeftX: (i / 3).rounded(.down) * 480, topLeftY: i.truncatingRemainder(dividingBy: 3) * 360, width: 480, height: 360)
            }
            startDrag(try #require(Window.get(byId: 1)))
            let clock = ContinuousClock()
            let runs = 1000
            // The fastest of five runs: a loaded Mac only adds time to a run, so the fastest is the landing's own cost (it failed
            // once in a full suite on a busy Mac, passing alone).
            let elapsed = try (0..<5).map { _ in try clock.measure { for i in 0..<runs { _ = try dropLanding(at: CGPoint(x: CGFloat(i % 1920), y: 700)) } } }.min()!
            let perMove = elapsed / runs
            print("drop landing on 12 windows: \(perMove) per move")
            #expect(perMove < .microseconds(200))
        }
    }
}
