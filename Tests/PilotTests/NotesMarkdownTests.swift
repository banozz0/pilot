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
        - Review [search ranking](https://example.com/ranking) with the team

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
        // Underline is <u>…</u>, strikethrough ~~…~~; a second press takes either off.
        let under = apply(.underline, text, NSRange(location: 5, length: 3))
        #expect(under.text == "ship <u>the</u> notes panel" && under.selection == NSRange(location: 8, length: 3))
        #expect(apply(.underline, under.text, under.selection).text == text)
        let struck = apply(.strike, text, NSRange(location: 9, length: 5))
        #expect(struck.text == "ship the ~~notes~~ panel" && apply(.strike, struck.text, NSRange(location: 11, length: 5)).text == text)
    }

    @Test("Link wraps words with the address picked to type over; Apple Notes' paragraph styles convert the picked lines and toggle back to Body; checklists and toggles toggle per line")
    func lines() {
        let link = apply(.link, "see docs", NSRange(location: 4, length: 4))
        #expect(link.text == "see [docs](https://)" && (link.text as NSString).substring(with: link.selection) == "https://")
        // The style keys read the key's own character: ⌘⇧7 is "7", not "&".
        #expect(MarkdownFormat.keyed("7", command: true, shift: true) == .bullets && MarkdownFormat.keyed("t", command: true, shift: true) == .title)
        #expect(MarkdownFormat.keyed("b", command: true, shift: true) == .body && MarkdownFormat.keyed("b", command: true, shift: false) == .bold)
        // ⌘⇧H sets Heading (##), the caret staying on its word; again, Body.
        let heading = apply(.heading, "Plan", NSRange(location: 2, length: 0))
        #expect(heading.text == "## Plan" && heading.selection.location == 5)
        #expect(apply(.heading, heading.text, heading.selection).text == "Plan")
        // Each style's form, from a bulleted line (its mark swapped), and what the Aa menu ticks on it.
        let forms: [(MarkdownFormat, String)] = [(.title, "# Plan"), (.heading, "## Plan"), (.subheading, "### Plan"), (.body, "Plan"),
                                                 (.mono, "```\nPlan\n```"), (.bullets, "- Plan"), (.dashes, "+ Plan"), (.numbers, "1. Plan"),
                                                 (.quote, "> Plan")]
        for (style, form) in forms {
            let from = style == .bullets ? "+ Plan" : "- Plan"
            let made = apply(style, from, NSRange(location: 3, length: 0)).text
            #expect(made == form, "\(style.title): \(made)")
            #expect(MarkdownFormat.style(of: made, selection: NSRange(location: (made as NSString).range(of: "Plan").location, length: 0)) == style)
        }
        // Over lines: blank ones stay blank, numbers count the lines with words, and the same style again is Body.
        let list = apply(.bullets, "milk\neggs\n\nbread", NSRange(location: 0, length: 16))
        #expect(list.text == "- milk\n- eggs\n\n- bread")
        #expect(apply(.bullets, list.text, NSRange(location: 0, length: (list.text as NSString).length)).text == "milk\neggs\n\nbread")
        #expect(apply(.numbers, list.text, NSRange(location: 0, length: 20)).text == "1. milk\n2. eggs\n\n3. bread")
        #expect(apply(.quote, "## a\n- b", NSRange(location: 0, length: 8)).text == "> a\n> b")
        // Monostyled fences the lines; any style inside the fence takes it off first; Monostyled again takes it off.
        let mono = apply(.mono, "- a\n- b\nc", NSRange(location: 0, length: 7))
        #expect(mono.text == "```\na\nb\n```\nc")
        #expect(apply(.mono, mono.text, NSRange(location: 4, length: 0)).text == "a\nb\nc")
        #expect(apply(.title, mono.text, NSRange(location: 4, length: 0)).text == "# a\nb\nc")
        let check = apply(.checklist, "- milk\n  1. eggs", NSRange(location: 0, length: 14))
        #expect(check.text == "- [ ] milk\n  - [ ] eggs")
        #expect(apply(.checklist, check.text, NSRange(location: 0, length: 5)).text == "milk\n  - [ ] eggs")
        let caret = apply(.checklist, "", NSRange(location: 0, length: 0))
        #expect(caret.text == "- [ ] " && caret.selection == NSRange(location: 6, length: 0))
        // A toggle (⌘⇧D) opens unfolded; again, folded or not, it is Body; Bold goes round its words, never its triangle.
        #expect(MarkdownFormat.keyed("d", command: true, shift: true) == .toggle)
        let toggle = apply(.toggle, "- Ideas", NSRange(location: 3, length: 0))
        #expect(toggle.text == "- ▾ Ideas" && MarkdownFormat.style(of: toggle.text, selection: toggle.selection) == .toggle)
        #expect(apply(.toggle, "- ▸ Ideas", NSRange(location: 5, length: 0)).text == "Ideas")
        #expect(apply(.bold, "- ▸ Ideas", NSRange(location: 4, length: 5)).text == "- ▸ **Ideas**")
        #expect(NotesFormatBar.lit("- ▾ Ideas", selection: NSRange(location: 5, length: 0)).contains(.toggle))
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

        // A toggle (Sven, 2026-11-21): a click on its triangle folds it, its ten indented lines (a box and a dot among
        // them) hidden, drawing nothing and taking no height; the triangle is the only change, saved and read back.
        let lines = (1...8).map { "  line \($0)" }.joined(separator: "\n")
        let open = "# Toggles\n- ▾ Ideas\n  - [ ] buy oat milk\n  - a dot\n\(lines)\nAfter\n"
        model.new(); model.text = open; model.flush()
        let toggled = self.editor(open), toggleFile = folder.appending(path: model.current)
        #expect(toggled.disclosures().map(\.folded) == [false] && toggled.checkboxes().count == 1 && toggled.bullets().count == 1)
        let mark = (open as NSString).range(of: "- ▾").location
        #expect(toggled.textStorage?.attribute(.notesToggle, at: mark, effectiveRange: nil) as? Bool == false && !hidden(toggled, "Ideas") && !hidden(toggled, "line 8"))
        let shown = try #require(toggled.linesRect((open as NSString).range(of: "  line 8")))
        let triangle = try #require(toggled.disclosures().first)
        toggled.fold(triangle.range, folded: true)
        toggled.restyle()
        model.text = toggled.string; model.flush()
        let folded = open.replacingOccurrences(of: "▾", with: "▸")
        #expect(toggled.string == folded && toggled.disclosures().map(\.folded) == [true])
        #expect(toggled.checkboxes().isEmpty && toggled.bullets().isEmpty && hidden(toggled, "buy oat") && hidden(toggled, "line 8") && !hidden(toggled, "After"))
        let gone = toggled.linesRect((folded as NSString).range(of: "  - [ ] buy oat milk\n  - a dot\n\(lines)\n"))
        #expect((gone?.height ?? 0) < 1 && shown.height > 10, "folded lines take no height: \(String(describing: gone))")
        // The caret never rests in the folded lines: from the toggle's words' end it goes on to After.
        let after = (folded as NSString).range(of: "After").location
        #expect(toggled.settled((folded as NSString).range(of: "buy").location, from: (folded as NSString).range(of: "Ideas").location + 5) == after)
        #expect(try String(contentsOf: toggleFile, encoding: .utf8) == folded)
        model.reload()
        #expect(model.text == folded && self.editor(model.text).disclosures().map(\.folded) == [true])
        // Unfolded again, the lines show as they were.
        toggled.fold(triangle.range, folded: false)
        toggled.restyle()
        #expect(toggled.string == open && toggled.checkboxes().count == 1 && !hidden(toggled, "line 8"))
        // Return at the end of a folded toggle's line unfolds it and starts a line under it; Return on that line left
        // blank takes its indent off, so the block ends.
        let typing = self.editor("- ▸ Ideas\n  inside\nAfter")
        typing.setSelectedRange(NSRange(location: 9, length: 0))
        typing.insertNewline(nil)
        #expect(typing.string == "- ▾ Ideas\n  \n  inside\nAfter" && typing.selectedRange().location == 12)
        typing.insertText("first", replacementRange: typing.selectedRange())
        typing.restyle()
        typing.insertNewline(nil)
        #expect(typing.string == "- ▾ Ideas\n  first\n  \n  inside\nAfter")
        let fresh = self.editor("- ▾ Ideas\n  first")
        fresh.setSelectedRange(NSRange(location: 17, length: 0))
        fresh.insertNewline(nil)
        fresh.restyle()
        fresh.insertNewline(nil)
        #expect(fresh.string == "- ▾ Ideas\n  first\n")
    }

    @Test("Marks never show, the caret's line included; the caret rests outside them, typing and deleting at a span's edge keep the Markdown whole")
    func marksNeverShow() throws {
        let editor = editor(Self.reference)
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = editor
        #expect(window.makeFirstResponder(editor) && window.firstResponder === editor)
        let ref = editor.string as NSString
        // The caret inside a bold word, in a list line and in a table cell (Sven, 2026-11-20, Q285): nothing shows.
        for words in ["Attendees", "notes markdown", "Shortcut map"] {
            editor.setSelectedRange(NSRange(location: ref.range(of: words).location + 3, length: 0))
            editor.restyle()
            #expect(hidden(editor, "**Attendees") && hidden(editor, "**Tip") && hidden(editor, "| Item") && hidden(editor, "| --- |"), "\(words)")
        }
        #expect(editor.string == Self.reference)

        // Bold, italic, strike and code inside every line kind are drawn with their marks hidden (Sven, 2026-11-20).
        let kinds = ["Plain", "- Dash", "* Star", "+ Plus", "1. Num", "- [ ] Box", "> Quote", "# Title", "## Head", "### Sub"]
        let marks = [("**", "b"), ("_", "i"), ("~~", "s"), ("`", "c")]
        let lines = kinds.enumerated().map { n, kind in kind + " " + marks.map { "\($0.0)w\(n)\($0.1)\($0.0)" }.joined(separator: " ") }
        func set(_ text: String, _ caret: Int) {
            editor.string = text
            editor.restyle()
            editor.setSelectedRange(NSRange(location: caret, length: 0))
        }
        set(lines.joined(separator: "\n") + "\nlast\n", 0)
        for n in kinds.indices {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).range(of: "w\(n)b").location + 1, length: 0))
            for (mark, kind) in marks {
                #expect(hidden(editor, "\(mark)w\(n)\(kind)") && !hidden(editor, "w\(n)\(kind)"), "\(kinds[n]): \(mark) shows")
            }
        }
        #expect(editor.textStorage?.attribute(.strikethroughStyle, at: (editor.string as NSString).range(of: "w0s").location, effectiveRange: nil) != nil)
        // A format leaves its line drawn, and so does every caret after it.
        set("**asdasda**\nnext\n", 0)
        editor.setSelectedRange(NSRange(location: 2, length: 7))
        editor.format(.bullets)
        editor.restyle()
        #expect(editor.string == "- **asdasda**\nnext\n" && hidden(editor, "**asdasda") && editor.bullets().count == 1)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(hidden(editor, "**asdasda"))

        // The caret: never inside a mark. In a span's marks it rests before them, so at a bold word's end typing stays
        // bold and at its start it is plain; a space at the end goes past the closing mark.
        set("a **bold** c", 3)
        #expect(editor.selectedRange().location == 2)
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        #expect(editor.selectedRange().location == 8)
        editor.insertText("er", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.restyle()
        #expect(editor.string == "a **bolder** c" && editor.selectedRange().location == 10)
        editor.insertText(" x", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.restyle()
        #expect(editor.string == "a **bolder** x c")
        // → from a bold word's end passes its closing mark and the character after it.
        set("a **b**cd", 0)
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.moveRight(nil)
        #expect(editor.selectedRange().location == 8, "\(editor.selectedRange())")
        // ⌘B at a span's end ends the style for what is typed next; with nothing picked elsewhere it waits for typing.
        set("a **b** c", 5)
        editor.format(.bold)
        #expect(editor.string == "a **b** c" && editor.selectedRange().location == 7)
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "a **b**x c")
        set("a c", 2)
        editor.format(.bold)
        #expect(editor.string == "a c" && editor.pending == [.bold])
        editor.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "a **z**c" && editor.selectedRange().location == 5)
        // Deleting a span's last letter takes its marks too; Delete before a span skips its hidden mark.
        set("a **b** c", 5)
        editor.deleteBackward(nil)
        #expect(editor.string == "a  c" && editor.selectedRange().location == 2, "\(editor.string) \(editor.selectedRange())")
        set("a **b** c", 2)
        editor.deleteForward(nil)
        #expect(editor.string == "a  c")

        // A list line: the caret starts its words; Backspace there takes the list off; ← goes to the line above.
        set("top\n- item", 4)
        #expect(editor.selectedRange().location == 6)
        editor.moveLeft(nil)
        #expect(editor.selectedRange().location == 3)
        set("top\n- item", 6)
        editor.deleteBackward(nil)
        #expect(editor.string == "top\nitem")
        set("# Head\nx", 0)
        #expect(editor.selectedRange().location == 2)
        editor.deleteBackward(nil)
        #expect(editor.string == "Head\nx")

        // A link shows its words; its address is set or taken off in the link field, never typed in the note.
        set("see [docs](https://a.b) now", 6)
        #expect(hidden(editor, "[docs") && hidden(editor, "](https") && !hidden(editor, "docs]"))
        editor.setLink("https://c.d")
        #expect(editor.string == "see [docs](https://c.d) now")
        editor.restyle()
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.setLink(nil)
        #expect(editor.string == "see docs now")
        set("see docs now", 0)
        editor.setSelectedRange(NSRange(location: 4, length: 4))
        editor.setLink("https://e.f")
        #expect(editor.string == "see [docs](https://e.f) now")
    }
}
