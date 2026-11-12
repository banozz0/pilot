import Foundation

/// What an app leaves in ~/Library once it is in the Trash (Sven, 2026-11-12, Q181): its folders and files in the
/// places macOS apps keep them, found by its bundle id (and its embedded helpers' and extensions') or its exact name, at
/// the top of each place only, never through a link. Never anything else in ~/Library, and never another app's: an item
/// another installed app could own (its id, a dot-relative of it, or its name matches) is listed unticked, "shared".
public enum AppLeftovers {
    /// An app as the finder reads it, before it goes to the Trash.
    public struct App: Sendable, Equatable {
        public let bundleID: String, name: String, path: String
        /// The bundle ids of the helpers and extensions inside it: their containers and preferences are its own too.
        public let embedded: [String]
        public init(bundleID: String, name: String, path: String, embedded: [String] = []) {
            self.bundleID = bundleID; self.name = name; self.path = path; self.embedded = embedded
        }

        /// The bundle id in the app's Info.plist, one file read: what Remove's quit step needs on the main thread.
        public static func bundleID(at url: URL) -> String? {
            (plist(url.appending(path: "Contents/Info.plist"))?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// The app at `url` from its Info.plist and those of the bundles in Contents (PlugIns, Library/LoginItems,
        /// Helpers, Library/LaunchServices, Frameworks); nil without a bundle id.
        public static func read(_ url: URL) -> App? {
            guard let info = plist(url.appending(path: "Contents/Info.plist")), let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
            let name = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
            let inner = ["PlugIns", "Library/LoginItems", "Helpers", "Library/LaunchServices", "Frameworks"].flatMap { folder in
                ((try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: "Contents/\(folder)").path)) ?? []).compactMap {
                    plist(url.appending(path: "Contents/\(folder)/\($0)/Contents/Info.plist"))?["CFBundleIdentifier"] as? String
                }
            }
            // A framework's id is its vendor's, shared by every app that embeds it: only those under the app's own id count.
            return App(bundleID: id, name: name, path: url.path(percentEncoded: false),
                       embedded: Set(inner.filter { isID($0, of: id) && $0.lowercased() != id.lowercased() }).sorted())
        }

        var ids: [String] { ([bundleID] + embedded).map { $0.lowercased() } }
    }

    /// One leftover: where it is, the place it is in, its size when read, and the other app it may belong to.
    public struct Item: Sendable, Equatable, Identifiable {
        public let url: URL, place: String
        public var bytes: Int64?
        /// Another installed app that matches it too: listed unticked.
        public let sharedWith: String?
        public var id: String { url.path(percentEncoded: false) }
        public var tickedFirst: Bool { sharedWith == nil }
        /// Where it is, short: "Library/Caches/<name>".
        public var shown: String { "Library/\(place)/\(url.lastPathComponent)" }
    }

    /// A place under ~/Library and what an item at its top must be called to be an app's: one of its ids with one of
    /// `endings`, or its exact name where `byName`; ByHost's `<id>.<host>.plist`; a group container with an id inside its
    /// dotted name; a LaunchAgent named, labelled or tied to the app, or running a program inside it.
    struct Place: Sendable {
        enum Rule: Sendable { case endings([String]), byHost, groupContainer, launchAgent }
        let path: String, rule: Rule
        var byName = false
    }

    static let places: [Place] = [
        Place(path: "Application Support", rule: .endings([""]), byName: true), Place(path: "Caches", rule: .endings([""]), byName: true),
        Place(path: "Logs", rule: .endings([""]), byName: true), Place(path: "WebKit", rule: .endings([""]), byName: true),
        Place(path: "Preferences", rule: .endings([".plist"])), Place(path: "Preferences/ByHost", rule: .byHost),
        Place(path: "Saved Application State", rule: .endings([".savedstate"])), Place(path: "HTTPStorages", rule: .endings(["", ".binarycookies"])),
        Place(path: "Containers", rule: .endings([""])), Place(path: "Group Containers", rule: .groupContainer),
        Place(path: "LaunchAgents", rule: .launchAgent),
    ]
    /// The places' names, as `pilot help` lists them.
    public static let placeNames = places.map(\.path)

    /// ~/Library; in a test run the throwaway home's, so a sandbox host or a test never reads Sven's.
    public static let library = PilotFolder.home.appending(path: "Library", directoryHint: .isDirectory)

    /// `app`'s leftovers under `library`, in the places' order, each matched against `others` (every other installed app,
    /// its id and name enough). `size` measures each; nil leaves it unread.
    public static func find(_ app: App, others: [App], library: URL = library, size: ((URL) -> Int64?)? = nil) -> [Item] {
        let others = others.filter { $0.bundleID.lowercased() != app.bundleID.lowercased() }
        return places.flatMap { place -> [Item] in
            let folder = library.appending(path: place.path, directoryHint: .isDirectory)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
            return names.compactMap { name -> Item? in
                let url = folder.appending(path: name)
                let job = place.rule.isLaunchAgent ? launchJob(url) : nil
                guard owns(app, name, place, job: job), FileOps.identity(of: url) != nil, !isLink(url) else { return nil }
                let other = others.first { owns($0, name, place, job: job) || related($0, app) }
                return Item(url: url, place: place.path, bytes: size?(url), sharedWith: other?.name)
            }
        }
    }

    /// Whether the item called `name` in `place` is `app`'s; `job` is a LaunchAgent's plist, read once.
    static func owns(_ app: App, _ name: String, _ place: Place, job: LoginItems.Item?) -> Bool {
        let lower = name.lowercased(), ids = app.ids
        switch place.rule {
        case .endings(let endings):
            return ids.contains { id in endings.contains { lower == id + $0 } } || (place.byName && lower == app.name.lowercased())
        case .byHost: return lower.hasSuffix(".plist") && ids.contains { lower.hasPrefix("\($0).") }
        case .groupContainer: return ids.contains { ".\(lower).".contains(".\($0).") }
        case .launchAgent:
            guard lower.hasSuffix(".plist") else { return false }
            if ids.contains(where: { isID(String(lower.dropLast(6)), of: $0) }) { return true }
            guard let job else { return false }
            return ids.contains { isID(job.label, of: $0) || job.bundleID?.lowercased() == $0 } || (!app.path.isEmpty && job.appPath == app.path)
        }
    }

    /// `name` is `id` or one under it (`id.helper`), case aside.
    static func isID(_ name: String, of id: String) -> Bool {
        let name = name.lowercased(), id = id.lowercased()
        return name == id || name.hasPrefix(id + ".")
    }

    /// Two apps of one family (`com.x.App` and `com.x.App.beta`): what one leaves, the other may read.
    static func related(_ a: App, _ b: App) -> Bool { isID(a.bundleID, of: b.bundleID) || isID(b.bundleID, of: a.bundleID) }

    private static func launchJob(_ url: URL) -> LoginItems.Item? {
        read(url).flatMap { LoginItems.job($0, path: url.path(percentEncoded: false), kind: .agent) }
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func read(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000 else { return nil }
        return data
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        read(url).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    }
}

extension AppLeftovers.Place.Rule {
    var isLaunchAgent: Bool { if case .launchAgent = self { true } else { false } }
}
