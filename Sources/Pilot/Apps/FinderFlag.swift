import Foundation

/// Finder's hidden flag on an app (UF_HIDDEN, what `chflags hidden` sets), for Hidden apps (Pilot 1.0.2, Sven Q713):
/// only on an app in /Applications or ~/Applications, never on the sealed system volume or through a link, and never
/// with its owner or permissions changed. Foundation alone, so the sandbox proof compiles this file by itself.
enum FinderFlag {
    /// Where an app can hide besides Pilot's own lists.
    enum Reach: Equatable, Sendable {
        /// Part of macOS: in /System, or a link into it (/Applications/Safari.app). Pilot only.
        case builtIn
        /// In /Applications or ~/Applications: Finder hides it too.
        case finder
        /// Anywhere else, or a link (an app left in Downloads): Pilot only.
        case elsewhere
    }

    /// The rule InstallModule.systemAppBundles reads too: a path that resolves into /System is macOS's own.
    static func reach(_ url: URL, home: String = NSHomeDirectory()) -> Reach {
        let resolved = url.resolvingSymlinksInPath().path
        if resolved.hasPrefix("/System/") { return .builtIn }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return .elsewhere }
        let roots = ["/Applications", home + "/Applications"].map { URL(filePath: $0).resolvingSymlinksInPath().path + "/" }
        return roots.contains(where: resolved.hasPrefix) ? .finder : .elsewhere
    }

    /// Whether Finder hides the file now, read past Foundation's cache.
    static func isHidden(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
    }

    /// Sets or clears the flag and reads it back: nil once it holds, else why not, as a row says it.
    static func set(_ hidden: Bool, on url: URL) -> String? {
        var target = url
        var values = URLResourceValues()
        values.isHidden = hidden
        do { try target.setResourceValues(values) } catch {
            // Only the owner (or root) may set a file's flags: an App Store app belongs to root.
            let owner = (try? FileManager.default.attributesOfItem(atPath: url.path)[.ownerAccountName]) as? String
            if let owner, owner != NSUserName() { return "Finder's flag needs an admin, as \(owner) owns the app" }
            return "macOS refused Finder's flag (\(error.localizedDescription))"
        }
        return isHidden(url) == hidden ? nil : "macOS kept Finder's flag as it was"
    }
}
