import Foundation
import Observation
import PilotCore

/// The Raycast store's state (raycast-extensions T24), one for Hyper+Space's Raycast Store, the Extensions page's store and
/// `pilot ext store`: the listing (kept a day, RaycastStore), each picked folder's package.json, which folders are
/// installed, and each install while it runs, with why it failed. An install is T6's GitHub route itself
/// (ControlVerbs.installFromGitHub), with its same question and answer.
@MainActor @Observable
final class RaycastStoreModel {
    static let shared = RaycastStoreModel(source: RaycastStoreModel.source())

    /// GitHub, or in a test run PILOT_SANDBOX_RAYCAST_STORE's folder (RaycastStore.Source.standIn). A test run without it
    /// reads GitHub into its own cache folder, never Pilot's.
    static func source(environment: [String: String] = ProcessInfo.processInfo.environment) -> RaycastStore.Source {
        guard isTestRun, let folder = environment["PILOT_SANDBOX_RAYCAST_STORE"] else { return .live }
        return .standIn(URL(filePath: folder))
    }

    /// Where the listing stands: not asked yet, being read, read, or why it could not be (with none kept).
    enum Load: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var load: Load = .idle
    private(set) var listing: RaycastStore.Listing?
    /// Whether the listing shown came from the cache (true) or from GitHub at this open.
    private(set) var cached = false
    /// Why a read failed while an older listing is shown in its place.
    private(set) var stale: String?
    /// Each folder's package.json, once picked, and its icon file once fetched.
    private(set) var infos: [String: RaycastStore.Info] = [:]
    private(set) var icons: [String: String] = [:]
    /// Why a folder's package.json could not be read.
    private(set) var infoFailures: [String: String] = [:]
    /// The installed extensions, by id.
    private(set) var installed: [String: Extension] = [:]
    /// The folders installing now, and why one's last install failed.
    private(set) var busy: Set<String> = []
    private(set) var failures: [String: String] = [:]

    @ObservationIgnored let source: RaycastStore.Source
    @ObservationIgnored let extensions: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var infoReads: [String: Task<RaycastStore.Info?, Never>] = [:]

    init(source: RaycastStore.Source, extensions: URL = Extension.folder, now: @escaping () -> Date = { .now }) {
        self.source = source; self.extensions = extensions; self.now = now
    }

    /// The store looked at: a listing kept less than a day used, otherwise read from GitHub; the installed ones read
    /// again either way. A read already running is waited for, never started twice.
    func open() async {
        await readInstalled()
        let source = source
        if listing == nil, let (kept, reads) = await Task.detached(operation: { source.kept().map { ($0, source.keptInfos($0)) } }).value {
            show(kept, cached: true, reads)
        }
        if let listing, now().timeIntervalSince(listing.fetched) < RaycastStore.fresh { return }
        await read()
    }

    /// Hyper+Space's root search (T25): `extensions`, already read by the menu, as the installed ones, and the listing
    /// kept on disk once, never GitHub, so typing at the root asks no one.
    func openKept(installed extensions: [Extension]) async {
        installed = Dictionary(extensions.map { ($0.id, $0) }) { a, _ in a }
        guard listing == nil else { return }
        let source = source
        if let (kept, reads) = await Task.detached(operation: { source.kept().map { ($0, source.keptInfos($0)) } }).value, listing == nil {
            show(kept, cached: true, reads)
        }
    }

    /// The root search's store rows for `query` (RaycastStore.rootRows), from what is held now.
    func rootRows(_ query: String) -> [MenuEntry] {
        if compactedFor != listing?.fetched, let listing {
            compacted = Dictionary(listing.folders.map { ($0.name, RaycastStore.compact($0.name)) }) { a, _ in a }
            compactedFor = listing.fetched
        }
        return RaycastStore.rootRows(query, listing: listing, infos: infos, icons: icons, compacted: compacted,
                                     installed: { self.installedExtension($0) != nil })
    }

    /// Each listed folder's name as the root search compares it, for the listing read at `compactedFor`.
    @ObservationIgnored private var compacted: [String: String] = [:]
    @ObservationIgnored private var compactedFor: Date?

    /// Refresh: the listing read from GitHub whatever is kept.
    func refresh() async {
        await readInstalled()
        await read()
    }

