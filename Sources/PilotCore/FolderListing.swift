import Foundation
import UniformTypeIdentifiers

/// One item in a folder as the Folder widget lists it (P86): a folder, an app or a file, with what its columns show.
public struct FolderItem: Sendable, Identifiable, Hashable {
    public let url: URL
    public let name: String
    /// A folder the widget goes into; a bundle (an app, a package) is one item, never a folder.
    public let isFolder: Bool
    /// Bytes, nil for a folder: Pilot never adds a folder's contents up.
    public let size: Int64?
    public let modified: Date?
    /// Finder's kind ("PNG image", "Folder", "Application").
    public let kind: String
    /// Its type's id, for its glyph.
    public let type: String?

    public init(url: URL, name: String, isFolder: Bool, size: Int64?, modified: Date?, kind: String, type: String?) {
        self.url = url; self.name = name; self.isFolder = isFolder; self.size = size; self.modified = modified; self.kind = kind; self.type = type
    }
    public var id: String { url.path }
    public var isApp: Bool { url.pathExtension.lowercased() == "app" }
}

/// The Folder widget's reading (P86): one folder's own level, read-only, nothing kept between reads. Hidden files
/// (dotfiles and Finder's hidden flag, which Install › Hidden apps sets on the apps it hides) stay out, and so does an
/// app whose bundle id `hidden` holds (a built-in app Pilot hides without the flag).
public enum FolderListing {
    public enum Sort: String, Sendable { case name, modified }

    /// What one read gives: the items, how many there were before `cap`, and the volume's free bytes.
    public struct Listing: Sendable, Equatable {
        public var items: [FolderItem]
        public var count: Int
        public var free: Int64?
        public init(items: [FolderItem], count: Int, free: Int64?) { self.items = items; self.count = count; self.free = free }
    }

    /// The most rows a read keeps, by the sort asked for; the status line counts them all.
    public static let cap = 500

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                         .localizedTypeDescriptionKey, .contentTypeKey]

    /// `folder`'s own items, sorted by `sort`, at most `cap`; throws when the folder does not read (gone, or a folder
    /// macOS keeps from Pilot).
    public static func list(_ folder: URL, sort: Sort, hidden: Set<String> = [], cap: Int = cap) throws -> Listing {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var items = urls.compactMap { url -> FolderItem? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            if !hidden.isEmpty, url.pathExtension.lowercased() == "app", let id = Bundle(url: url)?.bundleIdentifier, hidden.contains(id) { return nil }
            return FolderItem(url: url, name: url.lastPathComponent, isFolder: isFolder,
                              size: isFolder ? nil : values?.fileSize.map(Int64.init), modified: values?.contentModificationDate,
                              kind: values?.localizedTypeDescription ?? (isFolder ? "Folder" : "Document"), type: values?.contentType?.identifier)
        }
        let count = items.count
        items = sorted(items, by: sort)
        if items.count > cap { items.removeLast(items.count - cap) }
        return Listing(items: items, count: count, free: free(folder))
    }

    /// By name as Finder sorts, folders first; or newest first.
    public static func sorted(_ items: [FolderItem], by sort: Sort) -> [FolderItem] {
        switch sort {
        case .name:
            items.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        case .modified:
            items.sorted { a, b in (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
        }
    }

    /// The free bytes on `folder`'s volume, as Finder counts them (purgeable space included).
    public static func free(_ folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// "4.2 MB", "315.8 KB", "5 bytes"; "—" for a folder.
    public static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "2026-10-31 15:52", as the reference shows it.
    public static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                        timeZone: .current, calendar: .current))
    }

    /// "9 items · 1.4 TB free".
    public static func status(_ listing: Listing) -> String {
        let items = listing.count == 1 ? "1 item" : "\(listing.count) items"
        guard let free = listing.free else { return items }
        return "\(items) · \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free"
    }

    /// The path as the path bar shows it: the home folder as `~`.
    public static func shown(_ folder: URL, home: String = NSHomeDirectory()) -> String {
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == home { return "~" }
        return trimmed.hasPrefix(home + "/") ? "~" + trimmed.dropFirst(home.count) : trimmed
    }

    /// A path as Edit widget keeps it (`~/Downloads`, an absolute path) as a folder URL.
    public static func folder(_ path: String, home: String = NSHomeDirectory()) -> URL {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        return URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL
    }

    /// The SF Symbol for an item: a folder, an app, or its type's family.
    public static func symbol(_ item: FolderItem) -> String {
        if item.isFolder { return "folder" }
        if item.isApp { return "app" }
        guard let id = item.type, let type = UTType(id) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return "archivebox" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json) || type.conforms(to: .xml) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}
