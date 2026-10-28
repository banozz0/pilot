import CryptoKit
import Foundation

public enum WebAppError: Error, Equatable {
    case badURL(String)
    case emptyName
    case stampFailed(String)
}

/// One site to stamp as a web app: what the stamped copy's Info.plist says (story 86).
public struct WebAppSpec: Sendable, Equatable {
    public static let bundleIDPrefix = "dev.banozz.pilot.webapp."
    /// The template's binary name; every stamped copy keeps it.
    public static let executable = "PilotWebApp"

    public var name: String
    public var url: URL
    /// Bundle id of the browser that opens links to other sites; nil means the default browser.
    public var externalBrowser: String?
    /// Extra host suffixes that count as the same site, e.g. twitter.com for x.com.
    public var sameSiteHosts: [String] = []

    public init(name: String, url: String) throws {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased()),
              let host = parsed.host, !host.isEmpty else { throw WebAppError.badURL(url) }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw WebAppError.emptyName }
        self.name = name
        self.url = parsed
    }

    /// Read back from a stamped app's Info.plist, the reverse of infoPlist(hasIcon:) (card agent-bo-95422813).
    public init?(infoPlist plist: [String: Any]) {
        guard let name = plist["CFBundleName"] as? String, let url = plist[WebAppKey.url] as? String,
              var spec = try? WebAppSpec(name: name, url: url) else { return nil }
        spec.externalBrowser = plist[WebAppKey.externalBrowser] as? String
        spec.sameSiteHosts = plist[WebAppKey.sameSiteHosts] as? [String] ?? []
        self = spec
    }

    /// The stamped app's icon, Contents/Resources/<iconName>.icns.
    public static let iconName = "AppIcon"

    /// The host lowercased, `www.` dropped, every non-alphanumeric run turned into `-`.
    public var hostSlug: String {
        SameSite.normalized(url.host ?? "").split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).joined(separator: "-")
    }

    public var bundleID: String { Self.bundleIDPrefix + hostSlug }

    /// What a web app cannot do, shown before it is built (story 87; SPEC.md, the Web apps line).
    /// Bitwarden's fill login types into a web app too (card agent-bo-95422814), so autofill is no limit (card agent-bo-95422994).
    public static let limits = ["No browser extensions", "Notifications only while the web app is running", "No passkeys"]
    public static let unverified = "Continue with Google is unverified."

    /// Fetches the page and suggests its name; the host's name when the page does not load.
    public static func suggestedName(for page: URL) async -> String {
        suggestedName(html: await SiteIcon.get(page).map { String(decoding: $0, as: UTF8.self) } ?? "", page: page)
    }

    /// The name the form fills in: the site's own short name (application-name, og:site_name), then the page
    /// title, then the host's first label capitalised.
    public static func suggestedName(html: String, page: URL) -> String {
        func meta(_ key: String) -> String? {
            html.matches(of: /(?i)<meta\b[^>]*>/).lazy.compactMap { tag -> String? in
                let attrs = SiteIcon.attributes(String(tag.output))
                return (attrs["name"] ?? attrs["property"])?.lowercased() == key ? attrs["content"] : nil
            }.first
        }
        let title = html.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/).map { String($0.1) }
        let found = [meta("application-name"), meta("og:site_name"), title].lazy
            .compactMap { $0.map(decoded)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let found { return found }
        let label = SameSite.normalized(page.host ?? "").split(separator: ".").first.map(String.init) ?? ""
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    static func decoded(_ s: String) -> String {
        [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")]
            .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// Derived from the bundle id, so a re-stamp opens the same WKWebsiteDataStore and keeps its logins.
    public var dataStoreID: UUID {
        var bytes = Array(SHA256.hash(data: Data(bundleID.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // name-based UUID version and variant bits
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public var appFileName: String { Self.safeFileName(name) + ".app" }

    /// A name Finder can hold: slashes and colons become dashes.
    static func safeFileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    public func infoPlist(hasIcon: Bool) -> [String: Any] {
        var plist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": Self.executable,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "26.0",
            "NSHighResolutionCapable": true,
            WebAppKey.url: url.absoluteString,
            WebAppKey.dataStoreID: dataStoreID.uuidString,
            WebAppKey.sameSiteHosts: sameSiteHosts,
        ]
        if hasIcon { plist["CFBundleIconFile"] = Self.iconName }
        if let externalBrowser { plist[WebAppKey.externalBrowser] = externalBrowser }
        return plist
    }
}
