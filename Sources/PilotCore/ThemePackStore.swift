import Foundation
import ImageIO
import Synchronization
import Darwin

/// Roots are composition authority, never a manifest field. Colliding user/factory IDs refuse explicitly.
public struct ThemePackStore: Sendable {
    public let root, writableRoot: String
    public let factoryRoot: String?
    public init(root: String, writableRoot: String, factoryRoot: String? = nil) {
        self.root = root; self.writableRoot = writableRoot; self.factoryRoot = factoryRoot
    }
    public struct Loaded: Sendable {
        public let folder: String
        public let pack: ThemePack
        public let revision: String
        public let factory: Bool
        public let images: [String]
        public let portraits: Set<String>
        /// The pack's own picture, resolved inside its folder; nil when it names none.
        public let preview: String?

        /// This pack with `other`'s wallpapers: a shipped pack with the pictures its catalogue copy brought
        /// (ShippedWallpapers). Its revision stays its own, which Apply checks the shipped pack against.
        public func picturing(_ other: Loaded) -> Loaded {
            Loaded(folder: folder, pack: pack, revision: revision, factory: factory, images: other.images, portraits: other.portraits, preview: preview)
        }
    }
    private static let images = DispatchQueue(label: "dev.banozz.pilot.theme-assets", qos: .userInitiated)

