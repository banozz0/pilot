import Foundation
import Observation
import PilotCore

/// The Extensions page's state (card agent-bo-95423247): the folder read off the main thread as the page opens, each
/// extension's preference values with it, and an edit saved through ExtensionStorage as it changes (a password into the
/// Keychain).
@MainActor @Observable
final class ExtensionsSettings {
    private(set) var rows: [ExtensionsPage.Row] = []
    private(set) var broken: [Extension.Broken] = []
    /// Read once the first load finished, so the page can tell an empty folder from one not read yet.
    private(set) var loaded = false
    /// Update all runs, so a second press waits for it.
    private(set) var updatingAll = false
    /// Why the last save failed, shown under the field until the next edit.
    private(set) var failure: (field: String, message: String)?

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let storage: ExtensionStorage
    @ObservationIgnored private let label: @Sendable (String) -> String?
    /// Uninstall goes through the catalogue's model, so its card shows the remove in flight too; a test's is on its folder.
    @ObservationIgnored let catalogue: ExtensionCatalogueModel

    init(folder: URL = Extension.folder, storage: ExtensionStorage = ExtensionStorage(),
         label: @escaping @Sendable (String) -> String? = { id in MainActor.assumeIsolated { Engine.shared?.registry.actions[id]?.label } },
         catalogue: ExtensionCatalogueModel? = nil) {
        self.folder = folder; self.storage = storage; self.label = label
        self.catalogue = catalogue ?? .shared
    }

    /// Reads the folder and every extension's values again (a Keychain read per password preference), off the main thread.
    func load() async {
        let (folder, storage) = (folder, storage)
        let (found, values) = await Task.detached {
            let found = Extension.find(in: folder)
            return (found, Dictionary(uniqueKeysWithValues: found.extensions.map { ($0.id, storage.values(of: $0)) }))
        }.value
        rows = ExtensionsPage.rows(found, values: { values[$0.id] ?? [:] }, label: label)
        broken = found.broken
        loaded = true
        // The sidebar's extension pages follow an install or an uninstall (story 161).
        if folder == Extension.folder { ExtensionPages.shared.show(found.extensions) }
    }

    /// Saves `value` for `field` of the extension `row` shows, or clears it when nil, and shows the value a run gets now.
    func set(_ value: JSONValue?, for field: ExtensionsPage.Field, of row: ExtensionsPage.Row) {
        let key = "\(row.id).\(field.id)"
        do {
            try storage.set(value, for: field.preference, of: row.ext)
            if failure != nil { failure = nil }
        } catch {
            dlog.error("extension: \(row.id, privacy: .public) preference \(field.id, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
            failure = (key, "Not saved: \(error.localizedDescription)")
            return
        }
        // The store clears a password set empty, so the page shows none.
        let saved = field.preference.kind == .password && value == .string("") ? nil : value
        guard let r = rows.firstIndex(where: { $0.id == row.id }), let f = rows[r].fields.firstIndex(where: { $0.id == field.id }) else { return }
        rows[r].fields[f] = ExtensionsPage.Field(preference: field.preference, value: field.preference.resolved(saved))
    }

    /// Uninstall (story 158): the catalogue's remove (the folder to the Trash, its settings and data kept), then the folder
    /// read again. The HUD line it ended on; nil while that extension is busy already.
    func uninstall(_ row: ExtensionsPage.Row) async -> String? {
        let line = await catalogue.remove(row.id)
        await load()
        return line
    }

    /// Get or Update (pilot-1-1 T7): the catalogue's install, then the folder read again, so the row moves to Installed.
    /// The HUD line it ended on; nil while that extension is busy already.
    func install(_ entry: ExtensionCatalogue.Entry) async -> String? {
        let line = await catalogue.install(entry)
        await load()
        return line
    }

    /// Update all: `entries` one after another (each hashes and writes its files; two at once would race the folder's
    /// read), each row turning ✓ as it lands; one uninstalled meanwhile is skipped, never installed again. One HUD line
    /// for the lot; nil while Update all runs already, or when it updated none.
    func updateAll(_ entries: [ExtensionCatalogue.Entry]) async -> String? {
        guard !updatingAll, !entries.isEmpty else { return nil }
        updatingAll = true
        defer { updatingAll = false }
        var updated = 0, failed: [String] = []
        for entry in entries {
            // Uninstalled since the press: the folder read after the remove no longer holds it.
            guard catalogue.installed[entry.id] != nil else { continue }
            // Nil: its own Update was pressed meanwhile and says how it went.
            guard await install(entry) != nil else { continue }
            if catalogue.failures[entry.id] == nil { updated += 1 } else { failed.append(entry.title) }
        }
        guard updated + failed.count > 0 else { return nil }
        return ExtensionCatalogue.updatedAllLine(updated: updated, failed: failed)
    }

    /// The save failure under `field` of `row`, if the last save of it failed.
    func failure(of field: ExtensionsPage.Field, in row: ExtensionsPage.Row) -> String? {
        failure.flatMap { $0.field == "\(row.id).\(field.id)" ? $0.message : nil }
    }
}
