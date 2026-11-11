import Foundation
import OSLog
import PilotCore

private let favouriteLog = Logger(subsystem: "dev.banozz.pilot", category: "favourites")

/// The menu's favourites (Cmd+K, card agent-bo-95422968) by frecency key, read once and saved on every change; the menu
/// reads them as it opens, and Cmd+K and `pilot add favourites` change them one row at a time, so neither saves over the
/// other. A file that does not decode loads as none and is never saved over: a change says so.
@MainActor
final class FavouriteBook {
    static let shared = FavouriteBook(store: .standard)

    private(set) var rows: Set<String>

    private let store: FavouritesStore
    private let readable: Bool

    static let unreadable = "Pilot can not read favourites.json, so it saves nothing over it; fix or move that file."

    init(store: FavouritesStore) {
        self.store = store
        do {
            rows = try store.load()
            readable = true
        } catch {
            favouriteLog.error("favourites: \(store.url.path, privacy: .public) unreadable, \(String(describing: error), privacy: .public)")
            rows = []
            readable = false
        }
    }

    /// Makes `row` a favourite or not and saves; nil when done or nothing changed, else the line saying why not.
    @discardableResult func set(_ row: String, _ on: Bool) -> String? {
        guard readable else { return Self.unreadable }
        var changed = rows
        if on { changed.insert(row) } else { changed.remove(row) }
        guard changed != rows else { return nil }
        do { try store.save(changed) } catch {
            favouriteLog.error("favourites: not saved, \(error.localizedDescription, privacy: .public)")
            return "Pilot could not save favourites.json: \(error.localizedDescription)"
        }
        rows = changed
        return nil
    }

    /// A folder renamed or moved, including undo: its favourites and any pinned children keep pointing at it.
    func relocate(_ moves: [URL: URL]) -> String? {
        let changed = Set(rows.map { row in
            guard row.hasPrefix("file:") else { return row }
            let url = URL(filePath: String(row.dropFirst(5)))
            return "file:" + FileOps.relocated(url, by: moves).path
        })
        guard changed != rows else { return nil }
        guard readable else { return Self.unreadable }
        do { try store.save(changed) } catch { return "Folder moved, but favourites could not be updated: \(error.localizedDescription)" }
        rows = changed
        return nil
    }
}
