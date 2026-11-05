import AppKit
import OSLog
import PilotCore

private let menusLog = Logger(subsystem: "dev.banozz.pilot", category: "menus")

/// Every app's menu bar, kept so the menu lists a closed app's menu items (T41, Sven Q827): read as the app comes
/// forward, three seconds on so a launching app has built its menus, off the main thread, at most once per version a day,
/// and saved as SavedMenu keeps it. Nothing runs between activations; each activation's check is in memory but an app's
/// first this run, which reads its saved copy's date once. Apps no longer on this Mac lose theirs at launch and when the
/// menu looks for it. The log names bundle ids and counts, never a title.
@MainActor
final class MenuCache {
    static let shared = MenuCache()

    private let store = SavedMenuStore.standard
    /// Each app's saved copy by bundle id: its version and when it was read, nil for none; an app not in here yet has not
    /// been looked up this run.
    private var known: [String: (version: String, read: Date)?] = [:]
    /// The apps with a saved copy, listed at launch, so the menu knows without a disk read whether a closed app has one.
    private(set) var saved: Set<String> = []
    private var reading: Set<String> = []
    /// The process each app's `known` version was read from: an update relaunches the app, so the same process keeps it.
    private var versionPID: [String: pid_t] = [:]
    /// The saved copies the menu read this run, so a pause on a closed app's name decodes its file once.
    private var loaded: [String: SavedMenu] = [:]
    private var observer: NSObjectProtocol?
    /// What a read at activation found: the menu bar kept, none answering, or one in another language.
    private enum Read: Sendable { case items([MenuItemNode]), unread, foreign }

    /// Once, at launch: drops the copies of apps gone from this Mac, then reads each app as it comes forward.
    func start() {
        guard observer == nil, !isTestRun else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                  object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { MenuCache.shared.activated(app) }
        }
        let store = store
        Task {
            let (kept, gone) = await Task.detached(priority: .utility) { store.prune(installed: Self.installed) }.value
            saved.formUnion(kept)
            if !gone.isEmpty { menusLog.notice("saved menus: dropped \(gone.count) of apps no longer here") }
        }
    }

    /// Whether an app is on this Mac: LaunchServices finds it, outside the Trash, and its bundle is still on disk
    /// (LaunchServices remembers an app deleted a moment ago).
    nonisolated static func installed(_ bundle: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return false }
        return !url.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: url.path)
    }

    /// A closed app's saved menu bar, read off the main thread; nil when it has none, and dropped when the app is gone.
    func menu(of bundle: String) async -> SavedMenu? {
        guard saved.contains(bundle) else { return nil }
        if let menu = loaded[bundle] { return menu }
        let store = store
        let menu = await Task.detached(priority: .userInitiated) { () -> SavedMenu? in
            guard Self.installed(bundle) else { store.remove(bundle); return nil }
            return store.load(bundle)
        }.value
        if let menu { loaded[bundle] = menu } else { saved.remove(bundle); known[bundle] = .some(nil) }
        return menu
    }

    /// An app came forward: its menu bar is read when its saved copy is from another version or a day old, or it has none.
    /// The stamp check runs first, in memory: the same process with a copy under a day old reads nothing, Info.plist
    /// included; past it, the version is read off the main thread.
    private func activated(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier,
              !reading.contains(bundle), let url = app.bundleURL else { return }
        let pid = app.processIdentifier
        if case let stamp?? = known[bundle], versionPID[bundle] == pid, !SavedMenu.due(saved: stamp, version: stamp.version) { return }
        guard AXIsProcessTrusted() else { return }
        reading.insert(bundle)
        let store = store, name = app.localizedName ?? AppsModule.displayName(bundle)
        Task {
            defer { reading.remove(bundle) }
            let version = await Task.detached(priority: .utility) { Self.version(of: url) }.value
            versionPID[bundle] = pid
            if known[bundle] == nil {
                known[bundle] = await Task.detached(priority: .utility) { store.load(bundle).map { ($0.version, $0.read) } }.value
            }
            guard SavedMenu.due(saved: known[bundle] ?? nil, version: version) else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !app.isTerminated else { return }
            let started = Date()
            let read = await Task.detached(priority: .utility) { () -> Read in
                // The skips read English titles: a menu bar in another language is not kept (review round 1).
                let menus = AXMenuItems.menuTitles(pid: pid)
                guard !menus.isEmpty else { return .unread }
                guard SavedMenu.english(menus: menus) else { return .foreign }
                let skip = SavedMenu.skip(windowTitles: AXMenuItems.windowTitles(pid: pid), app: name)
                return .items(SavedMenu.kept(AXMenuItems.read(pid: pid, budget: 2, skip: skip)))
            }.value
            let items: [MenuItemNode]
            switch read {
            case .items(let read): items = read
            case .unread:
                known[bundle] = (version, .now)
                return menusLog.notice("saved menus: \(bundle, privacy: .public) menu bar did not answer, not kept")
            case .foreign:
                known[bundle] = (version, .now)
                return menusLog.notice("saved menus: \(bundle, privacy: .public) not English, not kept")
            }
            let count = SavedMenu.count(items)
            // A few items (an app still building its menus) never replace a good copy; the read counts as today's all the same,
            // so an app with a tiny menu bar is not read at every activation.
            guard count >= 5 else {
                known[bundle] = (version, .now)
                return menusLog.notice("saved menus: \(bundle, privacy: .public) gave \(count) items, not kept")
            }
            let menu = SavedMenu(bundle: bundle, version: version, read: .now, items: items)
            do {
                try await Task.detached(priority: .utility) { try store.save(menu) }.value
                known[bundle] = (version, menu.read)
                saved.insert(bundle)
                loaded[bundle] = nil
                menusLog.notice("saved menus: \(bundle, privacy: .public), \(count) items in \(Int(-started.timeIntervalSinceNow * 1000)) ms")
            } catch {
                // Counted as today's read too, so a full disk is not written at every activation.
                known[bundle] = (version, .now)
                menusLog.error("saved menus: \(bundle, privacy: .public) not saved, \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// An app's version and build from its Info.plist, as SavedMenu stamps them.
    nonisolated static func version(of app: URL) -> String {
        let info = Bundle(url: app)?.infoDictionary
        return [info?["CFBundleShortVersionString"], info?["CFBundleVersion"]].compactMap { $0 as? String }.joined(separator: " ")
    }
}
