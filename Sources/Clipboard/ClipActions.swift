// Written from scratch for Pilot; ClipBook's item actions are the behaviour reference (clipbook.app guides), no code.
import AppKit

/// Cmd+K → Format (card agent-bo-95422784): the seven text formats ClipBook lists.
public enum TextFormat: String, CaseIterable, Sendable {
    case lowercase, uppercase, capitaliseWords, sentenceCase, removeEmptyLines, stripWhitespace, trim

    public var title: String {
        switch self {
        case .lowercase: "Lowercase"
        case .uppercase: "Uppercase"
        case .capitaliseWords: "Capitalise words"
        case .sentenceCase: "Sentence case"
        case .removeEmptyLines: "Remove empty lines"
        case .stripWhitespace: "Strip all whitespace"
        case .trim: "Trim surrounding whitespace"
        }
    }

    public func apply(_ text: String) -> String {
        switch self {
        case .lowercase: return text.lowercased()
        case .uppercase: return text.uppercased()
        case .capitaliseWords: return text.capitalized
        case .sentenceCase:
            // Lower case, then a capital at the start and after each . ! or ? that a space follows.
            var result = "", capital = true
            for character in text.lowercased() {
                result.append(capital && character.isLetter ? Character(character.uppercased()) : character)
                if character.isLetter { capital = false } else if ".!?".contains(character) { capital = true }
            }
            return result
        case .removeEmptyLines: return text.nonEmptyLines.joined(separator: "\n")
        case .stripWhitespace: return text.filter { !$0.isWhitespace }
        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// A QR code in an image copy (Sven, Q398): a web or mail link Open link opens, or anything else Copy text copies, so a
/// code never opens an app's scheme.
public enum ClipCode: Hashable, Sendable {
    case link(URL), text(String)

    public init(_ payload: String) { self = Self.link(payload).map(Self.link) ?? .text(payload) }

    /// The http, https or mailto link a code holds; nil for anything else. Read a QR code's Open follows it too.
    public static func link(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    /// What the code holds, as the preview shows it.
    public var payload: String {
        switch self {
        case .link(let url): url.absoluteString
        case .text(let text): text
        }
    }

    /// What the copy's row and preview offer.
    public var title: String {
        switch self {
        case .link: "Open link"
        case .text: "Copy text"
        }
    }
}

/// One row of the panel's Cmd+K list.
public enum ClipAction: Equatable, Hashable, Sendable {
    case pasteAndDelete, pasteInSequence, open, openWith, reveal, copyPath, saveImage, copyText, rename, edit, split, merge, format(TextFormat), pin, delete
    /// The previewed image's QR code: its link opened, or its text copied.
    case code(ClipCode)

    public var title: String {
        switch self {
        case .pasteAndDelete: "Paste and delete"
        case .pasteInSequence: "Paste one by one"
        case .open: "Open"
        case .openWith: "Open With…"
        case .reveal: "Show in Finder"
        case .copyPath: "Copy path"
        case .saveImage: "Save image as PNG…"
        case .copyText: "Copy text"
        case .code(.link): "Open QR link"
        case .code(.text): "Copy QR text"
        case .rename: "Rename…"
        case .edit: "Edit text…"
        case .split: "Split into lines"
        case .merge: "Merge into one item"
        case .format(let format): "Format: \(format.title)"
        case .pin: "Pin or unpin"
        case .delete: "Delete"
        }
    }

    /// The key that does it without the list, shown beside it.
    public var key: String? {
        switch self {
        case .pasteAndDelete: "⌥↵"
        case .pasteInSequence: "⌃↵"
        case .pin: "⌘P"
        case .delete: "⌘⌫"
        default: nil
        }
    }

    /// What fits the targets, paste and delete first, then paste one by one for several, and pin and delete last: open and open with for a link or files, reveal and copy path for files,
    /// save for one image, copy text for one image with text read from it, formats for text, split for text of several lines, edit for one text,
    /// rename for one item, merge for several texts; `code` is one image's QR code, read for its preview.
    public static func available(for targets: [StoredClip], code: ClipCode? = nil) -> [ClipAction] {
        guard !targets.isEmpty else { return [] }
        let kinds = Set(targets.map(\.kind))
        // Text to work on: links, emails and colours too, never files (their text is paths) or images.
        let texts = targets.allSatisfy { !$0.text.isEmpty && $0.kind != .image && $0.kind != .file }
        let lines = targets.count == 1 && texts && targets[0].text.contains(where: \.isNewline) ? targets[0].text.nonEmptyLines.count : 1
        var actions: [ClipAction] = [.pasteAndDelete]
        if targets.count > 1 { actions.append(.pasteInSequence) }
        if kinds == [.link] || kinds == [.file] { actions += [.open, .openWith] }
        if kinds == [.file] { actions += [.reveal, .copyPath] }
        if targets.count == 1, kinds == [.image], let code { actions.append(.code(code)) }
        if targets.count == 1, kinds == [.image] { actions.append(.saveImage) }
        if targets.count == 1, kinds == [.image], targets[0].recognised?.isEmpty == false { actions.append(.copyText) }
        if targets.count == 1 { actions.append(.rename) }
        if targets.count == 1, texts { actions.append(.edit) }
        if lines > 1 { actions.append(.split) }
        if targets.count > 1, texts { actions.append(.merge) }
        if texts { actions += TextFormat.allCases.map(ClipAction.format) }
        return actions + [.pin, .delete]
    }
}

/// What Pilot does outside the store for an action: real in the app (WorkspaceOpener), a fake in tests.
@MainActor
public protocol ClipOpening {
    func open(_ url: URL)
    /// Lists the apps that open the first URL, and opens every URL in the one picked (card agent-bo-95422994).
    func openWith(_ urls: [URL])
    func reveal(_ urls: [URL])
    /// Copies text and says so in a tip.
    func copy(_ text: String, tip: String)
    func saveImage(_ data: Data, named name: String)
}

/// Runs the actions that need no typing (rename and edit take the panel's field first).
@MainActor
public struct ClipActions {
    let store: ClipboardStore
    let opener: any ClipOpening

    public init(store: ClipboardStore, opener: any ClipOpening) {
        self.store = store; self.opener = opener
    }

    /// The new rows to select, when the action made some (split, merge). Paste and delete, rename and edit are the
    /// panel's: it pastes, or opens its field for the new name or text first.
    @discardableResult
    public func run(_ action: ClipAction, on targets: [StoredClip]) throws -> [Int64] {
        switch action {
        case .open:
            for url in try targets.flatMap(urls) { opener.open(url) }
        case .openWith: opener.openWith(try targets.flatMap(urls))
        case .reveal: opener.reveal(try targets.flatMap(fileURLs))
        case .copyPath: opener.copy(try targets.flatMap(fileURLs).map(\.path).joined(separator: "\n"), tip: "Path copied")
        case .saveImage:
            guard let clip = targets.first, let item = try store.contents(of: clip.id).first,
                  let data = item[NSPasteboard.PasteboardType.png.rawValue] ?? item[NSPasteboard.PasteboardType.tiff.rawValue]
                      .flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else { return [] }
            opener.saveImage(data, named: "Clipboard image.png")
        case .copyText: if let text = targets.first?.recognised { opener.copy(text, tip: "Text copied") }
        case .code(.link(let url)): opener.open(url)
        case .code(.text(let text)): opener.copy(text, tip: "Copied the QR code's text")
        case .split: return try targets.first.map { try store.split($0.id) } ?? []
        case .merge: return [try store.merge(targets.map(\.id))]
        case .format(let format):
            for clip in targets { try store.setText(clip.id, to: format.apply(clip.text)) }
        case .pin: try store.setPinned(targets.map(\.id), !targets.allSatisfy(\.pinned))
        case .delete: try store.delete(targets.map(\.id))
        case .pasteAndDelete, .pasteInSequence, .rename, .edit: break  // they need the panel: it pastes, or types the new name or text
        }
        return []
    }

    private func urls(_ clip: StoredClip) throws -> [URL] {
        clip.kind == .link ? URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)).map { [$0] } ?? [] : try fileURLs(clip)
    }

    private func fileURLs(_ clip: StoredClip) throws -> [URL] {
        try store.contents(of: clip.id).compactMap { item in
            item[NSPasteboard.PasteboardType.fileURL.rawValue].flatMap { URL(string: String(decoding: $0, as: UTF8.self)) }
        }
    }
}

extension String {
    /// Its lines that hold more than whitespace: what split makes items of and remove empty lines keeps.
    var nonEmptyLines: [Substring] { split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) } }
}
