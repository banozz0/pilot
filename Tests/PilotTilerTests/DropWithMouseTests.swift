// Card agent-bo-95422997, AC5 (cards agent-bo-95422860 and agent-bo-95422861 at the source): a dragged tiled window stays
// where it was in the tree until the mouse is released, then lands on the workspace under the pointer, in the slot under
// it. A fake pointer (UnitTestScreen.mouse) and a second test monitor to the right.
import AppKit
@testable import PilotTiler
import Testing

extension TilerTreeTests {
    @MainActor
    @Suite
    struct DropWithMouseTests {
        private let second = MonitorInfoImpl(
            monitorAppKitNsScreenScreensId: 2,
            name: "Second Monitor",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            isMain: false,
        )

        /// Windows 1 and 2 side by side on the first monitor, 3 and 4 on the second, each laid out as halves.
        private func twoMonitors() throws -> (left: Workspace, right: Workspace) {
            let left = try Workspace.get(byName: name).with {
                try $0.rootTilingContainer.with {
                    try TestWindow.new(id: 1, parent: $0)
                    try TestWindow.new(id: 2, parent: $0)
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
            for id in UInt32(1)...4 { // where layout put them: halves of their screens
                try #require(Window.get(byId: id)).lastAppliedLayoutPhysicalRect = Rect(topLeftX: CGFloat(id - 1) * 960, topLeftY: 0, width: 960, height: 1080)
            }
            return (left, right)
        }

        private func drag(_ id: UInt32, releasingAt point: CGPoint) throws {
            startDrag(try #require(Window.get(byId: id)))
            #expect(draggedWindowId == id && currentlyManipulatedWithMouseWindowId == id)
            unitTestScreen.withLock { $0.mouse = point }
            try dropDraggedWindow(at: mouseLocation)
            #expect(draggedWindowId == nil)
        }

        @Test func theTreeWaitsForTheRelease() throws {
            let (left, right) = try twoMonitors()
            let before = try (left.layoutDescription, right.layoutDescription)
            startDrag(try #require(Window.get(byId: 1)))
            unitTestScreen.withLock { $0.mouse = CGPoint(x: 2000, y: 500) }
            #expect(try (left.layoutDescription, right.layoutDescription) == before)
            #expect(Window.get(byId: 1)?.lastAppliedLayoutPhysicalRect == nil) // layout skips it
        }

        @Test func autoWorkspaceTakesTheSlotUnderTheRelease() throws {
            let (left, right) = try twoMonitors()
            arrangements = [right.name: WorkspaceArrangement(.columns, auto: true, order: [3, 4])]
            // Left half of window 4's column: before 4.
            try drag(1, releasingAt: CGPoint(x: 3000, y: 500))
            #expect(try right.rootTilingContainer.layoutDescription == .h_tiles([.window(3), .window(1), .window(4)]))
            #expect(arrangements[right.name]?.order == [3, 1, 4])
            #expect(try left.rootTilingContainer.layoutDescription == .h_tiles([.window(2)]))
        }

        @Test func autoWorkspaceTakesTheFarEdge() throws {
            let (_, right) = try twoMonitors()
            arrangements = [right.name: WorkspaceArrangement(.mainStack, auto: true, order: [3, 4])]
            // Left edge of the main column: first, so it becomes the main window.
            try drag(2, releasingAt: CGPoint(x: 1930, y: 500))
            #expect(try right.rootTilingContainer.layoutDescription == .h_tiles([.window(2), .v_tiles([.window(3), .window(4)])]))
        }

        /// Scrolling layout spec: an auto strip takes the drop by its x, before the column in view nearest the release or
        /// after it past its middle; a column hidden off the strip has no frame and is never the target.
        @Test func autoStripTakesTheDropByItsX() throws {
            let (_, right) = try twoMonitors()
            let root = try right.rootTilingContainer
            root.layout = .scrolling
            try TestWindow.new(id: 5, parent: root) // hidden past the edge: no frame
            try #require(Window.get(byId: 3)).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 1930, topLeftY: 10, width: 633, height: 1060)
            try #require(Window.get(byId: 4)).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 2573, topLeftY: 10, width: 1257, height: 1060)
            arrangements = [right.name: WorkspaceArrangement(.scrolling, auto: true, order: [3, 4, 5])]
            // Past window 4's middle, where hidden 5 would be: after 4, before 5.
            try drag(1, releasingAt: CGPoint(x: 3800, y: 500))
            #expect(arrangements[right.name]?.order == [3, 4, 1, 5])
            #expect(try root.layoutDescription == .h_scrolling([.window(3), .window(4), .window(1), .window(5)]))
            // Left of window 3's middle: first.
            try drag(2, releasingAt: CGPoint(x: 2000, y: 500))
            #expect(arrangements[right.name]?.order == [2, 3, 4, 1, 5])
        }

        @Test func otherWorkspaceWithoutPresetTakesTheSideOfTheWindowUnderIt() throws {
            let (left, right) = try twoMonitors()
            // Right half of window 3: after it.
            try drag(1, releasingAt: CGPoint(x: 2600, y: 500))
            #expect(try right.rootTilingContainer.layoutDescription == .h_tiles([.window(3), .window(1), .window(4)]))
            #expect(try left.rootTilingContainer.layoutDescription == .h_tiles([.window(2)]))
        }

        @Test func sameWorkspaceSwapsWithTheWindowUnderIt() throws {
            let (left, _) = try twoMonitors()
            try drag(1, releasingAt: CGPoint(x: 1500, y: 500))
            #expect(try left.rootTilingContainer.layoutDescription == .h_tiles([.window(2), .window(1)]))
        }

        @Test func aFloatingWindowIsNoDrag() throws {
            _ = try twoMonitors()
            let floating = try TestWindow.new(id: 9, parent: focus.workspace.floatingWindowsContainer)
            startDrag(floating)
            #expect(draggedWindowId == nil)
        }
    }
}
