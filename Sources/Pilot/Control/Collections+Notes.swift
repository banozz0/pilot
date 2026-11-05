import Foundation
import PilotCore

extension ControlVerbs {
    /// The quick notes as a collection (CLI W12): list in the Notes page's order, add as its New note, remove as its Move
    /// to Trash…, which waits on the Allow gate as the page's confirm does. Scratch never goes. A note with dated lines
    /// lists their reminders (P66).
    func registerNoteCollection(_ app: ControlNotes) {
        register(ControlCollection("notes", help: "Quick notes in the notes folder, Scratch first, each with its dated lines' reminders (line, at, ahead); add makes one, remove moves one to the Trash after Allow.",
                                   fields: [.init("text", help: "the new note's text; its first line is its title", required: false)],
                                   rowKey: "id", asks: [.remove],
                                   list: { () throws(ControlError) in
            let notes = try app.notes()
            return Self.withReminders(app.rows(notes), NoteReminders.shared.plan(notes))
        },
                                   askerAdd: { args, _ throws(ControlError) in
            let note = try app.io("the note was not made") { try app.model().create(text: args.value("text") ?? "") }
            return .object(try app.saved(note.id))
        }, askerRemove: { args, peer throws(ControlError) in
            let note = try app.note(try args.word(0, "note id (pilot list notes lists them)"))
            guard !note.isScratch else { throw ControlError(.badValue, "Scratch stays: clear it with pilot note write scratch --text …") }
            // The page's confirm; read again after Allow, so a note renamed meanwhile denies.
            @MainActor func ask() -> ControlGate.Ask {
                let question = NotesPanel.trashQuestion((try? app.note(note.id))?.title ?? note.id)
                return ControlGate.Ask(question.title, question.detail)
            }
            return try await app.gate.allow(ask(), peer: peer) { () throws(ControlError) in
                let model = app.model()
                try app.io("\(note.id) did not go to the Trash") { try model.moveToTrash(note.id) }
                var row = ControlNotes.row(note, folder: model.store.folder)
                row["trashed"] = .bool(true)
                return .object(row)
            }
        }))
    }

    /// The notes' rows, each note with a dated line given `reminders`: the line, its time in local time with its offset,
    /// and whether it is still ahead.
    static func withReminders(_ rows: JSONValue, _ reminders: [NoteReminders.Reminder], now: Date = .now) -> JSONValue {
        guard case .array(let list) = rows else { return rows }
        let byNote = Dictionary(grouping: reminders, by: \.note), local = Date.ISO8601FormatStyle(timeZone: .current)
        return .array(list.map { row in
            guard case .object(var fields) = row, case .string(let id)? = fields["id"], let mine = byNote[id] else { return row }
            fields["reminders"] = .array(mine.map { .object(["line": .string($0.line), "at": .string($0.at.formatted(local)), "ahead": .bool($0.at > now)]) })
            return .object(fields)
        })
    }
}
