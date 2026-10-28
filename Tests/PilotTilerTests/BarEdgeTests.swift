// Pilot (Sven on build 21): the top bar is a hard edge. A floating window under it goes just under it once its frame has
// settled, never while the mouse holds it, and an app that puts it back twice keeps it there; native "fullscreen" in the
// tiler keeps the bar clear too.
import AppKit
@testable import PilotTiler
import Testing

@Suite struct BarEdgeClampTests {
    @Test func underTheBarGoesJustUnderItCutToFit() {
        let tall = Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 1080)
        #expect(BarEdge.clamped(tall, edge: 40, bottom: 1080) == Rect(topLeftX: 100, topLeftY: 40, width: 800, height: 1040))
        let small = Rect(topLeftX: 100, topLeftY: 10, width: 400, height: 300)
        #expect(BarEdge.clamped(small, edge: 40, bottom: 1080) == Rect(topLeftX: 100, topLeftY: 40, width: 400, height: 300))
        // Above the screen's top too.
        #expect(BarEdge.clamped(Rect(topLeftX: 0, topLeftY: -20, width: 400, height: 300), edge: 40, bottom: 1080)?.topLeftY == 40)
        #expect(BarEdge.clamped(Rect(topLeftX: 0, topLeftY: 40, width: 400, height: 300), edge: 40, bottom: 1080) == nil)
    }
}

extension TilerTreeTests {
    @MainActor
    @Suite
    struct BarEdgeLayoutTests {
        private func floating(_ rect: Rect) throws -> (Workspace, TestWindow) {
            config.topBar = .constant(40)
            BarEdge.reset()
            BarEdge.settle = .zero
            let workspace = try Workspace.get(byName: name)
            let window = try TestWindow.new(id: 61, parent: workspace.floatingWindowsContainer, rect: rect)
            #expect(workspace.focusWorkspace())
            return (workspace, window)
        }

        @Test func aFloatingWindowUnderTheBarMovesOnceItHasSettled() async throws {
            defer { BarEdge.settle = .milliseconds(300) }
            let (workspace, window) = try floating(Rect(topLeftX: 100, topLeftY: 0, width: 800, height: 1080))
            try await workspace.layoutWorkspace()
            #expect(window.frameWrites == 0, "moved on its first frame: an app mid-animation would be fought")
            try await workspace.layoutWorkspace()
            #expect(window.axRect == Rect(topLeftX: 100, topLeftY: 40, width: 800, height: 1040))
            // Clear of the bar now: nothing more.
            try await workspace.layoutWorkspace()
            #expect(window.frameWrites == 1)
        }

        @Test func neverWhileTheMouseHoldsIt() async throws {
            defer {
                BarEdge.settle = .milliseconds(300)
                unitTestScreen.withLock { $0.leftMouseDown = false }
            }
            let (workspace, window) = try floating(Rect(topLeftX: 100, topLeftY: 5, width: 400, height: 300))
            unitTestScreen.withLock { $0.leftMouseDown = true }
            for _ in 0..<3 { try await workspace.layoutWorkspace() }
            #expect(window.frameWrites == 0)
            unitTestScreen.withLock { $0.leftMouseDown = false }
            for _ in 0..<2 { try await workspace.layoutWorkspace() }
            #expect(window.axRect?.topLeftY == 40)
        }

        @Test func anAppThatPutsItBackTwiceKeepsIt() async throws {
            defer { BarEdge.settle = .milliseconds(300) }
            let under = Rect(topLeftX: 100, topLeftY: 0, width: 400, height: 300)
            let (workspace, window) = try floating(under)
            for _ in 0..<2 {
                for _ in 0..<2 { try await workspace.layoutWorkspace() }
                #expect(window.axRect?.topLeftY == 40)
                window.movedByPilot(to: under) // the app moves it back
            }
            for _ in 0..<3 { try await workspace.layoutWorkspace() }
            #expect(window.axRect == under && window.frameWrites == 2, "fought the app past twice")
        }

        @Test func noBarNoEdge() async throws {
            let (workspace, window) = try floating(Rect(topLeftX: 100, topLeftY: 0, width: 400, height: 300))
            config.topBar = .constant(0)
            for _ in 0..<2 { try await workspace.layoutWorkspace() }
            #expect(window.frameWrites == 0)
            #expect(mainMonitorInfo.visibleRectBelowBar == mainMonitorInfo.visibleRect)
        }

        @Test func theBelowBarRectLeavesTheBar() throws {
            config.topBar = .constant(40)
            #expect(mainMonitorInfo.visibleRectBelowBar == Rect(topLeftX: 0, topLeftY: 40, width: 1920, height: 1040))
        }
    }
}
