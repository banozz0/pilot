import AppKit
import Foundation

/// One of the folder designs Pilot draws itself (P43, redrawn in P54): its art is `folder-designs/<id>.heic` in the app's
/// Resources, a 1024 px cut-out with a simpler 64 px `<id>-small.png` for 32 px and under, and `<id>.png` at 256 px for
/// the grid and menu (Scripts/folder-designs.py).
/// Pilot ships only art it may bundle, so no outside collection; a picture of your own and Your designs
/// (YourFolderDesigns, P55) are the other looks.
public struct FolderDesign: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String

    /// The twelve, in the design page's order (launcher-ideas 2026-10-18, P43).
    public static let all: [FolderDesign] = [
        ("lagoon", "Lagoon"), ("graphite", "Graphite"), ("paper", "Paper"), ("blueprint", "Blueprint"), ("kraft", "Kraft"),
        ("terminal", "Terminal"), ("code", "Code"), ("sunset", "Sunset"), ("mint", "Mint"), ("music", "Music"),
        ("archive", "Archive"), ("candy", "Candy"),
    ].map { FolderDesign(id: $0, title: $1) }

    /// A picture of your own (PNG or SVG), recorded under this id.
    public static let own = FolderDesign(id: "own", title: "Your own")
    /// The plain folder whose front a picture of your own is fitted into.
    public static let plain = "plain"

    /// Pilot's design, Your own, or one of `yours` (Your designs as last read, P55).
    public static func named(_ id: String, yours: [FolderDesign] = []) -> FolderDesign? {
        id == own.id ? own : (all + yours).first { $0.id == id }
    }

    /// What a folder dressed in `id` says it wears: the design's title, or that it was one of Your designs, since removed.
    public static func wearing(_ id: String, yours: [FolderDesign]) -> String {
        named(id, yours: yours)?.title ?? (id.hasPrefix(YourFolderDesigns.prefix) ? "Removed design" : id)
    }
}

/// Your designs (P55): pictures you added (PNG, SVG, HEIC, JPEG, ICNS, or a folder of them), copied into Pilot's own
/// folder so moving or deleting the source breaks nothing. Each is recorded as `yours:` and a hash of its bytes, so the
/// same picture added twice is kept once and a folder dressed in it finds it again once it is added back; its title is
/// the file's name. Removing one deletes Pilot's copy only: a folder dressed in it keeps its icon and still Resets.
public struct YourFolderDesigns: Sendable {
    struct Entry: Codable, Equatable {
        let id: String, title: String, file: String
    }

    public static let prefix = "yours:"
    public static let standard = YourFolderDesigns()
    /// The kinds a design may be, by extension.
    public static let extensions: Set<String> = ["png", "svg", "heic", "heif", "jpg", "jpeg", "icns"]
    /// The most entries walked in an added folder, and the largest picture copied.
    static let walkLimit = 2_000, largest = 20 << 20

    /// Pilot's copies and their list, `designs.json`.
    public let folder: URL

    public init(folder: URL = PilotFolder.support.appending(path: "Your folder designs", directoryHint: .isDirectory)) { self.folder = folder }

    /// The designs in the order they were added, each with Pilot's copy; none while the list does not read.
    public func list() -> [(design: FolderDesign, file: URL)] {
        ((try? index.load(or: [])) ?? []).map(design)
    }

    /// Copies the pictures among `urls` into Pilot's folder, a folder's own and its subfolders' as Finder sorts them
    /// (hidden files left out); a file no picture can be read from, or one already in, is skipped. Returns those added,
    /// none when the list does not read, so no add wipes it.
    @discardableResult public func add(_ urls: [URL]) -> [(design: FolderDesign, file: URL)] {
        guard var kept = try? index.load(or: []) else { return [] }
        var added: [Entry] = []
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in Self.pictures(in: urls) {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.largest,
                  let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { continue }
            let hash = String(FolderLooks.hash(data).prefix(16))
            let entry = Entry(id: Self.prefix + hash, title: url.deletingPathExtension().lastPathComponent, file: "\(hash).\(url.pathExtension.lowercased())")
            guard !kept.contains(where: { $0.id == entry.id }),
                  (try? data.write(to: folder.appending(path: entry.file), options: .atomic)) != nil else { continue }
            kept.append(entry)
            added.append(entry)
        }
        guard !added.isEmpty, (try? index.save(kept)) != nil else { return [] }
        return added.map(design)
    }

