import AppKit
import Foundation
import Observation
import PilotCore

/// Look › Catalogue's state (public-repo-catalogue T22, Sven's variant C): the catalogue's theme packs from the index the
/// Extensions page keeps (ExtensionCatalogueModel, read ten minutes), where each stands in your themes, each tile's card
/// picture, and its Get, Update, Apply and Remove while they run. `pilot theme catalogue|get` read and install through it
/// too, so the command proves what the tab does. A pack is data: Get applies nothing; the theme in use is never updated
/// or removed (apply another or Restore default first), as `theme delete` refuses it.
@MainActor @Observable
final class ThemeCatalogueModel {
    static let shared = ThemeCatalogueModel()

    /// Where a catalogue theme stands: not in your themes, there as the catalogue has it, there with other files (an
    /// older copy or one you edited), or one of the themes Pilot ships, which is never installed or removed.
    enum Standing: Equatable {
        case get, installed, update, builtIn

        /// The command's word.
        var word: String {
            switch self {
            case .get: "install"
            case .installed: "installed"
            case .update: "update"
            case .builtIn: "built-in"
            }
        }

        /// The command's button: Extensions' words ("Install", "Installed", "Update"); "Built in" for a shipped one.
        var label: String {
            switch self {
            case .get: ExtensionCatalogue.Standing.install.label
            case .installed: ExtensionCatalogue.Standing.installed.label
            case .update: ExtensionCatalogue.Standing.update.label
            case .builtIn: "Built in"
            }
        }
    }

    /// The digest of each catalogue theme's pack in your themes, by id.
    private(set) var installed: [String: String] = [:]
    /// The catalogue themes Pilot ships, and those of them the app holds palette-only (Apply fetches their wallpapers).
    private(set) var builtIn: Set<String> = []
    private(set) var pictured: Set<String> = []
    /// The theme applied now, nil for none.
    private(set) var applied: String?
    /// The tiles working now, each with what it says ("Getting 2 of 5…"), and why a tile's last press failed.
    private(set) var busy: [String: String] = [:]
    private(set) var failures: [String: String] = [:]
    /// Each tile's card picture, made small as it shows and let go when the tab closes.
    private(set) var pictures: [String: NSImage] = [:]

    @ObservationIgnored let catalogue: ExtensionCatalogueModel
    @ObservationIgnored private var fetching: Set<String> = []

    init(catalogue: ExtensionCatalogueModel = .shared) { self.catalogue = catalogue }

    var load: ExtensionCatalogueModel.Load { catalogue.load }
    var themes: [ExtensionCatalogue.Theme] { catalogue.index?.themes ?? [] }

    /// The tab or the command looked: the index (kept or read again on `refresh`), then where each theme stands.
    func open(refresh: Bool = false) async {
        if refresh { await catalogue.refresh() } else { await catalogue.open() }
        await readInstalled()
    }

    /// Where each catalogue theme stands in your themes now, read off the main thread.
    func readInstalled() async {
        guard let owner = try? ThemeCoordinator.production() else { return }
        let installer = Self.installer(owner), store = owner.store, ids = themes.map(\.id)
        // Off the main thread, which runs the key tap: every installed file is hashed, and a pack's load decodes its pictures.
        (installed, builtIn, pictured) = await Task.detached {
            let builtIn = Set(ids.filter(installer.isBuiltIn))
            return (installer.installed(ids), builtIn, builtIn.filter { id in (try? store.load(id)).map(ShippedWallpapers.wants) == true })
        }.value
        applied = try? owner.appliedTheme().id
    }

    func standing(of theme: ExtensionCatalogue.Theme) -> Standing {
        if builtIn.contains(theme.id) { return .builtIn }
        return switch ExtensionCatalogue.standing(of: theme, installed: installed) {
        case .install: .get
        case .installed: .installed
        case .update: .update
        }
    }

    /// Why Get or Update of `theme` can't start, before anything is asked or fetched; nil when it can.
    func refusal(_ theme: ExtensionCatalogue.Theme) -> String? {
        guard let owner = try? ThemeCoordinator.production() else { return "Pilot's themes did not open." }
        // Its files are the applied theme's (wallpapers on the desktop now): replaced only once another is applied. A
        // ledger that does not read counts as applied, so nothing in use is replaced.
        let now: String?
        do { now = try owner.appliedTheme().id } catch { now = theme.id }
        if installed[theme.id] != nil, now == theme.id {
            return "\(theme.id) is the theme applied now: apply another or restore first, then update it."
        }
        // An id Pilot's own themes or another pack root hold is refused first, so nothing starts bound to fail.
        do { try Self.installer(owner).refuseTaken(theme.id) } catch {
            return ExtensionCatalogue.Problem.reason(error) + (builtIn.contains(theme.id) ? " Apply it to download its wallpapers." : "")
        }
        return nil
    }

