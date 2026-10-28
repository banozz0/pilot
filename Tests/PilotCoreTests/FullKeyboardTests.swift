import Foundation
import Testing
@testable import PilotCore

/// Binds' whole keyboard (card agent-bo-95423003, Sven 2026-10-07: "no fn keys no arrows etc, it should match any
/// keyboard layout"): a tenkeyless board with the function row, every modifier on both sides, the arrows and the nav
/// cluster, shaped ANSI or ISO, its captions read from the Mac's keyboard layout.
@Suite("Full keyboard")
struct FullKeyboardTests {
    static func codes(_ board: BindsKeyboard.Board) -> Set<Int64> { Set(board.spots.compactMap(\.code)) }

    @Test("The function row, the arrows and the nav cluster are on the board, the arrows an inverted T, compact too", arguments: [false, true])
    func wholeBoard(compact: Bool) {
        let board = BindsKeyboard.Board(.ansi, compact: compact)
        let codes = Self.codes(board)
        for f in 1...12 { #expect(codes.contains(KeyNames.code(for: "F\(f)")!), "F\(f) missing") }
        for arrow: Int64 in [123, 124, 125, 126] { #expect(codes.contains(arrow)) }
        for nav in (compact ? [] : ["Insert"]) + ["Home", "End", "PageUp", "PageDown", "ForwardDelete", "Escape", "Delete", "`", "\\", "'"] {
            #expect(codes.contains(KeyNames.code(for: nav)!), "\(nav) missing")
        }
        #expect(Set(board.spots.map(\.row)) == Set(0...5))
        let up = board.spots.first { $0.code == 126 }, down = board.spots.first { $0.code == 125 }
        #expect(up?.row == 4 && down?.row == 5 && up?.x == down?.x, "the up arrow is not over the down arrow")
    }

    @Test("Every modifier sits on both sides, fn by the right Ctrl; none of them is a key a bind takes")
    func modifiers() {
        let board = BindsKeyboard.Board(.ansi)
        for modifier: BindsKeyboard.Modifier in [.shift, .ctrl, .alt, .cmd] {
            let sides = board.spots.filter { $0.modifier == modifier }.map(\.side)
            #expect(sides == [.left, .right], "\(modifier) is not on both sides")
        }
        #expect(board.spots.filter { $0.modifier == .fn }.map(\.side) == [.right])
        #expect(board.spots.filter { $0.modifier == .caps }.count == 1)
        #expect(board.spots.allSatisfy { $0.modifier == nil || $0.code == nil })
    }

    @Test("ANSI: backslash over Return, one long left Shift, no ISO key")
    func ansi() {
        let board = BindsKeyboard.Board(.ansi)
        let backslash = board.spots.first { $0.code == 42 }
        #expect(backslash?.row == 2 && backslash?.width == 1.5)
        #expect(board.spots.first { $0.modifier == .shift && $0.side == .left }?.width == 2.25)
        #expect(!Self.codes(board).contains(10))
        #expect(board.spots.first { $0.code == 36 }?.isoReturn == false)
    }

    @Test("ISO: the extra key left of Z, the key by Return, Return over two rows; British-PC swaps the two § keys")
    func iso() {
        let apple = BindsKeyboard.Board(.iso)
        let row4 = apple.spots.filter { $0.row == 4 }.sorted { $0.x < $1.x }
        #expect(row4[0].modifier == .shift && row4[0].width == 1.25)
        #expect(row4[1].code == 50 && row4[2].code == 6, "the key left of Z is not the ISO key")
        #expect(apple.spots.filter { $0.row == 1 }.min { $0.x < $1.x }?.code == 10, "Apple's ISO board has § left of 1")
        let hash = apple.spots.first { $0.code == 42 }
        #expect(hash?.row == 3 && hash?.width == 1)
        let enter = apple.spots.first { $0.code == 36 }
        #expect(enter?.isoReturn == true && enter?.row == 2)
        let pc = BindsKeyboard.Board(.iso, pcSwap: true)
        #expect(pc.spots.filter { $0.row == 1 }.min { $0.x < $1.x }?.code == 50)
        #expect(pc.spots.filter { $0.row == 4 }.sorted { $0.x < $1.x }[1].code == 10)
    }

    @Test("Each row fits the board's width and no two keys overlap")
    func geometry() {
        for board in [BindsKeyboard.Board(.ansi), BindsKeyboard.Board(.iso), BindsKeyboard.Board(.ansi, compact: true), BindsKeyboard.Board(.iso, compact: true)] {
            for row in 0...5 {
                let spots = board.spots.filter { $0.row == row }.sorted { $0.x < $1.x }
                #expect((spots.last.map { $0.x + $0.width } ?? 0) <= board.width + 0.001)
                for (a, b) in zip(spots, spots.dropFirst()) { #expect(a.x + a.width <= b.x + 0.001, "\(a.legend) overlaps \(b.legend)") }
            }
        }
    }

    @Test("Captions come from the layout: a French board's A sits where a US board has Q, lowercase drawn as capitals")
    func captions() {
        let board = BindsKeyboard.Board(.iso, legends: [12: "a", 0: "q", 10: "@", 50: "<"])
        #expect(board.spots.first { $0.code == 12 }?.legend == "A")
        #expect(board.spots.first { $0.code == 0 }?.legend == "Q")
        #expect(board.spots.first { $0.code == 10 }?.legend == "@")
        #expect(board.spots.first { $0.code == 13 }?.legend == "W", "a key the layout does not name keeps the US name")
        #expect(board.spots.first { $0.code == 122 }?.legend == "F1", "a function key keeps its own name")
    }

    @Test("Hyper plus an arrow shows on its arrow key")
    func arrows() {
        let store = BindStore(defaults: ["windows.focusLeft": Key(keyCode: 123), "windows.focusUp": Key(keyCode: 126)])
        let bound = BindsKeyboard.bound(store: store, layer: .hyper)
        let board = BindsKeyboard.Board(.ansi)
        #expect(bound[123] == ["windows.focusLeft"] && bound[126] == ["windows.focusUp"])
        #expect(board.codes.contains(123) && board.codes.contains(126))
        #expect(board.spots.first { $0.code == 123 }?.legend == "←")
    }
    @Test("The split board (card agent-bo-95423023) holds every key of the compact board once, in two halves one over the other: Esc to F5, 6, T, G, B and Space on the left; F6 on, 7, Y, H, N, the nav column and the arrows on the right, ISO's Return whole", arguments: [BindsKeyboard.Shape.ansi, .iso])
    func split(shape: BindsKeyboard.Shape) {
        let compact = BindsKeyboard.Board(shape, compact: true), split = compact.split()
        #expect(split.spots.count == compact.spots.count)
        #expect(Self.codes(split) == Self.codes(compact) && split.codes == compact.codes)
        #expect(split.halves == 2 && compact.halves == 1)
        #expect(Set(split.spots.map(\.row)) == Set(0...11))
        func half(_ name: String) -> Int? { split.spots.first { $0.code == KeyNames.code(for: name) }.map { $0.row / 6 } }
        for left in ["Escape", "F5", "6", "T", "G", "B", "Space"] { #expect(half(left) == 0, "\(left) is not on the left") }
        for right in ["F6", "F12", "7", "Y", "H", "N", "Delete", "Home", "End", "PageUp", "PageDown", "ForwardDelete", "Left", "Up"] {
            #expect(half(right) == 1, "\(right) is not on the right")
        }
        let iso = split.spots.filter(\.isoReturn)
        #expect(iso.count == (shape == .iso ? 1 : 0) && iso.allSatisfy { $0.row == 8 })
        // Each row inside the board, no two keys over each other; the right half's outer edge one line.
        for row in 0...11 {
            let spots = split.spots.filter { $0.row == row }.sorted { $0.x < $1.x }
            #expect((spots.first?.x ?? 0) >= 0)
            #expect((spots.last.map { $0.x + $0.width } ?? 0) <= split.width + 0.001)
            for (a, b) in zip(spots, spots.dropFirst()) { #expect(a.x + a.width <= b.x + 0.001, "\(a.legend) overlaps \(b.legend) on row \(row)") }
        }
        #expect(split.width == 9.75)
        for row in 7...11 { #expect(split.spots.filter { $0.row == row }.map { $0.x + $0.width }.max() == 9.75, "row \(row) is not flush right") }
    }
}
