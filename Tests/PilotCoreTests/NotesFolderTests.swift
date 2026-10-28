import Foundation
import Testing
@testable import PilotCore

/// Where notes live (task N1): Pilot's own folder in Documents, the old Application Support folder kept while it holds
/// notes, and a move that loses nothing. Each test gets fresh folders of its own.
@Suite("Notes folder")
struct NotesFolderTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "pilot-notes-folder-\(UUID().uuidString)")
    var old: URL { root.appending(path: "old") }
    var new: URL { root.appending(path: "new") }

    func write(_ text: String, _ name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
    }

    func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test("Pilot's own folder is Documents/Pilot Notes; nil names it, and naming it saves nil")
    func pilotDefault() {
        #expect(NotesFolder.pilotDefault.path.hasSuffix("/Documents/Pilot Notes"))
        #expect(NotesFolder.folder(nil) == NotesFolder.pilotDefault)
        #expect(NotesFolder.folder("/tmp/vault/Inbox").path == "/tmp/vault/Inbox")
        #expect(NotesFolder.setting(NotesFolder.pilotDefault) == nil)
        #expect(NotesFolder.setting(URL(fileURLWithPath: "/tmp/vault/Inbox")) == "/tmp/vault/Inbox")
    }

    @Test("A picked folder stays; with none, the old folder is kept while it holds a note, else Pilot's own")
    func kept() throws {
        #expect(NotesFolder.kept(saved: "/tmp/vault", legacy: old) == "/tmp/vault")
        // Missing, or only the Scratch Pilot wrote and nobody touched: Pilot's own.
        #expect(NotesFolder.kept(saved: nil, legacy: old) == nil)
        try write(NoteStore.scratchText, "Scratch.md", in: old)
        #expect(NotesFolder.kept(saved: nil, legacy: old) == nil)
        try write("# Scratch\n\nmilk", "Scratch.md", in: old)
        #expect(NotesFolder.kept(saved: nil, legacy: old) == old.path)
        try write(NoteStore.scratchText, "Scratch.md", in: old)
        try write("# Idea", "idea-123456.md", in: old)
        #expect(NotesFolder.kept(saved: nil, legacy: old) == old.path)
    }

    @Test("A move carries every note and its pin to a new folder it makes, and leaves what is not a note")
    func move() throws {
        try write("# Scratch\n\nmilk", "Scratch.md", in: old)
        try write("# Idea", "idea-123456.md", in: old)
        try write("from the vault", "Inbox.md", in: old)
        try write("[\"idea-123456.md\"]", "pins.json", in: old)
        try write("keep me", "photo.png", in: old)
        let moved = try NotesFolder.move(from: old, to: new)
        #expect(moved == NotesFolder.Moved(count: 3, renamed: [:]))
        #expect(names(new) == ["Inbox.md", "Scratch.md", "idea-123456.md", "pins.json"])
        #expect(names(old) == ["photo.png"])
        let notes = try NoteStore(folder: new).load()
        #expect(notes.map(\.id) == ["Scratch.md", "idea-123456.md", "Inbox.md"])
        #expect(notes[1].pinned && notes[0].text == "# Scratch\n\nmilk")
    }

    @Test("A name the new folder has stays; the incoming note takes 'name 2', its pin follows; an unwritten Scratch gives way")
    func clashes() throws {
        try write("# Scratch\n\nmilk", "Scratch.md", in: old)
        try write("old inbox", "Inbox.md", in: old)
        try write("[\"Inbox.md\"]", "pins.json", in: old)
        try write(NoteStore.scratchText, "Scratch.md", in: new)
        try write("vault inbox", "inbox.md", in: new)
        try write("[\"inbox.md\"]", "pins.json", in: new)
        let moved = try NotesFolder.move(from: old, to: new)
        #expect(moved == NotesFolder.Moved(count: 2, renamed: ["Inbox.md": "Inbox 2.md"]))
        #expect(names(new) == ["Inbox 2.md", "Scratch.md", "inbox.md", "pins.json"])
        #expect(try String(contentsOf: new.appending(path: "Scratch.md"), encoding: .utf8) == "# Scratch\n\nmilk")
        #expect(try String(contentsOf: new.appending(path: "inbox.md"), encoding: .utf8) == "vault inbox")
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: new.appending(path: "pins.json"))) == ["Inbox 2.md", "inbox.md"])

        // Both Scratches written in: the incoming one becomes a note of its own. An unwritten one left behind just goes.
        try write("# Scratch\n\neggs", "Scratch.md", in: old)
        #expect(try NotesFolder.move(from: old, to: new).renamed == ["Scratch.md": "Scratch 2.md"])
        try write(NoteStore.scratchText, "Scratch.md", in: old)
        #expect(try NotesFolder.move(from: old, to: new).count == 0)
        #expect(names(old).isEmpty)
    }

    @Test("Moving to the folder the notes are in moves nothing, however the path is written")
    func sameFolder() throws {
        try write("# Idea", "idea-123456.md", in: old)
        #expect(try NotesFolder.move(from: old, to: URL(fileURLWithPath: old.path + "/../old/")) == NotesFolder.Moved())
        #expect(names(old) == ["idea-123456.md"])
    }

    @Test("The page's search: matching titles best first, then notes with every word in their text")
    func search() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let notes = [Note(id: "Scratch.md", text: "# Scratch\n\nbuy milk", edited: at, pinned: true),
                     Note(id: "milk-123456.md", text: "# Milk run\n\noat", edited: at, pinned: false),
                     Note(id: "plan-234567.md", text: "# Plan\n\nship pilot", edited: at, pinned: false)]
        #expect(Notes.search(notes, query: " ").map(\.id) == notes.map(\.id))
        #expect(Notes.search(notes, query: "milk").map(\.id) == ["milk-123456.md", "Scratch.md"])
        #expect(Notes.search(notes, query: "ship pilot").map(\.id) == ["plan-234567.md"])
        #expect(Notes.search(notes, query: "zebra").isEmpty)
    }

    @Test("A move carries attachments/ too; a picture name the new folder has takes 'name 2' and the moved notes follow it")
    func moveAttachments() throws {
        try write("# Trip\n![](attachments/beach.png)\n![](attachments/map.png)\n", "trip-123456.md", in: old)
        try write("sand", "beach.png", in: old.appending(path: "attachments"))
        try write("roads", "map.png", in: old.appending(path: "attachments"))
        try write("someone else's beach", "beach.png", in: new.appending(path: "attachments"))
        let moved = try NotesFolder.move(from: old, to: new)
        #expect(moved.count == 1)
        #expect(names(new.appending(path: "attachments")) == ["beach 2.png", "beach.png", "map.png"])
        #expect(!FileManager.default.fileExists(atPath: old.appending(path: "attachments").path))
        let text = try String(contentsOf: new.appending(path: "trip-123456.md"), encoding: .utf8)
        #expect(text == "# Trip\n![](attachments/beach%202.png)\n![](attachments/map.png)\n")
        #expect(try String(contentsOf: new.appending(path: "attachments/beach 2.png"), encoding: .utf8) == "sand")
        #expect(NoteAttachments.references(in: text) == ["beach 2.png", "map.png"])
    }
}
