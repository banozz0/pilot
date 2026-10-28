import AppKit
import Testing
@testable import Clipboard

/// Several items picked in the panel and pasted together, in pick order (card agent-bo-95422780, ClipBook's
/// "paste multiple items" behaviour, no ClipBook code).
@Suite("Clipboard picks")
struct PicksTests {
    let rows = ["a", "b", "c", "d"].enumerated().map { index, text in
        StoredClip(id: Int64(index + 1), kind: .text, text: text, sourceApp: nil, copiedAt: Date(timeIntervalSince1970: Double(10 - index)), pinned: false)
    }

    func texts(_ selection: PanelSelection) -> [String] { selection.targets(in: rows).map(\.text) }

    @Test("Shift+Up/Down extend the picks, Cmd+A picks every row; a plain arrow is still a move")
    func keys() {
        #expect(PanelCommand(key: .down, shift: true, searchEmpty: true) == .extend(1))
        #expect(PanelCommand(key: .up, shift: true, searchEmpty: false) == .extend(-1))
        #expect(PanelCommand(key: .character("a"), command: true, searchEmpty: false) == .pickAll)
        #expect(PanelCommand(key: .down, searchEmpty: true) == .move(1))
        #expect(PanelCommand(key: .character("a"), searchEmpty: true) == nil)
    }

    @Test("Shift+Down twice from a picks a, b, c in order; stepping back drops the last pick; a plain move keeps them (Sven, 2026-10-21)")
    func extendAndMove() {
        var selection = PanelSelection()
        #expect(texts(selection) == ["a"])
        selection.extend(1, in: rows)
        selection.extend(1, in: rows)
        #expect(texts(selection) == ["a", "b", "c"])
        #expect(selection.cursor == 2)
        #expect(selection.pickNumber(of: 3) == 3)
        selection.extend(-1, in: rows)
        #expect(texts(selection) == ["a", "b"])
        selection.move(1, in: rows)
        #expect(selection.cursor == 2)
        #expect(texts(selection) == ["a", "b"])
        #expect(selection.pickNumber(of: 3) == nil)
        selection.extend(-1, in: rows)   // a fresh run: c joins, then b, already picked, stays
        #expect(texts(selection) == ["a", "b", "c"])
        #expect(selection.cursor == 1)
        selection.clearPicks()
        #expect(texts(selection) == ["b"])
        selection.extend(1, in: rows)
        selection.extend(-1, in: rows)   // back to b alone: no picks, as an empty text selection
        #expect(selection.picks.isEmpty)
    }

    @Test("Escape clears the picks while rows are picked, else closes")
    func escapeClearsPicks() {
        #expect(PanelCommand(key: .escape, searchEmpty: true, picked: true) == .clearPicks)
        #expect(PanelCommand(key: .escape, searchEmpty: true) == .close)
        #expect(PanelCommand(key: .escape, prompting: true, searchEmpty: true, picked: true) == .dismiss)
        #expect(PanelCommand(key: .character("/"), command: true, searchEmpty: true) == .keys)
        #expect(PanelCommand(key: .escape, searchEmpty: true, picked: true, keysShown: true) == .keys)
    }

    @Test("Picks keep the order they were made in: c, then up to a, then the cursor jumps back")
    func pickOrder() {
        var selection = PanelSelection()
        selection.move(2, in: rows)  // c
        selection.extend(-1, in: rows)
        selection.extend(-1, in: rows)
        #expect(texts(selection) == ["c", "b", "a"])
        selection.pickAll(rows)
        #expect(texts(selection) == ["a", "b", "c", "d"])
    }

    @Test("Edges clamp; a reload drops picks that are gone and keeps the cursor on its row")
    func refit() {
        var selection = PanelSelection()
        selection.extend(-1, in: rows)
        #expect(texts(selection) == ["a"])
        selection.extend(1, in: rows)
        selection.extend(1, in: rows)  // a, b, c
        selection.refit(Array(rows.dropFirst()), cursorOn: 3)  // a deleted
        #expect(selection.targets(in: Array(rows.dropFirst())).map(\.text) == ["b", "c"])
        #expect(selection.cursor == 1)
        selection.refit([], cursorOn: nil)
        #expect(selection.targets(in: []).isEmpty)
    }

    @Test("Picked c then a paste as one string, c first, marked transient")
    @MainActor func joinedText() {
        let pasteboard = NSPasteboard.makePrivate()
        let items = [PanelRows.Paste(contents: [[NSPasteboard.PasteboardType.string.rawValue: Data("c".utf8),
                                                  NSPasteboard.PasteboardType.rtf.rawValue: Data(#"{\rtf1 c}"#.utf8)]], text: "c"),
                     PanelRows.Paste(contents: [[NSPasteboard.PasteboardType.string.rawValue: Data("a".utf8)]], text: "a")]
        PanelRows.write(items, plain: false, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "c\na")
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
        PanelRows.write(items, plain: true, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "c\na")
    }

    @Test("Two files write two file URLs; an image picked before a text writes both, image first")
    @MainActor func filesAndImages() {
        let pasteboard = NSPasteboard.makePrivate()
        let file: (String) -> PanelRows.Paste = {
            PanelRows.Paste(contents: [[NSPasteboard.PasteboardType.fileURL.rawValue: Data("file://\($0)".utf8)]], text: $0)
        }
        PanelRows.write([file("/tmp/a"), file("/tmp/b")], plain: false, to: pasteboard)
        #expect(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) } == ["file:///tmp/a", "file:///tmp/b"])
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
        // Plain text of files is their paths, joined.
        PanelRows.write([file("/tmp/a"), file("/tmp/b")], plain: true, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "/tmp/a\n/tmp/b")

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        PanelRows.write([PanelRows.Paste(contents: [[NSPasteboard.PasteboardType.png.rawValue: png]], text: ""),
                         PanelRows.Paste(contents: [[NSPasteboard.PasteboardType.string.rawValue: Data("hi".utf8)]], text: "hi")],
                        plain: false, to: pasteboard)
        let written = pasteboard.pasteboardItems ?? []
        #expect(written.count == 2)
        #expect(written.first?.data(forType: .png) == png)
        #expect(written.last?.string(forType: .string) == "hi")
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)
    }

    @Test("One target writes exactly as a single paste does, so a re-copy still moves it to the top")
    @MainActor func single() {
        let pasteboard = NSPasteboard.makePrivate()
        PanelRows.write([PanelRows.Paste(contents: [[NSPasteboard.PasteboardType.string.rawValue: Data("x".utf8)]], text: "x")],
                        plain: false, to: pasteboard)
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil)?.text == "x")
    }
}
