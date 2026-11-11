import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Binds in Toybox (card agent-bo-95423182): the board's names whole on their keys at every page width from the least
/// window to the widest, the 75 % board while it holds them, split in two halves only where it cannot.
@MainActor
@Suite("Toybox Binds")
struct ToyboxBindsTests {
    /// The keys' width on a page `page` wide: less the page's sides, the case's and the well's outlines and paddings.
    static func board(page: CGFloat) -> (width: CGFloat, spacing: ToyBoardFit.Spacing) {
        let case_ = page - 2 * ToyBindsPage.side(page), spacing = ToyBoardFit.Spacing(width: case_)
        return (spacing.inner(case_, outline: 2), spacing)
    }

    @Test("Every bound key's name fits its key whole, on two lines at most (one on the function row), at one size for the board and never under 10 pt (a long one-word name on the least board alone shrinks, to no less than 0.8), ANSI and ISO; the 75 % board on a wide page, two halves on a narrow one")
    func namesFit() throws {
        DisplayFaces.directory = LookThemeTests.fonts
        for shape in [BindsKeyboard.Shape.ansi, .iso] {
            let boards = KeyboardCaptions.Boards(full: .init(shape), compact: .init(shape, compact: true))
            // From the least window's page (760 less the rail) to past the widest.
            for page in stride(from: CGFloat(680), through: 1500, by: 10) {
                let (width, spacing) = Self.board(page: page)
                let fit = ToyBoardFit.best(names: BindsKeyboardPageTests.names, boards: boards, width: width, spacing: spacing)
                #expect(fit.size >= 10)
                #expect(!fit.shrinks || page < 760, "\(shape) at \(page) shrinks names")
                let rooms = ToyBoardFit.rooms(BindsKeyboardPageTests.names, on: fit.board, width: width, spacing: spacing)
                #expect(rooms.count == BindsKeyboardPageTests.names.keys.filter(boards.compact.codes.contains).count, "a named key is off the board at \(page)")
                for key in rooms {
                    let lines = ToyBoardFit.lines(key.name, size: fit.size * (fit.shrinks ? ToyBoardFit.leastScale : 1), room: key.room)
                    #expect((lines ?? .max) <= key.lines, "\(shape) at \(page): \(key.name) in \(key.room) pt")
                }
            }
            let wide = Self.board(page: 1364)
            #expect(ToyBoardFit.best(names: BindsKeyboardPageTests.names, boards: boards, width: wide.width, spacing: wide.spacing).board == boards.compact,
                    "the mockup's page draws the whole board")
            for page in [CGFloat(924), 684] {
                let (width, spacing) = Self.board(page: page)
                #expect(ToyBoardFit.best(names: BindsKeyboardPageTests.names, boards: boards, width: width, spacing: spacing).board.halves == 2, "\(page)")
            }
            // Binds draws the board whole (simplify-pages T14, Sven's Q36): wordSize keeps each name's longest word whole, on its
            // 0.25 pt grid so a resize makes no new font; this guards the helper, the renders show the board.
            for page in stride(from: CGFloat(680), through: 1500, by: 10) {
                let (width, spacing) = Self.board(page: page)
                let fit = ToyBoardFit.best(names: BindsKeyboardPageTests.names, boards: boards, width: width, spacing: spacing, whole: true)
                for key in ToyBoardFit.rooms(BindsKeyboardPageTests.names, on: fit.board, width: width, spacing: spacing) {
                    guard let size = ToyBoardFit.wordSize(key.name, size: fit.size, room: key.room) else { continue }
                    #expect((size / ToyBoardFit.wordStep).rounded() * ToyBoardFit.wordStep == size, "\(key.name) at \(size) pt is off the grid")
                    #expect(ToyBoardFit.lines(key.name, size: size, room: key.room) != nil, "\(shape) whole at \(page): \(key.name) in \(key.room) pt breaks a word")
                }
            }
        }
    }

    @Test("A name wraps word by word into the lines its room holds; a word wider than the room alone does not fit at all")
    func lines() {
        DisplayFaces.directory = LookThemeTests.fonts
        let one = ToyBoardFit.width("Display", size: 11)
        #expect(ToyBoardFit.lines("Display", size: 11, room: one + 2) == 1)
        #expect(ToyBoardFit.lines("Display left", size: 11, room: one + 2) == 2)
        #expect(ToyBoardFit.lines("Display left", size: 11, room: 400) == 1)
        #expect(ToyBoardFit.lines("Passwords", size: 11, room: 20) == nil)
    }

    @Test("A key's legend as the mockup prints it: words in lower case, letters, signs and F-keys as they are")
    func legends() {
        let board = BindsKeyboard.Board(.ansi, compact: true)
        let legend = { (code: Int64?, modifier: BindsKeyboard.Modifier?) in
            BindsKeyboard.printed(board.spots.first { $0.code == code && $0.modifier == modifier }!)
        }
        #expect(legend(53, nil) == "esc" && legend(36, nil) == "return" && legend(nil, .shift) == "shift")
        #expect(legend(11, nil) == "B" && legend(109, nil) == "F10" && legend(126, nil) == "↑")
    }
}