    public func load(_ id: String) throws -> Loaded {
        guard ThemePack.validID(id) else { throw ThemeFailure("invalid pack id") }
        let fm = FileManager.default
        let userRoots = Array(Set([root, writableRoot])).sorted().filter { fm.fileExists(atPath: $0 + "/" + id) }
        let factory = isFactory(id)
        guard userRoots.count + (factory ? 1 : 0) <= 1 else { throw ThemeFailure("user/factory pack ID collision: \(id); rename the user pack") }
        guard factory || PilotTheme.named(id) == nil else { throw ThemeFailure("reserved stock theme ID: \(id); give the user pack its own ID") }
        let source = factory ? factoryRoot! : userRoots.first ?? root
        let folder = source + "/" + id
        let manifest = try ThemeFiles.read(root: source, path: id + "/manifest.json")
        guard manifest.resolved.hasPrefix(folder + "/"), let bytes = manifest.bytes else { throw ThemeFailure("missing/escaping manifest") }
        let pack = try ThemePack.decode(bytes)
        guard pack.id == id else { throw ThemeFailure("pack folder and identity differ") }
        // Enumeration and actual image decoding execute on the asset queue, never the UI thread.
        let result = Mutex<Result<Loaded, any Error>?>(nil)
        let ready = DispatchSemaphore(value: 0)
        Self.images.async {
            result.withLock { value in
                value = Result {
                    guard !Thread.isMainThread else { throw ThemeFailure("asset processing requires a worker thread") }
                    var inputs = [manifest], paths: [String] = [], portraits = Set<String>()
                    for asset in pack.wallpapers {
                        let url = URL(fileURLWithPath: folder + "/" + asset)
                        guard url.resolvingSymlinksInPath().path.hasPrefix(folder + "/") else { throw ThemeFailure("escaping pack asset") }
                        var directory: ObjCBool = false
                        guard fm.fileExists(atPath: url.path, isDirectory: &directory) else { throw ThemeFailure("missing pack asset") }
                        let files: [URL]
                        if directory.boolValue {
                            files = try WallpaperCycle.images(in: url, inspect: {
                                guard $0.resolvingSymlinksInPath().path.hasPrefix(folder + "/") else { throw ThemeFailure("escaping wallpaper folder entry") }
                            })
                            guard !files.isEmpty else { throw ThemeFailure("empty wallpaper folder; use wallpapers: [] for none") }
                        } else { files = [url] }
                        for file in files {
                            let relative = String(file.path.dropFirst(source.count + 1))
                            let observed = try ThemeFiles.read(root: source, path: relative)
                            guard let data = observed.bytes, observed.resolved.hasPrefix(folder + "/"),
                                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                                  CGImageSourceGetStatus(imageSource) == .statusComplete,
                                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                                  image.width > 0, image.height > 0 else { throw ThemeFailure("missing/escaping/undecodable wallpaper asset: \(file.lastPathComponent)") }
                            inputs.append(observed)
                            if !paths.contains(observed.resolved) { paths.append(observed.resolved) }
                            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
                            if ImageShapes.shape(width: image.width, height: image.height,
                                orientation: properties?[kCGImagePropertyOrientation] as? Int ?? 1) == .portrait { portraits.insert(observed.resolved) }
                        }
                    }
                    // The pack's own picture: inside the folder, links resolved, and a whole image, as a wallpaper must be.
                    var preview: String?
                    if let picture = pack.preview {
                        let observed = try ThemeFiles.read(root: source, path: id + "/" + picture)
                        guard let data = observed.bytes, observed.resolved.hasPrefix(folder + "/"),
                              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                              CGImageSourceGetStatus(imageSource) == .statusComplete,
                              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                              image.width > 0, image.height > 0 else { throw ThemeFailure("missing/escaping/undecodable pack picture: \(picture)") }
                        inputs.append(observed)
                        preview = observed.resolved
                    }
                    if factory || fm.fileExists(atPath: folder + "/PROVENANCE.md") {
                        let provenance = try ThemeFiles.read(root: source, path: id + "/PROVENANCE.md")
                        guard provenance.bytes?.isEmpty == false, provenance.resolved.hasPrefix(folder + "/") else { throw ThemeFailure("missing factory asset provenance") }
                        inputs.append(provenance)
                    }
                    return Loaded(folder: folder, pack: pack, revision: ThemeDigest.of(try ThemeDigest.encoded(inputs)), factory: factory,
                                  images: WallpaperCycle.sortedByName(paths.map { URL(fileURLWithPath: $0) }).map(\.path), portraits: portraits,
                                  preview: preview)
                }
            }
            ready.signal()
        }
        ready.wait()
        return try result.withLock { try $0!.get() }
    }
    /// Whether a pack ships with Pilot (its factory library).
    public func isFactory(_ id: String) -> Bool { factoryRoot.map { FileManager.default.fileExists(atPath: $0 + "/" + id) } ?? false }
    /// Pilot's own: a stock theme or a factory pack, which can't be deleted.
    public func isPilots(_ id: String) -> Bool { PilotTheme.named(id) != nil || isFactory(id) }
    public static func pilotsOwn(_ name: String) -> ThemeFailure {
        ThemeFailure("\(name) is one of Pilot's own themes, so it can't be deleted. Only packs you made or imported can.")
    }
    public func list() throws -> [ThemePack] {
        let roots = Set([root, writableRoot] + [factoryRoot].compactMap { $0 })
        let names = try roots.flatMap { path -> [String] in
            var directory = ObjCBool(false)
            if !FileManager.default.fileExists(atPath: path, isDirectory: &directory) {
                var info = stat()
                guard lstat(path, &info) != 0, errno == ENOENT, path != factoryRoot else { throw ThemeFailure("unreadable pack library") }
                // A genuinely absent user library is a valid first run; corrupt/dangling roots aren't.
                let parent = try PackDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                _ = parent
                return []
            }
            let checked = try PackDirectory(path); _ = checked
            return try FileManager.default.contentsOfDirectory(atPath: path).filter(ThemePack.validID)
        }
        return try Set(names).sorted().map { try load($0).pack }
    }
}

extension ThemePackStore {
    /// Explicit JSON envelope, not an archive: base64 regular assets and a versioned manifest only.
    /// Local destinations, ownership, display identities and executable installation have no representation.
    public struct Draft: Codable, Equatable, Sendable {
        public var format = 1
        public var pack: ThemePack
        public var files: [String: Data]
        public init(pack: ThemePack, files: [String: Data] = [:]) { self.pack = pack; self.files = files }
    }

