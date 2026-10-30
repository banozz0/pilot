import Foundation

/// The note Pilot writes once into a notes folder with no notes in it (Q529, Sven 2026-10-27: "Yes, write it only when
/// Notes is empty"): how Notes works, and every piece of Markdown the editor draws (MarkdownEditor's marks). Pictures
/// are only named, as one needs a file in attachments/.
public enum NotesWelcome {
    public static let name = "Welcome to Notes.md"

    public static let text = """
    # Welcome to Notes

    Every note is a plain Markdown file on your Mac. Pilot wrote this one once; move it to the Trash when you are done.

    ## How it works

    - **Open:** Hyper+N shows the notes panel, or open Notes in Pilot's window.
    - **New note:** ⌘N. What you type in Scratch becomes a note of its own.
    - **Save a line fast:** Hyper+Space, type `note` and your words, then Return.
    - **Pin:** ⌘P, or ⌘K for every action on a note. Pinned notes stay on top.
    - **Find:** Escape moves to the list; type to filter, Return opens.

    ## Where your notes live

    At first in Documents › Pilot Notes, one `.md` file per note, so any Markdown app reads them. A picture you paste is saved in `attachments/` beside them.

    To keep them somewhere else, such as a vault or iCloud Drive, open Notes in Pilot's window and click **Change…** under the list. Pilot asks whether to move your notes along.

    ## What Markdown shows

    The marks hide as you write and come back on the line you are on.

    ### Text

    **Bold**, _italic_, `code` and a [link](https://github.com). A bare address links too: https://github.com

    ### Lists

    - A bullet
      - One step in
    1. A numbered step
    2. And the next

    - [ ] A checkbox: click it
    - [x] A done one

    ### Quotes and code

    > A quote reads as a callout.

    ```
    A code block
      keeps its spacing
    ```

    ### Tables

    | Key | Does |
    |---|---|
    | ⌘K | Actions on a note |
    | ⌘N | New note |
    | ⌘P | Pin or unpin |

    """

    /// Writes the welcome note into `folder` (made when missing) when it holds no notes (NotesFolder.notes, so an
    /// untouched Scratch counts as none); never replaces a file. Returns the note written, nil when there were notes.
    @discardableResult
    public static func write(in folder: URL) throws -> URL? {
        guard NotesFolder.notes(in: folder).isEmpty else { return nil }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
}
