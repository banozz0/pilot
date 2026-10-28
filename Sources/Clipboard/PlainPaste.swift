// Written from scratch for Pilot (card agent-bo-95423072); Raycast's and SuperCmd's paste as plain text are the behaviour reference.
import AppKit

/// Paste as plain text, from any app: what is copied goes in as its text alone, and the copy goes back afterwards. The
/// text is what the history would search it by (a file copy's paths), or for an image the text read from it; a
/// password manager's copy, an image with no text or an empty pasteboard pastes as it is, untouched. A plain paste
/// during a paste in sequence pastes that pick plain, ends the sequence (the pasteboard changed) and puts the pick back.
@MainActor
public struct PlainPaste {
    let pasteboard: NSPasteboard
    let store: ClipboardStore?
    /// Sends Cmd+V into the focused app.
    let post: () -> Void
    let later: PasteBack.Later

    public init(pasteboard: NSPasteboard = .general, store: ClipboardStore?, post: @escaping () -> Void,
                later: @escaping PasteBack.Later = PasteBack.onMain) {
        self.pasteboard = pasteboard; self.store = store; self.post = post; self.later = later
    }

    /// Pastes, and returns how many characters went in as plain text; nil when it pasted the copy as it is.
    @discardableResult
    public func run() -> Int? {
        // A stored recognised text can be empty: an image read with none.
        guard let text = text(), !text.isEmpty else { post(); return nil }
        PasteBack.paste(text, to: pasteboard, post: post, later: later)
        return text.count
    }

    /// A transient copy is read too: Pilot's own put-back, a pick of a paste in sequence, a paste-and-delete.
    private func text() -> String? {
        var capture = ClipboardCapture()
        capture.skipped = [ClipboardCapture.concealed]
        guard pasteboard.accessBehavior != .alwaysDeny, let item = capture.capture(pasteboard, sourceApp: nil) else { return nil }
        return item.text.isEmpty ? (try? store?.recognised(hash: item.contentHash)) ?? nil : item.text
    }
}
