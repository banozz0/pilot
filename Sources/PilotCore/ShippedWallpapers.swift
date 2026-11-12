import Foundation

/// The wallpapers of Pilot's shipped themes (Sven Q119, 2026-11-12): the app bundles each shipped pack palette-only,
/// and catalogue/themes/<id>/ carries the whole pack, same id, with its pictures. On Apply the catalogue copy is fetched
/// into `root/<id>`, every file held to the index's size and sha256, and kept only when it is the shipped pack with
/// wallpapers: its manifest the shipped one's but for `wallpapers`, its pictures whole images, its provenance there (it
/// loads as a factory pack). A copy fetched once is used offline after; none at all leaves the wallpaper as it is.
public struct ShippedWallpapers: Sendable {
    /// Where the fetched copies live, each in a folder named its id (ThemeSystem/wallpapers).
    public let root: String
    public let source: ExtensionCatalogue.Source
    let trash: @Sendable (URL) throws -> Void

    public init(root: String, source: ExtensionCatalogue.Source = .live, trash: @escaping @Sendable (URL) throws -> Void = FileOps.trashNow) {
        self.root = root; self.source = source; self.trash = trash
    }

    /// Whether `loaded` is a shipped pack whose pictures come from the catalogue: built in, naming no wallpaper.
    public static func wants(_ loaded: ThemePackStore.Loaded) -> Bool { loaded.factory && loaded.pack.wallpapers.isEmpty }

    /// `loaded` with the pictures of the copy fetched for it, when it wants them and that copy is its pack; else as it is.
    public func picturing(_ loaded: ThemePackStore.Loaded) -> ThemePackStore.Loaded {
        guard Self.wants(loaded), let copy = try? Self.load(loaded.pack.id, in: root), Self.matches(copy.pack, loaded.pack), !copy.images.isEmpty else { return loaded }
        return loaded.picturing(copy)
    }

    /// Fetches `theme`, the catalogue's copy of the shipped pack `shipped`, into `root/<id>` unless the copy there already
    /// holds its files; an older copy goes to the Trash. Throws a Problem, leaving the copy there as it was, when a file
    /// does not arrive or match, or what arrived is not `shipped` with pictures.
    public func fetch(_ theme: ExtensionCatalogue.Theme, for shipped: ThemePackStore.Loaded) async throws {
        let fm = FileManager.default, id = shipped.pack.id
        guard theme.id == id, Self.wants(shipped) else { throw ExtensionCatalogue.Problem.notATheme("it is not a shipped pack that takes pictures") }
        let target = URL(filePath: root, directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory)
        if fm.fileExists(atPath: target.path), ThemeInstaller.digest(of: target) == theme.digest { return }
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let stage = URL(filePath: root, directoryHint: .isDirectory).appending(path: ".pilot-fetch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: stage) }
        let temp = stage.appending(path: id, directoryHint: .isDirectory)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try await source.download(theme.files, from: "themes/\(id)", limit: ExtensionCatalogue.themeFileLimit, into: temp, mode: { _ in 0o644 }, progress: { _, _ in })
        let arrived = try ThemeInstaller.check(Self.load(id, in: stage.path))
        guard Self.matches(arrived.pack, shipped.pack) else { throw ExtensionCatalogue.Problem.notATheme("its manifest is not Pilot's own \(id) but for its wallpapers") }
        guard !arrived.images.isEmpty else { throw ExtensionCatalogue.Problem.notATheme("it has no wallpapers") }
        try Task.checkCancellation()
        let aside = stage.appending(path: "old", directoryHint: .isDirectory)
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: aside) }
        do { try fm.moveItem(at: temp, to: target) } catch {
            if fm.fileExists(atPath: aside.path) { try? fm.moveItem(at: aside, to: target) }
            throw error
        }
        // An older copy may hold the picture on a screen now: to the Trash, recoverable, never deleted; when the Trash
        // refuses, it stays beside the copies as a hidden folder rather than going with the stage.
        if fm.fileExists(atPath: aside.path) {
            do { try trash(aside) } catch {
                try? fm.moveItem(at: aside, to: URL(filePath: root, directoryHint: .isDirectory).appending(path: ".pilot-replaced-\(id)-\(UUID().uuidString)", directoryHint: .isDirectory))
            }
        }
    }

    /// The pack `id` in `folder` loaded as a shipped one, its provenance required; no user root, so a shipped id loads.
    static func load(_ id: String, in folder: String) throws -> ThemePackStore.Loaded {
        let none = folder + "/.none"
        return try ThemePackStore(root: none, writableRoot: none, factoryRoot: folder).load(id)
    }

    /// Whether `copy` is `shipped` but for its wallpapers (check.py's rule for a catalogue pack with a shipped id).
    public static func matches(_ copy: ThemePack, _ shipped: ThemePack) -> Bool {
        var same = copy
        same.wallpapers = shipped.wallpapers
        return same == shipped
    }
}
