import Foundation
import Testing
@testable import PilotCore

/// Quick notes (card agent-bo-95423042): one .md file per note in a folder, Scratch always there and never pinned, pins in
/// pins.json beside them. Each test gets a fresh folder of its own.
@Suite("Quick notes")
struct NotesTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-notes-\(UUID().uuidString)")
    let ids = ["123456", "234567", "345678"]

    /// The short ids new notes get, in order.
    final class IDs: @unchecked Sendable {
        var left: [String]
        init(_ ids: [String]) { left = ids }
        func next() -> String { left.removeFirst() }
    }

    func store(now: Date = Date(timeIntervalSince1970: 1_800_000_000), trash: @escaping @Sendable (URL) throws -> Void = { _ in }) -> NoteStore {
        let ids = IDs(ids)
        return NoteStore(folder: folder, now: { now }, newID: { ids.next() }, trash: trash)
    }

    /// A picture saved in the folder's attachments/ as the editor saves one, at the store's fixed time.
    func attach(_ data: Data, named name: String?, ext: String) throws -> String {
        try NoteAttachments.save(data, named: name, ext: ext, in: folder, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func file(_ name: String) throws -> String { try String(contentsOf: folder.appending(path: name), encoding: .utf8) }

    @Test("An empty folder gets Scratch.md, not pinned, and nothing else")
    func scratchAlwaysPresent() throws {
        let notes = try store().load()
        #expect(notes.map(\.id) == ["Scratch.md"])
        #expect(!notes[0].pinned && notes[0].isScratch && notes[0].title == "Scratch")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Scratch.md").path))
        // Deleted behind Pilot's back, it comes back on the next read.
        try FileManager.default.removeItem(at: folder.appending(path: "Scratch.md"))
        #expect(try store().load().map(\.id) == ["Scratch.md"])
    }

    @Test("A new note is a file named by a slug of its first line plus a short id; saving a new first line renames it")
    func createAndRename() throws {
        let s = store()
        let note = try s.create()
        #expect(note.id == "untitled-123456.md")
        let id = try s.save(note.id, text: "# Buy milk & eggs!\nfrom the shop")
        #expect(id == "buy-milk-eggs-123456.md")
        #expect(try file(id) == "# Buy milk & eggs!\nfrom the shop")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: note.id).path))
        let saved = try #require(try s.load().first { $0.id == id })
        #expect(saved.title == "Buy milk & eggs!")
        // The same first line keeps the name.
        #expect(try s.save(id, text: "# Buy milk & eggs!\nand bread") == id)
    }

    @Test("Scratch and a file written elsewhere keep their names whatever their first line says")
    func foreignNamesKept() throws {
        let s = store()
        _ = try s.load()
        #expect(try s.save("Scratch.md", text: "Groceries\n- milk") == "Scratch.md")
        try "Inbox from the vault".write(to: folder.appending(path: "Inbox.md"), atomically: true, encoding: .utf8)
        #expect(try s.save("Inbox.md", text: "Something else") == "Inbox.md")
        // A vault note that only looks like Pilot's names (capitals, a date) is never renamed, so never removed: on a
        // case-insensitive disk "Meeting-261008.md" and "meeting-261008.md" are one file.
        try "Meeting".write(to: folder.appending(path: "Meeting-261008.md"), atomically: true, encoding: .utf8)
        #expect(try s.save("Meeting-261008.md", text: "Meeting\nnotes") == "Meeting-261008.md")
        #expect(try file("Meeting-261008.md") == "Meeting\nnotes")
    }

    @Test("A pin is kept in pins.json and follows its note through a rename; Scratch cannot be pinned; the welcome note stays over the pins")
    func pins() throws {
        let s = store()
        _ = try NotesWelcome.write(in: folder)
        let note = try s.create(text: "Plan")
        try s.setPinned(note.id, true)
        #expect(try s.load().filter(\.pinned).map(\.id) == [note.id])
        #expect(try s.load().map(\.id) == ["Scratch.md", NotesWelcome.name, note.id])
        #expect(try file("pins.json").contains(note.id))
        let renamed = try s.save(note.id, text: "Plans")
        #expect(try s.load().filter(\.pinned).map(\.id) == [renamed])
        try s.setPinned(renamed, false)
        try s.setPinned("Scratch.md", true)
        #expect(try s.load().filter(\.pinned).isEmpty)
    }

    @Test("A .md file added to the folder outside Pilot shows on the next read, titled by its first line as plain text; other files do not")
    func outsideFileAppears() throws {
        let s = store()
        _ = try s.load()
        try "## From Obsidian\nbody".write(to: folder.appending(path: "Vault note.md"), atomically: true, encoding: .utf8)
        try "not a note".write(to: folder.appending(path: "readme.txt"), atomically: true, encoding: .utf8)
        let notes = try s.load()
        #expect(notes.map(\.id).sorted() == ["Scratch.md", "Vault note.md"])
        #expect(notes.first { $0.id == "Vault note.md" }?.title == "From Obsidian")
        #expect(Notes.title(of: "**_Craft anything -> crm - farmops_**\nbody") == "Craft anything -> crm - farmops")
        #expect(Notes.title(of: "- [ ] Ring `Ana` about [the farm](https://x.com)") == "Ring Ana about the farm")
        #expect(Notes.title(of: "```\n1. *Plan* __B__") == "Plan B" && Notes.title(of: "#\n\n") == "Untitled")
    }

    @Test("A line added to Scratch goes on a line of its own at the end")
    func appendToScratch() throws {
        let s = store()
        _ = try s.load()
        try s.appendToScratch("buy milk")
        #expect(try file("Scratch.md") == "buy milk")
        _ = try s.save("Scratch.md", text: "Scratch\nfirst\n")
        try s.appendToScratch("second")
        #expect(try file("Scratch.md") == "Scratch\nfirst\nsecond")
    }

    @Test("What Scratch holds moves to a note of its own and Scratch is left empty; the old heading alone, or nothing, stays")
    func moveScratch() throws {
        let s = store()
        _ = try s.load()
        #expect(try file("Scratch.md") == "")
        #expect(try s.moveScratch() == nil)
        try Data(NoteStore.scratchText.utf8).write(to: folder.appending(path: "Scratch.md"))
        #expect(try s.moveScratch() == nil)
        #expect(try file("Scratch.md") == "", "the old heading alone is cleared")
        try Data("# Scratch\n\nbuy oat milk\n".utf8).write(to: folder.appending(path: "Scratch.md"))
        let moved = try #require(try s.moveScratch())
        #expect(moved.title == "buy oat milk" && moved.id.hasPrefix("buy-oat-milk-"))
        #expect(try file(moved.id) == "buy oat milk\n")
        #expect(try file("Scratch.md") == "")
        #expect(try s.load().map(\.id).sorted() == ["Scratch.md", moved.id].sorted())
    }

    @Test("Moving a note to the Trash goes through the trash seam and drops its pin; Scratch never goes")
    func trash() throws {
        let trashed = IDs([])
        let s = store { trashed.left.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }
        let note = try s.create(text: "Gone")
        try s.setPinned(note.id, true)
        try s.trash(note.id)
        try s.trash("Scratch.md")
        #expect(trashed.left == ["gone-123456.md"])
        #expect(try s.load().map(\.id) == ["Scratch.md"])
        #expect(try !file("pins.json").contains("gone"))
    }

    @Test("The list groups Scratch alone, the welcome note right under it, then Pinned, Today, Yesterday and Earlier, newest edited first")
    func groups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
        let day: TimeInterval = 86_400
        func note(_ id: String, _ ago: TimeInterval, pinned: Bool = false) -> Note {
            Note(id: id, text: id, edited: now.addingTimeInterval(-ago), pinned: pinned)
        }
        let notes = [note("old", 5 * day), note("today1", 3600), note("Scratch.md", 9 * day),
                     note("yest", day), note("today2", 60), note("pin", 2 * day, pinned: true), note("older", 3 * day),
                     note(NotesWelcome.name, 20 * day)]
        let groups = Notes.groups(notes, now: now, calendar: calendar)
        #expect(groups.map(\.notes).map { $0.map(\.id) } == [["Scratch.md"], [NotesWelcome.name], ["pin"], ["today2", "today1"], ["yest"], ["older", "old"]])
        #expect(groups.map(\.title) == ["Scratch", "Welcome", "Pinned", "Today", "Yesterday", "Earlier"] && groups[0].section == .scratch)
    }

    @Test("Typing note and text at the menu root offers New note; note alone, or another word, offers nothing")
    func notePrefixRow() {
        let row = RootAnswers.entries(for: "note buy milk", now: .now)
        #expect(row.count == 1)
        #expect(row.first?.title == "New note")
        #expect(row.first?.target == .note(.append("buy milk")))
        #expect(row.first?.isAnswer == true)
        #expect(RootAnswers.entries(for: "note ", now: .now).isEmpty)
        #expect(RootAnswers.entries(for: "notes", now: .now).isEmpty)
        #expect(RootAnswers.entries(for: "Note  call mum ", now: .now).first?.target == .note(.append("call mum")))
    }

    @Test("The Notes branch lists every note; search matches its text too, and Return opens it in the panel")
    func branchRows() {
        let notes = [Note(id: "Scratch.md", text: "Scratch\nmilk", edited: .now, pinned: false),
                     Note(id: "plan-123456.md", text: "Plan\nship pilot", edited: .now, pinned: false)]
        let rows = Notes.rows(notes)
        #expect(rows.map(\.title) == ["Scratch", "Plan"])
        #expect(rows.allSatisfy { $0.home == .notes && !$0.inSearch })
        #expect(rows[1].target == .note(.open("plan-123456.md")))
        #expect(rows[1].searchText.contains("ship pilot"))
        #expect(MenuBranch.notes.parent == .trigger)
    }

    @Test("Scratch is titled Scratch whatever is written in it, so it never passes for a note the Trash takes")
    func scratchTitle() throws {
        let s = store()
        _ = try s.load()
        try s.save("Scratch.md", text: "so for notes it looks good")
        let scratch = try #require(try s.load().first)
        #expect(scratch.isScratch && scratch.title == "Scratch")
        #expect(Notes.rows(try s.load()).first?.title == "Scratch")
    }

    @Test("A note's Cmd+K in the menu: Open, Show in Finder and Move to Trash, wherever it is listed; Scratch never trashes")
    func menuActions() {
        let rows = Notes.rows([Note(id: "Scratch.md", text: "", edited: .now, pinned: false),
                               Note(id: "plan-123456.md", text: "# Plan", edited: .now, pinned: true),
                               Note(id: "idea-234567.md", text: "Idea", edited: .now, pinned: false)])
        #expect(RowAction.list(for: rows[0], favourite: false) == [.open, .showInFinder])
        #expect(RowAction.list(for: rows[1], favourite: false) == [.open, .showInFinder, .trash])
        #expect(RowAction.list(for: rows[2], favourite: false) == [.open, .showInFinder, .trash])
    }

    @Test("A pasted picture is attachments/image-<time>.png, a dropped one a slug of its name; a name taken gets -2")
    func attach() throws {
        let pasted = try attach(Data([1, 2, 3]), named: nil, ext: "PNG")
        let stamp = NoteAttachments.stamp(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(pasted == "![](attachments/image-\(stamp).png)")
        #expect(try attach(Data([4]), named: nil, ext: "png") == "![](attachments/image-\(stamp)-2.png)")
        #expect(try attach(Data([5]), named: "Screenshot 2026-10-10 at 07.49.12.png", ext: "png")
            == "![](attachments/screenshot-2026-10-10-at-07-49-12.png)")
        #expect(try Data(contentsOf: folder.appending(path: "attachments/image-\(stamp).png")) == Data([1, 2, 3]))
        #expect(NoteAttachments.references(in: "# Moodboard\n\(pasted)\n![x](https://example.com/a.png)\n![](attachments/a%20b.png)")
            == ["image-\(stamp).png", "a b.png"])
        // A line that only shows a picture is never the title.
        #expect(Notes.title(of: "\(pasted)\nMoodboard") == "Moodboard")
        #expect(NoteAttachments.url("attachments/a%20b.png", in: folder) == folder.appending(path: "attachments/a b.png"))
        #expect(NoteAttachments.url("https://example.com/a.png", in: folder) == nil)
    }

    @Test("Trashing a note takes its pictures only when no other note shows them; Scratch's stay")
    func trashPictures() throws {
        final class Trashed: @unchecked Sendable { var names: [String] = [] }
        let trashed = Trashed()
        let s = store(trash: { trashed.names.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) })
        _ = try s.load()
        let own = try attach(Data([1]), named: "own.png", ext: "png"), shared = try attach(Data([2]), named: "shared.png", ext: "png")
        let note = try s.create(text: "# Trip\n\(own)\n\(shared)\n")
        try s.save("Scratch.md", text: "# Scratch\n\(shared)\n")
        try s.trash(note.id)
        #expect(trashed.names.sorted() == ["own.png", note.id])
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "attachments/shared.png").path))
    }
}
