import AppKit
import Testing
@testable import Clipboard

/// The clipboard panel's behaviour without a window (story 89, the panel half): which key does what, the row
/// order, and what a paste writes to the pasteboard.
@Suite("Clipboard panel")
struct PanelTests {
    @Test("Return pastes, Cmd+C copies, Cmd+Return picks or unpicks the row, Shift+Return pastes plain text, Escape closes")
    func returnKeys() {
        #expect(PanelCommand(key: .return, searchEmpty: true) == .paste(plain: false))
        #expect(PanelCommand(key: .character("c"), command: true, searchEmpty: false) == .copy)
        #expect(PanelCommand(key: .return, command: true, searchEmpty: false) == .togglePick)
        #expect(PanelCommand(key: .return, shift: true, searchEmpty: false) == .paste(plain: true))
        #expect(PanelCommand(key: .return, control: true, searchEmpty: false) == .pasteInSequence)
        #expect(PanelCommand(key: .escape, searchEmpty: false) == .close)
        // Text selected in the search field: Cmd+C copies that text, as in any field.
        #expect(PanelCommand(key: .character("c"), command: true, textSelected: true, searchEmpty: false) == nil)
        #expect(PanelCommand(key: .character("c"), searchEmpty: false) == nil)
    }

    @Test("With Return set to Copy only, Return copies and Cmd+C pastes; Cmd+Return still picks, Shift+Return pastes plain text")
    func returnCopiesSetting() {
        #expect(PanelCommand(key: .return, returnCopies: true, searchEmpty: true) == .copy)
        #expect(PanelCommand(key: .character("c"), command: true, returnCopies: true, searchEmpty: true) == .paste(plain: false))
        #expect(PanelCommand(key: .return, command: true, returnCopies: true, searchEmpty: true) == .togglePick)
        #expect(PanelCommand(key: .return, shift: true, returnCopies: true, searchEmpty: true) == .paste(plain: true))
    }

    @Test("Arrows move the selection; Cmd+P pins")
    func moveAndPin() {
        #expect(PanelCommand(key: .down, searchEmpty: false) == .move(1))
        #expect(PanelCommand(key: .up, searchEmpty: true) == .move(-1))
        #expect(PanelCommand(key: .character("p"), command: true, searchEmpty: false) == .togglePin)
        #expect(PanelCommand(key: .character("p"), searchEmpty: false) == nil)
    }

    @Test("Backspace only edits the search; Cmd or Ctrl+Backspace deletes, typed or not; 1 to 9 paste that row while the search is empty")
    func emptySearchKeys() {
        // Sven held Backspace to clear a search and its repeats went on deleting copies (build 31, 2026-10-11).
        #expect(PanelCommand(key: .backspace, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .backspace, searchEmpty: false) == nil)
        #expect(PanelCommand(key: .backspace, option: true, searchEmpty: false) == nil)
        for searchEmpty in [true, false] {
            #expect(PanelCommand(key: .backspace, command: true, searchEmpty: searchEmpty) == .delete)
            #expect(PanelCommand(key: .backspace, control: true, searchEmpty: searchEmpty) == .delete)
            // Cmd+Shift+Backspace deletes the tag whose tab is open (card agent-bo-95422986).
            #expect(PanelCommand(key: .backspace, command: true, shift: true, searchEmpty: searchEmpty) == .deleteTag)
        }
        #expect(PanelCommand(key: .character("1"), searchEmpty: true) == .pasteRow(0))
        #expect(PanelCommand(key: .character("9"), searchEmpty: true) == .pasteRow(8))
        #expect(PanelCommand(key: .character("0"), searchEmpty: true) == nil)
        #expect(PanelCommand(key: .character("3"), searchEmpty: false) == nil)
    }

    @Test("Pins come first, then the rest newest first")
    func pinsOnTop() {
        func clip(_ id: Int64, _ pinned: Bool, _ age: TimeInterval) -> StoredClip {
            StoredClip(id: id, kind: .text, text: "\(id)", sourceApp: nil, copiedAt: Date(timeIntervalSinceNow: -age), pinned: pinned)
        }
        let newestFirst = [clip(1, false, 1), clip(2, true, 2), clip(3, false, 3), clip(4, true, 4)]
        #expect(PanelRows.ordered(newestFirst).map(\.id) == [2, 4, 1, 3])
    }

