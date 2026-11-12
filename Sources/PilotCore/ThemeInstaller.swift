import Darwin
import Foundation

/// Installs, updates and removes catalogue theme packs (public-repo spec T20), by ExtensionInstaller's rules. Every file
/// of the entry is fetched into a hidden folder inside the writable pack library (one volume, so the last step is a
/// rename), each held to the index's size and sha256, and written as it came, so the installed folder's digest is the
/// index's until the person edits the pack. The folder must then load as a pack with the entry's id through
/// ThemePackStore.load's own checks, carry no custom mappings (catalogue themes carry none, Open question 5) and no adapter
/// data. Only then does it take `<library>/<id>`, under the lock the pack editor's save takes, an installed copy going to
/// the Trash after the real store has loaded the new one. A file that does not match installs nothing.
public struct ThemeInstaller: Sendable {
    public let store: ThemePackStore, source: ExtensionCatalogue.Source
    let trash: @Sendable (URL) throws -> Void

    public init(store: ThemePackStore, source: ExtensionCatalogue.Source = .live, trash: @escaping @Sendable (URL) throws -> Void = FileOps.trashNow) {
        self.store = store; self.source = source; self.trash = trash
    }

    private var library: URL { URL(filePath: store.writableRoot, directoryHint: .isDirectory) }

    /// The pack `id`'s folder in the writable library: a valid id and a folder there itself, never a link; else nil.
    public func folder(_ id: String) -> URL? {
        let folder = library.appending(path: id, directoryHint: .isDirectory)
        var info = stat()
        guard ThemePack.validID(id), lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return folder
    }

    /// The digest of each pack in the writable library named one of `ids`, made as build-index.py makes an entry's.
    public func installed(_ ids: some Sequence<String>) -> [String: String] {
        var found: [String: String] = [:]
        for id in ids {
            guard let folder = folder(id) else { continue }
            let files = ExtensionCheck.listing(folder).compactMap { listed in
                (try? Data(contentsOf: listed.url)).map { ExtensionCatalogue.File(path: listed.path, sha256: ExtensionCatalogue.sha256($0), size: $0.count) }
            }
            found[id] = ExtensionCatalogue.digest(files)
        }
        return found
    }

    /// Installs `theme`, or replaces the pack with its id in the writable library, and returns it as the store loads it.
    /// `expecting` is the digest the question named for the pack there (nil: none), read again under the lock, so a pack
    /// saved while Allow was up is never replaced unasked. `progress` hears each file fetched (done, of all). Throws a
    /// Problem, and leaves the library as it was, when a file does not arrive or match, what arrived is not that pack or
    /// carries what a catalogue pack may not, the pack there changed, or Pilot's own themes or another pack root use its id.
    @discardableResult
    public func install(_ theme: ExtensionCatalogue.Theme, expecting: String?, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> ThemePackStore.Loaded {
        try refuseTaken(theme.id)
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let stage = library.appending(path: ".pilot-catalogue-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: stage) }
        let temp = stage.appending(path: theme.id, directoryHint: .isDirectory)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try await source.download(theme.files, from: "themes/\(theme.id)", limit: ExtensionCatalogue.themeFileLimit, into: temp,
                                  mode: { _ in 0o644 }, progress: progress)
        try Self.check(ThemePackStore(root: stage.path, writableRoot: stage.path).load(theme.id))
        try Task.checkCancellation()
        let (loaded, replaced): (ThemePackStore.Loaded, URL?) = try locked {
            // Asked again: a pack may have been saved while the files came or the question was up.
            try refuseTaken(theme.id)
            guard installed([theme.id])[theme.id] == expecting else {
                throw ExtensionCatalogue.Problem.themeTaken(id: theme.id, why: "that changed since Pilot asked")
            }
            let target = library.appending(path: theme.id, directoryHint: .isDirectory)
            let aside = stage.appending(path: "old", directoryHint: .isDirectory).appending(path: theme.id, directoryHint: .isDirectory)
            var info = stat(), replacing = false
            if lstat(target.path, &info) == 0 {
                guard folder(theme.id) != nil else { throw ExtensionCatalogue.Problem.themeTaken(id: theme.id, why: "that is not a folder") }
                try fm.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: target, to: aside)
                replacing = true
            }
            let loaded: ThemePackStore.Loaded
            do {
                try fm.moveItem(at: temp, to: target)
                do { loaded = try Self.check(store.load(theme.id)) } catch {
                    try? fm.moveItem(at: target, to: temp)
                    throw error
                }
            } catch {
                if replacing { try? fm.moveItem(at: aside, to: target) }
                throw error
            }
            return (loaded, replacing ? aside : nil)
        }
        // The old copy goes to the Trash once the lock is let go, so a save never waits on the Trash; when the Trash
        // refuses, it stays in the library as a hidden folder rather than going with the stage.
        if let replaced {
            do { try trash(replaced) } catch {
                try? fm.moveItem(at: replaced, to: library.appending(path: ".pilot-replaced-\(theme.id)-\(UUID().uuidString)", directoryHint: .isDirectory))
            }
        }
        return loaded
    }

    /// Moves the pack `id` in the writable library to the Trash.
    public func remove(_ id: String) throws {
        guard let folder = folder(id) else { throw ExtensionCatalogue.Problem.themeNotInstalled(id) }
        try locked { try trash(folder) }
    }

    /// `loaded`, once it carries nothing a catalogue pack may not: custom mappings write pack text into a local config,
    /// and an adapter carries no data (ThemePackStore.plainAdapters, validate's rule).
    @discardableResult
    static func check(_ loaded: @autoclosure () throws -> ThemePackStore.Loaded) throws -> ThemePackStore.Loaded {
        let pack: ThemePackStore.Loaded
        do { pack = try loaded() } catch let problem as ExtensionCatalogue.Problem { throw problem }
        catch { throw ExtensionCatalogue.Problem.notATheme("\(error)") }
        guard pack.pack.customMappings == nil else { throw ExtensionCatalogue.Problem.notATheme("it carries custom mappings") }
        guard ThemePackStore.plainAdapters(pack.pack) else {
            throw ExtensionCatalogue.Problem.notATheme("it carries adapter data")
        }
        return pack
    }

    /// Refuses an id Pilot's own themes, its built-in packs or the store's other root hold, which the store would refuse
    /// to load beside a library copy.
    public func refuseTaken(_ id: String) throws {
        guard ThemePack.validID(id) else { throw ExtensionCatalogue.Problem.notATheme("its id is not a pack id") }
        guard PilotTheme.named(id) == nil else { throw ExtensionCatalogue.Problem.themeTaken(id: id, why: "as one of its own themes") }
        for other in Set([store.root] + [store.factoryRoot].compactMap { $0 }) where other != store.writableRoot {
            var info = stat()
            guard lstat(other + "/" + id, &info) != 0, errno == ENOENT else {
                throw ExtensionCatalogue.Problem.themeTaken(id: id, why: other == store.factoryRoot ? "built in" : "in \(other)")
            }
        }
    }

    /// `work` while holding the library's lock, the one ThemePackStore.save takes, so an install never interleaves a save.
    private func locked<T>(_ work: () throws -> T) throws -> T {
        let fd = open(store.writableRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ExtensionCatalogue.Problem.failed("Pilot's theme folder \(store.writableRoot) could not be opened") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ExtensionCatalogue.Problem.failed("Pilot's theme folder could not be locked") }
        defer { flock(fd, LOCK_UN) }
        return try work()
    }
}
