import AppKit
import PilotCore
import Testing
@testable import Pilot

/// The menu's key codes (card agent-bo-95423021): plain ← and → are the menu's, which hands them back to the field while
/// text is typed (Sven 2026-10-12); with Option, Command or Shift the field gets them, so the caret moves or the selection grows.
@MainActor
@Suite("Menu keys")
struct MenuKeysTests {
    @Test("Plain arrows are the menu's; Option, Command and Shift arrows are the search field's")
    func arrows() {
        #expect(PilotMenu.key(123, []) == .left)
        #expect(PilotMenu.key(124, []) == .right)
        #expect(PilotMenu.key(123, .function) == .left, "the arrow keys carry the fn flag")
        for flags: NSEvent.ModifierFlags in [.option, .command, .shift, [.option, .shift], [.command, .shift]] {
            #expect(PilotMenu.key(123, flags) == nil, "\(flags.rawValue)")
            #expect(PilotMenu.key(124, flags) == nil, "\(flags.rawValue)")
        }
        #expect(PilotMenu.key(126, .shift) == .up, "Up and Down stay the menu's")
        #expect(PilotMenu.key(53, []) == .escape)
        #expect(PilotMenu.key(48, []) == .tab && PilotMenu.key(48, .shift) == .backTab, "Shift+Tab steps the kinds back")
    }
}
