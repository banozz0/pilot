import AppKit
import PilotCore

/// A click on a picture in a note opens it big in Pilot's image viewer (Sven, 2026-11-21: "pressing on an image in notes
/// … i should be able to preview it bigger"), in the quick notes panel and on the Notes page alike; Esc or a click outside
/// closes it. A click is a plain single press inside a drawn picture whose release comes within 4 points of it
/// (NotesPanel.isClick): the
/// caret and selection never move. A press that moves further is handed to the text view as it came, so it still selects
/// or drags. Shift, Cmd, Option or Control presses, double-clicks, the list's read-only preview and sketches (SVG, which
/// the viewer does not read) place the caret as before.
extension NotesTextView {
    /// The press's next move or release, as AppKit's tracking reads it; a test hands its own in, as pulling events from
    /// AppKit's queue in the test process stops its main run loop.
    static var nextPress: (NSWindow) -> NSEvent? = { $0.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) }

    /// Each drawn picture a click opens, and its file: none in a read-only view or without a folder.
    private func viewablePictures() -> [(rect: NSRect, url: URL)] {
        guard isEditable, let folder else { return [] }
        return pictureRects().compactMap { picture in
            NoteAttachments.url(picture.link, in: folder).flatMap { ViewerImages.viewable($0) ? (picture.rect, $0) : nil }
        }
    }

    /// The picture file under `point` (view coordinates) that the viewer opens; nil off a picture or in a read-only view.
    func viewablePicture(at point: NSPoint) -> URL? { viewablePictures().first { $0.rect.contains(point) }?.url }

    /// mouseDown's first look: true when the press was a click on a picture, which opened the viewer. A press that moves
    /// past the slop goes back on the queue, and the text view gets the press itself.
    func openPicture(_ down: NSEvent) -> Bool {
        let flags = down.modifierFlags.intersection([.shift, .command, .option, .control])
        guard down.clickCount == 1, flags.isEmpty, let window,
              let url = viewablePicture(at: convert(down.locationInWindow, from: nil)) else { return false }
        while let next = Self.nextPress(window) {
            if next.type == .leftMouseUp { break }
            if !NotesPanel.isClick(from: down.locationInWindow, to: next.locationInWindow) {
                // NSTextView's own tracking starts from the press, with the move that ended the click first in line.
                NSApp.postEvent(next, atStart: true)
                return false
            }
        }
        if ImageViewer.show([url], closesOnClickOutside: true) == nil {
            noteslog.error("notes: picture did not open in the viewer")
        } else {
            noteslog.notice("notes: picture opened in the viewer")
        }
        return true
    }

    /// A pointing hand over each picture a click opens.
    func addPictureCursors() {
        for picture in viewablePictures() { addCursorRect(picture.rect, cursor: .pointingHand) }
    }
}
