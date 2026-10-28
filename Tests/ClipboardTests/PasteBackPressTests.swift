import AppKit
import Clipboard
import Foundation
import Testing

/// PasteBack through a press that takes its time (the selection box's Paste menu item, spec ai-selected-text T2), on a
/// pasteboard of its own: the answer is on the pasteboard while the press runs, and Sven's copy is back once the restore
/// step runs, whether the press found a Paste or not.
@Suite("Paste back through a press")
@MainActor
struct PasteBackPressTests {
    func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.banozz.pilot.test.\(UUID().uuidString)"))
        board.clearContents()
        board.setString("Sven's copy", forType: .string)
        return board
    }

    @Test("The answer is on the pasteboard when the press runs, and the user's copy is back after the restore step", arguments: [true, false])
    func restores(pressed: Bool) async throws {
        let board = board()
        defer { board.releaseGlobally() }
        var seen: String?, scheduledBefore = -1, delays: [TimeInterval] = [], steps: [@MainActor () -> Void] = []
        let press: () async -> Bool = {
            seen = board.string(forType: .string)
            scheduledBefore = steps.count
            return pressed
        }
        let got = await PasteBack.paste("The fox.", to: board, press: press, later: { delays.append($0); steps.append($1) })
        #expect(got == pressed && seen == "The fox.")
        #expect(scheduledBefore == 0, "the restore is scheduled only once the press returns")
        #expect(delays == [PasteBack.after] && steps.count == 1)
        #expect(board.string(forType: .string) == "The fox.", "nothing goes back before the restore step")
        let step = try #require(steps.first)
        step()
        #expect(board.string(forType: .string) == "Sven's copy")
    }

    @Test("A copy made while the paste waits is the user's newest, so the restore leaves it")
    func keepsNewerCopy() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        var steps: [@MainActor () -> Void] = []
        _ = await PasteBack.paste("The fox.", to: board, press: { true }, later: { steps.append($1) })
        board.clearContents()
        board.setString("newer", forType: .string)
        let step = try #require(steps.first)
        step()
        #expect(board.string(forType: .string) == "newer")
    }
}
