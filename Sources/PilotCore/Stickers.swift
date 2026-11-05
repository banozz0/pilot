import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// The markers clipboard managers honour (nspasteboard.org): concealed for a secret, transient for something that
    /// should not be kept. Pilot's own history skips both.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}

/// What Stickers and GIFs pastes: a picture file of Sven's GIFs folder by its path, or a GIF GIPHY found (story 164).
/// Emoji drawn as stickers went with P39 (parked on parked/emoji-stickers).
public enum Sticker: Hashable, Sendable {
    case image(String), giphy(WebGIF)

    /// The path or GIPHY's id, for the frecency key.
    var value: String {
        switch self {
        case .image(let path): path
        case .giphy(let gif): "giphy:\(gif.id)"
        }
    }
    /// The row's kind word: GIF or Image.
    var word: String {
        switch self {
        case .image(let path): Stickers.type(of: path) == .gif ? "GIF" : "Image"
        case .giphy: "GIF"
        }
    }
}

/// One picture of the GIFs folder: its name without the extension and the subfolder it sits in, if any.
public struct StickerFile: Sendable, Equatable {
    public let path: String, name: String, folder: String?
    /// The name's words and the folder's, lower case, split once as the folder is read.
    let words: [String]
}

/// Stickers and GIFs (card agent-bo-95423130): the pictures in a folder of Sven's, and with a GIPHY key the web's GIFs
/// (Giphy, story 164); emoji live in Trigger › Emoji's grid since P39 (Q290). A pick goes on the pasteboard for one
/// paste, marked transient so no clipboard history keeps it.
public enum Stickers {
    /// The word that opens this branch from the root on GIPHY's GIFs, searching what follows it ("gif funny", T39), as
    /// the branch's own alias does too.
    public static let gifWord = "gif"
    public static let branchKey = "branch:\(MenuBranch.stickers.rawValue)"
    /// The GIFs folder: the one picked on Defaults › Folders (story 160), else Pilot's own.
    public static var folder: URL { pickedLock.withLock { _picked } ?? standardFolder }
    public static var standardFolder: URL {
        PilotFolder.support.appending(path: "GIFs")
    }
    /// Set by the app as the pick loads and changes; read off the main thread as the branch lists the folder.
    public static var picked: URL? {
        get { pickedLock.withLock { _picked } }
        set { pickedLock.withLock { _picked = newValue } }
    }
    private static let pickedLock = NSLock()
    nonisolated(unsafe) private static var _picked: URL?
    /// The most entries walked in the folder, so a folder dropped in by mistake cannot stall the branch.
    static let walkLimit = 10_000

    /// The kinds the folder lists.
    static let extensions: Set<String> = ["gif", "png", "jpg", "jpeg", "webp"]
    /// The row thumbnail's longest side in pixels: the row icon's 14 points at 2x, with room for a larger row.
    static let thumbnailPixels = 56

    /// A picture's type by its extension; nil for any other kind.
    static func type(of path: String) -> UTType? {
        let ext = (path as NSString).pathExtension.lowercased()
        return extensions.contains(ext) ? UTType(filenameExtension: ext) : nil
    }

    /// The picture's first frame, its middle cropped square and at most `thumbnailPixels` a side, for its square row
    /// icon, so a wide GIF is never squashed; nil when the file is no picture. Made off the main thread as the folder is
    /// read, so no row reads the disk while it draws.
    public static func thumbnail(of path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        // The longest side that leaves the shortest at `thumbnailPixels`.
        let size = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var longest = Double(thumbnailPixels)
        if let w = size?[kCGImagePropertyPixelWidth] as? Double, let h = size?[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 {
            longest *= max(w, h) / min(w, h)
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: Int(longest.rounded())] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let side = min(image.width, image.height)
        return image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side))
    }

    /// The folder's pictures, subfolders included, hidden files left out: the folder's own first, then by subfolder
    /// and name as Finder sorts them.
    public static func files(in folder: URL) -> [StickerFile] {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let base = folder.standardizedFileURL.path + "/"
        var found: [(key: String, file: StickerFile)] = []
        for case let url as URL in walk.prefix(walkLimit) where type(of: url.path) != nil {
            let path = url.standardizedFileURL.path
            let sub = (String(path.dropFirst(base.count)) as NSString).deletingLastPathComponent
            let name = url.deletingPathExtension().lastPathComponent
            let file = StickerFile(path: path, name: name, folder: sub.isEmpty ? nil : sub,
                                   words: EmojiSearch.words(name) + EmojiSearch.words(sub))
            found.append(((sub.isEmpty ? "0/" : "1/\(sub)/") + name, file))
        }
        return found.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map(\.file)
    }

    /// The branch's rows: every picture when nothing is typed; else the pictures each typed word starts a word of. Only
    /// the branch lists them, never the root's search.
    public static func entries(for query: String, files: [StickerFile]) -> [MenuEntry] {
        let typed = EmojiSearch.words(query)
        return files.filter { EmojiSearch.covers(typed, $0.words) }.map { f in
            MenuEntry(title: f.name, target: .sticker(.image(f.path)), home: .stickers, inSearch: false, keywords: f.folder, subtitle: f.folder)
        }
    }

    /// The row that shows the folder in Finder; the panel makes the folder first.
    public static var folderRow: MenuEntry {
        MenuEntry(title: "Open the GIFs folder", target: .file(folder.path), home: .stickers, inSearch: false,
                  subtitle: "drop GIFs and pictures here")
    }

    /// Writes the sticker as the one item on `board`, marked transient, and returns the board's change count after it;
    /// throws when the picture cannot be read. A picture keeps its own type, so a GIF moves where it lands.
    public static func put(_ sticker: Sticker, on board: NSPasteboard) throws -> Int {
        let item = NSPasteboardItem()
        switch sticker {
        case .image(let path):
            let url = URL(fileURLWithPath: path)
            guard let type = type(of: path) else { throw CocoaError(.fileReadUnsupportedScheme) }
            item.setData(try Data(contentsOf: url), forType: .init(type.identifier))
            item.setString(url.absoluteString, forType: .fileURL)
        case .giphy:
            // A web GIF is downloaded first and pasted as the file it became.
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        item.setData(Data(), forType: .transient)
        board.clearContents()
        board.writeObjects([item])
        return board.changeCount
    }
}

/// Every item and type a pasteboard holds, read so a sticker's paste can give it back; an app's undeclared types (dyn.)
/// included, as they hold the copy's own data.
public struct PasteboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]

    public init(_ board: NSPasteboard) {
        items = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    /// Puts the items back, marked transient so the history does not add them again, unless the board changed since
    /// `count` (something else was copied meanwhile); says whether it did.
    @discardableResult
    public func restore(to board: NSPasteboard, ifUnchangedSince count: Int) -> Bool {
        guard board.changeCount == count else { return false }
        board.clearContents()
        let restored = items.map { saved in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        }
        restored.first?.setData(Data(), forType: .transient)
        if !restored.isEmpty { board.writeObjects(restored) }
        return true
    }
}
