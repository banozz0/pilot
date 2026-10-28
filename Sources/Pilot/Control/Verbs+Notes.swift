import Foundation
import ImageIO
import PilotCore

/// What `pilot note` and the `notes` collection reach (CLI W12): the notes model the panel and the Notes page share, so
/// a command's edit shows in both at once and what Sven is typing is saved before any read or write. The tests hand in a
/// model over a folder of their own, a gate and a show, so Sven's notes are never read or written and no panel opens.
@MainActor
final class ControlNotes {
    var model: @MainActor () -> NotesModel = { NotesPanel.shared.currentModel() }
    var gate = AllowPrompt.gate
    /// Opens the panel on a note, as the menu's note rows do.
    var show: @MainActor (String) -> Void = { NotesPanel.shared.show(note: $0) }

    /// Runs one of the model's edits, its failure a bad-value naming what was not done.
    func io<T>(_ what: String, _ body: () throws -> T) throws(ControlError) -> T {
        do { return try body() } catch { throw ControlError(.badValue, "\(what): \(error.localizedDescription)") }
    }

    /// Every note as the panel would show it, what is typed saved first.
    func notes() throws(ControlError) -> [Note] {
        let model = model()
        model.flush()
        return try io("the notes folder does not read") { try model.store.load() }
    }

    /// The note a word names in `notes`: its id (the file's name), the id without ".md", or "scratch".
    static func note(_ word: String, in notes: [Note]) throws(ControlError) -> Note {
        let id = word.lowercased() == "scratch" ? NoteStore.scratch : word
        guard let note = notes.first(where: { $0.id == id || $0.id == id + ".md" }) else {
            throw ControlError(.badValue, "no note \(word); pilot list notes lists them")
        }
        return note
    }

    /// The note a word names, read from disk.
    func note(_ word: String) throws(ControlError) -> Note { try Self.note(word, in: try notes()) }

    /// One note's row: what the page's list shows of it, its group there, and where its file is.
    static func row(_ note: Note, folder: URL, group: String? = nil) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["id": .string(note.id), "title": .string(note.title), "pinned": .bool(note.pinned),
                                        "edited": .string(note.edited.ISO8601Format()),
                                        "path": .string(folder.appending(path: note.id).path(percentEncoded: false))]
        if note.isScratch { row["scratch"] = .bool(true) }
        row["group"] = group.map(JSONValue.string)
        return row
    }

    /// Rows in the page's order, each with its group: Scratch, Pinned, Today, Yesterday, Earlier.
    func rows(_ notes: [Note]) -> JSONValue {
        let folder = model().store.folder
        return .array(Notes.groups(notes, now: .now).flatMap { group in group.notes.map { .object(Self.row($0, folder: folder, group: group.title)) } })
    }

    /// A note read whole: its row, its text, its word count as the page counts it, and the pictures it shows.
    func full(_ note: Note) -> [String: JSONValue] {
        let folder = model().store.folder
        var full = Self.row(note, folder: folder)
        full["text"] = .string(note.text)
        full["words"] = .number(Double(NotesText.words(note.text)))
        full["attachments"] = .array(NoteAttachments.references(in: note.text).map { name in
            let url = folder.appending(path: NoteAttachments.folder).appending(path: name)
            return .object(["name": .string(name), "path": .string(url.path(percentEncoded: false)),
                            "exists": .bool(FileManager.default.fileExists(atPath: url.path))])
        })
        return full
    }

    /// A note whole as the model read it back after an edit.
    func saved(_ id: String) throws(ControlError) -> [String: JSONValue] { full(try Self.note(id, in: model().notes)) }

    /// The Allow question for a picture copied into a note: what goes where. Read again after Allow, so a note renamed
    /// or gone meanwhile denies.
    func attachAsk(_ id: String, _ file: URL) -> ControlGate.Ask {
        ControlGate.Ask("Attach a picture to “\((try? note(id))?.title ?? id)”", "copy \(file.path(percentEncoded: false)) into the notes folder's attachments/")
    }

    /// Copies a picture into attachments/ and links it on a line of its own at the end of the note, as a paste at the
    /// note's end would; answers the note read back and the link.
    func attach(_ note: Note, _ file: URL) throws(ControlError) -> [String: JSONValue] {
        let data = try io("\(file.lastPathComponent) does not read") { try Data(contentsOf: file) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw ControlError(.badValue, "\(file.path(percentEncoded: false)) is not a picture Pilot can read")
        }
        let model = model()
        let link = try io("\(file.lastPathComponent) was not copied") {
            try NoteAttachments.save(data, named: file.lastPathComponent, ext: file.pathExtension, in: model.store.folder, now: .now)
        }
        let before = note.text.isEmpty || note.text.hasSuffix("\n") ? "" : "\n"
        var answer = try saved(try io("\(note.id) was not saved") { try model.write(note.id, text: note.text + before + link + "\n") })
        answer["link"] = .string(link)
        return answer
    }
}

