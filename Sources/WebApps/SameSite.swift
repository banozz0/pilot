import Foundation

/// The Info.plist keys a stamped web app reads: written by WebAppSpec, read by the PilotWebApp template.
public enum WebAppKey {
    public static let url = "PilotURL"
    public static let dataStoreID = "PilotDataStoreID"
    public static let externalBrowser = "PilotExternalBrowser"
    public static let sameSiteHosts = "PilotSameSiteHosts"
}

/// Which links stay inside a web app: the site's host, its subdomains and the extra hosts; anything else
/// opens in the browser.
public struct SameSite: Sendable {
    let hosts: [String]

    public init(siteURL: URL, extraHosts: [String]) {
        hosts = ([siteURL.host ?? ""] + extraHosts).map(Self.normalized).filter { !$0.isEmpty }
    }

    public func contains(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }  // about:, data:, blob:
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Lowercased, `www.` dropped.
    public static func normalized(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
