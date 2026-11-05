import Foundation
import UniformTypeIdentifiers

/// One item in a folder as the Folder widget lists it (P86): a folder, an app or a file, with what its columns show.
public struct FolderItem: Sendable, Identifiable, Hashable {
    public let url: URL
    public let name: String
    /// A folder the widget goes into; a bundle (an app, a package) is one item, never a folder.
    public let isFolder: Bool
    /// Bytes, nil for a folder or a package: the listing never adds one's contents up (Pilot Files' list view works them
    /// out on its own, `FolderListing.folderSize`).
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
    public enum Sort: String, Sendable { case name, modified, size }

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
    /// macOS keeps from Pilot). `showHidden` (Pilot Files' Cmd+Shift+.) lists hidden files too, as Finder's does; an
    /// app whose bundle id `hidden` holds stays out either way.
    public static func list(_ folder: URL, sort: Sort, hidden: Set<String> = [], showHidden: Bool = false, cap: Int = cap) throws -> Listing {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])
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

    /// By name as Finder sorts, folders first; newest first; or largest first, a folder by its worked-out size in
    /// `sizes` (by item id), what has no size last by name.
    public static func sorted(_ items: [FolderItem], by sort: Sort, sizes: [String: Int64] = [:]) -> [FolderItem] {
        let byName = { (a: FolderItem, b: FolderItem) in a.name.localizedStandardCompare(b.name) == .orderedAscending }
        switch sort {
        case .name:
            return items.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : byName(a, b) }
        case .modified:
            return items.sorted { a, b in (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
        case .size:
            return items.sorted { a, b in
                switch (a.size ?? sizes[a.id], b.size ?? sizes[b.id]) {
                case let (x?, y?): x != y ? x > y : byName(a, b)
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): byName(a, b)
                }
            }
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

    /// "9 items · 1.4 TB available": Finder's word for the volume's space, as Pilot Files' status bar and sidebar say it.
    public static func status(_ listing: Listing) -> String {
        let items = listing.count == 1 ? "1 item" : "\(listing.count) items"
        guard let free = listing.free else { return items }
        return "\(items) · \(size(free)) available"
    }

    /// The path as the path bar shows it: the home folder as `~`.
    public static func shown(_ folder: URL, home: String = NSHomeDirectory()) -> String {
        let trimmed = plainPath(folder)
        if trimmed == home { return "~" }
        return trimmed.hasPrefix(home + "/") ? "~" + trimmed.dropFirst(home.count) : trimmed
    }

    /// A path as Edit widget keeps it (`~/Downloads`, an absolute path) as a folder URL.
    public static func folder(_ path: String, home: String = NSHomeDirectory()) -> URL {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        return URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL
    }

    // MARK: Paths (Pilot Files, T55)

    /// How Copy path words a path: as it is, quoted for a shell, or from the home folder as `~/…`.
    public enum PathForm: String, CaseIterable, Sendable {
        case plain, shell, home
        public var title: String {
            switch self {
            case .plain: "Path"
            case .shell: "Path for the shell"
            case .home: "Path from ~"
            }
        }
    }

    /// `url`'s path in `form`.
    public static func path(_ url: URL, as form: PathForm, home: String = NSHomeDirectory()) -> String {
        let plain = plainPath(url)
        switch form {
        case .plain: return plain
        case .shell: return shellQuoted(plain)
        case .home: return shown(url, home: home)
        }
    }

    /// `url`'s path, standardized, without a trailing "/" (but "/" itself).
    private static func plainPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// `text` as one shell word: as it is when every character is safe, else in single quotes (a quote in it as '\'').
    public static func shellQuoted(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%=")
        guard text.isEmpty || !text.unicodeScalars.allSatisfy(safe.contains) else { return text }
        return LoginItems.quoted(text)
    }

    /// What the path bar's typed words name: `~` the home folder, a relative path from `base`, a file URL, and a path
    /// pasted in shell quotes or with backslashes before spaces as the plain path.
    public static func resolve(_ typed: String, from base: URL, home: String = NSHomeDirectory()) -> URL {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL { return url.standardizedFileURL }
        if text.count > 1, let first = text.first, first == text.last, first == "'" || first == "\"" {
            text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        } else if text.contains("\\") {
            let literal = resolve(path: text, base: base, home: home)
            if !FileManager.default.fileExists(atPath: literal.path(percentEncoded: false)) {
                text = text.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            }
        }
        return resolve(path: text, base: base, home: home)
    }

    private static func resolve(path: String, base: URL, home: String) -> URL {
        if path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") { return folder(path, home: home) }
        return base.appending(path: path).standardizedFileURL
    }

    /// The folders whose path begins with `typed`, for the path bar's completion, in `typed`'s own form (from `~`, from
    /// `base`, or whole), each ending in "/": by name, at most `limit`. Dot folders only when the typed name starts with
    /// a dot; letter case is ignored.
    public static func completions(_ typed: String, from base: URL, home: String = NSHomeDirectory(), limit: Int = 8) -> [String] {
        guard !typed.isEmpty, !typed.contains("\n") else { return [] }
        let typed = typed == "~" ? "~/" : typed
        let cut = typed.lastIndex(of: "/").map { typed.index(after: $0) } ?? typed.startIndex
        let lead = String(typed[..<cut]), stem = String(typed[cut...])
        let folder = lead.isEmpty ? base : resolve(path: lead, base: base, home: home)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return [] }
        // Names first, then a folder check only until `limit` are found: a big folder is not read item by item.
        return names
            .filter { name in
                (stem.hasPrefix(".") || !name.hasPrefix(".")) && (stem.isEmpty || name.range(of: stem, options: [.caseInsensitive, .anchored]) != nil)
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .lazy.filter { FolderLooks.isFolder(folder.appending(path: $0)) }
            .prefix(limit)
            .map { lead + $0 + "/" }
    }

    // MARK: Folder sizes (Pilot Files' list view, T55)

    /// The folders macOS asks about before an app reads them (Desktop, Documents, Downloads, iCloud Drive, cloud storage,
    /// other apps' data, contacts, calendars, reminders, mail, messages, photos) and the mounted volumes' folder; with Full
    /// Disk Access only the volumes. A size is never worked out from outside them, so no question shows.
    public static func protectedRoots(home: String = NSHomeDirectory(), fullDiskAccess: Bool) -> [String] {
        guard !fullDiskAccess else { return ["/Volumes"] }
        return ["/Volumes"] + ["Desktop", "Documents", "Downloads", "Pictures/Photos Library.photoslibrary", "Library/Mobile Documents",
                               "Library/CloudStorage", "Library/Application Support/AddressBook", "Library/Calendars", "Library/Reminders",
                               "Library/Mail", "Library/Messages", "Library/Safari"]
            .map { home + "/" + $0 } + appData(home: home)
    }

    /// The folders whose every folder is one app's own data: never read from outside that app's folder, even with Full
    /// Disk Access.
    public static func appData(home: String = NSHomeDirectory()) -> [String] {
        ["Library/Containers", "Library/Group Containers"].map { home + "/" + $0 }
    }

    /// The most items a size walk reads before it gives up and the folder shows "—".
    public static let walkCap = 2_000_000

    /// Where a size walk may go, by device and inode (a link or another spelling of a folder is that folder): the shown
    /// folder's volume only; no protected root the shown folder is not inside; no app's data folder but the one the shown
    /// folder is in.
    public struct Fence: Sendable {
        let device: UInt64
        /// The shown folder and every folder above it: the protected roots and app folders it is inside stay open.
        let open: Set<FileOps.Identity>
        let shut: Set<FileOps.Identity>
        let appData: Set<FileOps.Identity>
        /// The shut roots by spelling, to give up before reading anything when a folder plainly holds one.
        let shutPaths: [String]

        /// The fence for a walk under `inside`, the shown folder; nil when it can't be read (nothing is walked).
        public init?(inside: String, protected: [String], appData: [String]) {
            guard let real = FileOps.real(URL(filePath: inside)), let here = Fence.id(real.path(percentEncoded: false)) else { return nil }
            var open: Set<FileOps.Identity> = [], at = real.path(percentEncoded: false)
            while true {
                if let id = Fence.id(at) { open.insert(id) }
                if at == "/" || at.isEmpty { break }
                at = (at as NSString).deletingLastPathComponent
            }
            let shut = protected.compactMap { path in Fence.id(path).flatMap { open.contains($0) ? nil : ($0, path) } }
            (device, self.open, self.shut, shutPaths) = (here.device, open, Set(shut.map(\.0)), shut.map(\.1))
            self.appData = Set(appData.compactMap(Fence.id))
        }

        /// A folder's identity, links followed.
        static func id(_ path: String) -> FileOps.Identity? {
            var info = Darwin.stat()
            return stat(path, &info) == 0 ? Fence.id(info) : nil
        }

        static func id(_ info: Darwin.stat) -> FileOps.Identity { FileOps.Identity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino) }

        /// Whether the folder `id`, inside the folder `parent`, may not be read.
        func closed(_ id: FileOps.Identity, parent: FileOps.Identity?) -> Bool {
            shut.contains(id) || (parent.map(appData.contains) == true && !open.contains(id))
        }
    }

    /// The bytes in `folder` and everything under it (each file's own size, a link as itself, the way the listing counts
    /// a file). Nil, reading no further, when the fence closes on it or on a folder in it (another volume, a protected
    /// root, another app's data), when a part of it does not read, past `cap` items, or once `cancelled` says so.
    public static func folderSize(_ folder: URL, fence: Fence, cap: Int = walkCap, cancelled: () -> Bool = { false }) -> Int64? {
        let root = folder.standardizedFileURL.path(percentEncoded: false)
        var info = Darwin.stat()
        guard lstat(root, &info) == 0, UInt64(UInt32(bitPattern: info.st_dev)) == fence.device,
              !fence.closed(Fence.id(info), parent: Fence.id((root as NSString).deletingLastPathComponent)),
              !fence.shutPaths.contains(where: { $0 == root || $0.hasPrefix(root.hasSuffix("/") ? root : root + "/") || root.hasPrefix($0 + "/") })
        else { return nil }
        guard let start = strdup(root) else { return nil }
        defer { Darwin.free(start) }
        var paths: [UnsafeMutablePointer<CChar>?] = [start, nil]
        // FTS_XDEV: no folder on another volume is entered; FTS_PHYSICAL: a link is never followed.
        guard let walk = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(walk) }
        var total: Int64 = 0, seen = 0
        // fts_read answers nil with errno 0 at the end, else on a failure.
        errno = 0
        while let entry = fts_read(walk) {
            seen += 1
            if seen > cap || (seen % 256 == 0 && cancelled()) { return nil }
            let at = entry.pointee
            switch Int32(at.fts_info) {
            case FTS_D:
                // Checked before fts reads the folder's entries.
                let parent = at.fts_level > 0 ? at.fts_parent.map { Fence.id($0.pointee.fts_statp.pointee) } : nil
                if at.fts_level > 0, fence.closed(Fence.id(at.fts_statp.pointee), parent: parent) { return nil }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT: total += Int64(at.fts_statp.pointee.st_size)
            case FTS_DNR, FTS_ERR, FTS_NS: return nil
            default: break
            }
        }
        return errno == 0 ? total : nil
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