extension ControlVerbs {
    /// `pilot note …` over one note, then the `notes` collection: the Notes page, the quick notes panel and the menu's
    /// "note …".
    func registerNotes(_ app: ControlNotes) {
        let words = ["search", "show", "write", "append", "pin", "unpin", "attach", "open"]
        let index = JSONValue.array(words.map(JSONValue.string))
        let detail: [String: String] = [
            "search": "pilot note search <words>: the Notes page's search: titles that match, best first, then notes with every word in their text.",
            "show": "pilot note show <id>: one note whole: its row, text, words (as the page counts them) and the pictures it shows. scratch names Scratch.",
            "write": "pilot note write <id> --text <text>: replaces the note's text, as typing in the editor does; a to-do is ticked by writing - [x]. A new first line renames a note Pilot named, so the answer's id may be new. Scratch stays empty: text written to it is saved as a new note, whose id the answer gives. Text starting with -- goes as --text=<text>.",
            "append": "pilot note append <text>: saves the line as a new note (through Scratch, which stays empty), as the menu's \"note …\" does, without the tip; answers that note.",
            "pin": "pilot note pin|unpin <id>: pins or unpins a note, as the page's Pin; Scratch is never pinned.",
            "attach": "pilot note attach <id> <picture>: copies a picture file into the notes folder's attachments/ and links it on a line at the note's end, after Allow.",
            "open": "pilot note open <id>: shows the quick notes panel on that note, as the menu's note rows do.",
        ]
        register(ControlVerb("note", help: "Searches, reads, writes, pins and attaches pictures to quick notes; opens the panel on one.",
                             usage: "pilot note [search <words> | show <id> | write <id> --text <text> | append <text> | pin <id> | unpin <id> | attach <id> <picture> | open <id>]",
                             flags: [.init("text", help: "write only: the note's whole new text")],
                             schema: {
                                 .object(["subcommands": index, "rowKey": .string("id"), "rows": .object([
                                     "id": .string("the note's file name in the notes folder; it changes when a new first line renames a note Pilot named"),
                                     "title": .string("its first line with text"), "pinned": .string("pinned on the page; Scratch never is"),
                                     "scratch": .string("true: Scratch, which can be neither pinned nor moved to the Trash"),
                                     "edited": .string("ISO 8601"), "group": .string("list only: its group on the page: Scratch, Pinned, Today, Yesterday or Earlier"),
                                     "path": .string("the note's file"),
                                     "text": .string("show and the edits: the note's text"), "words": .string("show and the edits: words as the page counts them"),
                                     "attachments": .string("show and the edits: the pictures in attachments/ it links: name, path, exists"),
                                 ])])
                             },
                             index: { .object(["subcommands": index]) },
                             detail: { word in detail[word == "unpin" ? "pin" : word] }) { call throws(ControlError) in
            let args = call.arguments()
            let word = args.positional.first ?? "search"
            if word != "write", let refusal = ControlVerb.unknownFlag(args.flags, known: [], in: "pilot note \(word)") { throw refusal }
            @MainActor func target() throws(ControlError) -> Note { try app.note(try args.word(1, "note id (pilot list notes lists them)")) }
            let model = app.model()
            switch word {
            case "search":
                // Best match first, as the page's search lists them, not grouped by day.
                let folder = model.store.folder
                return .array(Notes.search(try app.notes(), query: args.positional.dropFirst().joined(separator: " ")).map { .object(ControlNotes.row($0, folder: folder)) })
            case "show":
                return .object(app.full(try target()))
            case "write":
                let note = try target(), text = try args.required("text")
                // Scratch stays empty: its words go to a note of their own, which the answer names, so a retry never
                // writes them twice.
                if note.isScratch {
                    guard !Notes.isBlankScratch(text) else { return .object(try app.saved(NoteStore.scratch)) }
                    return .object(try app.saved(try app.io("the note was not saved") { try model.appendToScratch(text) }))
                }
                return .object(try app.saved(try app.io("\(note.id) was not saved") { try model.write(note.id, text: text) }))
            case "append":
                let line = args.positional.dropFirst().joined(separator: " ")
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { throw ControlError(.badRequest, "missing text for the note") }
                let id = try app.io("the note was not saved") { try model.appendToScratch(line) }
                return .object(try app.saved(id))
            case "pin", "unpin":
                let note = try target()
                guard !note.isScratch else { throw ControlError(.badValue, "Scratch is never pinned") }
                try app.io("\(note.id) was not \(word)ned") { try model.setPin(note.id, word == "pin") }
                return .object(try app.saved(note.id))
            case "attach":
                let id = try target().id, path = try args.word(2, "picture file")
                let file = ExtensionTools.folder(path, cwd: call.cwd)
                guard NoteAttachments.isImage(file) else { throw ControlError(.badValue, "\(path) is not a picture: attach takes an image file, e.g. .png or .jpg") }
                // Pilot may read where the asker cannot (Full Disk Access): nothing is read before Allow.
                return try await app.gate.allow(app.attachAsk(id, file), peer: call.peer) { () throws(ControlError) in
                    .object(try app.attach(try app.note(id), file))
                }
            case "open":
                let note = try target()
                app.show(note.id)
                return .object(["id": .string(note.id), "opened": .bool(true)])
            case let other: throw ControlError(.badValue, "no note \(other); subcommands: \(words.joined(separator: ", "))")
            }
        })
        registerNoteCollection(app)
    }
}
