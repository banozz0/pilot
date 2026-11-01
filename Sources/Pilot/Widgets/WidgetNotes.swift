import Foundation
import PilotCore

/// A Notes widget's data (`"data": {"notes": "<setting>"}`): Pilot's notes, drawn by Pilot as blocks and never handed to a
/// page or a program. Its note setting picks what shows: "" every note by title, in the panel's order, a click opening one
/// in the notes panel; a note's id, that note in full with Open under it. The folder is read again only when a note or
/// the pins change (FolderWatch), never on a clock.
enum WidgetNotes {
    /// The rows a widget lists, the newest; the panel holds the rest.
    static let most = 30

    /// An open press, as Pilot builds it in these blocks: the note's id after it. It is never a registered action:
    /// WidgetDesk.press takes it only from a notes widget, and only for a note it listed.
    static let openPrefix = "notes.open:"

    /// The notes panel's folder: the one the Notes page picked, else Pilot's own.
    @MainActor static var folder: URL { NotesPanel.shared.folder }

    /// The files whose change reads the notes again: a note, or the pins.
    static func watched(_ name: String) -> Bool { name.hasSuffix(".md") || name == "pins.json" }

    /// Every note, in the panel's order (Scratch, the pinned, then the newest), read off the main actor.
    @concurrent static func read(_ folder: URL) async -> [Note] {
        (try? NoteStore(folder: folder).load()) ?? []
    }

    /// What the widget draws for `picked` ("" for every note, else a note's id), and the ids its presses may open.
    @MainActor static func blocks(_ notes: [Note], picked: String) -> (blocks: [Extension.Block], opens: Set<String>) {
        func open(_ note: Note, _ title: String) -> Extension.Item.Action { .init(kind: .pilot(openPrefix + note.id), title: title) }
        if !picked.isEmpty {
            guard let note = notes.first(where: { $0.id == picked }) else {
                return ([.note(.init(text: "That note is gone: pick another in Edit widget."))], [])
            }
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ([.markdown(text.isEmpty ? "*Empty*" : text), .buttons([open(note, "Open")])], [note.id])
        }
        let shown = notes.prefix(most)
        guard !shown.isEmpty else { return ([.note(.init(text: "No notes yet: Hyper+Shift+N writes one."))], []) }
        let rows = shown.map { note in
            Extension.Item(id: note.id, title: note.title, subtitle: NotesText.stamp(note.edited, clock: false),
                           icon: note.pinned ? "📌" : nil, actions: [open(note, "Open \(note.title)")])
        }
        return ([.list(title: nil, items: Array(rows))], Set(shown.map(\.id)))
    }

    /// Each note, by id and title, for Edit widget's picker: "" first for every note.
    static func choices(_ notes: [Note]) -> [(id: String, title: String)] {
        [("", "All notes")] + notes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map { ($0.id, $0.title) }
    }
}