    public func draft(_ id: String) throws -> Draft {
        let loaded = try load(id)
        var files: [String: Data] = [:]
        for image in loaded.images {
            let path = String(image.dropFirst(loaded.folder.count + 1))
            let snapshot = try ThemeFiles.read(root: loaded.folder, path: path)
            guard snapshot.resolved == image, let bytes = snapshot.bytes else { throw ThemeFailure("asset changed") }
            files[path] = bytes
        }
        let provenance = try ThemeFiles.read(root: loaded.folder, path: "PROVENANCE.md")
        if let bytes = provenance.bytes { files["PROVENANCE.md"] = bytes }
        guard try load(id).revision == loaded.revision else { throw ThemeFailure("pack changed while copying") }
        return Draft(pack: loaded.pack, files: files)
    }

    /// Folder inputs are data, not library authority. No link or hard-link objects are imported.
    public static func readFolder(_ path: String) throws -> Draft {
        let root = try PackDirectory(path); _ = root
        let observed = try ThemeFiles.read(root: path, path: "manifest.json")
        guard observed.resolved == path + "/manifest.json", let bytes = observed.bytes else { throw ThemeFailure("missing regular manifest") }
        let pack = try ThemePack.decode(bytes)
        var files: [String: Data] = [:]
        for asset in pack.wallpapers {
            let source = path + "/" + asset
            var info = stat()
            guard lstat(source, &info) == 0 else { throw ThemeFailure("missing wallpaper") }
            let paths: [String]
            if info.st_mode & S_IFMT == S_IFDIR {
                let directory = try PackDirectory(source); _ = directory
                paths = try WallpaperCycle.images(in: URL(fileURLWithPath: source), inspect: { url in
                    guard url.resolvingSymlinksInPath().path == url.path else { throw ThemeFailure("linked wallpaper") }
                }).map(\.path)
                guard !paths.isEmpty else { throw ThemeFailure("empty wallpaper folder") }
            } else { paths = [source] }
            for item in paths {
                let relative = String(item.dropFirst(path.count + 1))
                let read = try ThemeFiles.read(root: path, path: relative)
                guard read.resolved == item, let data = read.bytes else { throw ThemeFailure("linked/missing wallpaper") }
                files[relative] = data
            }
        }
        let provenance = try ThemeFiles.read(root: path, path: "PROVENANCE.md")
        guard provenance.resolved == path + "/PROVENANCE.md" else { throw ThemeFailure("linked provenance") }
        if let bytes = provenance.bytes { files["PROVENANCE.md"] = bytes }
        guard try ThemeFiles.read(root: path, path: "manifest.json") == observed else { throw ThemeFailure("source changed") }
        let draft = Draft(pack: pack, files: files)
        try validate(draft)
        return draft
    }

    public static func readPortable(_ path: String) throws -> Draft {
        let url = URL(fileURLWithPath: path), parent = url.deletingLastPathComponent().path
        let root = try PackDirectory(parent); _ = root
        let file = try ThemeFiles.read(root: parent, path: url.lastPathComponent)
        guard file.resolved == path, let bytes = file.bytes else { throw ThemeFailure("invalid portable file") }
        // Check the original member stream, including the entire manifest subtree, before
        // JSONSerialization can erase duplicate (including escaped or UTF-16/32) names.
        let raw = try JSONDecoder().decode(JSONValue.self, from: bytes)
        try ThemeLedger.validateFields(bytes, encoded: ThemeDigest.encoded(raw))
        guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(fields.keys) == ["format", "pack", "files"] else { throw ThemeFailure("invalid portable envelope") }
        // Decode manifest through its strict public validator too; synthesized Codable isn't validation.
        let pack = try ThemePack.decode(JSONSerialization.data(withJSONObject: fields["pack"]!))
        var draft = try JSONDecoder().decode(Draft.self, from: bytes); draft.pack = pack
        try validate(draft)
        return draft
    }

