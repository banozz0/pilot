import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Workspaces in the editor's look and the editor's placed apps (card agent-bo-95423003).
@MainActor
@Suite("Workspaces page")
struct WorkspacesPageTests {
    @Test("A placed app under the mouse offers Replace and Remove as buttons, labelled where the tile has room, signs alone on a small tile; never the corner ×")
    func hoverButtons() {
        #expect(PreviewTile.hoverButtons(CGSize(width: 360, height: 300)) == .labelled)
        #expect(PreviewTile.hoverButtons(CGSize(width: 170, height: 96)) == .labelled)
        #expect(PreviewTile.hoverButtons(CGSize(width: 120, height: 96)) == .signs)
        #expect(PreviewTile.hoverButtons(CGSize(width: 200, height: 60)) == .signs)
        #expect(PreviewTile.HoverAction.allCases.map(\.title) == ["Replace", "Remove"])
    }
}