    /// Installs `theme`, or replaces your pack with its id when `expecting` (its digest) still holds, its tile saying how
    /// far it got; throws the reason, which stays on the tile.
    @discardableResult
    func install(_ theme: ExtensionCatalogue.Theme, expecting: String?) async throws -> ThemePackStore.Loaded {
        let id = theme.id, verb = expecting == nil ? "Getting" : "Updating"
        guard busy[id] == nil else { throw ExtensionCatalogue.Problem.failed("\(id) is already \(busy[id] ?? "busy")") }
        let installer = Self.installer(try ThemeCoordinator.production())
        failures[id] = nil
        busy[id] = "\(verb)…"
        defer { busy[id] = nil }
        do {
            // Off the main thread, which runs the key tap: the files are hashed and written there.
            let loaded = try await Task.detached {
                try await installer.install(theme, expecting: expecting) { done, all in
                    Task { @MainActor in if self.busy[id] != nil { self.busy[id] = "\(verb) \(done) of \(all)…" } }
                }
            }.value
            looklog.notice("theme catalogue: \(id, privacy: .public) \(expecting == nil ? "installed" : "updated", privacy: .public)")
            await readInstalled()
            return loaded
        } catch {
            await readInstalled()
            throw failed(id, ExtensionCatalogue.Problem.reason(error), error)
        }
    }

    /// A tile's Get or Update: no Allow from Pilot's own window, as Extensions' Get; the HUD line it ended on.
    func get(_ theme: ExtensionCatalogue.Theme) async -> String {
        let had = installed[theme.id]
        if let why = refusal(theme) { return failed(theme.id, why) }
        do {
            let loaded = try await install(theme, expecting: had)
            return "\(loaded.pack.title) \(had == nil ? "is in your themes" : "updated"). Nothing applied."
        } catch {
            return "\(theme.title) was not \(had == nil ? "installed" : "updated"): \(ExtensionCatalogue.Problem.reason(error))"
        }
    }

    /// A tile's Apply: Look's one press (plan and apply, what changed shown after, Restore undoes it); the HUD line.
    func apply(_ id: String) async -> String {
        let look = Look.shared
        guard !look.themePressing else { return "A theme is being applied already." }
        look.themePressing = true
        busy[id] = "Applying…"
        failures[id] = nil
        defer { look.themePressing = false; busy[id] = nil }
        do {
            let result = try await ThemeCoordinator.production().press(id)
            look.endTrial(keep: false)
            await readInstalled()
            return themeOutcomeText(result)
        } catch { return failed(id, String(describing: error)) }
    }

    /// A tile's Remove: the downloaded pack out of your themes through `theme delete`'s rules (never Pilot's own, the
    /// applied one or one whose wallpaper is on screen); the HUD line.
    func remove(_ theme: ExtensionCatalogue.Theme) async -> String {
        guard installed[theme.id] != nil, !builtIn.contains(theme.id) else { return "\(theme.title) is not one you downloaded." }
        failures[theme.id] = nil
        do {
            try ThemeCoordinator.production().delete(theme.id)
            looklog.notice("theme catalogue: \(theme.id, privacy: .public) removed")
            await readInstalled()
            return "\(theme.title) removed from your themes. Get brings it back."
        } catch { return failed(theme.id, String(describing: error)) }
    }

    /// `why` kept on `id`'s tile until its next press; `why` back for the HUD.
    private func failed(_ id: String, _ why: String) -> String { failures[id] = why; return why }
    private func failed(_ id: String, _ why: String, _ error: any Error) -> any Error { failures[id] = why; return error }

    // MARK: Card pictures

    /// `theme`'s card picture: your copy's file when it is installed, else the one fetched before, else fetched now from
    /// the catalogue (its sha256 checked) into Pilot's cache; made small off the main thread. None leaves its desk on the
    /// palette alone.
    func picture(for theme: ExtensionCatalogue.Theme) async {
        guard pictures[theme.id] == nil, !fetching.contains(theme.id), let file = theme.picture,
              let owner = try? ThemeCoordinator.production() else { return }
        fetching.insert(theme.id)
        defer { fetching.remove(theme.id) }
        let own = Self.installer(owner).folder(theme.id)?.appending(path: file.path)
        let cached = Self.cache.appending(path: theme.id).appending(path: String(file.sha256.prefix(16)), directoryHint: .isDirectory)
        let source = CatalogueSource.live
        let made = await Task.detached { () -> NSImage? in
            let fm = FileManager.default
            var url = own.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
            if url == nil, fm.fileExists(atPath: cached.appending(path: file.path).path) { url = cached.appending(path: file.path) }
            if url == nil { url = try? await source.picture(of: theme, into: cached) }
            return url.flatMap { WallpaperScreen.thumbnail($0, size: 480) }
        }.value
        if let made { pictures[theme.id] = made }
    }

    /// The tab closed: its pictures go; the files stay cached.
    func close() { pictures = [:] }

    /// Where fetched card pictures are kept: Pilot's cache, a test run's own folder.
    private static let cache = isIsolatedTestRun ? PilotFolder.support.appending(path: "Caches/ThemeCatalogue", directoryHint: .isDirectory)
        : URL.cachesDirectory.appending(path: "dev.banozz.pilot/ThemeCatalogue", directoryHint: .isDirectory)

    /// The installer for your themes, reading the catalogue where the Extensions page does.
    static func installer(_ owner: ThemeCoordinator) -> ThemeInstaller { ThemeInstaller(store: owner.store, source: CatalogueSource.live) }
}
