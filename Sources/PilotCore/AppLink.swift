import Foundation

/// The actions the app picker and the presets make, named by what they open (stories 17 and 19): not in the registry,
/// rebuilt from the id whenever a bind runs one.
public enum AppLink: Equatable, Sendable {
    /// Launch or focus the app.
    case open(bundle: String)
    /// A page in its web app, else the default browser.
    case web(url: String)
    /// A page in one app, as Hammerspoon's "Claude.ai in Zen" did.
    case url(bundle: String, url: String)
    /// A new private window of a browser.
    case privateWindow(bundle: String)

    public init?(id: String) {
        func rest(_ prefix: String) -> String? { id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil }
        if let bundle = rest("apps.open:") { self = .open(bundle: bundle) }
        else if let url = rest("apps.web:") { self = .web(url: url) }
        else if let pair = rest("apps.url:"), let colon = pair.firstIndex(of: ":") {
            self = .url(bundle: String(pair[..<colon]), url: String(pair[pair.index(after: colon)...]))
        }
        else if let bundle = rest("apps.private:") { self = .privateWindow(bundle: bundle) }
        else { return nil }
    }

    public var id: String {
        switch self {
        case .open(let bundle): "apps.open:\(bundle)"
        case .web(let url): "apps.web:\(url)"
        case .url(let bundle, let url): "apps.url:\(bundle):\(url)"
        case .privateWindow(let bundle): "apps.private:\(bundle)"
        }
    }

    /// The command-line flag a running browser takes for a new private window: Firefox's family hands the flag to
    /// the instance holding the profile, Chromium's opens incognito. Nil for an app with no such flag.
    public static func privateFlag(bundle: String) -> String? {
        if ["app.zen-browser.zen", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "io.gitlab.librewolf-community"].contains(bundle) {
            return "--private-window"
        }
        if ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi"].contains(bundle) { return "--incognito" }
        return nil
    }
}
