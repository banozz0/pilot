import AppKit
import Foundation
import OSLog
import PilotCore
import ServiceManagement
import WebApps

private let ulog = Logger(subsystem: "dev.banozz.pilot", category: "uninstall")

/// One row of General › Uninstall… (Sven, 2026-10-23, Q423): files Pilot put on disk, moved to the Trash
/// together. Never another app's: ~/.config/ghostty, ~/.aerospace.toml and the configs Pilot edits are not listed.
struct UninstallItem: Identifiable, Equatable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case downloads, data, pilot
        var title: String {
            switch self {
            case .downloads: "Downloads"
            case .data: "Your data"
            case .pilot: "Pilot itself"
            }
        }
    }

    /// What the row is, which says its group, its tick and what the run does around it.
    enum Kind: Equatable, Sendable {
        /// A folder in Speech that is neither model Pilot knows: a leftover, trashed with nothing to tell.
        case dictation(SpeechChoice), voice, speech(String)
        case upscale, terminal, giphy, caches, clipboard, fileIndex, extensions, webApps, rest, pilot

        var id: String {
            switch self {
            case .dictation(let choice): "speech.\(choice.rawValue)"
            case .voice: "speech.kokoro"
            case .speech(let name): "speech.\(name)"
            default: String(describing: self)
            }
        }

        var group: Group {
            switch self {
            case .dictation, .voice, .speech, .upscale, .terminal, .giphy, .caches: .downloads
            case .clipboard, .fileIndex, .extensions, .webApps, .rest: .data
            case .pilot: .pilot
            }
        }
    }

    let kind: Kind
    let title: String
    let detail: String?
    /// What goes to the Trash.
    let urls: [URL]
    /// Measured but never trashed: the preferences plist, which goes through UserDefaults (cfprefsd holds it).
    var measured: [URL] = []
    var bytes: Int64 = 0

    var id: String { kind.id }
    var group: Group { kind.group }
    /// Ticked when the panel opens: what comes back by itself, the downloads and the file index.
    var tickedFirst: Bool { group == .downloads || kind == .fileIndex }
    /// The rest loses something that does not come back by itself, so Move to Trash asks once.
    var asks: Bool { !tickedFirst }
    /// A store Pilot holds open (the clipboard's database, extensions, settings): Pilot opens again after, so nothing
    /// it held writes into the Trash or back into its folder.
    var relaunches: Bool { [.clipboard, .extensions, .rest].contains(kind) }

    static func tickedFirst(_ items: [UninstallItem]) -> Set<String> { Set(items.filter(\.tickedFirst).map(\.id)) }
}

/// Where Pilot writes, so the `--list` proof can hand in a moved home.
struct UninstallPlaces: Sendable {
    static let bundleID = "dev.banozz.pilot"

    var support = PilotFolder.support
    var library = URL.libraryDirectory
    var applications = WebAppStamper.applicationsFolder
    /// Pilot.app, nil for a bare binary (`swift run`, the tests).
    var bundle: URL? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
    /// The pilot command's link, General's button's (CommandLineLink).
    var commandLink = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/pilot")
}

