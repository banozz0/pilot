// Written from scratch for Pilot (Sven, 2026-11-14: Return on images in Ghostty pasted nothing).
import AppKit
import CryptoKit
import Synchronization

/// A paste into a terminal: a terminal reads a pasteboard's file URLs and text, never an image (Ghostty asked for
/// `public.file-url`, then `public.utf8-plain-text`, on every step and found neither), so each image goes on as a PNG
/// file in `folder`: its file URL and its path, shell-escaped, as text. The terminal pastes the path, which an agent's
/// CLI there takes as the image. Images next to each other go on as one paste of their paths, space-separated, as a
/// drag of several files types them; a text between keeps its own step, so no new line runs the command line.
public enum TerminalPaste {
    /// Where the images go, kept a day: a CLI reads one after the paste, when Sven sends his message.
    public static let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-pastes", directoryHint: .isDirectory)
    public static let kept: TimeInterval = 24 * 60 * 60

    /// `pastes` with every image as its file; the rest as they were.
    public static func files(_ pastes: [PanelRows.Paste], in folder: URL = folder) throws -> [PanelRows.Paste] {
        guard pastes.contains(where: isImage) else { return pastes }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prune(folder)
        var out: [PanelRows.Paste] = [], run: [URL] = []
        func endRun() {
            guard !run.isEmpty else { return }
            let fileURL = NSPasteboard.PasteboardType.fileURL.rawValue, string = NSPasteboard.PasteboardType.string.rawValue
            let text = run.map { escaped($0.path) }.joined(separator: " ")
            out.append(.init(contents: run.enumerated().map { index, url in
                var item = [fileURL: Data(url.absoluteString.utf8)]
                if index == 0 { item[string] = Data(text.utf8) }
                return item
            }, text: text))
            run = []
        }
        for paste in pastes {
            if isImage(paste), let url = try file(paste, in: folder) { run.append(url) } else { endRun(); out.append(paste) }
        }
        endRun()
        return out
    }

    /// What one Return types into a terminal straight, each its own paste: the steps' texts with images as paths, or,
    /// when the copies go on as one, their texts joined by new lines, as one paste joins them.
    public static func texts(_ pastes: [PanelRows.Paste], in folder: URL = folder) throws -> [String] {
        let steps = PanelRows.steps(pastes)
        let texts = try files(steps ?? pastes, in: folder).map(\.text).filter { !$0.isEmpty }
        return steps == nil && texts.count > 1 ? [texts.joined(separator: "\n")] : texts
    }

    /// An image copy: no text, as the history hands one back, an image type and no file of its own.
    public static func isImage(_ paste: PanelRows.Paste) -> Bool {
        let fileURL = NSPasteboard.PasteboardType.fileURL.rawValue
        let png = NSPasteboard.PasteboardType.png.rawValue, tiff = NSPasteboard.PasteboardType.tiff.rawValue
        return paste.text.isEmpty && paste.contents.contains { $0[fileURL] == nil && ($0[png] != nil || $0[tiff] != nil) }
    }

    /// The image's PNG in `folder`, named by its bytes, so one image pasted twice is one file, written once and
    /// touched after, so the prune keeps it.
    private static func file(_ paste: PanelRows.Paste, in folder: URL) throws -> URL? {
        guard let data = paste.contents.lazy.compactMap(png).first else { return nil }
        let name = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let url = folder.appending(path: "clip-\(name).png")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } else {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    /// The item's PNG, or its TIFF as one: the image as a file holds it (a terminal's paste, Save image).
    static func png(_ item: [String: Data]) -> Data? {
        if let png = item[NSPasteboard.PasteboardType.png.rawValue] { return png }
        guard let tiff = item[NSPasteboard.PasteboardType.tiff.rawValue] else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// When the folder was last pruned: once an hour at most, not on every paste.
    private static let pruned = Mutex(Date.distantPast)

    /// Images older than `kept` go, at most once an hour.
    private static func prune(_ folder: URL) {
        let due = pruned.withLock { last in
            guard Date().timeIntervalSince(last) > 3600 else { return false }
            last = Date()
            return true
        }
        guard due else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > kept { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The path as a shell reads one word, backslashed as a dragged file types it: a backslash before every character
    /// outside letters, digits and `/._-+`.
    static func escaped(_ path: String) -> String {
        let plain = CharacterSet.alphanumerics.union(.init(charactersIn: "/._-+"))
        return path.unicodeScalars.map { plain.contains($0) && $0.isASCII ? String($0) : "\\" + String($0) }.joined()
    }
}
