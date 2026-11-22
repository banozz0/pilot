import AppKit
import Observation
import PilotCore

/// Launcher › More rows' two browser switches (spec launcher-best T9): bookmarks in Hyper+Space's search, on; history
/// behind `hist <words>`, off until switched on (Sven, Q328). `pilot set menu.bookmarks` and `menu.browserHistory` flip
/// the same.
@MainActor @Observable
final class BrowserSettings {
    static let shared = BrowserSettings()

    /// Off, the kept bookmark rows go too, so nothing of them stays in memory.
    var bookmarks: Bool {
        didSet {
            defaults.set(bookmarks, forKey: Self.bookmarksKey)
            if !bookmarks { Task { await BrowserReader.shared.forget() } }
        }
    }
    var history: Bool { didSet { defaults.set(history, forKey: Self.historyKey) } }
    @ObservationIgnored private let defaults: UserDefaults

    static let bookmarksKey = "menu.browserBookmarks", historyKey = "menu.browserHistory"

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        bookmarks = defaults.object(forKey: Self.bookmarksKey) as? Bool ?? true
        history = defaults.bool(forKey: Self.historyKey)
    }
}

/// Reads the browsers' bookmarks and history for Hyper+Space (spec launcher-best T9), only when the menu asks: bookmarks
/// as it opens, history at a `hist` search while history is switched on. The threat model:
/// - Another app's private record. Every browser's folder is read only under Full Disk Access, which Pilot never asks for
///   here: without it they are skipped. Safari's is TCC's; since macOS 27 Chrome's and Firefox's profiles under Application
///   Support are guarded too (Apple DTS: "This is an intentional change", developer forums thread 847030; build 2495's log:
///   sandboxd "checking kTCCServiceSystemPolicyAppDataDetailed for com.google.Chrome", then "Data Access Blocked" naming
///   Pilot, commit ca8ee1d). A browser whose app is gone is skipped: its folder is never read (`installed`).
/// - A running browser's lock. A SQLite file (History, History.db, places.sqlite) is never opened: it and its `-wal` and
///   `-journal` are copied (a clone on APFS) into a folder only this user reads, the copy queried, the folder removed at
///   once. Bookmarks' JSON and plist are read whole, as any reader does.
/// - Logs and stores. No title or address is logged: the menu logs counts, a pick of one privately, and Return opens it
///   through `open`, which logs nothing. A bookmark is a pick like any row, so one picked is kept in the ranking
///   (frecency.json, with the short query it was picked from) and can be a favourite; history pages are never a pick,
///   never a favourite and never cached. The bookmarks' rows live in this reader's memory, read again only when a file's
///   date or size changed.
/// - Isolated test runs read only `PILOT_SANDBOX_BROWSERS=<folder>` as the home (no Full Disk Access asked of it), and
///   nothing at all without it, so a sandbox never reads Sven's real profiles.
actor BrowserReader {
    static let shared = BrowserReader()

    /// Opens a browser page row's `apps.url:<browser>:<address>` in that browser (the default one when it is gone), logging
    /// nothing, unlike a bind's AppsModule.open: the address is another app's record. The browser's id, or nil.
    @MainActor static func open(_ id: String) -> String? {
        guard case .url(let bundle, let raw)? = AppLink(id: id), let url = URL(string: raw) else { return nil }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        return bundle
    }

    /// The home the browsers' files are under: the user's, or the sandbox's stand-in; nil reads nothing.
    nonisolated static func home() -> URL? {
        guard isIsolatedTestRun else { return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
        guard let folder = ProcessInfo.processInfo.environment["PILOT_SANDBOX_BROWSERS"], folder.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: folder, isDirectory: true)
    }

    /// The home to read from while the browsers' files may be read: only under Full Disk Access, as every family's is
    /// guarded (a sandbox's stand-in always); nil reads nothing.
    nonisolated static func readableHome() -> URL? {
        guard let home = home(), isIsolatedTestRun || FileIndex.hasFullDiskAccess() else { return nil }
        return home
    }

    /// Each bookmarks file's rows, by its path, with the date and size it was read at.
    private var kept: [String: (stamp: String, rows: [MenuEntry])] = [:]

    /// The browsers installed at the menu's last open; nil before the first.
    private var onMac: [BrowserBookmarks.Browser]?

    /// The known browsers whose app is on the Mac (LaunchServices by bundle id): one removed leaves its profile folder
    /// behind (Zen's, combined-10 build 3091), which is never read. An isolated run's stand-in is the seam's
    /// `Applications/<bundle id>`, as its host runs on a real Mac whose apps would decide.
    @MainActor static func installed() -> [BrowserBookmarks.Browser] {
        guard isIsolatedTestRun else {
            return BrowserBookmarks.browsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil }
        }
        guard let home = home() else { return [] }
        return BrowserBookmarks.browsers.filter { FileManager.default.fileExists(atPath: home.appending(path: "Applications/\($0.bundle)").path) }
    }

    /// Every browser's bookmarks as menu rows, a file read again only when it changed. Each address once per browser (a
    /// row's target is the browser and the address), however many of its profiles keep it, and none whose target a row
    /// in `listed` already has (an `apps.url:` bind of the same page), as the menu keys its rows by target.
    /// The switch is read first, past the one wait, so a read asked for before it went off and reaching the reader after
    /// forget() keeps nothing; one already reading finishes before forget() runs. The menu asks as it opens, switch on or
    /// off, so the browsers installed are looked up then, once, for `hist`'s reads too.
    func bookmarks(listed: Set<MenuEntry.Target> = []) async -> [MenuEntry] {
        let (on, browsers) = await MainActor.run { (BrowserSettings.shared.bookmarks, Self.installed()) }
        onMac = browsers
        guard on, let home = Self.readableHome() else { kept = [:]; return [] }
        var rows: [MenuEntry] = [], paths = Set<String>(), seen = listed
        for browser in browsers {
            for profile in BrowserBookmarks.profiles(browser, home: home) {
                let path = profile.bookmarks.path
                guard let stamp = Self.stamp(profile.bookmarks) else { kept[path] = nil; continue }
                paths.insert(path)
                if kept[path]?.stamp != stamp { kept[path] = (stamp, BrowserBookmarks.rows(Self.pages(browser, profile), browser: browser, kind: .bookmark)) }
                rows += (kept[path]?.rows ?? []).filter { seen.insert($0.target).inserted }
            }
        }
        // A profile gone since the last read leaves nothing kept.
        kept = kept.filter { paths.contains($0.key) }
        return Array(rows.prefix(BrowserBookmarks.bookmarkCap))
    }

    /// The bookmark rows kept, dropped when the switch goes off.
    func forget() { kept = [:] }

    /// The history pages `words` find in every browser's history, the last visited first; while history is off, only the
    /// row that says so. Read from copies, never kept; only the installed browsers' (as the menu last opened).
    func history(_ words: [String], on: Bool) async -> [MenuEntry] {
        guard on else { return [BrowserBookmarks.historyOff] }
        guard let home = Self.home() else { return [] }
        // Switched on without Full Disk Access: the row that opens its setting, as the Files view's does.
        guard isIsolatedTestRun || FileIndex.hasFullDiskAccess() else { return [BrowserBookmarks.historyNeedsAccess] }
        var browsers = onMac ?? []
        if onMac == nil { browsers = await MainActor.run { Self.installed() }; onMac = browsers }
        var found: [(page: BrowserBookmarks.Page, browser: BrowserBookmarks.Browser)] = []
        for browser in browsers {
            for profile in BrowserBookmarks.profiles(browser, home: home) {
                let pages = Self.copied(profile.history) { BrowserBookmarks.history(browser.family, copy: $0, words: words) } ?? []
                found += pages.map { ($0, browser) }
            }
        }
        found.sort { ($0.page.visited ?? .distantPast) > ($1.page.visited ?? .distantPast) }
        // Each page once per browser, at its last visit (two profiles, or a database's two rows for one address).
        var seen = Set<String>()
        found = found.filter { seen.insert($0.browser.bundle + " " + $0.page.url).inserted }
        return Array(found.flatMap { BrowserBookmarks.rows([$0.page], browser: $0.browser, kind: .history) }.prefix(BrowserBookmarks.historyCap))
    }

    /// A profile's bookmarks: Chromium's JSON, Safari's plist, Firefox's from a copy of its database.
    private static func pages(_ browser: BrowserBookmarks.Browser, _ profile: BrowserBookmarks.Profile) -> [BrowserBookmarks.Page] {
        switch browser.family {
        case .chromium: (try? Data(contentsOf: profile.bookmarks)).map(BrowserBookmarks.chromium) ?? []
        case .safari: (try? Data(contentsOf: profile.bookmarks)).map(BrowserBookmarks.safari) ?? []
        case .firefox: copied(profile.bookmarks, BrowserBookmarks.firefoxBookmarks) ?? []
        }
    }

    /// A file's date and size (with a database's `-wal`), what a cached read is kept by; nil when it is not there.
    private static func stamp(_ file: URL) -> String? {
        func one(_ url: URL) -> String? {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
        }
        guard let main = one(file) else { return nil }
        return ([main] + BrowserBookmarks.sidecars(of: file).compactMap(one)).joined(separator: " ")
    }

    /// `read` over a copy of the database at `file` and its sidecars, in a folder only this user reads, removed once read;
    /// nil when there is no such file or it does not copy.
    private static func copied<T>(_ file: URL, _ read: (URL) -> T) -> T? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return nil }
        let folder = manager.temporaryDirectory.appending(path: "pilot-browser-\(UUID().uuidString)", directoryHint: .isDirectory)
        do { try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) } catch { return nil }
        defer { try? manager.removeItem(at: folder) }
        let copy = folder.appending(path: "copy.sqlite")
        do { try manager.copyItem(at: file, to: copy) } catch { return nil }
        for (side, to) in zip(BrowserBookmarks.sidecars(of: file), BrowserBookmarks.sidecars(of: copy)) where manager.fileExists(atPath: side.path) {
            try? manager.copyItem(at: side, to: to)
        }
        return read(copy)
    }
}
