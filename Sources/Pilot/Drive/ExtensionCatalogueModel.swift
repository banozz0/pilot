import Foundation
import Observation
import PilotCore

/// The extension catalogue's state (2026-10-10), shared by the Extensions page's one list (Q601) and the menu's Extension
/// catalogue: the index, read from GitHub only when one of them opens or Refresh is pressed and kept ten minutes; which
/// extensions are installed at which version, read from the Extensions folder each time; and each entry's install,
/// update or remove while it runs, with why it failed.
@MainActor @Observable
final class ExtensionCatalogueModel {
    static let shared = ExtensionCatalogueModel(installer: ExtensionInstaller(source: CatalogueSource.live))

    /// Where the index stands: not asked yet, being read, read, or why it could not be.
    enum Load: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var load: Load = .idle
    private(set) var index: ExtensionCatalogue.Index?
    private(set) var installed: [String: ExtensionCatalogue.Installed] = [:]
    /// The entries installing, updating or being removed now, each with what the page says ("Installing 2 of 3…").
    private(set) var busy: [String: String] = [:]
    /// Why an entry's last install, update or remove failed, shown on its card until the next try.
    private(set) var failures: [String: String] = [:]

    @ObservationIgnored let installer: ExtensionInstaller
    @ObservationIgnored private var kept = ExtensionCatalogue.Kept()
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date

    init(installer: ExtensionInstaller = ExtensionInstaller(), now: @escaping () -> Date = { .now }) {
        self.installer = installer; self.now = now
    }

    /// The catalogue looked at: the index read unless one read in the last ten minutes is kept, and the installed
    /// versions read again either way. A read already running is waited for, not started twice.
    func open() async {
        await readInstalled()
        if let fresh = kept.fresh(at: now()) {
            index = fresh
            load = .loaded
            return
        }
        await read()
    }

    /// Refresh: the index read again whatever is kept.
    func refresh() async {
        await readInstalled()
        await read()
    }

    private func read() async {
        if let reading { return await reading.value }
        load = .loading
        let installer = installer
        let task = Task { @MainActor in
            do {
                let index = try await Task.detached { try await installer.index() }.value
                for skipped in index.skipped {
                    dlog.error("catalogue: \(skipped.id, privacy: .public) skipped: \(skipped.reason, privacy: .public)")
                }
                kept.keep(index, at: now())
                self.index = index
                load = .loaded
                dlog.notice("catalogue: read \(index.entries.count) extensions")
            } catch {
                let why = ExtensionCatalogue.Problem.reason(error)
                dlog.error("catalogue: not read: \(why, privacy: .public)")
                load = .failed(why)
            }
        }
        reading = task
        await task.value
        reading = nil
    }

    /// Which extensions the folder holds now, off the main thread.
    func readInstalled() async {
        let folder = installer.extensions
        installed = await Task.detached { ExtensionCatalogue.installed(Extension.find(in: folder)) }.value
    }

    func standing(of entry: ExtensionCatalogue.Entry) -> ExtensionCatalogue.Standing {
        ExtensionCatalogue.standing(of: entry, installed: installed)
    }

    /// The entries `query` finds, all for a blank one; none before the index is read.
    func entries(_ query: String = "") -> [ExtensionCatalogue.Entry] { ExtensionCatalogue.search(index?.entries ?? [], query) }

    /// Installs or updates `entry`, its card saying how far it got; the HUD line it ended on, or nil when it was busy
    /// already. Its failure stays on its card.
    @discardableResult
    func install(_ entry: ExtensionCatalogue.Entry) async -> String? {
        guard busy[entry.id] == nil else { return nil }
        let updating = installed[entry.id] != nil
        let id = entry.id, verb = updating ? "Updating" : "Installing", installer = installer
        failures[id] = nil
        busy[id] = "\(verb)…"
        defer { busy[id] = nil }
        do {
            // Off the main thread, which runs the key tap: the files are hashed and written there.
            _ = try await Task.detached {
                try await installer.install(entry) { done, all in
                    Task { @MainActor in if self.busy[id] != nil { self.busy[id] = "\(verb) \(done) of \(all)…" } }
                }
            }.value
            dlog.notice("catalogue: \(entry.id, privacy: .public) \(updating ? "updated" : "installed", privacy: .public) at \(entry.version, privacy: .public)")
            await readInstalled()
            return ExtensionCatalogue.installedLine(entry, updated: updating)
        } catch {
            let why = ExtensionCatalogue.Problem.reason(error)
            dlog.error("catalogue: \(entry.id, privacy: .public) not installed: \(why, privacy: .public)")
            failures[entry.id] = why
            await readInstalled()
            return "\(entry.title) was not \(updating ? "updated" : "installed"): \(why)"
        }
    }

    /// Moves the installed extension `id` to the Trash, its settings kept; the HUD line it ended on, or nil when it was
    /// busy already.
    @discardableResult
    func remove(_ id: String) async -> String? {
        guard busy[id] == nil else { return nil }
        failures[id] = nil
        busy[id] = "Removing…"
        defer { busy[id] = nil }
        let installer = installer
        do {
            let title = try await Task.detached { try installer.remove(id) }.value
            dlog.notice("catalogue: \(id, privacy: .public) moved to the Trash")
            await readInstalled()
            return ExtensionCatalogue.removedLine(title)
        } catch {
            let why = ExtensionCatalogue.Problem.reason(error)
            dlog.error("catalogue: \(id, privacy: .public) not removed: \(why, privacy: .public)")
            failures[id] = why
            await readInstalled()
            return "Not removed: \(why)"
        }
    }
}
