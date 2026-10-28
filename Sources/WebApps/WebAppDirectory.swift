import Foundation

/// One web app Pilot stamped, as its Info.plist describes it.
public struct InstalledWebApp: Sendable, Identifiable, Equatable {
    /// What it was stamped from, read back, so a rebuild stamps the same app (card agent-bo-95422813).
    public let spec: WebAppSpec
    /// The bundle id its Info.plist carries, which a rebuild must keep.
    public let bundleID: String
    public let location: URL
    public var name: String { spec.name }
    public var url: URL { spec.url }
    public var id: String { bundleID }
}

/// The web apps Pilot stamped into a folder: Settings › Web apps lists and removes them, and a URL bind opens its
/// site's web app when one exists (stories 87 and 19).
public enum WebAppDirectory {
    /// Every app in `folder` whose bundle id is a Pilot web app's, by name.
    public static func list(in folder: URL = WebAppStamper.applicationsFolder) -> [InstalledWebApp] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "app" }.compactMap(read)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The web app whose site holds `url` (its host or a subdomain of it); the most specific site wins.
    public static func app(for url: URL, in folder: URL = WebAppStamper.applicationsFolder) -> InstalledWebApp? {
        guard url.host != nil else { return nil }
        return list(in: folder)
            .filter { SameSite(siteURL: $0.url, extraHosts: []).contains(url) }
            .max { ($0.url.host ?? "").count < ($1.url.host ?? "").count }
    }


    /// Moves anything to the Trash, where Finder can put it back, and returns where it went: Remove's web apps (their saved
    /// logins stay, so stamping the same site again finds them) and apps Homebrew did not install.
    public static func trash(_ url: URL) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return (trashed as URL?) ?? url
    }

    /// Read straight from Info.plist: Bundle caches by path, so a re-stamped app would show its old site.
    public static func read(_ app: URL) -> InstalledWebApp? {
        guard var plist = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, bundleID.hasPrefix(WebAppSpec.bundleIDPrefix) else { return nil }
        plist["CFBundleName"] = plist["CFBundleName"] ?? app.deletingPathExtension().lastPathComponent
        guard let spec = WebAppSpec(infoPlist: plist) else { return nil }
        return InstalledWebApp(spec: spec, bundleID: bundleID, location: app)
    }
}
