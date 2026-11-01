import Foundation
import Observation

/// Hidden apps (Pilot 1.0.2, Sven Q713: "hide apps from everywhere on mac"), by bundle id, on Install › Hidden apps and
/// `pilot get|set apps.hidden`. Pilot's lists of installed apps leave them out at AppsModule's installedApps,
/// pickableApps and apps(opening:); a hidden app that runs still shows where running apps do, and its windows tile as
/// ever. macOS has no system-wide hide: an app in /Applications or ~/Applications gets Finder's flag too (FinderFlag), a
/// built-in one hides in Pilot alone, and Spotlight still finds every app. Pilot keeps the files it flagged, so Unhide
/// and Uninstall clear only its own flags, never one set by hand.
@Observable @MainActor
final class HiddenApps {
    /// The app's: the one store that writes Finder's flag. Every other store (a test's, a render's) flags nothing.
    static let shared = HiddenApps(flag: { FinderFlag.set($0, on: $1) })

    /// `pilot get|set` key.
    static let key = "apps.hidden"

    private(set) var bundles: Set<String>
    /// Bundle id → every app file Pilot set Finder's flag on: LaunchServices may hand back another copy of the same app
    /// (one in /Applications, one in ~/Applications) at a later reflag, and each copy's flag is Pilot's to clear.
    private(set) var flagged: [String: Set<String>]
    /// Why Finder's flag did not take, by bundle id, for this run's rows.
    private(set) var problems: [String: String] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let flag: @MainActor (Bool, URL) -> String?
    @ObservationIgnored private let locate: @MainActor (String) -> URL?

    init(defaults: UserDefaults = .pilot(), flag: @escaping @MainActor (Bool, URL) -> String? = { _, _ in "not this store's to set" },
         locate: @escaping @MainActor (String) -> URL? = AppsModule.url(forBundle:)) {
        self.defaults = defaults
        self.flag = flag
        self.locate = locate
        bundles = Set(defaults.stringArray(forKey: Self.listKey) ?? [])
        // A list per app; a single path is how the first 1.0.2 builds saved it.
        flagged = (defaults.dictionary(forKey: Self.flaggedKey) ?? [:]).compactMapValues { value in
            (value as? [String]).map(Set.init) ?? (value as? String).map { [$0] }
        }
    }

    func isHidden(_ bundle: String) -> Bool { bundles.contains(bundle) }

    /// `apps` without the hidden ones.
    func shown<App>(_ apps: [App], bundle: (App) -> String) -> [App] {
        bundles.isEmpty ? apps : apps.filter { !bundles.contains(bundle($0)) }
    }

    func hide(_ bundle: String) {
        guard bundles.insert(bundle).inserted else { return }
        flagInFinder(bundle)
        save()
    }

    /// Back in every list, and Finder's flag off when Pilot set it.
    func unhide(_ bundle: String) {
        guard bundles.remove(bundle) != nil else { return }
        problems[bundle] = nil
        flagged.removeValue(forKey: bundle)?.sorted().forEach(unflag)
        save()
    }

    /// The command's whole list: what left it is unhidden, what joined it hidden.
    func set(_ list: [String]) {
        let new = Set(list)
        bundles.subtracting(new).sorted().forEach(unhide)
        new.subtracting(bundles).sorted().forEach(hide)
    }

    /// Opening the page sets Finder's flag again where it fell off (an update replaces the app's file); never polled.
    func reflag() {
        for bundle in bundles.sorted() { flagInFinder(bundle) }
        save()
    }

    /// Uninstall: Finder shows every app Pilot hid there again; the list goes with Pilot's preferences.
    func clearFinderFlags() {
        flagged.values.flatMap { $0 }.sorted().forEach(unflag)
        flagged = [:]
        save()
    }

    /// A row of the page: the app, and where it hides as the row says it.
    struct Row: Identifiable, Equatable {
        let bundle: String
        let name: String
        let place: String
        var id: String { bundle }
    }

    func rows(name: (String) -> String?) -> [Row] {
        bundles.map { Row(bundle: $0, name: name($0) ?? $0, place: place($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static let both = "Pilot and Finder", builtIn = "Pilot only, a built-in app"

    private func place(_ bundle: String) -> String {
        guard let url = locate(bundle) else { return "Pilot only, not on this Mac now" }
        switch FinderFlag.reach(url) {
        case .builtIn: return Self.builtIn
        case .elsewhere: return "Pilot only, outside Applications"
        case .finder:
            if FinderFlag.isHidden(url) { return Self.both }
            return "Pilot only: \(problems[bundle] ?? "Finder shows it")"
        }
    }

    /// Finder's flag on an app in Applications that Finder still shows; one already hidden by hand stays Sven's.
    private func flagInFinder(_ bundle: String) {
        guard let url = locate(bundle), FinderFlag.reach(url) == .finder, !FinderFlag.isHidden(url) else { return }
        if let problem = flag(true, url) {
            problems[bundle] = problem
            alog.notice("hidden apps: \(bundle, privacy: .public) hides in Pilot only: \(problem, privacy: .public)")
        } else {
            problems[bundle] = nil
            flagged[bundle, default: []].insert(url.path)
        }
    }

    /// Clears the flag Pilot set at `path`, only while the path is still an app in Applications: never through a link it
    /// has become, nor on a file that moved out.
    private func unflag(_ path: String) {
        let url = URL(filePath: path)
        guard FinderFlag.reach(url) == .finder else {
            alog.notice("hidden apps: \(path, privacy: .public) is no longer an app in Applications; its flag is left")
            return
        }
        if let problem = flag(false, url) { alog.error("hidden apps: \(path, privacy: .public) kept Finder's flag: \(problem, privacy: .public)") }
    }

    private func save() {
        defaults.set(bundles.sorted(), forKey: Self.listKey)
        defaults.set(flagged.mapValues { $0.sorted() }, forKey: Self.flaggedKey)
    }

    private static let listKey = "hiddenApps", flaggedKey = "hiddenApps.flagged"
}