    public static func attaching(_ paths: [String], to original: Draft) throws -> Draft {
        var draft = original
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let parent = try PackDirectory(url.deletingLastPathComponent().path); _ = parent
            var info = stat()
            guard lstat(path, &info) == 0 else { throw ThemeFailure("missing selected asset") }
            let destination = "wallpapers/" + url.lastPathComponent
            guard !draft.pack.wallpapers.contains(destination) else { throw ThemeFailure("asset name collision; rename the selected input") }
            let items: [URL]
            if info.st_mode & S_IFMT == S_IFDIR {
                let directory = try PackDirectory(path); _ = directory
                items = try WallpaperCycle.images(in: url, inspect: { item in
                    guard item.resolvingSymlinksInPath().path == item.path else { throw ThemeFailure("linked selected asset") }
                })
            } else { items = [url] }
            guard !items.isEmpty else { throw ThemeFailure("empty selected folder") }
            for item in items {
                let root = info.st_mode & S_IFMT == S_IFDIR ? path : url.deletingLastPathComponent().path
                let relative = String(item.path.dropFirst(root.count + 1))
                let file = try ThemeFiles.read(root: root, path: relative)
                guard file.resolved == item.path, let bytes = file.bytes else { throw ThemeFailure("unsafe selected asset") }
                let target = info.st_mode & S_IFMT == S_IFDIR ? destination + "/" + relative : destination
                guard draft.files[target] == nil else { throw ThemeFailure("asset collision") }
                draft.files[target] = bytes
            }
            draft.pack.wallpapers.append(destination)
        }
        try validate(draft)
        return draft
    }

    /// Whether `pack` names only the built-in adapters, each with no data of its own (`{}`).
    public static func plainAdapters(_ pack: ThemePack) -> Bool {
        Set(pack.adapters.keys).isSubset(of: ["ghostty", "zed", "obsidian"]) && pack.adapters.values.allSatisfy { $0 == .object([:]) }
    }

    public static func validate(_ draft: Draft) throws {
        _ = try ThemePack.decode(ThemeDigest.encoded(draft.pack))
        guard draft.format == 1, plainAdapters(draft.pack) else { throw ThemeFailure("unsupported portable format or adapter payload; preserved source must be updated explicitly") }
        for (path, data) in draft.files {
            guard ThemeFiles.relative(path), path != "manifest.json",
                  path == "PROVENANCE.md" || draft.pack.wallpapers.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  !draft.files.keys.contains(where: { $0 != path && path.hasPrefix($0 + "/") }) else { throw ThemeFailure("unsafe/unreferenced/colliding asset") }
            if path == "PROVENANCE.md" {
                guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else { throw ThemeFailure("invalid provenance") }
            }
        }
        for asset in draft.pack.wallpapers {
            guard draft.files[asset] != nil || draft.files.keys.contains(where: { $0.hasPrefix(asset + "/") }) else { throw ThemeFailure("missing portable asset") }
        }
        // Decoding is always on the existing asset queue, including saves originating in a native view.
        let error = Mutex<String?>(nil), ready = DispatchSemaphore(value: 0)
        images.async {
            for (path, bytes) in draft.files where path != "PROVENANCE.md" {
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      CGImageSourceGetStatus(source) == .statusComplete,
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                      image.width > 0, image.height > 0 else {
                    error.withLock { $0 = "undecodable portable image: \(path)" }; break
                }
            }
            ready.signal()
        }
        ready.wait()
        if let message = error.withLock({ $0 }) { throw ThemeFailure(message) }
    }

    /// nil means create exclusively. Replacement requires the caller's exact previously read revision.
    /// Staging contains a whole validated pack; atomic swap publishes no partial manifest/asset set.
    public func save(_ draft: Draft, replacing revision: String? = nil, fault: (String) throws -> Void = { _ in }) throws -> Loaded {
        try Self.validate(draft)
        let id = draft.pack.id
        guard PilotTheme.named(id) == nil else { throw ThemeFailure("reserved stock ID; make a user copy") }
        let parentURL = URL(fileURLWithPath: writableRoot).deletingLastPathComponent()
        let parent = try PackDirectory(parentURL.path)
        let leaf = URL(fileURLWithPath: writableRoot).lastPathComponent
        if mkdirat(parent.fd, leaf, 0o700) != 0, errno != EEXIST { throw ThemeFailure("cannot create user library") }
        let directory = try PackDirectory(writableRoot)
        guard flock(directory.fd, LOCK_EX) == 0 else { throw ThemeFailure("cannot lock user library") }
        defer { flock(directory.fd, LOCK_UN) }
        // A collision in any other root is never a replacement of this writable library.
        for path in Set([root] + [factoryRoot].compactMap { $0 }) where path != writableRoot {
            var info = stat()
            guard lstat(path + "/" + id, &info) != 0, errno == ENOENT else { throw ThemeFailure("pack ID collision in another store/factory") }
        }
        var info = stat()
        let exists = fstatat(directory.fd, id, &info, AT_SYMLINK_NOFOLLOW) == 0
        guard exists || errno == ENOENT else { throw ThemeFailure("cannot inspect existing pack") }
        if exists {
            guard info.st_mode & S_IFMT == S_IFDIR, let revision, try load(id).revision == revision else { throw ThemeFailure("collision or stale replacement revision") }
        } else if revision != nil { throw ThemeFailure("replacement pack disappeared") }
        let predecessor = exists ? try PackDirectory(writableRoot + "/" + id) : nil
        let previous = try predecessor?.revision()
        let stage = ".pilot-draft-" + UUID().uuidString
        guard mkdirat(directory.fd, stage, 0o700) == 0 else { throw ThemeFailure("cannot stage pack") }
        let staging = try PackDirectory(writableRoot + "/" + stage)
        guard mkdirat(staging.fd, id, 0o700) == 0 else { throw ThemeFailure("cannot stage identity") }
        let content = try PackDirectory(writableRoot + "/" + stage + "/" + id)
        // A failed/interrupted stage is hidden and recoverable; never listed as a saved pack.
        for (path, bytes) in draft.files.sorted(by: { $0.key < $1.key }) { try content.create(path, bytes: bytes) }
        try content.create("manifest.json", bytes: ThemeDigest.encoded(draft.pack))
        guard fsync(content.fd) == 0, fsync(staging.fd) == 0 else { throw ThemeFailure("cannot sync pack stage") }
        try fault("editor-staged")
        try parent.check(); try directory.check(); try staging.check(); try content.check()
        try fault("editor-publish")
        try parent.check(); try directory.check(); try staging.check(); try content.check()
        guard try Self.readFolder(content.path) == draft else { throw ThemeFailure("staged content changed") }
        let publishedRevision = try content.revision()
        if exists {
            try predecessor?.check()
            guard try load(id).revision == revision, try predecessor?.revision() == previous else { throw ThemeFailure("concurrent save") }
        } else {
            guard fstatat(directory.fd, id, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ThemeFailure("concurrent pack collision") }
        }
        guard renameatx_np(staging.fd, id, directory.fd, id, exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)) == 0 else { throw ThemeFailure("atomic pack publication refused") }
        do {
            guard fsync(directory.fd) == 0, fsync(staging.fd) == 0 else { throw ThemeFailure("publication sync failed") }
            try fault("editor-published")
            let saved = try load(id)
            guard saved.pack == draft.pack, try Self.readFolder(writableRoot + "/" + id) == draft else { throw ThemeFailure("concurrent publication") }
            // Successful replacements retain the previous complete folder as local recovery data.
            if !exists { _ = unlinkat(directory.fd, stage, AT_REMOVEDIR) }
            return saved
        } catch {
            // Only undo OUR still-identical published directory; never overwrite a later publisher.
            try parent.check(); try directory.check(); try staging.check()
            var current = stat(), staged = stat()
            guard fstat(content.fd, &staged) == 0, fstatat(directory.fd, id, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  staged.st_ino == current.st_ino, staged.st_dev == current.st_dev,
                  try Self.readFolder(writableRoot + "/" + id) == draft,
                  try PackDirectory(writableRoot + "/" + id).revision() == publishedRevision else { throw ThemeFailure("publication conflict; recovery retained at \(stage)") }
            // The old folder is recovery data, not trusted input: a failed palette-only save
            // must not activate changed wallpaper bytes or a substituted predecessor.
            if let predecessor {
                do {
                    let retained = try PackDirectory(staging.path + "/" + id)
                    try predecessor.check(retained.path)
                    guard try retained.revision() == previous else { throw ThemeFailure("changed predecessor") }
                    try parent.check(); try directory.check(); try staging.check()
                } catch { throw ThemeFailure("predecessor conflict; recovery retained at \(stage)") }
            }
            guard renameatx_np(directory.fd, id, staging.fd, id, exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)) == 0,
                  fsync(directory.fd) == 0, fsync(staging.fd) == 0 else { throw ThemeFailure("publication rollback failed; recovery retained at \(stage)") }
            do {
                try fault("editor-restored")
                try parent.check(); try directory.check(); try staging.check()
                try predecessor?.check()
                guard try predecessor?.revision() == previous else { throw ThemeFailure("changed restoration") }
            } catch { throw ThemeFailure("rollback verification conflict; recovery retained at \(stage)") }
            throw error
        }
    }

    /// Removes a pack a person made from the writable library: Pilot's own packs and stock themes are refused. The folder is
    /// first renamed out of the library under the lock, so it is never listed half removed, then removed with what it holds.
    public func delete(_ id: String) throws {
        guard ThemePack.validID(id) else { throw ThemeFailure("invalid pack id") }
        guard !isPilots(id) else { throw Self.pilotsOwn(id) }
        let directory = try PackDirectory(writableRoot)
        guard flock(directory.fd, LOCK_EX) == 0 else { throw ThemeFailure("cannot lock user library") }
        defer { flock(directory.fd, LOCK_UN) }
        var info = stat()
        guard fstatat(directory.fd, id, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ThemeFailure("no pack named \(id) in your themes") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ThemeFailure("\(id) is not a pack folder; nothing deleted") }
        let gone = ".pilot-deleted-" + UUID().uuidString
        guard renameatx_np(directory.fd, id, directory.fd, gone, UInt32(RENAME_EXCL)) == 0, fsync(directory.fd) == 0 else { throw ThemeFailure("could not delete \(id)") }
        // A leftover hidden folder is never listed, so a failed removal only leaves disk space behind.
        try? FileManager.default.removeItem(atPath: writableRoot + "/" + gone)
    }

    public func export(_ id: String, to path: String, fault: (String) throws -> Void = { _ in }) throws {
        let revision = try load(id).revision
        let draft = try draft(id); try Self.validate(draft)
        guard try load(id).revision == revision else { throw ThemeFailure("export source changed") }
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), path == url.standardizedFileURL.path else { throw ThemeFailure("explicit absolute export file required") }
        let parent = try PackDirectory(url.deletingLastPathComponent().path)
        try parent.create(url.lastPathComponent, bytes: ThemeDigest.encoded(draft), beforePublish: {
            try fault("export-staged")
            guard try load(id).revision == revision else { throw ThemeFailure("export source changed; stage retained") }
        }, afterPublish: {
            try fault("export-published")
            guard try load(id).revision == revision else { throw ThemeFailure("export source changed; publication retained") }
        })
    }
}

