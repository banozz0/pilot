import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// The notes editor's Markdown round (Q114 and Q116, Sven 2026-10-15): the toolbar types Markdown at the selection, and
/// the live preview hides marks off the caret's line without changing a character of the note.
@MainActor
@Suite("Notes Markdown")
struct NotesMarkdownTests {
    /// The SuperCmd picture's note, as Sven's reference (Q114).
    static let reference = """
        # Weekly Planning — Product Notes
        A sample note showing how we capture ideas, tasks, and snippets in one place.

        > **Tip:** Mix headings, lists, and code so a note stays scannable and useful later.

        ## Today's focus
        - Ship the notes markdown preview
        - Review search ranking with the team

        ## Priorities
        1. Polish the editor chrome
        2. Tighten keyboard shortcuts
        3. Write a short help article

        ## Checklist
        - [x] Outline the feature set
        - [x] Sketch the empty state
        - [ ] Record a 30s demo
        - [ ] Share with design for review

        ## Meeting notes — Thursday
        **Attendees:** Maya, Jordan, Alex
        _Goal:_ align on the `v1` scope

        | Item | Owner | Status |
        | --- | --- | --- |
        | Preview renderer | Maya | In progress |
        | Shortcut map | Jordan | Done |
        | Onboarding copy | Alex | Not started |

        ## Snippets
        ```swift
        let note = try store.create(text: "Hello")
        print(note.title)
        ```

        """

    func apply(_ format: MarkdownFormat, _ text: String, _ selection: NSRange) -> (text: String, selection: NSRange) {
        let edit = format.edit(text, selection: selection)
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    @Test("The toolbar wraps the selection in bold, italic and code, and a second press takes the marks off")
    func wraps() {
        let text = "ship the notes panel"
        let bold = apply(.bold, text, NSRange(location: 5, length: 3))
        #expect(bold.text == "ship **the** notes panel" && bold.selection == NSRange(location: 7, length: 3))
        #expect(apply(.bold, bold.text, bold.selection).text == text)
        #expect(apply(.italic, text, NSRange(location: 0, length: 4)).text == "_ship_ the notes panel")
        #expect(apply(.code, text, NSRange(location: 9, length: 5)).text == "ship the `notes` panel")
        // No selection: the pair, the caret between.
        let empty = apply(.bold, text, NSRange(location: 4, length: 0))
        #expect(empty.text == "ship**** the notes panel" && empty.selection == NSRange(location: 6, length: 0))
        // Code over lines: a fenced block.
        #expect(apply(.code, "a\nb\nc", NSRange(location: 0, length: 3)).text == "```\na\nb\n```\nc")
    }

    @Test("Link wraps words with the address picked to type over; heading cycles #, ##, ### and back; lists and checklists toggle per line")
    func lines() {
        let link = apply(.link, "see docs", NSRange(location: 4, length: 4))
        #expect(link.text == "see [docs](https://)" && (link.text as NSString).substring(with: link.selection) == "https://")
        var heading = apply(.heading, "Plan", NSRange(location: 2, length: 0))
        #expect(heading.text == "# Plan" && heading.selection.location == 4)
        heading = apply(.heading, heading.text, heading.selection)
        #expect(heading.text == "## Plan")
        heading = apply(.heading, apply(.heading, heading.text, heading.selection).text, heading.selection)
        #expect(heading.text == "Plan")
        let list = apply(.bullets, "milk\neggs\n\nbread", NSRange(location: 0, length: 16))
        #expect(list.text == "- milk\n- eggs\n\n- bread")
        #expect(apply(.bullets, list.text, NSRange(location: 0, length: (list.text as NSString).length)).text == "milk\neggs\n\nbread")
        let check = apply(.checklist, "- milk\n  1. eggs", NSRange(location: 0, length: 14))
        #expect(check.text == "- [ ] milk\n  - [ ] eggs")
        #expect(apply(.checklist, check.text, NSRange(location: 0, length: 5)).text == "milk\n  - [ ] eggs")
        let caret = apply(.checklist, "", NSRange(location: 0, length: 0))
        #expect(caret.text == "- [ ] " && caret.selection == NSRange(location: 6, length: 0))
    }

    func editor(_ text: String) -> NotesTextView {
        let editor = NotesTextView(usingTextLayoutManager: false)
        editor.layoutManager?.delegate = editor
        editor.isRichText = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
        editor.string = text
        editor.restyle()
        return editor
    }

    func hidden(_ editor: NotesTextView, _ words: String) -> Bool {
        let range = (editor.string as NSString).range(of: words)
        return editor.textStorage?.attribute(.notesHidden, at: range.location, effectiveRange: nil) != nil
    }

    @Test("Styling the reference note hides its marks and draws its blocks, but the text, the model and the file on disk stay the Markdown typed")
    func diskUnchanged() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-notes-md-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = NotesModel(store: NoteStore(folder: folder), defaults: UserDefaults(suiteName: testSuite())!)
        model.reload()
        model.new(); model.text = Self.reference; model.flush()
        let file = folder.appending(path: model.current)
        let editor = editor(model.text)
        #expect(editor.string == Self.reference && model.text == Self.reference)
        // Every format at a selection and Undo-able edits aside, styling alone writes nothing.
        editor.restyle(); editor.restyle()
        model.flush()
        #expect(try String(contentsOf: file, encoding: .utf8) == Self.reference && editor.string == Self.reference)

        // Off the caret: the marks are hidden, the words are not.
        #expect(hidden(editor, "# Weekly") && !hidden(editor, "Weekly"))
        #expect(hidden(editor, "**Tip") && !hidden(editor, "Tip:"))
        #expect(hidden(editor, "> **Tip"))
        #expect(hidden(editor, "`v1") && !hidden(editor, "v1`"))
        #expect(hidden(editor, "```swift") && !hidden(editor, "let note"))
        #expect(hidden(editor, "| Item") && !hidden(editor, "Item |") && hidden(editor, "| --- |"))
        // A `-` is drawn as a dot, a box as a box; numbers stay.
        #expect(editor.bullets().count == 2 && editor.checkboxes().count == 4)
        let storage = try #require(editor.textStorage)
        #expect(storage.attribute(.notesTable, at: (editor.string as NSString).range(of: "Maya | In").location, effectiveRange: nil) is MarkdownTableGrid)
        #expect(storage.attribute(.notesCodeBlock, at: (editor.string as NSString).range(of: "print(").location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.notesQuote, at: (editor.string as NSString).range(of: "Mix headings").location, effectiveRange: nil) != nil)
        // Inside a code block nothing is Markdown.
        #expect(MarkdownBlocks.fences(editor.string as NSString).count == 1)
        #expect(MarkdownBlocks.tables(editor.string as NSString).first?.rows.count == 5)
    }

    @Test("The line the caret is on shows its raw marks while the note is typed in; every other line stays drawn")
    func caretLineShowsMarks() throws {
        let editor = editor(Self.reference)
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = editor
        let attendees = (editor.string as NSString).range(of: "Attendees")
        editor.setSelectedRange(NSRange(location: attendees.location, length: 0))
        #expect(window.makeFirstResponder(editor))
        #expect(!hidden(editor, "**Attendees") && hidden(editor, "**Tip"))
        // Into the table: the whole table shows as typed, pipes and all.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).range(of: "Shortcut map").location, length: 0))
        #expect(!hidden(editor, "| Item") && !hidden(editor, "| --- |") && hidden(editor, "**Attendees"))
        // The keyboard elsewhere (the list has it): every line drawn again.
        window.makeFirstResponder(nil)
        #expect(hidden(editor, "| Item"))
        #expect(editor.string == Self.reference)
    }
}
