import Foundation
import PilotCore
import Testing
@testable import Pilot

/// A menu row's picker finds where the menu stood (card agent-bo-95423020): Kill a process, a drive picker and lazygit
/// open theirs from a task the row's action starts, after the menu closed.
@MainActor
@Suite("Menu origin")
struct MenuOriginTests {
    @Test("Where the menu stood reaches a task the row starts, and nothing outside the row")
    func originReachesTheRowsTask() async {
        let spot = MenuNavigator.Spot(branch: .system, row: .action("system.killProcess"))
        let task = PilotMenu.$origin.withValue(spot) { Task { @MainActor in PilotMenu.origin } }
        #expect(await task.value == spot)
        #expect(PilotMenu.origin == nil, "a bind's picker, outside a menu row, closes on Escape")
    }
}