    @Test("A paste writes every item and type back; a plain paste writes only the text")
    @MainActor func write() throws {
        let pasteboard = NSPasteboard.makePrivate()
        let rich: [[String: Data]] = [[NSPasteboard.PasteboardType.string.rawValue: Data("bold".utf8),
                                       NSPasteboard.PasteboardType.rtf.rawValue: Data(#"{\rtf1 \b bold}"#.utf8)]]
        PanelRows.write(rich, text: "bold", plain: false, to: pasteboard)
        #expect(Set(pasteboard.types ?? []).isSuperset(of: [.string, .rtf]))
        #expect(pasteboard.string(forType: .string) == "bold")

        PanelRows.write(rich, text: "bold", plain: true, to: pasteboard)
        #expect(pasteboard.types?.contains(.string) == true)
        #expect(pasteboard.types?.contains(.rtf) == false)  // macOS adds the legacy NSStringPboardType alias itself
        #expect(pasteboard.string(forType: .string) == "bold")
        // Marked transient, so the history does not keep the plain copy as a second item.
        #expect(ClipboardCapture().capture(pasteboard, sourceApp: nil) == nil)

        // An image has no text, so a plain paste of it pastes the image instead of an empty string.
        let png: [[String: Data]] = [[NSPasteboard.PasteboardType.png.rawValue: Data([0x89, 0x50, 0x4E, 0x47])]]
        PanelRows.write(png, text: "", plain: true, to: pasteboard)
        #expect(pasteboard.data(forType: .png) == Data([0x89, 0x50, 0x4E, 0x47]))

        let files: [[String: Data]] = [[NSPasteboard.PasteboardType.fileURL.rawValue: Data("file:///tmp/a".utf8)],
                                       [NSPasteboard.PasteboardType.fileURL.rawValue: Data("file:///tmp/b".utf8)]]
        PanelRows.write(files, text: "/tmp/a\n/tmp/b", plain: false, to: pasteboard)
        #expect(pasteboard.pasteboardItems?.count == 2)
    }

    @Test("Left and Right step the tabs when the search is empty or the caret sits at that edge; mid-text, with a modifier or in a prompt they stay the field's")
    func arrowTabs() {
        #expect(PanelCommand(key: .left, searchEmpty: true) == .cycleFilter(-1))
        #expect(PanelCommand(key: .right, searchEmpty: true) == .cycleFilter(1))
        #expect(PanelCommand(key: .left, caretAtStart: true, searchEmpty: false) == .cycleFilter(-1))
        #expect(PanelCommand(key: .right, caretAtEnd: true, searchEmpty: false) == .cycleFilter(1))
        #expect(PanelCommand(key: .left, caretAtEnd: true, searchEmpty: false) == nil)
        #expect(PanelCommand(key: .right, caretAtStart: true, searchEmpty: false) == nil)
        #expect(PanelCommand(key: .left, searchEmpty: false) == nil)
        #expect(PanelCommand(key: .right, searchEmpty: false) == nil)
        #expect(PanelCommand(key: .right, shift: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .left, command: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .left, option: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .left, prompting: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .right, prompting: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .left, editing: true, searchEmpty: true) == nil)
    }

    @Test("The tabs are the eight kinds, Snippets after Pinned, then one per tag; stepping wraps both ways, and a tab that is gone steps from All")
    func tabs() {
        let work = ClipTag(id: 1, name: "work", colour: 0), todo = ClipTag(id: 2, name: "todo", colour: 3)
        let tabs = PanelTab.all(tags: [work, todo])
        #expect(tabs.map(\.label) == ["All", "Text", "Image", "File", "Link", "Colour", "Email", "Pinned", "Snippets", "#work", "#todo"])
        #expect(PanelTab.kind(.pinned).step(1, in: tabs) == .kind(.snippet))
        #expect(PanelTab.kind(.snippet).step(1, in: tabs) == .tag(work))
        #expect(PanelTab.tag(work).step(1, in: tabs) == .tag(todo))
        #expect(PanelTab.tag(todo).step(1, in: tabs) == .kind(.all))
        #expect(PanelTab.kind(.all).step(-1, in: tabs) == .tag(todo))
        #expect(PanelTab.tag(ClipTag(id: 9, name: "gone", colour: 0)).step(1, in: tabs) == .kind(.text))
        #expect(PanelTab.all(tags: []).count == 9)
    }

    @Test("The Snippets tab, or type:snippet typed, lists snippets and no copy; its words match a snippet's name, keyword or text (Sven, 2026-10-08)")
    func snippetQuery() {
        let tab = ClipQuery("SIG", tab: .kind(.snippet))
        #expect(tab.snippets && tab.kinds == [])
        #expect(tab.matches(["Signature", ";s", "Best, Sven"]))
        #expect(tab.matches(["Greeting", ";sig", "Hi"]))
        #expect(!tab.matches(["Greeting", ";g", "Hi"]))
        let typed = ClipQuery("type:snippet best sven")
        #expect(typed.snippets && typed.matches(["Signature", ";s", "Best, Sven"]) && !typed.matches(["Signature", ";s", "Best"]))
        #expect(ClipQuery("#sig", tab: .kind(.snippet)).matches(["Tag", "#sig", ""]))
        #expect(!ClipQuery("sig").snippets && !ClipQuery("", tab: .kind(.pinned)).snippets)
    }

    @Test("On the Snippets tab Cmd+E edits them and Return pastes even with Copy only; a copy's keys do nothing there")
    func snippetKeys() {
        #expect(PanelCommand(key: .character("e"), command: true, searchEmpty: true, snippets: true) == .editSnippets)
        #expect(PanelCommand(key: .character("e"), command: true, searchEmpty: true) == nil)
        #expect(PanelCommand(key: .return, returnCopies: true, searchEmpty: true, snippets: true) == .paste(plain: false))
        #expect(PanelCommand(key: .character("c"), command: true, returnCopies: true, searchEmpty: true, snippets: true) == nil)
        for (key, command, shift) in [(PanelCommand.Key.character("p"), true, false), (.character("t"), true, false), (.return, true, false),
                                      (.backspace, true, false), (.down, false, true), (.character("s"), true, false)] {
            #expect(PanelCommand(key: key, command: command, shift: shift, searchEmpty: true, snippets: true) == nil)
        }
        #expect(PanelCommand(key: .character("1"), searchEmpty: true, snippets: true) == .pasteRow(0))
        #expect(PanelCommand(key: .character("k"), command: true, searchEmpty: true, snippets: true) == .actions)
    }

    @Test("Several picked images all go on the pasteboard, one item each in pick order (Sven: 'only 1st one changes')")
    @MainActor func severalImages() {
        let pasteboard = NSPasteboard.makePrivate()
        let png = NSPasteboard.PasteboardType.png.rawValue
        let images = (1...3).map { PanelRows.Paste(contents: [[png: Data([0x89, 0x50, 0x4E, 0x47, UInt8($0)])]], text: "") }
        for plain in [false, true] {
            PanelRows.write(images, plain: plain, to: pasteboard)
            #expect(pasteboard.pasteboardItems?.map { $0.data(forType: .png)?.last } == [1, 2, 3])
        }
    }
}
