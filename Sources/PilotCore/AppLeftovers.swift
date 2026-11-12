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

        /// The app at `url` from its Info.plist and those of the bundles in Contents (PlugIns, Library/LoginItems,
        /// Helpers, Library/LaunchServices); nil without a bundle id.
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
                       embedded: Array(Set(inner.filter { $0.lowercased().hasPrefix(id.lowercased() + ".") })).sorted())
        }

        var ids: [String] { [bundleID] + embedded }
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

    /// The places, under ~/Library, each with what an item at its top must be called to be the app's.
    enum Rule: Sendable { case idOrName, idPlist, idSavedState, idOrCookies, idOrInner, groupContainer, byHost, launchAgent }
    static let places: [(path: String, rule: Rule)] = [
        ("Application Support", .idOrName), ("Caches", .idOrName), ("Logs", .idOrName), ("WebKit", .idOrName),
        ("Preferences", .idPlist), ("Preferences/ByHost", .byHost), ("Saved Application State", .idSavedState),
        ("HTTPStorages", .idOrCookies), ("Containers", .idOrInner), ("Group Containers", .groupContainer), ("LaunchAgents", .launchAgent),
    ]

    /// ~/Library; in a test run the throwaway home's, so a sandbox host or a test never reads Sven's.
    public static let library = (isIsolatedTestRun ? PilotFolder.support.appending(path: "home", directoryHint: .isDirectory)
                                     : URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)).appending(path: "Library", directoryHint: .isDirectory)

    /// `app`'s leftovers under `library`, in the places' order, each matched against `others` (every other installed app).
    /// `size` measures each; nil leaves it unread.
    public static func find(_ app: App, others: [App], library: URL = library, size: ((URL) -> Int64?)? = nil) -> [Item] {
        places.flatMap { place -> [Item] in
            let folder = library.appending(path: place.path, directoryHint: .isDirectory)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
            return names.compactMap { name -> Item? in
                let url = folder.appending(path: name)
                guard FileOps.identity(of: url) != nil, !isLink(url), owns(app, name, place.rule, at: url) else { return nil }
                let other = others.first { $0.bundleID != app.bundleID && (owns($0, name, place.rule, at: url) || related($0, app)) }
                return Item(url: url, place: place.path, bytes: size?(url), sharedWith: other?.name)
            }
        }
    }

    /// Whether the item called `name` in a place with `rule` is `app`'s.
    static func owns(_ app: App, _ name: String, _ rule: Rule, at url: URL) -> Bool {
        let lower = name.lowercased(), ids = app.ids.map { $0.lowercased() }
        switch rule {
        case .idOrName: return ids.contains(lower) || lower == app.name.lowercased()
        case .idPlist: return ids.contains { lower == "\($0).plist" }
        case .byHost: return ids.contains { lower.hasPrefix("\($0).") && lower.hasSuffix(".plist") }
        case .idSavedState: return ids.contains { lower == "\($0).savedstate" }
        case .idOrCookies: return ids.contains { lower == $0 || lower == "\($0).binarycookies" }
        case .idOrInner: return ids.contains { lower == $0 }
        case .groupContainer: return ids.contains { ".\(lower).".contains(".\($0).") }
        case .launchAgent:
            guard lower.hasSuffix(".plist") else { return false }
            let stem = String(lower.dropLast(6))
            if ids.contains(where: { stem == $0 || stem.hasPrefix("\($0).") }) { return true }
            guard let job = plist(url) else { return false }
            let label = (job["Label"] as? String)?.lowercased() ?? ""
            if ids.contains(where: { label == $0 || label.hasPrefix("\($0).") }) { return true }
            let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first ?? ""
            return !app.path.isEmpty && program.hasPrefix(app.path.hasSuffix("/") ? app.path : app.path + "/")
        }
    }

    /// Two apps of one family (`com.x.App` and `com.x.App.beta`): what one leaves, the other may read.
    static func related(_ a: App, _ b: App) -> Bool {
        let x = a.bundleID.lowercased(), y = b.bundleID.lowercased()
        return x.hasPrefix(y + ".") || y.hasPrefix(x + ".")
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .uncached), data.count < 1_000_000 else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
