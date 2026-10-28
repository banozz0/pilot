import Foundation

/// What Hyper + right-click on a file offers (story 199): Pilot's own actions for the files under the pointer, in
/// Finder, on the desktop or in the menu's Files view, as a picker at the pointer. Each kind of file gets its own:
/// images Resize, Upscale, Convert and (one) Read QR code, plain text Read aloud, folders their designs; any one file Ask AI and Change icon.
public enum FileAction: String, CaseIterable, Sendable {
    case open, openWith, preview, quickLook, askAI, readAloud, resize, upscale, convert, readQR, folderDesign, changeIcon, resetIcon
    case copyPath, copyFile, reveal, trash

    /// What a file is to the menu: a picture, plain text (Markdown, a .txt, source), a folder, or anything else.
    public enum Kind: Sendable, Equatable { case image, text, pdf, folder, other }

    /// The most characters Read aloud and Ask AI take from a file: about 20 minutes of speech; the rest is left out, and
    /// the tip says so.
    public static let textLimit = 20_000

    public var title: String {
        switch self {
        case .open: "Open"
        case .openWith: "Open With…"
        case .preview: "Show preview"
        case .quickLook: "Quick Look"
        case .askAI: "Ask AI about it"
        case .readAloud: "Read aloud"
        case .resize: "Resize…"
        case .upscale: "Upscale…"
        case .convert: "Convert to…"
        case .readQR: "Read QR code"
        case .folderDesign: "Folder design…"
        case .changeIcon: "Change icon…"
        case .resetIcon: "Reset icon"
        case .copyPath: "Copy path"
        case .copyFile: "Copy to clipboard"
        case .reveal: "Show in Finder"
        case .trash: "Move to Trash…"
        }
    }

    public var symbol: String {
        switch self {
        case .open: "doc"
        case .openWith: "arrow.up.forward.app"
        case .preview: "doc.text.magnifyingglass"
        case .quickLook: "eye"
        case .askAI: "sparkles"
        case .readAloud: "text.bubble"
        case .resize: "arrow.down.right.and.arrow.up.left"
        case .upscale: "arrow.up.left.and.arrow.down.right"
        case .convert: "arrow.triangle.2.circlepath"
        case .readQR: "qrcode.viewfinder"
        case .folderDesign: "folder.badge.gearshape"
        case .changeIcon: "photo"
        case .resetIcon: "arrow.uturn.backward"
        case .copyPath: "doc.on.doc"
        case .copyFile: "doc.on.clipboard"
        case .reveal: "folder"
        case .trash: "trash"
        }
    }

    /// The actions for files of `kinds`, in the menu's order: every kind's when they all have it, so a mix of images and
    /// a folder offers only what both take. Show preview (a file's), Ask AI, Read aloud, Quick Look, Change icon and Move to Trash take one file;
    /// Reset icon too, and only when `customIcon` (a file's or app's own icon, or a folder Pilot dressed), so Change icon
    /// is undone as a folder's design is.
    public static func list(for kinds: [Kind], customIcon: Bool = false) -> [FileAction] {
        guard !kinds.isEmpty else { return [] }
        let one = kinds.count == 1
        let all = { (kind: Kind) in kinds.allSatisfy { $0 == kind } }
        let folders = kinds.contains(.folder)
        var actions: [FileAction] = [.open]
        if !folders { actions.append(.openWith) }
        if one, !folders { actions.append(.preview) }
        if one { actions.append(.quickLook) }
        if one, !folders { actions.append(.askAI) }
        if one, all(.text) { actions.append(.readAloud) }
        if all(.image) { actions += [.resize, .upscale] }
        if !folders { actions.append(.convert) }
        if one, all(.image) { actions.append(.readQR) }
        if all(.folder) { actions.append(.folderDesign) }
        if one { actions.append(.changeIcon) }
        if one, customIcon { actions.append(.resetIcon) }
        actions += [.copyPath, .copyFile, .reveal]
        if one { actions.append(.trash) }
        return actions
    }

    /// Markdown as it is read aloud, each line's words as a note's list shows them (Notes.words): no heading, list,
    /// emphasis or link marks, no fences, table rules or picture lines. Plain text goes as it is.
    public static func speakable(_ text: String, markdown: Bool) -> String {
        markdown ? Notes.words(text).joined(separator: "\n") : text
    }

    /// `text` cut to `textLimit` characters at the last space before it, and whether anything was cut.
    public static func capped(_ text: String) -> (text: String, cut: Bool) {
        guard text.count > textLimit else { return (text, false) }
        let head = text.prefix(textLimit)
        let end = head.lastIndex(where: \.isWhitespace) ?? head.endIndex
        return (String(head[..<end]), true)
    }
}
