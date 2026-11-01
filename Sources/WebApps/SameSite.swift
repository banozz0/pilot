import Foundation

/// The Info.plist keys a stamped web app reads: written by WebAppSpec, read by the PilotWebApp template.
public enum WebAppKey {
    public static let url = "PilotURL"
    public static let dataStoreID = "PilotDataStoreID"
    public static let externalBrowser = "PilotExternalBrowser"
    public static let sameSiteHosts = "PilotSameSiteHosts"
    /// The SHA-256 of the template the app was stamped from, so Pilot knows which apps an update has not reached yet.
    public static let template = "PilotTemplate"
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

/// Where a web app sends a URL its page asks for: this window, a popup window of the app, or the browser.
public enum WebAppRoute: Sendable, Equatable {
    case here, popup, browser
}

/// Sign-in stays in the web app (bug 2026-11-01: Messenger's Facebook verify went to Chrome, so the login landed in
/// Chrome's cookies, not the web app's store). The rule: a sign-in page always opens in the app, and every other page
/// of its host still goes to the browser.
extension SameSite {
    /// A web app's own same site: the stamped hosts plus the sites it is known to share an account or a move with.
    /// Only the template uses it; which web app a URL bind opens still goes by the site's own host.
    public static func forWebApp(siteURL: URL, extraHosts: [String]) -> SameSite {
        SameSite(siteURL: siteURL, extraHosts: extraHosts + pairs(for: siteURL))
    }

    /// Messenger signs in and verifies on Facebook (fbcdn.net and fbsbx.com serve its media and attachments); X and
    /// Threads moved domains. The cost: a facebook.com link inside Messenger opens in Messenger.
    static let pairs: [String: [String]] = [
        "messenger.com": ["facebook.com", "fbcdn.net", "fbsbx.com"],
        "x.com": ["twitter.com"], "twitter.com": ["x.com"],
        "threads.com": ["threads.net"], "threads.net": ["threads.com"],
    ]

    static func pairs(for site: URL) -> [String] {
        let host = normalized(site.host ?? "")
        return pairs.filter { host == $0.key || host.hasSuffix("." + $0.key) }.flatMap(\.value)
    }

    /// Hosts that only sign people in: Google, Apple, Microsoft (work and personal), Atlassian.
    static let signInHosts: Set = ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com", "id.atlassian.com"]
    /// Single sign-on, one subdomain per company (acme.okta.com).
    static let signInDomains = ["okta.com", "auth0.com", "onelogin.com"]
    /// The sign-in paths of hosts that serve everything else too, and their subdomains (m.facebook.com). Facebook's
    /// are unverified past /login and /dialog/oauth; Instagram signs Threads in; Slack signs other apps in.
    static let signInPaths: [String: [String]] = [
        "github.com": ["/login", "/session", "/sessions"],
        "facebook.com": ["/login", "/dialog/oauth", "/checkpoint", "/two_step_verification"],
        "instagram.com": ["/accounts/login", "/oauth"],
        "slack.com": ["/signin", "/openid", "/oauth"],
    ]

    public static func isSignIn(_ url: URL) -> Bool {
        let host = normalized(url.host ?? "")
        if signInHosts.contains(host) || signInDomains.contains(where: { host.hasSuffix("." + $0) }) { return true }
        let path = url.path.replacing(/^\/v\d+(\.\d+)?(?=\/)/, with: "")  // Facebook's versioned /v19.0/dialog/oauth
        return signInPaths.contains { site, paths in
            (host == site || host.hasSuffix("." + site)) && paths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    public func keepsInApp(_ url: URL) -> Bool { contains(url) || Self.isSignIn(url) }

    /// `click` is a clicked link, never a redirect, form or script; `newWindow` a target=_blank link or window.open,
    /// `sized` a window.open that asked for a size. A link or new window elsewhere leaves for the browser; a script's
    /// window to a sign-in page, or a blank one it fills in later, becomes a popup, so its opener gets the result.
    public func route(_ url: URL, click: Bool, newWindow: Bool = false, sized: Bool = false) -> WebAppRoute {
        if newWindow && (sized || !click && (url.host == nil || Self.isSignIn(url))) { return .popup }
        return (click || newWindow) && !keepsInApp(url) ? .browser : .here
    }
}

/// A popup the page opened: once it has been on a sign-in page or another site and finishes back on the site, the
/// flow is over and it closes itself, so the opener carries on with the result. A popup that never left stays open.
public struct SignInTrip: Sendable {
    let site: SameSite
    public private(set) var wentAway = false

    public init(site: SameSite) { self.site = site }

    public mutating func visit(_ url: URL) {
        if url.host != nil && !isHome(url) { wentAway = true }
    }

    public func isOver(at url: URL) -> Bool { wentAway && isHome(url) }

    func isHome(_ url: URL) -> Bool { url.host != nil && site.contains(url) && !SameSite.isSignIn(url) }
}