    /// `listing` shown, with the infos kept for it that are not already read.
    private func show(_ listing: RaycastStore.Listing, cached: Bool, _ reads: [String: RaycastStore.Source.Read]) {
        self.listing = listing
        self.cached = cached
        for (name, read) in reads where infos[name]?.sha != read.info.sha { keep(name, read) }
        load = .loaded
    }

    private func keep(_ name: String, _ read: RaycastStore.Source.Read) {
        infos[name] = read.info
        icons[name] = read.icon
    }

    private func read() async {
        if let reading { return await reading.value }
        if listing == nil { load = .loading }
        let (source, now) = (source, now())
        let task = Task { @MainActor in
            do {
                let (fresh, reads) = try await Task.detached { let l = try await source.read(at: now); return (l, source.keptInfos(l)) }.value
                stale = nil
                show(fresh, cached: false, reads)
                dlog.notice("raycast store: listed \(fresh.folders.count) folders")
            } catch {
                let why = (error as? RaycastStore.Problem)?.reason ?? error.localizedDescription
                dlog.error("raycast store: not listed: \(why, privacy: .public)")
                if listing == nil { load = .failed(why) } else { stale = why }
            }
        }
        reading = task
        await task.value
        reading = nil
    }

    /// Which extensions the folder holds now, off the main thread.
    func readInstalled() async {
        let folder = extensions
        installed = await Task.detached { Dictionary(Extension.find(in: folder).extensions.map { ($0.id, $0) }) { a, _ in a } }.value
    }

    /// The listing's folders matching what was typed (RaycastStore.matches), A to Z.
    func folders(matching query: String) -> [RaycastStore.Folder] {
        (listing?.folders ?? []).filter { RaycastStore.matches($0, infos[$0.name], query: query) }
    }

    /// The installed extension a folder stands for: by its package.json's name once read, else by the folder's name.
    func installedExtension(_ folder: String) -> Extension? { installed[infos[folder]?.name ?? folder] }

    func title(_ folder: String) -> String { infos[folder]?.title ?? folder }

    /// The folder's icon file once fetched.
    func iconFile(_ folder: String) -> String? { icons[folder] }

    /// The folder's package.json: kept at its tree hash, else read now; one read per folder at a time. Nil when the
    /// folder is not listed or the read failed (why in `infoFailures`).
    @discardableResult
    func info(_ name: String) async -> RaycastStore.Info? {
        guard let folder = listing?.folder(name) else { return nil }
        if let info = infos[name], info.sha == folder.sha { return info }
        if let running = infoReads[name] { return await running.value }
        let source = source
        let task = Task { @MainActor () -> RaycastStore.Info? in
            do {
                let read = try await Task.detached { try await source.readInfo(folder) }.value
                keep(name, read)
                infoFailures[name] = nil
                return read.info
            } catch {
                infoFailures[name] = (error as? RaycastStore.Problem)?.reason ?? error.localizedDescription
                return nil
            }
        }
        infoReads[name] = task
        defer { infoReads[name] = nil }
        return await task.value
    }

    /// T6's install of a listed folder, `github:raycast/extensions/extensions/<folder>`, with its question and answer;
    /// `from` names the surface in Pilot's log. The installed ones are read again after, whatever happened.
    func install(_ folder: String, tools: ExtensionTools, peer: ControlPeer?, from: String) async throws(ControlError) -> JSONValue {
        guard listing?.folder(folder) != nil else {
            throw ControlError(.badValue, "no folder \(ControlGate.Ask.visible(folder)) in Raycast's store listing; pilot ext store lists them")
        }
        guard let github = GitHubInstall(RaycastStore.spec(folder), extensions: tools.extensions) else {
            throw ControlError(.badValue, "\(folder) is not a GitHub folder")
        }
        busy.insert(folder)
        failures[folder] = nil
        defer { busy.remove(folder) }
        let result: Result<JSONValue, ControlError>
        do { result = .success(try await ControlVerbs.installFromGitHub(github, tools, peer: peer, from: from)) } catch { result = .failure(error) }
        if case .failure(let error) = result { failures[folder] = error.message }
        await readInstalled()
        return try result.get()
    }

    /// Install from a press (the menu or the page): Allow asked on screen, then one HUD line.
    func installPressed(_ folder: String, from: String) async -> String {
        let title = title(folder)
        do {
            _ = try await install(folder, tools: ExtensionTools(), peer: nil, from: from)
            return "Installed \(title)."
        } catch {
            return "\(title) not installed: \(error.message)"
        }
    }
}
