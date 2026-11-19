@testable import PilotTiler
import CoreGraphics
import PilotCore
import Testing

/// Bug 10 of the tester's feedback (2026-11-18, Sven's screenshot: Ghostex in Centred main's right column ran below the
/// left window's bottom). Windows whose apps will not shrink to their tiles, through the engine's own layout: Vesktop
/// (940 x 500 at the least) in the left column, two Ghostex windows (800 x 600, its NSWindow contentMinSize) stacked on
/// the right, on the 1920 x 1080 test screen. Sven's yes to this one test: W83 Q231, 2026-11-19.
extension TilerTreeTests {
    @MainActor
    @Suite
    struct WindowMinimumTests {
        @Test func windowsThatCannotShrinkStayInsideTheRoomInCentredMain() async throws {
            defer { for id in UInt32(1)...4 { WindowMinimums.forget(id) } }
            let workspace = try Workspace.get(byName: name)
            let windows = try (UInt32(1)...4).map { try TestWindow.new(id: $0, parent: workspace.rootTilingContainer) }
            #expect(workspace.focusWorkspace())
            try workspace.arrange(WorkspaceArrangement(.centred, auto: false, order: [1, 2, 3, 4]))
            try await workspace.layoutWorkspace()
            let room = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
            func frame(_ w: TestWindow) throws -> Rect { try #require(w.axRect) }
            // The tiles before any app refuses: one window left, one in the middle, two stacked on the right.
            let left = try #require(try windows.first { try frame($0).minX == room.minX })
            let right = try windows.filter { try frame($0).maxX >= room.maxX - 1 }.sorted { try frame($0).minY < frame($1).minY }
            try #require(right.count == 2)
            left.minimum = CGSize(width: 940, height: 500)
            for w in right { w.minimum = CGSize(width: 800, height: 600) }
            // An app's refusal counts once a second write bears it out; then layout makes room.
            for _ in 0..<3 { try await workspace.layoutWorkspace() }
            for w in windows {
                let f = try frame(w)
                #expect(f.minX >= room.minX - 0.5 && f.maxX <= room.maxX + 0.5, "\(w) runs past the room's side: \(f)")
                #expect(f.minY >= room.minY - 0.5 && f.maxY <= room.maxY + 0.5, "\(w) runs past the room's top or bottom: \(f)")
            }
            // The right column's bottom lines up with the left window's, the tester's gap.
            #expect(abs(try frame(right[1]).maxY - frame(left).maxY) < 1.5)
            // Vesktop is never under its neighbour: the columns side by side do not overlap.
            let columns = try windows.filter { !right.dropFirst().contains($0) }.map(frame).sorted { $0.minX < $1.minX }
            for (a, b) in zip(columns, columns.dropFirst()) { #expect(a.maxX <= b.minX + 0.5, "\(a) overlaps \(b)") }
        }
    }
}