/// Every absolute component is opened without following links; writers keep descriptors and recheck identity.
private final class PackDirectory {
    let path: String
    let fd: Int32
    private let inode: ino_t
    private let device: dev_t
    init(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw ThemeFailure("explicit canonical directory required") }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        for part in path.split(separator: "/") {
            let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(current); current = next
            guard current >= 0 else { throw ThemeFailure("unsafe/missing directory") }
        }
        var info = stat()
        guard fstat(current, &info) == 0 else { close(current); throw ThemeFailure("lost directory") }
        self.path = path; fd = current; inode = info.st_ino; device = info.st_dev
    }
    deinit { close(fd) }
    func check(_ location: String? = nil) throws {
        let current = try PackDirectory(location ?? path)
        guard current.inode == inode, current.device == device else { throw ThemeFailure("directory parent substitution") }
    }
    /// A relocation-independent revision of the complete retained tree, including exact
    /// manifest encoding, metadata, modes and object identities, not only decoded pack data.
    func revision() throws -> String {
        try check()
        var root = stat()
        guard fstat(fd, &root) == 0 else { throw ThemeFailure("lost pack directory") }
        var entries: [String: [String]] = [".": ["\(root.st_dev):\(root.st_ino):\(root.st_mode):\(root.st_nlink)"]]
        func scan(_ directory: PackDirectory, prefix: String) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            for name in names {
                var info = stat()
                guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ThemeFailure("pack entry disappeared") }
                let key = prefix + name
                entries[key] = ["\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_nlink)"]
                if info.st_mode & S_IFMT == S_IFDIR {
                    try scan(PackDirectory(directory.path + "/" + name), prefix: key + "/")
                } else {
                    guard info.st_mode & S_IFMT == S_IFREG,
                          let bytes = try ThemeFiles.read(root: directory.path, path: name).bytes else { throw ThemeFailure("unsafe pack entry") }
                    entries[key]!.append(ThemeDigest.of(bytes))
                }
            }
            try directory.check()
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names else { throw ThemeFailure("pack inventory changed") }
        }
        try scan(self, prefix: "")
        return ThemeDigest.of(try ThemeDigest.encoded(entries))
    }
    func create(_ path: String, bytes: Data, beforePublish: () throws -> Void = {}, afterPublish: () throws -> Void = {}) throws {
        guard ThemeFiles.relative(path) else { throw ThemeFailure("unsafe file path") }
        try check()
        var parent = dup(fd)
        defer { close(parent) }
        for part in path.split(separator: "/").dropLast() {
            if mkdirat(parent, String(part), 0o700) != 0, errno != EEXIST { throw ThemeFailure("cannot stage asset parent") }
            let next = openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(parent); parent = next
            guard parent >= 0 else { throw ThemeFailure("unsafe asset parent") }
        }
        let leaf = URL(fileURLWithPath: path).lastPathComponent, temp = ".pilot-file-" + UUID().uuidString
        let file = openat(parent, temp, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw ThemeFailure("cannot stage regular file") }
        // Failed stages are recovery evidence. Never unlink a pathname another writer may have replaced.
        defer { close(file) }
        try FileHandle(fileDescriptor: file, closeOnDealloc: false).write(contentsOf: bytes)
        var written = stat()
        guard fchmod(file, 0o600) == 0, fsync(file) == 0, fstat(file, &written) == 0 else { throw ThemeFailure("cannot sync asset") }
        func verify(_ name: String) throws {
            let observed = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard observed >= 0 else { throw ThemeFailure("staged/published file replaced; recovery retained") }
            defer { close(observed) }
            func matches(_ info: stat) -> Bool {
                info.st_dev == written.st_dev && info.st_ino == written.st_ino && info.st_mode & S_IFMT == S_IFREG &&
                info.st_nlink == 1 && info.st_mode & 0o7777 == 0o600 && info.st_size == bytes.count
            }
            var first = stat(), last = stat(), named = stat()
            guard fstat(observed, &first) == 0, matches(first),
                  try FileHandle(fileDescriptor: observed, closeOnDealloc: false).readToEnd() == bytes,
                  fstat(observed, &last) == 0, matches(last), first.st_mtimespec.tv_sec == last.st_mtimespec.tv_sec,
                  first.st_mtimespec.tv_nsec == last.st_mtimespec.tv_nsec,
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, matches(named) else {
                throw ThemeFailure("staged/published content conflict; recovery retained")
            }
        }
        try beforePublish()
        try check()
        // Reopen the complete parent through the original root to catch nested substitutions too.
        let parentPath = URL(fileURLWithPath: self.path + "/" + path).deletingLastPathComponent().path
        let observed = try PackDirectory(parentPath)
        var a = stat(), b = stat()
        guard fstat(parent, &a) == 0, fstat(observed.fd, &b) == 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev else { throw ThemeFailure("file parent substitution") }
        try verify(temp)
        guard renameatx_np(parent, temp, parent, leaf, UInt32(RENAME_EXCL)) == 0, fsync(parent) == 0 else { throw ThemeFailure("file collision/publication failed; recovery retained") }
        try afterPublish()
        try check(); try observed.check()
        try verify(leaf)
    }
}
