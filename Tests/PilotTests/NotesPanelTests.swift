import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Quick notes' panel side (card agent-bo-95423042): its bind, and the model the panel edits through, on a fresh folder.
@MainActor
@Suite("Quick notes panel")
struct NotesPanelTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-notes-\(UUID().uuidString)")

    /// A defaults domain of the test's own, so the note open last never lands in the runner's real defaults.
    let defaults = UserDefaults(suiteName: testSuite())!

    /// What the trash seam was handed.
    final class Trashed: @unchecked Sendable { var names: [String] = [] }

    @Test("notes.toggle is registered with its default key")
    func bind() {
        var registry = ActionRegistry()
        NotesPanel.register(into: &registry)
        let action = registry.actions["notes.toggle"]
        #expect(action?.label == "Quick notes" && action?.tier == .v1)
        #expect(registry.defaults["notes.toggle"] == Key("n", .shift))
    }

    @Test("The Hyper+Space menu, the clipboard and the tips open above the notes panel, never hidden under it")
    func hudsAboveNotes() {
        let panel = HUD.makePanel(Text("menu"))
        #expect(panel.level.rawValue > NotesPanel.level.rawValue)
        #expect(NotesPanel.level == .popUpMenu)
    }

    @Test("The note open last is where the panel opens after Pilot quits and starts again; a note gone since opens Scratch")
    func lastNoteRemembered() throws {
        let store = NoteStore(folder: folder)
        let first = NotesModel(store: store, defaults: defaults)
        first.reload()
        first.new(); first.text = "Plan"; first.flush()
        let plan = first.current
        let relaunched = NotesModel(store: store, defaults: defaults)
        relaunched.reload()
        #expect(relaunched.current == plan && relaunched.text == "Plan")
        try FileManager.default.removeItem(at: folder.appending(path: plan))
        let again = NotesModel(store: store, defaults: defaults)
        again.reload()
        #expect(again.current == "Scratch.md")
    }

    @Test("The panel opens on Scratch; text typed is on disk once the panel saves, and a new first line renames the note")
    func typeThenSave() throws {
        let model = NotesModel(store: NoteStore(folder: folder), defaults: defaults)
        model.reload()
        #expect(model.current == "Scratch.md")
        model.new()
        model.text = "Shopping\n- [ ] milk"
        model.flush()
        let note = try #require(model.note)
        #expect(note.title == "Shopping" && note.id.hasPrefix("shopping-"))
        #expect(try String(contentsOf: folder.appending(path: note.id), encoding: .utf8) == "Shopping\n- [ ] milk")
        // Shown again (reload), it stays on the same note.
        model.reload()
        #expect(model.current == note.id && model.text == "Shopping\n- [ ] milk")
    }

    @Test("The list's filter ranks titles; Cmd+Backspace asks first, then moves the note through the trash seam and lands on Scratch")
    func filterAndTrash() throws {
        let trashed = Trashed()
        let model = NotesModel(store: NoteStore(folder: folder, trash: { trashed.names.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }), defaults: defaults)
        model.reload()
        model.new(); model.text = "Groceries"; model.flush()
        model.new(); model.text = "Plan"; model.flush()
        model.focusList()
        model.queryField = "groc"
        #expect(model.rows.first?.title == "Groceries" && model.selectedNote?.title == "Groceries")
        model.openSelection()
        #expect(model.note?.title == "Groceries" && !model.listFocused && model.query.isEmpty)
        model.confirmTrash()
        #expect(trashed.names.isEmpty)
        model.askTrash()
        model.confirmTrash()
        #expect(trashed.names.count == 1 && trashed.names[0].hasPrefix("groceries-"))
        #expect(model.current == "Scratch.md" && !model.notes.contains { $0.title == "Groceries" })
    }

    @Test("The Notes page pins and unpins any note, open or not; Scratch is never pinned")
    func pinAny() throws {
        let model = NotesModel(store: NoteStore(folder: folder), defaults: defaults)
        model.reload()
        model.new(); model.text = "Plan"; model.flush()
        let plan = model.current
        model.open(NoteStore.scratch)
        model.pin(plan, true)
        #expect(model.notes.first { $0.id == plan }?.pinned == true && model.current == NoteStore.scratch)
        model.pin(plan, false)
        #expect(model.notes.first { $0.id == plan }?.pinned == false)
        model.pin(NoteStore.scratch, true)
        #expect(model.notes.first?.isScratch == true && model.notes.first?.pinned == false)
    }

    @Test("A picture pasted into the editor is saved in attachments/, linked on a line of its own and drawn under it")
    func pastePicture() throws {
        _ = try NoteStore(folder: folder).load()
        let editor = NotesTextView(usingTextLayoutManager: false)
        editor.layoutManager?.delegate = editor
        editor.isRichText = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        editor.folder = folder
        editor.string = "# Trip"
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        let board = NSPasteboard(name: NSPasteboard.Name("pilot-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        board.clearContents()
        let tiff = try #require(image.tiffRepresentation)
        board.setData(try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])), forType: .png)
        #expect(editor.insertPictures(from: board))
        let name = try #require(NoteAttachments.references(in: editor.string).first)
        #expect(editor.string == "# Trip\n![](attachments/\(name))\n" && name.hasPrefix("image-") && name.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "attachments/\(name)").path))
        editor.restyle()
        let drawn = try #require(editor.pictureRects().first)
        #expect(drawn.rect.width > 0 && drawn.rect.minY > 30)
        // Text on the clipboard pastes as text: nothing saved.
        board.clearContents()
        board.setString("just words", forType: .string)
        #expect(!editor.insertPictures(from: board))
    }

    @Test("Paste is offered for a copied screenshot (PNG and TIFF, no text), a TIFF alone and a file copied in Finder, and each lands in attachments/")
    func pasteOffered() throws {
        _ = try NoteStore(folder: folder).load()
        let editor = NotesTextView(usingTextLayoutManager: false)
        editor.isRichText = false
        // AppKit enables Paste, the menu item Cmd+V goes through, only for a type the view reads (build 15: greyed out
        // for a screenshot, so `paste` never ran). No folder, nothing to save a picture in: no picture types.
        #expect(!editor.readablePasteboardTypes.contains(.png))
        editor.folder = folder
        let board = NSPasteboard(name: NSPasteboard.Name("pilot-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        // Cmd+Ctrl+Shift+4's shape, as read off the clipboard on 2026-10-10.
        board.clearContents()
        board.setData(png, forType: .png)
        board.setData(tiff, forType: .tiff)
        #expect(board.availableType(from: editor.readablePasteboardTypes) != nil)
        #expect(editor.insertPictures(from: board))

        board.clearContents()
        board.setData(tiff, forType: .tiff)
        #expect(board.availableType(from: editor.readablePasteboardTypes) != nil)
        #expect(editor.insertPictures(from: board))

        // Finder's: the file, its name as text and its icon.
        let file = folder.appending(path: "Holiday Shot.png")
        try png.write(to: file)
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(file.lastPathComponent, forType: .string)
        item.setData(tiff, forType: .tiff)
        board.writeObjects([item])
        #expect(board.availableType(from: editor.readablePasteboardTypes) != nil)
        #expect(editor.insertPictures(from: board))

        let names = NoteAttachments.references(in: editor.string)
        #expect(names.count == 3 && names[0].hasPrefix("image-") && names[1].hasPrefix("image-") && names[1].hasSuffix(".png"))
        #expect(names[2] == "holiday-shot.png")
        for name in names { #expect(FileManager.default.fileExists(atPath: folder.appending(path: "attachments/\(name)").path), "\(name)") }
    }

    @Test("The Notes page takes the panel's keys: Escape gives the list the keyboard, ↓ previews, Return opens; Escape in the list goes back to the note")
    func pageKeys() throws {
        let model = NotesModel(store: NoteStore(folder: folder), defaults: defaults)
        model.reload()
        model.new(); model.text = "Alpha"; model.flush()
        model.new(); model.text = "Beta"; model.flush()
        #expect(model.groups.map(\.title) == ["Scratch", "Today"] && model.groups.flatMap(\.notes).map(\.title) == ["Scratch", "Beta", "Alpha"])
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ key: String? = nil) -> NotesKey? {
            NotesKey(code: code, flags: flags, key: key, list: model.listFocused, confirming: model.confirmingTrash, actions: model.actions != nil)
        }
        NotesPage.perform(try #require(key(53)), on: model)
        #expect(model.listFocused && model.selectedNote?.title == "Beta")
        NotesPage.perform(try #require(key(125)), on: model)
        #expect(model.selectedNote?.title == "Alpha" && model.note?.title == "Beta")
        NotesPage.perform(try #require(key(53)), on: model)
        #expect(!model.listFocused && model.note?.title == "Beta", "Escape in the list goes back to the note, not past it")
        NotesPage.perform(.list, on: model)
        NotesPage.perform(.step(1), on: model)
        NotesPage.perform(try #require(key(36)), on: model)
        #expect(model.note?.title == "Alpha" && !model.listFocused)
        // ⌘P pins the open note, ⌘⌫ from the list asks, Return answers.
        NotesPage.perform(try #require(key(35, .command, "p")), on: model)
        #expect(model.note?.pinned == true)
        NotesPage.perform(.list, on: model)
        NotesPage.perform(try #require(key(51, .command)), on: model)
        #expect(model.confirmingTrash && key(36) == .confirmTrash && key(53) == .keep)
        NotesPage.perform(.keep, on: model)
        #expect(!model.confirmingTrash && model.note?.title == "Alpha")
    }

    @Test("Escape in the note gives the list the keyboard on the open note; ↓ previews the next row, Return opens it and the editor has the keyboard again; Escape in the list hides")
    func listFocus() throws {
        let model = NotesModel(store: NoteStore(folder: folder), defaults: defaults)
        model.reload()
        model.new(); model.text = "Alpha"; model.flush()
        model.new(); model.text = "Beta"; model.flush()
        #expect(model.rows.map(\.title) == ["Scratch", "Beta", "Alpha"] && model.note?.title == "Beta")
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ key: String? = nil) -> NotesKey? {
            NotesKey(code: code, flags: flags, key: key, list: model.listFocused, confirming: model.confirmingTrash)
        }
        // In the note: Return, arrows and Cmd+Backspace (delete to the line's start, P56) are the editor's; Escape goes to the list.
        #expect(key(36) == nil && key(125) == nil && key(51, .command) == nil && key(53) == .list)
        model.perform(.list)
        #expect(model.listFocused && model.selection == model.current && model.selectedNote?.title == "Beta")
        #expect(key(125) == .step(1) && key(126) == .step(-1) && key(36) == .open && key(51, .command) == .askTrash && key(53) == .hide)
        model.perform(try #require(key(125)))
        // The pane previews Alpha; Beta stays the open note until Return.
        #expect(model.selectedNote?.title == "Alpha" && model.note?.title == "Beta")
        model.perform(.step(1))
        #expect(model.selectedNote?.title == "Alpha")
        model.perform(try #require(key(36)))
        #expect(model.note?.title == "Alpha" && model.text == "Alpha" && !model.listFocused && model.selection == nil)
        // Under the Trash question Escape keeps the note, from the note or the list alike.
        model.askTrash()
        #expect(key(53) == .keep && key(36) == .confirmTrash)
        model.perform(.keep)
        #expect(!model.confirmingTrash && model.note?.title == "Alpha" && !model.listFocused)
    }

    @Test("Cmd+P pins and unpins the open note (the highlighted one while the list has the keyboard); Shift+Cmd+P does nothing; Scratch is never pinned")
    func cmdPPins() throws {
        let model = NotesModel(store: NoteStore(folder: folder), defaults: defaults)
        model.reload()
        model.new(); model.text = "Alpha"; model.flush()
        model.new(); model.text = "Beta"; model.flush()
        let beta = model.current
        #expect(NotesKey(code: 35, flags: .command, key: "p", list: false, confirming: false) == .pin)
        #expect(NotesKey(code: 35, flags: [.command, .shift], key: "p", list: false, confirming: false) == nil)
        #expect(model.note.map { NoteAction.choices(for: $0).first } == .pin)
        model.perform(.pin)
        #expect(model.notes.first { $0.id == beta }?.pinned == true)
        #expect(model.note.map { NoteAction.choices(for: $0).first } == .unpin)
        model.perform(.pin)
        #expect(model.notes.first { $0.id == beta }?.pinned == false)
        // From the list: the highlighted row, not the open one.
        model.perform(.list)
        model.perform(.step(1))
        let alpha = try #require(model.selectedNote?.id)
        model.perform(.pin)
        #expect(model.notes.first { $0.id == alpha }?.pinned == true && model.notes.first { $0.id == beta }?.pinned == false)
        #expect(model.current == beta)
        model.open(NoteStore.scratch)
        model.perform(.pin)
        #expect(model.notes.first { $0.id == NoteStore.scratch }?.pinned == false)
    }

    @Test("A press and release in one place outside the panel is a click that hides it; one dragged away (a picture from Finder) is not")
    func clickOutside() {
        #expect(NotesPanel.isClick(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 101)))
        #expect(!NotesPanel.isClick(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 140, y: 100)))
        #expect(!NotesPanel.isClick(from: nil, to: CGPoint(x: 100, y: 100)))
    }

    func file(_ id: String) -> String? { try? String(contentsOf: folder.appending(path: id), encoding: .utf8) }

    @Test("Typing in Scratch makes a note of its own at once, with the caret staying in it; Scratch's file stays empty, and words left in the old Scratch move out on the next read")
    func scratchMovesToANote() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Scratch\n\nbuy oat milk\n".utf8).write(to: folder.appending(path: "Scratch.md"))
        let model = NotesModel(store: NoteStore(folder: folder), defaults: defaults)
        model.reload()
        #expect(file("Scratch.md") == "" && model.notes.contains { $0.title == "buy oat milk" }, "the old Scratch's words moved to a note")
        model.open(NoteStore.scratch)
        #expect(model.text == "" && model.note?.isScratch == true)
        model.text = "C"
        let id = model.current
        #expect(id != NoteStore.scratch && file(id) == "C" && file("Scratch.md") == "")
        #expect(model.text == "C" && model.notes.contains { $0.id == id && !$0.pinned })
        // Typing goes on in that note; Scratch stays empty and listed on top, in its own section, never pinned.
        model.text = "Call the bank\n"
        model.flush()
        #expect(model.note?.title == "Call the bank" && file(model.current) == "Call the bank\n" && file("Scratch.md") == "")
        #expect(model.rows.first?.isScratch == true && model.rows.first?.pinned == false && model.groups.first?.section == .scratch)
        // Opening Scratch again: empty. Blank keys alone make no note.
        model.open(NoteStore.scratch)
        model.text = "  \n"
        #expect(model.current == NoteStore.scratch && model.notes.count == 3)
        // Words another app wrote into Scratch.md while it sat open are moved, never written over, by the next key.
        try Data("from Obsidian\n".utf8).write(to: folder.appending(path: "Scratch.md"))
        model.text = "  \nD"
        #expect(model.current != NoteStore.scratch && file(model.current) == "  \nD" && file("Scratch.md") == "")
        #expect(model.notes.contains { $0.title == "from Obsidian" } && model.notes.count == 5)
    }

    @Test("Cmd+K lists a note's actions with the formats, typing searches them, ↑↓ choose and Return runs one; Escape closes it; Scratch has only its own")
    func cmdKActions() throws {
        let model = NotesModel(store: NoteStore(folder: folder), defaults: defaults)
        let board = NSPasteboard(name: NSPasteboard.Name("pilot-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        model.pasteboard = board
        var tips: [String] = []
        model.tip = { tips.append($0) }
        model.reload()
        model.new(); model.text = "# Plan\nship it"; model.flush()
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ key: String? = nil) -> NotesKey? {
            NotesKey(code: code, flags: flags, key: key, list: model.listFocused, confirming: model.confirmingTrash, actions: model.actions != nil)
        }
        #expect(key(40, .command, "k") == .actions)
        model.perform(.actions)
        #expect(model.actions?.choices.map(\.title) == ["Pin", "Rename", "Duplicate", "Copy as Markdown", "Reveal in Finder",
                                                       "Heading", "Bold", "Italic", "Code", "Checklist", "New note", "Move to Trash"])
        #expect(model.actions?.choices.compactMap(\.key) == ["⌘⇧H", "⌘B", "⌘I", "⌘E", "⌘⇧L", "⌘N", "⌘⌫"])
        #expect(key(125) == .stepActions(1) && key(36) == .runAction && key(53) == .closeActions && key(1, .command, "s") == .held)
        // Typing searches: "bo" leaves Bold; Backspace takes a letter off.
        model.perform(try #require(key(11, [], "b"))); model.perform(try #require(key(31, [], "o")))
        #expect(model.actions?.visible == [.format(.bold)] && model.actions?.index == 0)
        model.perform(try #require(key(51))); model.perform(try #require(key(51)))
        #expect(model.actions?.query == "" && model.actions?.visible.count == 12)
        model.perform(.stepActions(3))
        model.perform(.runAction)
        #expect(model.actions == nil && board.string(forType: .string) == "# Plan\nship it" && tips == ["Copied “Plan” as Markdown"])
        // Duplicate: a note of its own, its title marked as the copy, opened.
        model.perform(.actions); model.perform(.stepActions(2)); model.perform(.runAction)
        #expect(model.note?.title == "Plan copy" && model.text == "# Plan copy\nship it" && file(model.current) == "# Plan copy\nship it")
        // Pin from Cmd+K, then it offers Unpin.
        model.perform(.actions); model.perform(.runAction)
        #expect(model.note?.pinned == true)
        model.perform(.actions)
        #expect(model.actions?.choices.first == .unpin)
        model.perform(.closeActions)
        #expect(model.actions == nil)
        // Rename picks the title words, past the heading's marks.
        #expect(MarkdownFormat.titleRange("# Plan copy\nship it") == NSRange(location: 2, length: 9))
        #expect(MarkdownFormat.titleRange("") == NSRange(location: 0, length: 0))
        model.open(NoteStore.scratch)
        model.perform(.actions)
        #expect(model.actions?.choices == [.copy, .reveal] + MarkdownFormat.keyed.map(NoteAction.format) + [.new])
        // From the list, on a highlighted row, the formats stay out: no editor is being written in.
        model.perform(.closeActions)
        model.perform(.list)
        model.perform(.actions)
        #expect(model.actions?.choices == [.copy, .reveal, .new])
    }

    @Test("An emptied note offers Delete: Cmd+Backspace moves its file to the Trash with no question; Return in it is the editor's newline")
    func emptyNoteDeletes() throws {
        let trashed = Trashed()
        let model = NotesModel(store: NoteStore(folder: folder, trash: { trashed.names.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }), defaults: defaults)
        model.reload()
        model.new(); model.text = "Plan"; model.flush()
        let plan = model.current
        #expect(!model.isEmptyNote)
        model.text = "\n  "
        #expect(model.isEmptyNote)
        #expect(NotesKey(code: 36, flags: [], key: "\r", list: false, confirming: false) == nil, "Return types a newline")
        #expect(NotesKey(code: 51, flags: .command, key: nil, list: false, confirming: false, empty: true) == .askTrash)
        model.perform(.askTrash)
        #expect(!model.confirmingTrash && trashed.names == [plan] && file(plan) == nil && model.current == NoteStore.scratch)
        // Scratch is never an empty note to delete.
        #expect(!model.isEmptyNote)
    }
}