enum Uninstall {
    /// What Pilot put on disk, each row only when something of it is there, in the panel's order. Folder names come
    /// from their stores where those are readable off the main actor; Speech, kokoro, the databases and the socket
    /// belong to main-actor types, so they are spelled here.
    nonisolated static func inventory(_ places: UninstallPlaces = UninstallPlaces()) -> [UninstallItem] {
        let fm = FileManager.default, support = places.support, id = UninstallPlaces.bundleID
        func inSupport(_ store: URL) -> URL { support.appending(path: store.lastPathComponent) }
        var items: [UninstallItem] = []
        func add(_ kind: UninstallItem.Kind, _ title: String, _ detail: String?, _ urls: [URL], measured: [URL] = []) {
            let urls = urls.filter(exists), measured = measured.filter(exists)
            guard !urls.isEmpty || !measured.isEmpty else { return }
            items.append(UninstallItem(kind: kind, title: title, detail: detail, urls: urls, measured: measured))
        }

        // Children are named from their parent: a listing hands back the resolved path (/private/tmp), which no
        // longer reads as under the home.
        let speech = support.appending(path: "Speech")
        let models = ((try? fm.contentsOfDirectory(at: speech, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted()
        for name in models {
            let folder = [speech.appending(path: name)]
            if name == "kokoro" { add(.voice, "Voice model", "Kokoro", folder) }
            else if let choice = SpeechChoice(rawValue: name) { add(.dictation(choice), "Dictation model", choice.name, folder) }
            else { add(.speech(name), "Speech model", name, folder) }
        }
        let upscale = inSupport(UpscaleModels.folder), giphy = inSupport(Giphy.cache)
        add(.upscale, "Upscale model", "Max quality", [upscale])
        // The terminal pack (T76): libghostty, downloaded on the first Hyper+T; the one Pilot has mapped stays until it quits.
        let terminal = inSupport(TerminalPack.folder)
        add(.terminal, "Terminal", "Ghostty for Hyper+T, downloaded again on its next press", [terminal])
        add(.giphy, "GIF cache", "GIFs picked from GIPHY", [giphy])
        add(.caches, "Caches", nil, [places.library.appending(path: "Caches/\(id)")])

        let clipboard = ["clipboard.sqlite", "image-text.sqlite"].flatMap { [$0, "\($0)-wal", "\($0)-shm"] }.map { support.appending(path: $0) }
        let index = support.appending(path: "files.cache")
        let extensions = [inSupport(Extension.folder), inSupport(ExtensionStorage.dataFolder)]
        add(.clipboard, "Clipboard history", "Items and image text", clipboard)
        add(.fileIndex, "File index", "Built again at the next file search", [index])
        add(.extensions, "Extensions and their data", nil, extensions)
        let webApps = WebAppDirectory.list(in: places.applications).map { places.applications.appending(path: $0.location.lastPathComponent) }
        add(.webApps, "Web apps", "\(webApps.count) \(webApps.count == 1 ? "app" : "apps") in ~/Applications", webApps)
        // The rest of Pilot's folder: binds, settings, reports, notes, snapshots. The socket stays: the pilot command
        // talks over it until Pilot quits.
        let claimed = Set(([speech, upscale, terminal, giphy, index, support.appending(path: "pilot.sock")] + clipboard + extensions).map(\.lastPathComponent))
        // Speech's own files beside the models (the words dictation was taught, DictationWords) go with the rest.
        let speechFiles = ((try? fm.contentsOfDirectory(at: speech, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .map(\.lastPathComponent).sorted().map { speech.appending(path: $0) }
        let rest = ((try? fm.contentsOfDirectory(atPath: support.path(percentEncoded: false))) ?? [])
            .filter { !claimed.contains($0) }.sorted().map { support.appending(path: $0) } + speechFiles
        add(.rest, "Binds, settings and reports", "Everything else in Pilot's folder, and its preferences", rest,
            measured: [places.library.appending(path: "Preferences/\(id).plist")])

        let link = (try? fm.destinationOfSymbolicLink(atPath: places.commandLink.path(percentEncoded: false)))
            .flatMap { CommandLineLink.isPilots($0) ? places.commandLink : nil }
        add(.pilot, "Pilot.app, login item and the pilot command", "Quits Pilot when done",
            [places.bundle, link].compactMap { $0 } + ["HTTPStorages/\(id)", "WebKit/\(id)", "Saved Application State/\(id).savedState"]
                .map { places.library.appending(path: $0) })
        return items
    }

    /// The rows with their sizes, read off the main thread.
    nonisolated static func measured(_ places: UninstallPlaces = UninstallPlaces()) -> [UninstallItem] {
        inventory(places).map { item in
            var item = item
            item.bytes = (item.urls + item.measured).reduce(0) { $0 + bytes($1) }
            return item
        }
    }

    /// Space on disk under `url`; a link counts as nothing, and is never followed.
    nonisolated static func bytes(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Each URL to the Trash through `trash`; the ones that would not go, with why.
    nonisolated static func trash(_ items: [UninstallItem], using trash: (URL) throws -> Void) -> [String] {
        items.flatMap(\.urls).compactMap { url in
            do { try trash(url); return nil } catch {
                return "\(AppConfigs.tilde(url.path(percentEncoded: false), home: NSHomeDirectory())): \(error.localizedDescription)"
            }
        }
    }

    /// Whether anything is at `url`, a link counted as itself.
    private nonisolated static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }
}

/// The panel's state: the rows as they measure, the ticks, and the run.
@Observable @MainActor
final class UninstallModel {
    enum Phase: Equatable { case measuring, ready, confirming, working, failed([String]) }

    private(set) var items: [UninstallItem] = []
    var ticked: Set<String> = []
    private(set) var phase = Phase.measuring

    @ObservationIgnored private let measure: @Sendable () -> [UninstallItem]
    /// To the Trash; the proof hands in a move into a temporary folder, never ~/.Trash.
    @ObservationIgnored private let move: @Sendable (URL) throws -> Void
    @ObservationIgnored private let live: UninstallLive

    init(measure: @escaping @Sendable () -> [UninstallItem] = { Uninstall.measured() },
         move: @escaping @Sendable (URL) throws -> Void = { _ = try WebAppDirectory.trash($0) }, live: UninstallLive = UninstallLive()) {
        self.measure = measure
        self.move = move
        self.live = live
    }

    /// Rows already measured, as the renders hand them in: nothing is read, and a run touches nothing live.
    convenience init(items: [UninstallItem], phase: Phase = .ready) {
        self.init(measure: { items }, live: .none)
        show(items)
        self.phase = phase
    }

    func load() async {
        guard phase == .measuring else { return }
        let measure = measure
        show(await Task.detached(priority: .userInitiated) { measure() }.value)
    }

    private func show(_ items: [UninstallItem]) {
        self.items = items
        ticked = UninstallItem.tickedFirst(items)
        phase = .ready
    }

    var chosen: [UninstallItem] { items.filter { ticked.contains($0.id) } }
    var total: Int64 { chosen.reduce(0) { $0 + $1.bytes } }

    func toggle(_ id: String) {
        guard phase == .ready || phase == .confirming else { return }
        if ticked.remove(id) == nil { ticked.insert(id) }
        phase = .ready
    }

    /// Move to Trash: once more to confirm when the ticks hold your data or Pilot itself.
    func moveToTrash(close: @escaping () -> Void) async {
        let chosen = chosen
        guard !chosen.isEmpty, phase == .ready || phase == .confirming else { return }
        if phase == .ready, chosen.contains(where: \.asks) { phase = .confirming; return }
        phase = .working
        live.before(chosen)
        let move = move
        let failures = await Task.detached(priority: .userInitiated) { Uninstall.trash(chosen, using: move) }.value
        live.after(chosen)
        ulog.notice("uninstall: \(chosen.map(\.id).joined(separator: ", "), privacy: .public) to the Trash, \(failures.count) failed")
        for failure in failures { ulog.error("uninstall: \(failure, privacy: .public)") }
        if failures.isEmpty { end(close: close) } else { phase = .failed(failures) }
    }

    /// Done after a failure, or the run's own end: Pilot quits with itself gone, or opens again when a store it held went.
    /// The ticks cannot change once the run starts, so they still say which.
    func end(close: () -> Void) {
        close()
        if chosen.contains(where: { $0.group == .pilot }) { live.quit() } else if chosen.contains(where: \.relaunches) { live.relaunch() }
    }
}

/// What a run does to the running Pilot around the Trash; the renders hand in one that does nothing.
struct UninstallLive {
    var before: @MainActor ([UninstallItem]) -> Void = UninstallLive.stop
    var after: @MainActor ([UninstallItem]) -> Void = UninstallLive.forget
    var relaunch: @MainActor () -> Void = { PermissionDragPanel.relaunch(for: "uninstall") }
    var quit: @MainActor () -> Void = { NSApp.terminate(nil) }

    static let none = UninstallLive(before: { _ in }, after: { _ in }, relaunch: {}, quit: {})

    /// Nothing reads a model while it goes: the take, downloads, prepares and Read aloud stop. The file index helper
    /// ends without saving, and the login item goes while the bundle is still where it was registered from. Finder's
    /// hidden flags Pilot set (Hidden apps) come off with its settings or with Pilot.
    @MainActor static func stop(_ items: [UninstallItem]) {
        for item in items {
            switch item.kind {
            case .dictation(let choice):
                if SpeechModels.shared.active?.choice == choice { PilotDictation.shared.cancel() }
                SpeechModels.shared.model(choice).cancel()
            case .voice:
                if ReadAloud.shared.isBusy { ReadAloud.shared.stop() }
                KokoroModel.shared.cancel()
            case .fileIndex: FileIndex.shared.discard()
            // Finder shows the apps Pilot hid there again before the list goes with the preferences, or Pilot with it.
            case .rest: HiddenApps.shared.clearFinderFlags()
            case .pilot:
                HiddenApps.shared.clearFinderFlags()
                do { try SMAppService.mainApp.unregister() } catch { ulog.error("uninstall: login item: \(error.localizedDescription, privacy: .public)") }
            default: break
            }
        }
    }

    /// The models read their folders again, now gone; the preferences go with the rest of Pilot's folder.
    @MainActor static func forget(_ items: [UninstallItem]) {
        for item in items {
            switch item.kind {
            case .dictation(let choice): SpeechModels.shared.refresh(choice)
            case .voice: KokoroModel.shared.refresh()
            case .rest: UserDefaults.pilot().removePersistentDomain(forName: UninstallPlaces.bundleID)
            default: break
            }
        }
    }
}
