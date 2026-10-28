import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images in quick notes (notes round 2, Sven 2026-10-10): a picture pasted or dropped into a note is a file in the
/// notes folder's attachments/, the note holds `![](attachments/<name>)` on a line of its own, and the editor draws the
/// picture under that line. A pasted picture is named `image-<yyyyMMdd-HHmmss>.png`, a dropped file a slug of its own
/// name with its own extension; a name taken gets "-2", "-3".
public enum NoteAttachments {
    public static let folder = "attachments"
    /// `![alt](path)`: the alt words, then the path. The editor, the title, the Trash and a folder move all read links
    /// through it.
    public static let link = #"!\[([^\]\n]*)\]\(([^)\s]+)\)"#
    private static let linkExpression = try! NSRegularExpression(pattern: link)
    private static let lineExpression = try! NSRegularExpression(pattern: "^" + link + "$")

    /// Whether a dropped file counts as a picture: any image type the Mac knows by its extension.
    public static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// Whether a line (heading marks and spaces trimmed) only shows a picture.
    public static func isImageLine(_ line: some StringProtocol) -> Bool {
        let line = String(line)
        return lineExpression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// The files in attachments/ that `text` shows, by name.
    public static func references(in text: String) -> [String] {
        let s = text as NSString
        return linkExpression.matches(in: text, range: NSRange(location: 0, length: s.length)).compactMap { m in
            let path = s.substring(with: m.range(at: 2))
            guard path.hasPrefix(folder + "/") else { return nil }
            let name = String(path.dropFirst(folder.count + 1))
            return name.contains("/") ? nil : name.removingPercentEncoding ?? name
        }
    }

    /// Where a picture's link points: a path in the note's folder, or an absolute file path; nil for a web address.
    public static func url(_ link: String, in folder: URL) -> URL? {
        let path = link.removingPercentEncoding ?? link
        if path.hasPrefix("file://") { return URL(string: link) }
        if path.contains("://") { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appending(path: path)
    }

    /// A picture to draw in a note: at most `pixels` on its longest side, turned upright, so a camera's photo never sits
    /// in memory at full size; nil when the file is no picture.
    public static func picture(at url: URL, pixels: Int = 1200) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// Writes `data` into `folder`/attachments/ under a free name and returns the Markdown that shows it.
    public static func save(_ data: Data, named name: String?, ext: String, in folder: URL, now: Date) throws -> String {
        let dir = folder.appending(path: Self.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = name.map { Notes.slug(($0 as NSString).deletingPathExtension) } ?? "image-\(stamp(now))"
        let ext = ext.lowercased()
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
        // "-2", not Finder's " 2": a name with no space needs no escaping in the link.
        let file = NotesFolder.freeName("\(stem).\(ext)", taken: taken, separator: "-")
        try data.write(to: dir.appending(path: file), options: .withoutOverwriting)
        return "![](\(Self.folder)/\(file))"
    }

    /// "20261010-074912", in the Mac's time zone.
    static func stamp(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
