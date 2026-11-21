import Foundation

/// Installs, updates and removes catalogue extensions (2026-10-10, ADR 0010). An install fetches every file of the
/// entry into a temporary folder beside the Extensions folder (one volume, so the last step is a rename), each checked
/// against the index's size and sha256; the folder must then read as an Extension with the entry's id. Only then is
/// an installed copy with that id, in whatever folder, moved aside beside the temporary one and the new folder renamed
/// to `Extensions/<id>`; the copies aside go to the Trash after, or back where they were when that rename fails. A
/// file that does not match installs nothing. ExtensionData/<id> (preferences, data) and the Keychain are never touched,
/// so an update or a reinstall keeps its settings. Remove moves the folder to the Trash, recoverable.
public struct ExtensionInstaller: Sendable {
    /// The Extensions folder, the folder the temporary one is made in, where files come from, and the Trash.
    public let extensions: URL, staging: URL, source: ExtensionCatalogue.Source
    let trash: @Sendable (URL) throws -> Void

    public init(extensions: URL = Extension.folder, staging: URL? = nil, source: ExtensionCatalogue.Source = .live,
                trash: @escaping @Sendable (URL) throws -> Void = FileOps.trashNow) {
        self.extensions = extensions
        self.staging = staging ?? extensions.deletingLastPathComponent()
        self.source = source
        self.trash = trash
    }

    /// The catalogue's index, read now.
    public func index() async throws -> ExtensionCatalogue.Index {
        let data = try await source.fetch(ExtensionCatalogue.indexPath, ExtensionCatalogue.indexLimit)
        return try ExtensionCatalogue.index(data)
    }

    /// Installs `entry`, or updates the copy installed, and returns it as read from its new folder. `progress` hears
    /// each file fetched (done, of all). Throws a Problem, and leaves the Extensions folder as it was, when a file does
    /// not arrive or match, what arrived is not that extension, or a folder named its id holds something else.
    @discardableResult
    public func install(_ entry: ExtensionCatalogue.Entry, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Extension {
        _ = try replaced(entry.id)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let temp = staging.appending(path: ".extension-\(entry.id)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        try await source.download(entry.files, from: "extensions/\(entry.id)", limit: ExtensionCatalogue.fileLimit, into: temp,
                                  mode: { $0.executable ? 0o755 : 0o644 }, progress: progress)
        let arrived: Extension
        do { arrived = try Extension(folder: temp) }
        catch let problem as Extension.Problem { throw ExtensionCatalogue.Problem.notAnExtension(problem.reason) }
        guard arrived.id == entry.id else { throw ExtensionCatalogue.Problem.wrongID(found: arrived.id, expected: entry.id) }
        try Task.checkCancellation()
        // Asked again: the folder may have changed while the files came.
        let old = try replaced(entry.id)
        try fm.createDirectory(at: extensions, withIntermediateDirectories: true)
        // Renames on one volume: the old copies go aside, not to the Trash, until the new one is in place.
        let aside = staging.appending(path: ".extension-\(entry.id)-old-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: aside) }
        var moved: [(from: URL, to: URL)] = []
        let target = extensions.appending(path: entry.id)
        do {
            for (i, folder) in old.enumerated() {
                let to = aside.appending(path: "\(i)/\(folder.lastPathComponent)")
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: folder, to: to)
                moved.append((folder, to))
            }
            try fm.moveItem(at: temp, to: target)
        } catch {
            for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
            throw error
        }
        for (_, to) in moved { try? trash(to) }
        do { return try Extension(folder: target) }
        catch let problem as Extension.Problem { throw ExtensionCatalogue.Problem.notAnExtension(problem.reason) }
    }

    /// The folders an install of `id` replaces: the installed extension with that id, wherever it is, and a folder named
    /// `id` that reads as it. Throws when a folder named `id` holds another extension or none.
    func replaced(_ id: String) throws -> [URL] {
        let found = Extension.find(in: extensions)
        var folders = found.extensions.filter { $0.id == id }.map { $0.folder.resolvingSymlinksInPath() }
        let named = extensions.appending(path: id).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: named.path), !folders.contains(named) else { return folders }
        do {
            let other = try Extension(folder: named)
            guard other.id == id else { throw ExtensionCatalogue.Problem.folderTaken(id: id, why: "holds extension \"\(other.id)\"") }
            folders.append(named)
        } catch let problem as Extension.Problem {
            throw ExtensionCatalogue.Problem.folderTaken(id: id, why: "is not an extension (\(problem.reason))")
        }
        return folders
    }

    /// Moves the installed extension `id`'s folder to the Trash and returns its title; its data and settings stay.
    @discardableResult
    public func remove(_ id: String) throws -> String {
        guard let ext = Extension.find(in: extensions).extensions.first(where: { $0.id == id }) else {
            throw ExtensionCatalogue.Problem.notInstalled(id)
        }
        try trash(ext.folder)
        return ext.title
    }
}
