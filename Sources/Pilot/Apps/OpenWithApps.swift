import AppKit
import PilotCore
import UniformTypeIdentifiers

/// The apps that open a file type, the good ones first (OpenWithRanking): what Open With… on a file suggests, and the
/// order Open with's page lists a kind's apps in. Each app's claims are read from its Info.plist as the list is asked for.
@MainActor
enum OpenWithApps {
    /// The apps last picked for each type, the newest first, a few each: Open With… suggests them after the default.
    static let recentKey = "openWithRecent"
    static let recentCount = 3

    /// `apps` split into the suggested (the default, the ones last picked for `type`, then the best claimers) and the rest
    /// by name; with no type (a link), only the default and the recent are suggested.
    static func split(_ apps: [URL], type: UTType?, ext: String?, main: URL?, defaults: UserDefaults = .pilot()) -> (suggested: [URL], others: [URL]) {
        var byID: [String: URL] = [:], order: [String] = []
        for app in apps {
            let id = Bundle(url: app)?.bundleIdentifier ?? app.path
            if byID[id] == nil { byID[id] = app; order.append(id) }
        }
        let scores = type.map { type in
            order.reduce(into: [String: Int]()) { $0[$1] = OpenWithRanking.score(byID[$1].flatMap { Bundle(url: $0)?.infoDictionary }, type: type, ext: ext) }
        } ?? [:]
        let mainID = main.map { Bundle(url: $0)?.bundleIdentifier ?? $0.path }
        let first = (mainID.map { [$0] } ?? []) + (type.map { recent(for: $0, defaults: defaults) } ?? [])
        let split = OpenWithRanking.split(order, scores: scores, first: first)
        let others = split.others.compactMap { byID[$0] }
            .sorted { AppsModule.appName(at: $0).localizedStandardCompare(AppsModule.appName(at: $1)) == .orderedAscending }
        return (split.suggested.compactMap { byID[$0] }, others)
    }

    static func recent(for type: UTType, defaults: UserDefaults = .pilot()) -> [String] {
        (defaults.dictionary(forKey: recentKey)?[type.identifier] as? [String]) ?? []
    }

    /// `bundle` picked for `type`: first among its recent.
    static func picked(_ bundle: String, for type: UTType, defaults: UserDefaults = .pilot()) {
        var all = defaults.dictionary(forKey: recentKey) ?? [:]
        let list = [bundle] + recent(for: type, defaults: defaults).filter { $0 != bundle }
        all[type.identifier] = Array(list.prefix(recentCount))
        defaults.set(all, forKey: recentKey)
    }

    /// A file's type, by its contents' type as the file system names it, else its extension; nil for a link.
    static func type(of url: URL) -> UTType? {
        guard url.isFileURL else { return nil }
        return (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
    }
}