    /// Deletes Pilot's copy of the design; the folders dressed in it are left as they are.
    public func remove(_ id: String) {
        guard let kept = try? index.load(or: []) else { return }
        for entry in kept where entry.id == id { try? FileManager.default.removeItem(at: folder.appending(path: entry.file)) }
        try? index.save(kept.filter { $0.id != id })
    }

    /// The pictures `urls` name: a file of a design's kind as it is, a folder's walked.
    static func pictures(in urls: [URL]) -> [URL] {
        func kind(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
        return urls.flatMap { url -> [URL] in
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return [] }
            guard directory.boolValue else { return kind(url) ? [url] : [] }
            guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            return walk.prefix(walkLimit).compactMap { ($0 as? URL).flatMap { kind($0) ? $0 : nil } }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    private var index: JSONFile<[Entry]> { JSONFile(url: folder.appending(path: "designs.json")) }

    private func design(_ entry: Entry) -> (design: FolderDesign, file: URL) {
        (FolderDesign(id: entry.id, title: entry.title), folder.appending(path: entry.file))
    }
}

/// How a folder looks to Pilot: no icon of its own, an icon Pilot did not set (Get Info, another app, Pilot's since
/// replaced), or the design Pilot set.
public enum FolderLook: Equatable, Sendable {
    case plain, custom
    case pilot(String)
}

/// Sets and takes back a folder's icon (P43). Pilot sets it through NSWorkspace.setIcon, as Finder's Get Info does: a
/// hidden `Icon\r` file inside holding the icon in its resource fork, and the folder's has-custom-icon Finder flag. Before
/// that it keeps what the folder had, byte for byte: the flag, and the Icon file's contents, resource fork and Finder
/// info when there was one (`<id>/` in `store`). Each folder it dressed carries Pilot's stamp (an extended attribute: the
/// record's id, the design and a hash of the icon written). Reset touches only a stamped folder whose icon still hashes
/// the same, and puts back exactly what was kept; a write that fails halfway puts it back too. System folders (`/`, the
/// home folder, /Applications, /Library, /System, /Users …) are never dressed. Pilot never writes `.gitignore` or
/// Finder's own folder looks (macOS 26's colour, symbol or emoji).
public struct FolderLooks: Sendable {
    /// Pilot's stamp on a dressed folder.
    public struct Stamp: Codable, Equatable, Sendable {
        public let id: String, design: String, icon: String
    }

    /// What Pilot keeps of a folder it dressed: where it was last and the design. `unfinished` is written before setIcon
    /// and cleared once the stamp is on: a record still unfinished is a write that broke halfway, whose kept copy Reset
    /// puts back whatever the folder shows.
    public struct Record: Codable, Equatable, Sendable {
        public let id: String
        public var path: String, design: String
        public var unfinished: Bool?
    }

    /// Steps a proof makes fail on purpose, as a full disk or a vanished volume would; none in Pilot.
    struct Faults: Sendable {
        var stamp = false, restore = false
    }

    /// What the folder had before Pilot: its custom-icon flag and whether it had an Icon file (whose bytes sit beside).
    struct Before: Codable, Equatable {
        let flag: Bool, iconFile: Bool
    }

    public enum Failure: Error, Equatable, Sendable {
        /// `/`, the home folder, /Applications, /Library, /System, /Users and the like.
        case systemFolder
        /// What the folder had could not be kept, so Pilot left it as it was.
        case notSaved
        /// macOS did not take the icon (a folder Pilot may not write, a locked volume); the folder is as it was.
        case notWritten
        /// macOS took part of a change and Pilot could not put the folder back: what it had stays kept for Reset.
        case notRestored
        /// Reset found no record of what the folder had, so it leaves Pilot's icon.
        case noBackup
    }

    public enum Reset: Equatable, Sendable {
        /// Pilot's icon is gone and what was there before is back.
        case reset
        /// No icon Pilot set: nothing touched.
        case notPilot
        /// Pilot set one, but it was replaced since: that icon stays, and Pilot forgets the folder.
        case changed
    }

    /// Pilot's own folder for the record and what each folder had.
    public let store: URL

    let faults: Faults

    public init(store: URL = PilotFolder.support.appending(path: "folder-designs", directoryHint: .isDirectory)) { self.init(store: store, faults: Faults()) }

    init(store: URL, faults: Faults) { self.store = store; self.faults = faults }

    static let stampName = "dev.banozz.pilot.folder-design"
    private static let fork = "com.apple.ResourceFork", finderInfo = "com.apple.FinderInfo"

    // MARK: Reading

    /// The hidden file Finder keeps a folder's icon in.
    static func iconFile(_ folder: URL) -> URL { folder.appending(path: "Icon\r", directoryHint: .notDirectory) }

    public func look(of folder: URL) -> FolderLook {
        if let stamp = Self.stamp(folder), Self.pilotsIcon(folder, stamp) { return .pilot(stamp.design) }
        if let broken = unfinished(folder) { return .pilot(broken.design) }
        return Self.flagged(folder) || FileManager.default.fileExists(atPath: Self.iconFile(folder).path) ? .custom : .plain
    }

    static func stamp(_ folder: URL) -> Stamp? {
        attribute(stampName, of: folder.path).flatMap { try? JSONDecoder().decode(Stamp.self, from: $0) }
    }

    /// Whether the icon the folder shows is the one `stamp` says Pilot wrote.
    static func pilotsIcon(_ folder: URL, _ stamp: Stamp) -> Bool {
        flagged(folder) && iconFork(folder).map(hash) == stamp.icon
    }

    /// Whether a file, an app or a folder wears an icon of its own: its has-custom-icon Finder flag.
    public static func hasCustomIcon(_ url: URL) -> Bool { flagged(url) }

    /// The folder's has-custom-icon Finder flag (kHasCustomIcon, 0x0400 in the flags at byte 8).
    static func flagged(_ folder: URL) -> Bool {
        guard let info = attribute(finderInfo, of: folder.path), info.count >= 10 else { return false }
        return info[info.startIndex + 8] & 0x04 != 0
    }

    /// macOS 26's own folder look (Finder › Customize Folder: a colour, a symbol or an emoji), which Pilot never writes
    /// or removes; read by its attribute's name, `com.apple.icon.folder…` (unverified on a customised folder).
    public static func hasFinderLook(_ folder: URL) -> Bool {
        attributeNames(folder.path).contains { $0.hasPrefix("com.apple.icon.folder") }
    }

    static func iconFork(_ folder: URL) -> Data? { attribute(fork, of: iconFile(folder).path) }

    static func hash(_ data: Data) -> String { ExtensionCatalogue.sha256(data) }

    /// A folder Finder shows as one, not a package (an app, a library).
    public static func isFolder(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
            && !NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    /// A folder Pilot never dresses: `/`, the home folder and its Library, /Users and each home in it, the system's own
    /// folders (/Applications, /Library, /System, /usr, /private …) and what is inside them, and a volume's root.
    public static func isSystemFolder(_ folder: URL, home: String = NSHomeDirectory()) -> Bool {
        // Resolving drops /private (/private/tmp reads /tmp), so both spellings are listed.
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let home = URL(filePath: home).resolvingSymlinksInPath().standardizedFileURL.path
        let exact: Set<String> = ["/", "/Users", "/Volumes", "/private", "/private/tmp", "/tmp", "/cores", "/Network", "/dev", "/opt", home, home + "/Library"]
        let within = ["/Applications", "/Library", "/System", "/usr", "/bin", "/sbin", "/private/etc", "/private/var", "/etc", "/var"]
        if exact.contains(path) || (path as NSString).deletingLastPathComponent == "/Users" { return true }
        if within.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        // Inside ~/Library only iCloud Drive's and the sync apps' folders (Dropbox, Google Drive) are yours, not their roots.
        let synced = ["/Mobile Documents/", "/CloudStorage/"].contains { root in
            path.hasPrefix(home + "/Library" + root) && path.count > (home + "/Library" + root).count
        }
        if path.hasPrefix(home + "/Library/"), !synced { return true }
        return (try? folder.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }

    /// The git repository a folder is in or is, by its `.git`: a custom icon's Icon file shows there as untracked.
    public static func gitRepository(_ folder: URL) -> URL? {
        var at = folder.standardizedFileURL
        while at.path != "/" {
            if FileManager.default.fileExists(atPath: at.appending(path: ".git").path) { return at }
            at = at.deletingLastPathComponent()
        }
        return nil
    }

    /// In iCloud Drive or a sync app's folder (Dropbox, Google Drive, OneDrive), where a custom icon may not survive.
    public static func synced(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
    }

    // MARK: Writing

    /// `image` as `folder`'s icon under `design`. A folder already in a Pilot design keeps what was kept before it; any
    /// other folder's flag and Icon file are kept first. The record names that copy, unfinished, before setIcon runs, so a
    /// write that breaks anywhere after still leaves Reset the way back. Should setIcon fail, or the stamp not be written
    /// after it, the folder gets back what it had and only then is the copy let go; if it cannot, the record stays
    /// unfinished and the copy with it.
    public func apply(_ image: NSImage, design: String, to folder: URL) throws(Failure) {
        guard !Self.isSystemFolder(folder) else { throw .systemFolder }
        let stamp = Self.stamp(folder), path = folder.standardizedFileURL.path
        let id: String, fresh: Bool
        if let broken = unfinished(folder) {
            // An earlier write broke halfway: its copy is still what the folder had before Pilot.
            (id, fresh) = (broken.id, false)
        } else if let stamp, Self.pilotsIcon(folder, stamp) {
            (id, fresh) = (stamp.id, false)
        } else {
            if let stamp, !shared(stamp.id, besides: folder) { forget(stamp.id) }
            (id, fresh) = (UUID().uuidString, true)
            guard keep(folder, as: id) else {
                try? FileManager.default.removeItem(at: kept(id))
                throw .notSaved
            }
        }
        let earlier = records().first { $0.id == id }
        record(Record(id: id, path: path, design: design, unfinished: true))
        guard NSWorkspace.shared.setIcon(Self.square(image), forFile: folder.path, options: []), let written = Self.iconFork(folder),
              let data = try? JSONEncoder().encode(Stamp(id: id, design: design, icon: Self.hash(written))), !faults.stamp,
              setxattr(folder.path, Self.stampName, (data as NSData).bytes, data.count, 0, 0) == 0 else {
            // Untouched: a first dress lets its copy go, a re-dress keeps the design it had.
            if fresh, matches(folder, id) { forget(id); throw .notWritten }
            if let stamp, stamp.id == id, Self.pilotsIcon(folder, stamp), let earlier { record(earlier); throw .notWritten }
            // Else the folder back as it was before Pilot, then the copy let go; the record stays unfinished if it cannot.
            guard restore(folder, id) else { throw .notRestored }
            removexattr(folder.path, Self.stampName, 0)
            if !shared(id, besides: folder) { forget(id) }
            throw .notWritten
        }
        record(Record(id: id, path: path, design: design))
    }

    /// `image` whole and centred on a 1024-point square, drawn afresh at each size setIcon asks for. A cut-out handed over
    /// as its bitmap at a size the icon format lacks (800 × 300, 1000 × 1000, 4096 × 4096) made IconServices fault once
    /// per size, each fault a crash report (Build 68, 18 Oct 20:10); a drawn image or an SVG never did (P62 probe).
    public static func square(_ image: NSImage) -> NSImage {
        let size = image.size, side: CGFloat = 1024
        guard size.width > 0, size.height > 0 else { return image }
        let scale = side / max(size.width, size.height), w = size.width * scale, h = size.height * scale
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            return true
        }
    }

    /// Takes back Pilot's icon: the folder gets back exactly what it had (its flag, and its Icon file byte for byte, or
    /// none), and Pilot's stamp goes. A write that broke halfway is put back whatever the folder shows. A folder Pilot did
    /// not dress, or whose icon was replaced since, keeps its icon.
    public func reset(_ folder: URL) throws(Failure) -> Reset {
        let stamp = Self.stamp(folder)
        guard let id = unfinished(folder)?.id ?? stamp.flatMap({ Self.pilotsIcon(folder, $0) ? $0.id : nil }) else {
            guard let stamp else { return .notPilot }
            removexattr(folder.path, Self.stampName, 0)
            if !shared(stamp.id, besides: folder) { forget(stamp.id) }
            return .changed
        }
        guard before(id) != nil else { throw .noBackup }
        guard restore(folder, id) else { throw .notRestored }
        removexattr(folder.path, Self.stampName, 0)
        if !shared(id, besides: folder) { forget(id) }
        return .reset
    }

    /// The record of a write to `folder` that broke halfway, if any.
    func unfinished(_ folder: URL) -> Record? {
        let path = folder.standardizedFileURL.path
        return records().first { $0.path == path && $0.unfinished == true }
    }

    private func record(_ record: Record) { save(records().filter { $0.id != record.id } + [record]) }

    /// The folders Pilot dressed, as last recorded.
    public func records() -> [Record] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
    }

    // MARK: What the folder had

    /// Keeps the folder's flag, and its Icon file's contents, resource fork and Finder info when it has one.
    private func keep(_ folder: URL, as id: String) -> Bool {
        let icon = Self.iconFile(folder).path, at = kept(id)
        let iconFile = FileManager.default.fileExists(atPath: icon)
        do {
            try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
            try JSONEncoder().encode(Before(flag: Self.flagged(folder), iconFile: iconFile)).write(to: at.appending(path: "before.json"))
            guard iconFile else { return true }
            try Data(contentsOf: URL(filePath: icon)).write(to: at.appending(path: "data"))
            for (name, file) in [(Self.fork, "fork"), (Self.finderInfo, "info")] {
                if let bytes = Self.attribute(name, of: icon) { try bytes.write(to: at.appending(path: file)) }
            }
            return true
        } catch { return false }
    }

    private func before(_ id: String) -> Before? {
        (try? Data(contentsOf: kept(id).appending(path: "before.json"))).flatMap { try? JSONDecoder().decode(Before.self, from: $0) }
    }

    private func keptBytes(_ id: String, _ file: String) -> Data? { try? Data(contentsOf: kept(id).appending(path: file)) }

    /// Whether the folder is now exactly as kept: its flag, and its Icon file and the file's attributes, byte for byte.
    func matches(_ folder: URL, _ id: String) -> Bool {
        guard let before = before(id), Self.flagged(folder) == before.flag else { return false }
        let icon = Self.iconFile(folder).path
        guard before.iconFile else { return !FileManager.default.fileExists(atPath: icon) }
        return (try? Data(contentsOf: URL(filePath: icon))) == keptBytes(id, "data")
            && Self.attribute(Self.fork, of: icon) == keptBytes(id, "fork") && Self.attribute(Self.finderInfo, of: icon) == keptBytes(id, "info")
    }

    /// Puts back what was kept: Pilot's Icon file goes, the kept one (if any) is written back with its fork and Finder
    /// info, and the folder's flag is set as it was, its other Finder info left alone. True once the folder matches.
    private func restore(_ folder: URL, _ id: String) -> Bool {
        guard let before = before(id) else { return false }
        let icon = Self.iconFile(folder)
        if FileManager.default.fileExists(atPath: icon.path) { try? FileManager.default.removeItem(at: icon) }
        if faults.restore { return false }
        if before.iconFile {
            guard FileManager.default.createFile(atPath: icon.path, contents: keptBytes(id, "data") ?? Data()) else { return false }
            for (name, file) in [(Self.fork, "fork"), (Self.finderInfo, "info")] {
                guard let bytes = keptBytes(id, file) else { continue }
                guard setxattr(icon.path, name, (bytes as NSData).bytes, bytes.count, 0, 0) == 0 else { return false }
            }
        }
        var info = Self.attribute(Self.finderInfo, of: folder.path) ?? Data(count: 32)
        if info.count >= 10 {
            let i = info.startIndex + 8
            info[i] = before.flag ? info[i] | 0x04 : info[i] & ~0x04
        }
        // All zero is no Finder info at all, as macOS writes it.
        if info.allSatisfy({ $0 == 0 }) {
            removexattr(folder.path, Self.finderInfo, 0)
        } else if setxattr(folder.path, Self.finderInfo, (info as NSData).bytes, info.count, 0, 0) != 0 {
            return false
        }
        NSWorkspace.shared.noteFileSystemChanged(folder.path)
        return matches(folder, id)
    }

    /// Whether another folder, a copy's original, still wears the stamp `id`: its record and kept copy stay for it.
    private func shared(_ id: String, besides folder: URL) -> Bool {
        guard let record = records().first(where: { $0.id == id }), record.path != folder.standardizedFileURL.path else { return false }
        return Self.stamp(URL(filePath: record.path, directoryHint: .isDirectory))?.id == id
    }

    private func forget(_ id: String) {
        try? FileManager.default.removeItem(at: kept(id))
        save(records().filter { $0.id != id })
    }

    private var file: URL { store.appending(path: "folders.json") }
    private func kept(_ id: String) -> URL { store.appending(path: id, directoryHint: .isDirectory) }

    private func save(_ records: [Record]) {
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    // MARK: Extended attributes

    static func attribute(_ name: String, of path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }

    static func attributeNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, 0)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, 0) == size else { return [] }
        return names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}
